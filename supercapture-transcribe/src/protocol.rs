use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "lowercase")]
pub enum Command {
    Transcribe { path: PathBuf },
    Quit,
}

#[derive(Serialize)]
pub struct Progress {
    pub progress: f64,
    pub chunk: usize,
    pub total_chunks: usize,
}

#[derive(Serialize)]
pub struct Response {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chunks: Option<usize>,
}

impl Response {
    pub fn ok(text: String) -> Self {
        Self {
            ok: true,
            text: Some(text),
            error: None,
            chunks: None,
        }
    }

    pub fn ok_with_chunks(text: String, chunks: usize) -> Self {
        Self {
            ok: true,
            text: Some(text),
            error: None,
            chunks: Some(chunks),
        }
    }

    pub fn error(msg: String) -> Self {
        Self {
            ok: false,
            text: None,
            error: Some(msg),
            chunks: None,
        }
    }
}
