# feat: Post-Recording Transcription via Parakeet v3

## Context
User wants automatic transcription of both audio tracks (mic + system) after recording stops. Uses Parakeet TDT v3 (NVIDIA) via `transcribe-rs` Rust crate. Model should stay loaded between transcriptions but unload after configurable idle timeout.

## Architecture

Two components:
1. **`supercapture-transcribe`** - Rust CLI daemon (long-lived process, stdin/stdout JSON protocol)
2. **`TranscriptionService.swift`** - Swift service managing the CLI process lifecycle

### Why a daemon instead of one-shot CLI?
Parakeet v3 model loading takes several seconds. A persistent process keeps the model loaded between transcriptions and unloads after idle timeout. The Swift app spawns it on-demand and kills it when no longer needed.

## Part 1: Rust CLI (`supercapture-transcribe/`)

### Cargo.toml
```toml
[dependencies]
transcribe-rs = { version = "0.2.2", features = ["parakeet"] }
hound = "3.5.1"        # WAV reading
rubato = "0.16.2"      # 48kHz → 16kHz resampling
serde = { version = "1", features = ["derive"] }
serde_json = "1"
anyhow = "1"
```

### Protocol (stdin/stdout, JSON lines)
```
→ {"action":"transcribe","path":"/path/to/file.wav"}
← {"progress":0.15,"chunk":1,"total_chunks":20}
← {"progress":0.30,"chunk":2,"total_chunks":20}
← ...
← {"ok":true,"text":"Full transcription...","duration_secs":2.3,"chunks":20}

→ {"action":"transcribe","path":"/path/to/other.wav"}
← {"progress":1.0,"chunk":1,"total_chunks":1}
← {"ok":true,"text":"Short transcription","duration_secs":0.5,"chunks":1}

→ {"action":"quit"}
← (process exits)

(or: no input for --idle-timeout seconds → process exits automatically)
```

Progress messages allow the Swift app to show a progress bar during long transcriptions.

### Audio pipeline (chunked for long recordings)
Recordings can be hours long (meetings). Processing must be chunked.

1. Open WAV via `hound` streaming iterator (no full file load)
2. Read in **30-second chunks** (30 × 48000 = 1,440,000 samples per chunk)
3. Convert chunk to mono f32 if stereo (average channels)
4. Resample chunk 48kHz → 16kHz via `rubato::FftFixedIn` (→ 480,000 samples)
5. Pass chunk to `ParakeetEngine::transcribe_samples()`
6. Collect chunk result, report progress
7. Repeat until EOF
8. Concatenate all chunk texts

Memory: ~4MB per chunk instead of ~230MB per hour.

Chunk boundary handling: 1-second overlap between chunks, deduplicate at boundaries.

### CLI args
```
supercapture-transcribe --model-path <dir> --idle-timeout <seconds>
```
- `--model-path`: Path to extracted Parakeet v3 int8 model directory
- `--idle-timeout`: Seconds of inactivity before auto-exit (0 = exit after first batch)

### Model lifecycle
- Loads model lazily on first `transcribe` command
- Tracks last activity timestamp
- Background thread checks idle timeout, exits process when exceeded
- On exit, model is dropped (unloaded)

## Part 2: Swift App Integration

### New files

**`SuperCapture/Service/TranscriptionService.swift`**
- `@MainActor @Observable` class
- Manages the CLI daemon `Process()` lifecycle
- Sends JSON commands via stdin pipe, reads JSON responses from stdout pipe
- Spawns process on first transcription request
- Terminates process when idle timeout triggers (or app quits)
- Exposes: `isTranscribing: Bool`, `progress: Double` (0.0-1.0), `lastError: String?`
- Reads `progress` messages from stdout to update progress bar in UI

**`SuperCapture/Model/TranscriptionResult.swift`**
- `Codable` struct for transcription output

### Modified files

**`SuperCapture/Model/SettingsStore.swift`**
New settings (UserDefaults, existing pattern):
- `transcribeAfterRecording: Bool` (default: false)
- `transcriptionModelUnloadTimeout: Int` (default: 300, options: 0/60/300/900/1800 seconds)

**`SuperCapture/View/SettingsView.swift`**
New "Transcription" section in General tab:
- Toggle "Transcribe after recording"
- Picker "Model unload after" (Immediately / 1 min / 5 min / 15 min / 30 min)

**`SuperCapture/ViewModel/RecorderViewModel.swift`**
In `stopRecording()`, after WAV finalization:
- If `settings.transcribeAfterRecording`, call `transcriptionService.transcribe(files:)`
- Add `.transcribing` state (between `.stopping` and `.executingHooks`)
- Save results as `{timestamp}_transcription.json`

**`SuperCapture/SuperCaptureApp.swift`**
- Create and pass `TranscriptionService` instance

### Output format
```json
{
  "mic": { "text": "full transcribed mic audio...", "duration_secs": 2.3, "chunks": 20 },
  "system": { "text": "full transcribed system audio...", "duration_secs": 1.1, "chunks": 15 }
}
```
Saved as `{timestamp}_transcription.json` alongside other recording files.
Also saved as plain text: `{timestamp}_mic.txt` and `{timestamp}_system.txt` for easy access.

### Model download
First iteration: Manual download. User downloads model tar.gz, extracts to `~/Library/Application Support/SuperCapture/models/parakeet-tdt-0.6b-v3-int8/`.
Future: Add in-app download with progress bar.

## Implementation Order

1. Rust CLI binary (can test standalone)
2. TranscriptionService.swift (process management)
3. Settings + UI
4. RecorderViewModel integration
5. Test end-to-end

## Verification
1. Build Rust CLI: `cargo build --release`
2. Test standalone: `echo '{"action":"transcribe","path":"test.wav"}' | ./supercapture-transcribe --model-path ./models/parakeet-tdt-0.6b-v3-int8 --idle-timeout 60`
3. Build Swift app, record audio, verify transcription JSON appears alongside WAV files
4. Verify model unloads after configured timeout (check memory usage)
