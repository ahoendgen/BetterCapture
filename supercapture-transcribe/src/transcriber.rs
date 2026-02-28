use anyhow::Result;
use std::io::{Stdout, Write};
use std::path::Path;
use transcribe_rs::engines::parakeet::{
    ParakeetEngine, ParakeetInferenceParams, ParakeetModelParams,
};
use transcribe_rs::TranscriptionEngine;

use crate::audio::ChunkedAudioReader;
use crate::protocol::Progress;

const CHUNK_DURATION_SECS: f64 = 30.0;

pub struct Engine {
    inner: ParakeetEngine,
}

impl Engine {
    pub fn load(model_path: &Path) -> Result<Self> {
        let mut engine = ParakeetEngine::new();
        engine
            .load_model_with_params(model_path, ParakeetModelParams::int8())
            .map_err(|e| anyhow::anyhow!("failed to load Parakeet model: {e}"))?;
        Ok(Self { inner: engine })
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.inner.unload_model();
    }
}

/// Transcribes a WAV file in chunks, writing progress to stdout.
/// Returns the concatenated full transcription text.
pub fn transcribe_file(engine: &mut Engine, path: &Path, stdout: &Stdout) -> Result<String> {
    let reader = ChunkedAudioReader::open(path, CHUNK_DURATION_SECS)?;
    let total_chunks = reader.total_chunks;
    let mut texts: Vec<String> = Vec::new();

    let params = ParakeetInferenceParams::default();

    for (i, chunk_result) in reader.enumerate() {
        let samples = chunk_result?;

        // Skip very short chunks (< 0.1s at 16kHz)
        if samples.len() < 1600 {
            continue;
        }

        let result = engine
            .inner
            .transcribe_samples(samples, Some(params.clone()))
            .map_err(|e| anyhow::anyhow!("transcription failed: {e}"))?;

        let text = result.text.trim().to_string();
        if !text.is_empty() {
            texts.push(text);
        }

        // Report progress
        let progress = Progress {
            progress: (i + 1) as f64 / total_chunks as f64,
            chunk: i + 1,
            total_chunks,
        };
        let _ = writeln!(stdout.lock(), "{}", serde_json::to_string(&progress).unwrap());
        let _ = stdout.lock().flush();
    }

    Ok(texts.join(" "))
}
