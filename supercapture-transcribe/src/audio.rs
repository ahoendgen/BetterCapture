use anyhow::{Context, Result};
use rubato::{FftFixedIn, Resampler};
use std::path::Path;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

const TARGET_SAMPLE_RATE: u32 = 16_000;
const RESAMPLER_CHUNK_SIZE: usize = 1024;

/// Reads an audio file in chunks, resamples to 16kHz mono f32.
/// Supports WAV, M4A/AAC, and other formats via symphonia.
pub struct ChunkedAudioReader {
    samples: Vec<f32>,
    position: usize,
    input_sample_rate: u32,
    channels: u16,
    /// Samples per chunk at the input sample rate (per channel)
    chunk_size_samples: usize,
    pub total_chunks: usize,
    chunks_read: usize,
}

impl ChunkedAudioReader {
    pub fn open(path: &Path, chunk_duration_secs: f64) -> Result<Self> {
        let file = std::fs::File::open(path).context("failed to open audio file")?;
        let mss = MediaSourceStream::new(Box::new(file), Default::default());

        let mut hint = Hint::new();
        if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            hint.with_extension(ext);
        }

        let probed = symphonia::default::get_probe()
            .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
            .context("failed to probe audio format")?;

        let mut format = probed.format;

        let track = format
            .default_track()
            .context("no audio track found")?
            .clone();

        let sample_rate = track
            .codec_params
            .sample_rate
            .context("unknown sample rate")?;

        let mut decoder = symphonia::default::get_codecs()
            .make(&track.codec_params, &DecoderOptions::default())
            .context("failed to create decoder")?;

        // Decode all samples into a flat f32 buffer (interleaved).
        // Channel count is determined from the first decoded packet
        // since codec params may not include it (e.g. AAC).
        let mut all_samples: Vec<f32> = Vec::new();
        let mut channels: u16 = track
            .codec_params
            .channels
            .map(|c| c.count() as u16)
            .unwrap_or(1);

        loop {
            let packet = match format.next_packet() {
                Ok(p) => p,
                Err(symphonia::core::errors::Error::IoError(ref e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    break;
                }
                Err(e) => return Err(e.into()),
            };

            if packet.track_id() != track.id {
                continue;
            }

            let decoded = match decoder.decode(&packet) {
                Ok(d) => d,
                Err(symphonia::core::errors::Error::DecodeError(_)) => continue,
                Err(e) => return Err(e.into()),
            };

            let spec = *decoded.spec();
            if all_samples.is_empty() {
                channels = spec.channels.count() as u16;
            }
            let num_frames = decoded.frames();
            let mut sample_buf = SampleBuffer::<f32>::new(num_frames as u64, spec);
            sample_buf.copy_interleaved_ref(decoded);
            all_samples.extend_from_slice(sample_buf.samples());
        }

        let samples_per_channel = if channels == 0 { 0 } else { all_samples.len() / channels as usize };
        let chunk_size_samples = (chunk_duration_secs * sample_rate as f64) as usize;
        let total_chunks = if samples_per_channel == 0 {
            0
        } else {
            (samples_per_channel + chunk_size_samples - 1) / chunk_size_samples
        };

        Ok(Self {
            samples: all_samples,
            position: 0,
            input_sample_rate: sample_rate,
            channels,
            chunk_size_samples,
            total_chunks,
            chunks_read: 0,
        })
    }
}

impl Iterator for ChunkedAudioReader {
    /// Returns resampled 16kHz mono f32 chunk
    type Item = Result<Vec<f32>>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.chunks_read >= self.total_chunks {
            return None;
        }

        // Read chunk_size_samples frames (interleaved)
        let total_interleaved = self.chunk_size_samples * self.channels as usize;
        let end = (self.position + total_interleaved).min(self.samples.len());
        let raw = &self.samples[self.position..end];

        if raw.is_empty() {
            return None;
        }

        self.position = end;
        self.chunks_read += 1;

        // Convert to mono
        let mono = to_mono(raw, self.channels);

        // Resample if needed
        if self.input_sample_rate == TARGET_SAMPLE_RATE {
            Some(Ok(mono))
        } else {
            Some(resample(&mono, self.input_sample_rate, TARGET_SAMPLE_RATE))
        }
    }
}

fn to_mono(interleaved: &[f32], channels: u16) -> Vec<f32> {
    if channels == 1 {
        return interleaved.to_vec();
    }
    let ch = channels as usize;
    interleaved
        .chunks_exact(ch)
        .map(|frame| frame.iter().sum::<f32>() / ch as f32)
        .collect()
}

fn resample(samples: &[f32], from_rate: u32, to_rate: u32) -> Result<Vec<f32>> {
    let mut resampler = FftFixedIn::<f32>::new(
        from_rate as usize,
        to_rate as usize,
        RESAMPLER_CHUNK_SIZE,
        1,
        1,
    )
    .context("failed to create resampler")?;

    let mut output = Vec::new();
    for chunk in samples.chunks(RESAMPLER_CHUNK_SIZE) {
        // Pad last chunk if needed
        let input = if chunk.len() < RESAMPLER_CHUNK_SIZE {
            let mut padded = chunk.to_vec();
            padded.resize(RESAMPLER_CHUNK_SIZE, 0.0);
            padded
        } else {
            chunk.to_vec()
        };

        match resampler.process(&[&input], None) {
            Ok(result) => {
                if let Some(channel) = result.first() {
                    output.extend_from_slice(channel);
                }
            }
            Err(e) => return Err(anyhow::anyhow!("resampling failed: {e}")),
        }
    }

    Ok(output)
}
