# Plan: Dual-Audio WAV + Post-Recording Hooks

## Context

BetterCapture is a sandboxed macOS menu bar screen recorder. This fork extends it to:
1. Write **separate WAV files** (input/output audio) alongside the normal video recording
2. Run **post-recording hooks** (bash commands with env vars) for automation (transcription, analysis)
3. Add a **global keyboard shortcut** for toggle recording

WAV files are always produced when the corresponding audio source is enabled. The app sandbox will be removed to enable `Process`-based hook execution.

---

## Step 1: Remove Sandbox Entitlement

**File:** `BetterCapture/BetterCapture.entitlements`

- Set `com.apple.security.app-sandbox` to `false`
- Keep `com.apple.security.device.audio-input` and `com.apple.security.device.camera`
- Remove sandbox-specific entitlements that are no longer needed (`files.user-selected.*`, `assets.movies.*`)
- Keep `com.apple.security.network.client` (for Sparkle updates)
- Keep the mach-lookup exception (Sparkle XPC)

---

## Step 2: AudioTrackWriter Service

**New file:** `BetterCapture/Service/AudioTrackWriter.swift`

WAV file writer that receives `CMSampleBuffer` and writes 16-bit PCM WAV.

- `final class AudioTrackWriter: @unchecked Sendable`
- Thread-safe with `OSAllocatedUnfairLock` (same pattern as `AssetWriter`)
- `setup(url: URL, channelCount: Int)` — creates file, writes 44-byte WAV header with placeholder sizes
- `appendSample(_ sampleBuffer: CMSampleBuffer)` — extracts Float32 audio data via `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`, converts to Int16 PCM, handles mono downmix (average L+R) when `channelCount == 1`, writes via `FileHandle`
- `finishWriting()` — patches WAV header with final data size (seek to bytes 4 and 40), closes handle
- `cancel()` — closes handle, deletes file

WAV format: 48kHz, 16-bit PCM, mono (input) or stereo (output).

Conversion: Float32 `[-1.0, 1.0]` → Int16 `[-32767, 32767]` with clamping.

---

## Step 3: SampleBufferMultiplexer

**New file:** `BetterCapture/Service/SampleBufferMultiplexer.swift`

Fans `CaptureEngineSampleBufferDelegate` calls to both `AssetWriter` and WAV writers.

- `final class SampleBufferMultiplexer: CaptureEngineSampleBufferDelegate, @unchecked Sendable`
- Properties: `assetWriter: AssetWriter`, `outputWavWriter: AudioTrackWriter?`, `inputWavWriter: AudioTrackWriter?`
- Video callback → forwards to `assetWriter` only
- Audio callback → forwards to `assetWriter` + `outputWavWriter`
- Microphone callback → forwards to `assetWriter` + `inputWavWriter`

Set as `captureEngine.sampleBufferDelegate` instead of `assetWriter` directly.

---

## Step 4: RecorderViewModel — WAV Integration

**Modify:** `BetterCapture/ViewModel/RecorderViewModel.swift`

### Properties to add:
- `private let outputWavWriter = AudioTrackWriter()`
- `private let inputWavWriter = AudioTrackWriter()`
- `private let multiplexer: SampleBufferMultiplexer`
- `private var recordingTimestamp: String?`
- `private var recordingSessionID: UUID?`
- `private var recordingStartDate: Date?`

### In `init()`:
- Create `SampleBufferMultiplexer(assetWriter:outputWavWriter:inputWavWriter:)`
- Set `captureEngine.sampleBufferDelegate = multiplexer`

### In `startRecording()`:
- Generate timestamp: `yyyy-MM-dd_HH-mm-ss` format from `Date()`
- Generate session ID: `UUID()`
- Store both + `recordingStartDate`
- Setup WAV writers with URLs: `{outputDir}/{timestamp}_output.wav` and `{timestamp}_input.wav`
- Only setup each writer if the corresponding audio source is enabled
- Handle filename collision (append `_01` suffix if file exists)

### In `stopRecording()`:
- Capture end timestamp
- After `assetWriter.finishWriting()`, call `finishWriting()` on WAV writers
- Store WAV URLs for hooks phase (Step 8)
- Write `{TS}_meta.json` (Step 7)
- Run hooks (Step 8)

---

## Step 5: Hook Data Model

**New file:** `BetterCapture/Model/HookConfiguration.swift`

```swift
struct HookEntry: Codable, Identifiable {
    var id = UUID()
    var command: String
    var isEnabled: Bool = true
}

struct HookConfiguration: Codable {
    var hooks: [HookEntry] = []
    var stopOnError: Bool = true
    var timeoutSeconds: Int = 300
}
```

**New file:** `BetterCapture/Model/HookStore.swift`

- `@MainActor @Observable final class HookStore`
- Loads/saves from `~/Library/Application Support/BetterCapture/hooks.json`
- Properties: `configuration: HookConfiguration`
- Methods: `load()`, `save()`, `addHook()`, `removeHook(id:)`, `moveHook(from:to:)`
- Auto-saves on mutation

---

## Step 6: HookRunner Service

**New file:** `BetterCapture/Service/HookRunner.swift`

```swift
struct HookRunContext {
    let inputWavURL: URL?
    let outputWavURL: URL?
    let recordingDirectory: URL
    let timestampStart: String
    let timestampEnd: String
    let sessionID: UUID
    let hookCount: Int
}

struct HookResult: Codable {
    let index: Int
    let command: String
    let exitCode: Int32
    let durationSeconds: Double
    let stdout: String  // truncated to 64KB
    let stderr: String  // truncated to 64KB
    let timedOut: Bool
    let skipped: Bool
}
```

Execution:
- `func runHooks(_ config: HookConfiguration, context: HookRunContext) async -> [HookResult]`
- For each enabled hook: `Process()` with `/bin/bash -lc "<command>"`
- Set ENV: `BC_INPUT_WAV`, `BC_OUTPUT_WAV`, `BC_DIR`, `BC_TS_START`, `BC_TS_END`, `BC_SESSION_ID`, `BC_HOOK_INDEX`, `BC_HOOK_COUNT`
- stdout/stderr via `Pipe`, truncated to 64KB
- Timeout: background `Task` that calls `process.terminate()` after `timeoutSeconds`, then `process.interrupt()` 5s later if still running
- `stopOnError`: skip remaining hooks if exitCode != 0

---

## Step 7: Metadata Writer

**New file:** `BetterCapture/Service/RecordingMetadataWriter.swift`

Static methods:
- `writeSessionMeta(to directory: URL, timestamp: String, context: ...)` → `{TS}_meta.json`
  - Content: start/end timestamps, session ID, audio formats (48kHz/16bit/mono+stereo), WAV file paths, app version
- `writeHookResults(to directory: URL, timestamp: String, results: [HookResult])` → `{TS}_hooks.json`

---

## Step 8: RecorderViewModel — Hook Integration

**Modify:** `BetterCapture/ViewModel/RecorderViewModel.swift`

### New state:
- Add `executingHooks` case to `RecordingState` (between recording and idle)

### In `stopRecording()` after file finalization:
1. Write `{TS}_meta.json`
2. Load hook configuration from `hookStore`
3. If hooks exist: set `state = .executingHooks`, run `HookRunner.runHooks()` in a `Task`
4. Write `{TS}_hooks.json` with results
5. Set `state = .idle`
6. Send notification (delayed until after hooks complete)

### Add `cancelHooks()` method:
- Cancels the running hooks task
- Sets state back to idle

---

## Step 9: Hook Settings UI

**New file:** `BetterCapture/View/HookSettingsView.swift`

SwiftUI window opened from menu bar:
- `List` of hooks, each row: `TextField` for command, `Toggle` for enabled
- Add/Remove buttons
- Reorder via Up/Down buttons (or drag)
- Bottom section: `Toggle` for stopOnError, `Stepper`/`TextField` for timeoutSeconds
- Saves automatically via `HookStore`

### Modify: `BetterCapture/BetterCaptureApp.swift`
- Add `Window("Hooks", id: "hooks-editor")` scene with `HookSettingsView`

### Modify: `BetterCapture/View/MenuBarView.swift`
- Add `MenuBarActionButton(title: "Hooks...", systemImage: "terminal")` in idle content, before "Open Output Folder"
- Uses `@Environment(\.openWindow)` to open hooks editor

### Modify: `BetterCapture/View/MenuBarView.swift` (recording content)
- When `state == .executingHooks`: show "Running hooks..." indicator with cancel button

---

## Step 10: Global Keyboard Shortcut

**New file:** `BetterCapture/Service/GlobalShortcutService.swift`

- `@MainActor @Observable final class GlobalShortcutService`
- Uses `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` + `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`
- Default shortcut: `Cmd+Shift+R` (configurable)
- Callback: `onToggleRecording: (() -> Void)?`

### Modify: `BetterCapture/ViewModel/RecorderViewModel.swift`
- Add `let globalShortcut = GlobalShortcutService()`
- Add `toggleRecording()` method that calls `startRecording()` or `stopRecording()`
- Wire shortcut callback in `init()`

### Modify: `BetterCapture/Model/SettingsStore.swift`
- Add `shortcutKeyCode: UInt16` and `shortcutModifierFlags: UInt` (UserDefaults-backed)

### Modify: `BetterCapture/View/SettingsView.swift`
- Add "Shortcut" section in General tab with shortcut recorder

---

## Files Summary

### New files (8):
| File | Purpose |
|------|---------|
| `Service/AudioTrackWriter.swift` | WAV file writing from CMSampleBuffer |
| `Service/SampleBufferMultiplexer.swift` | Fans sample buffers to multiple delegates |
| `Model/HookConfiguration.swift` | Hook data model (Codable) |
| `Model/HookStore.swift` | Hook persistence (JSON in App Support) |
| `Service/HookRunner.swift` | Bash hook execution with env vars |
| `Service/RecordingMetadataWriter.swift` | meta.json + hooks.json writing |
| `Service/GlobalShortcutService.swift` | Global keyboard shortcut monitoring |
| `View/HookSettingsView.swift` | Hook editor SwiftUI window |

### Modified files (5):
| File | Changes |
|------|---------|
| `BetterCapture.entitlements` | Remove sandbox |
| `ViewModel/RecorderViewModel.swift` | WAV writers, multiplexer, hooks, global shortcut, timestamps |
| `Model/SettingsStore.swift` | Shortcut key settings |
| `BetterCaptureApp.swift` | Add hooks Window scene |
| `View/MenuBarView.swift` | "Hooks..." button, executingHooks state UI |
| `View/SettingsView.swift` | Shortcut recorder in General tab |

---

## Verification

1. **WAV output**: Start recording with both audio sources enabled → Stop → Verify two WAV files in output directory with correct naming, playable in QuickTime, correct format (48kHz 16-bit PCM, mono/stereo)
2. **Audio separation**: Play input.wav → should contain only microphone. Play output.wav → should contain only system audio.
3. **Hooks**: Configure a test hook `ls -lh "$BC_INPUT_WAV" "$BC_OUTPUT_WAV"` → Verify it runs after recording, check `{TS}_hooks.json` for correct output
4. **Hook env vars**: Hook `env | grep BC_` → Verify all vars set correctly
5. **Hook timeout**: Hook `sleep 999` with 5s timeout → Verify process killed, timedOut=true in log
6. **Hook stopOnError**: Two hooks, first `exit 1`, second `echo ok` → Verify second skipped
7. **Meta JSON**: Check `{TS}_meta.json` contains correct timestamps, formats, paths
8. **Global shortcut**: Press Cmd+Shift+R → Recording starts. Press again → Recording stops.
9. **Build**: `xcodebuild build` succeeds with no warnings
