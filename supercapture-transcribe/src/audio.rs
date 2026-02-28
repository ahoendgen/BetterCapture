use anyhow::{Context, Result};
use hound::WavReader;
use rubato::{FftFixedIn, Resampler};
use std::path::Path;

const TARGET_SAMPLE_RATE: u32 = 16_000;
const RESAMPLER_CHUNK_SIZE: usize = 1024;

/// Reads a WAV file in chunks, resamples to 16kHz mono f32.
/// Returns an iterator of audio chunks, each ~`chunk_duration_secs` long.
pub struct ChunkedWavReader {
    samples_iter: Box<dyn Iterator<Item = f32>>,
    input_sample_rate: u32,
    channels: u16,
    /// Samples per chunk at the input sample rate (per channel)
    chunk_size_samples: usize,
    pub total_chunks: usize,
    chunks_read: usize,
}

impl ChunkedWavReader {
    pub fn open(path: &Path, chunk_duration_secs: f64) -> Result<Self> {
        let reader = WavReader::open(path).context("failed to open WAV file")?;
        let spec = reader.spec();
        let total_samples = reader.len() as usize;
        let channels = spec.channels;
        let sample_rate = spec.sample_rate;

        // Samples per chunk (all channels)
        let chunk_size_samples = (chunk_duration_secs * sample_rate as f64) as usize;
        let samples_per_channel = total_samples / channels as usize;
        let total_chunks = (samples_per_channel + chunk_size_samples - 1) / chunk_size_samples;

        // Convert all samples to f32 via streaming iterator
        let samples_iter: Box<dyn Iterator<Item = f32>> = match spec.sample_format {
            hound::SampleFormat::Int => {
                let bits = spec.bits_per_sample;
                let max_val = (1i64 << (bits - 1)) as f32;
                Box::new(
                    reader
                        .into_samples::<i32>()
                        .map(move |s| s.unwrap_or(0) as f32 / max_val),
                )
            }
            hound::SampleFormat::Float => {
                Box::new(reader.into_samples::<f32>().map(|s| s.unwrap_or(0.0)))
            }
        };

        Ok(Self {
            samples_iter,
            input_sample_rate: sample_rate,
            channels,
            chunk_size_samples,
            total_chunks,
            chunks_read: 0,
        })
    }
}

impl Iterator for ChunkedWavReader {
    /// Returns resampled 16kHz mono f32 chunk
    type Item = Result<Vec<f32>>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.chunks_read >= self.total_chunks {
            return None;
        }

        // Read chunk_size_samples frames (interleaved)
        let total_interleaved = self.chunk_size_samples * self.channels as usize;
        let mut raw: Vec<f32> = Vec::with_capacity(total_interleaved);
        for sample in self.samples_iter.by_ref() {
            raw.push(sample);
            if raw.len() >= total_interleaved {
                break;
            }
        }

        if raw.is_empty() {
            return None;
        }

        self.chunks_read += 1;

        // Convert to mono
        let mono = to_mono(&raw, self.channels);

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
