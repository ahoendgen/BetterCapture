# Configurable Shortcut + Optional Video Recording

## Context

BetterCapture currently has a hardcoded-default global shortcut (Cmd+Shift+R) with limited reconfiguration (can change key letter but not modifier flags, no way to clear), and always records video. This plan adds:
- **A1**: Full shortcut configurability with clear/disable, modifier capture, and conflict warnings
- **A2**: A "Record Video" toggle (default: off) enabling audio-only recording mode

## A1: Configurable Global Recording Shortcut

### Files to modify
- `BetterCapture/Service/GlobalShortcutService.swift`
- `BetterCapture/View/SettingsView.swift` (GeneralSettingsView)

### Changes

#### GlobalShortcutService.swift

1. **Add `isEnabled: Bool` property** (UserDefaults key `"shortcutEnabled"`, default: `true`)
   - Follows existing `access(keyPath:)`/`withMutation(keyPath:)` pattern
   - Setter calls `reinstallMonitors()` (which already handles remove + install)

2. **Guard monitor installation on `isEnabled`**
   - In `installMonitors()`: early return if `!isEnabled`, log "Global shortcut disabled"
   - `shortcutDescription` returns `"Not set"` when `!isEnabled`

3. **Add `func clearShortcut()`** convenience that sets `isEnabled = false`

4. **Add `func updateShortcut(keyCode:modifierFlags:)`** convenience that sets both values and re-enables
   - Sets `isEnabled = true`, `keyCode`, `modifierFlags` (single reinstall at end)

#### SettingsView.swift (GeneralSettingsView)

1. **Replace `onKeyPress`-based recorder** with NSEvent local monitor approach:
   - When `isRecordingShortcut` is true, install `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`
   - On capture: extract `event.keyCode` and `event.modifierFlags`
   - Require at least one modifier (`.command`, `.option`, `.control`, `.shift`) — reject bare key presses
   - ESC (keyCode 53) cancels recording without changing shortcut
   - On successful capture: call `globalShortcut.updateShortcut(keyCode:modifierFlags:)`
   - Remove temporary monitor after capture
   - Store the monitor reference in `@State private var recordingMonitor: Any?`

2. **Add "Clear" button** next to the shortcut button
   - Calls `globalShortcut.clearShortcut()`
   - Only shown when shortcut is enabled

3. **Conflict warning (best-effort)**
   - Static set of known macOS shortcuts: Cmd+Q, Cmd+W, Cmd+H, Cmd+M, Cmd+C, Cmd+V, Cmd+X, Cmd+Z, Cmd+A, Cmd+S, Cmd+Tab, Cmd+Space
   - After recording, check if new combo matches → show `Text("This shortcut conflicts with a system shortcut")` in `.foregroundStyle(.orange)` below the picker
   - Non-blocking warning only — user can still use it

4. **"Not active" display**: When `!globalShortcut.isEnabled`, show "Not set" as button label

## A2: Video Recording Enable/Disable

### Files to modify
- `BetterCapture/Model/SettingsStore.swift`
- `BetterCapture/Service/CaptureEngine.swift`
- `BetterCapture/ViewModel/RecorderViewModel.swift`
- `BetterCapture/View/SettingsView.swift` (VideoSettingsView)
- `BetterCapture/View/MenuBarSettingsView.swift` (VideoSettingsSection)
- `BetterCapture/View/MenuBarView.swift`

### Changes

#### SettingsStore.swift

1. **Add `recordVideo: Bool` property** (UserDefaults key `"recordVideo"`, default: `false`)
   - Same `access(keyPath:)`/`withMutation(keyPath:)` pattern as other settings

#### CaptureEngine.swift — `startCapture(with:videoSize:sourceRect:)`

1. **Conditionally add `.screen` stream output**:
   ```swift
   if settings.recordVideo {
       try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoSampleQueue)
   }
   ```
   Audio and microphone outputs remain unconditional (gated on their own settings as before).

2. **Adjust `createStreamConfiguration()`**: When `!settings.recordVideo`:
   - Set `config.width = 2` and `config.height = 2` (minimal, valid dimensions)
   - Set `config.minimumFrameInterval = CMTime(value: 1, timescale: 1)` (1 fps — minimal)
   - Skip pixel format / dynamic range config (leave defaults)
   - Audio config remains the same

#### RecorderViewModel.swift

1. **Add `private var isRecordingVideo: Bool = false`** — tracks per-session whether video is active

2. **`startRecording()` changes**:
   - Set `isRecordingVideo = settings.recordVideo`
   - **If `isRecordingVideo`**: existing flow (videoSize calc, AssetWriter setup, multiplexer wired to assetWriter)
   - **If `!isRecordingVideo`**:
     - Skip videoSize calculation (leave at .zero)
     - Skip `assetWriter.setup()` and `assetWriter.startWriting()`
     - Don't set `multiplexer.assetWriter` (leave nil — multiplexer safely skips nil)
     - Skip camera/Presenter Overlay setup
     - WAV writer setup remains the same
     - Pass `videoSize: CGSize(width: 2, height: 2)` to `captureEngine.startCapture()`

3. **`stopRecording()` changes**:
   - **If `isRecordingVideo`**: existing flow (finalize assetWriter → get videoURL)
   - **If `!isRecordingVideo`**:
     - Skip `assetWriter.finishWriting()`
     - `videoURL` is nil
     - Pass `nil` for videoFileURL in `RecordingMetadataWriter.writeSessionMeta()`
     - For notification: use `settings.outputDirectory` instead of `videoURL`
     - For hooks: existing `HookRunContext` already doesn't include video URL — no change needed
   - After stop: reset `isRecordingVideo = false` in `clearSessionState()`

4. **Error path**: In catch block, only call `assetWriter.cancel()` if `isRecordingVideo`

#### SettingsView.swift (VideoSettingsView)

1. **Add "Record Video" toggle** at the top of the form, in a new "Recording Mode" section:
   ```swift
   Section("Recording Mode") {
       Toggle("Record Video", isOn: $settings.recordVideo)
           .help("When disabled, only audio WAV files are recorded")
   }
   ```

2. **Disable video-specific settings** when `!settings.recordVideo`:
   - Frame Rate, Codec, Container, Alpha Channel, HDR — all `.disabled(!settings.recordVideo)`
   - Display Elements section — `.disabled(!settings.recordVideo)`

#### MenuBarSettingsView.swift (VideoSettingsSection)

1. **Add "Record Video" toggle** at the top of the VStack (using existing `MenuBarToggle`):
   ```swift
   MenuBarToggle(name: "Record Video", isOn: $settings.recordVideo)
   ```

2. **Gray out video-specific settings when video disabled**: Pass `isDisabled: !settings.recordVideo` to each `MenuBarToggle` and disable `MenuBarExpandablePicker` options when `!settings.recordVideo`

#### MenuBarView.swift

1. **VideoSettingsSection**: Always visible, grayed out when `!settings.recordVideo` (handled by the section above)
2. **PresenterOverlaySettingsSection**: **Hidden** when `!settings.recordVideo` (wrap in `if settings.recordVideo { ... }`)
2. **Notification text**: When audio-only, notification says "Recording saved" and links to output folder

### Key invariants preserved
- `canStartRecording` still requires `selectedContentFilter != nil` (audio capture needs it)
- Content selection flow unchanged — user still picks a display/window for audio routing
- Screen recording permission still required (ScreenCaptureKit needs it even for audio-only)
- WAV writers always produce `{timestamp}_input.wav` and `{timestamp}_output.wav`
- `SampleBufferMultiplexer` requires zero changes — optional weak `assetWriter` handles nil gracefully
- `RecordingMetadataWriter.writeSessionMeta()` already accepts optional `videoFileURL`
- `HookRunContext` already has no video reference

## Verification

1. **Shortcut config**: Open Settings → General → change shortcut to Cmd+Option+R → verify it works globally → restart app → verify it persists → clear → verify shortcut is disabled
2. **Conflict warning**: Set shortcut to Cmd+Q → verify warning appears
3. **Audio-only recording** (default): Select a display → start recording → stop → verify only `*_input.wav`, `*_output.wav`, `*_meta.json` appear — no video file
4. **Video recording**: Enable Record Video in settings → record → verify video file + WAV files both appear
5. **CPU usage**: Compare Activity Monitor between audio-only and video mode — audio-only should be materially lower
6. **Settings UI**: Toggle Record Video off → verify video settings are hidden/disabled in both Settings window and menu bar
