mod audio;
mod protocol;
mod transcriber;

use anyhow::Result;
use clap::Parser;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

#[derive(Parser)]
#[command(name = "supercapture-transcribe")]
#[command(about = "Transcription daemon for SuperCapture")]
struct Cli {
    /// Path to the Parakeet v3 model directory
    #[arg(long)]
    model_path: PathBuf,

    /// Seconds of inactivity before auto-exit (0 = exit after each command)
    #[arg(long, default_value = "300")]
    idle_timeout: u64,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let shutdown = Arc::new(AtomicBool::new(false));

    // Idle timeout watcher
    let last_activity = Arc::new(std::sync::Mutex::new(Instant::now()));
    if cli.idle_timeout > 0 {
        let shutdown_clone = shutdown.clone();
        let last_activity_clone = last_activity.clone();
        let timeout = Duration::from_secs(cli.idle_timeout);
        std::thread::spawn(move || {
            loop {
                std::thread::sleep(Duration::from_secs(5));
                let elapsed = last_activity_clone.lock().unwrap().elapsed();
                if elapsed >= timeout {
                    shutdown_clone.store(true, Ordering::Relaxed);
                    break;
                }
            }
        });
    }

    let mut engine: Option<transcriber::Engine> = None;
    let stdin = io::stdin();
    let stdout = io::stdout();

    for line in stdin.lock().lines() {
        if shutdown.load(Ordering::Relaxed) {
            break;
        }

        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };

        if line.trim().is_empty() {
            continue;
        }

        *last_activity.lock().unwrap() = Instant::now();

        let cmd: protocol::Command = match serde_json::from_str(&line) {
            Ok(c) => c,
            Err(e) => {
                let resp = protocol::Response::error(format!("invalid command: {e}"));
                writeln!(stdout.lock(), "{}", serde_json::to_string(&resp)?)?;
                continue;
            }
        };

        match cmd {
            protocol::Command::Transcribe { path } => {
                // Lazy model loading
                if engine.is_none() {
                    match transcriber::Engine::load(&cli.model_path) {
                        Ok(e) => engine = Some(e),
                        Err(e) => {
                            let resp = protocol::Response::error(format!("model load failed: {e}"));
                            writeln!(stdout.lock(), "{}", serde_json::to_string(&resp)?)?;
                            continue;
                        }
                    }
                }

                let eng = engine.as_mut().unwrap();
                match transcriber::transcribe_file(eng, &path, &stdout) {
                    Ok(text) => {
                        let resp = protocol::Response::ok(text);
                        writeln!(stdout.lock(), "{}", serde_json::to_string(&resp)?)?;
                    }
                    Err(e) => {
                        let resp = protocol::Response::error(format!("transcription failed: {e}"));
                        writeln!(stdout.lock(), "{}", serde_json::to_string(&resp)?)?;
                    }
                }
                stdout.lock().flush()?;
            }
            protocol::Command::Quit => break,
        }

        *last_activity.lock().unwrap() = Instant::now();
    }

    // Model is dropped here, freeing memory
    drop(engine);
    Ok(())
}
