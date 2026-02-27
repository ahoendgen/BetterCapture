# Fix: Menu-Bar-Hang und Race Conditions

## Context

Zwei Probleme:
1. **Menu-Bar-Icon reagiert nicht auf Klicks** - `AppleEvent activation suspension timed out` in den Logs. Alle Init-Logs erscheinen korrekt, also ist es kein blockierender Init. Mögliche Ursachen:
   - `SCContentSharingPicker.shared.add(self)` im `CaptureEngine.init()` löst XPC-Kommunikation aus die den Event-Loop blockiert
   - `.task` auf `MenuBarView` feuert bei jedem Popover-Öffnen und könnte Focus-Stealing verursachen
   - Stale DerivedData nach Sandbox-Änderung
2. **Race Condition in SampleBufferMultiplexer** - `nonisolated(unsafe)` Properties ohne Synchronisation

## Schritt 0: Clean Build (Diagnostik)

Bevor Code geändert wird: Clean Build nach der Sandbox-Änderung, da Xcode alte Artefakte cachen kann.

```
Cmd+Shift+K (Clean Build Folder) → Cmd+B (Build) → Run
```

Falls das den Menu-Bar-Klick bereits fixt → nur die Race-Condition-Fixes implementieren.

## Schritt 1: SCContentSharingPicker lazy machen

**Datei:** `Service/CaptureEngine.swift`

`picker.add(self)` aus `init()` entfernen. Stattdessen den Observer erst bei `presentPicker()` registrieren (lazy, einmalig).

```swift
// Property
private var pickerConfigured = false

// init() - setupPicker() NICHT mehr aufrufen

// presentPicker() - lazy setup
func presentPicker() {
    if !pickerConfigured {
        setupPicker()
        pickerConfigured = true
    }
    picker.isActive = true
    picker.present()
}
```

## Schritt 2: .task aus MenuBarView entfernen

**Dateien:** `BetterCaptureApp.swift`

Permission-Request einmalig beim App-Start statt bei jedem Popover-Öffnen. `.task` von `MenuBarView` auf `MenuBarExtra`-Ebene verschieben mit einem Flag.

```swift
@State private var hasRequestedPermissions = false

MenuBarExtra {
    MenuBarView(viewModel: viewModel)
} label: {
    MenuBarLabel(viewModel: viewModel)
}
.menuBarExtraStyle(.window)
.task {
    guard !hasRequestedPermissions else { return }
    hasRequestedPermissions = true
    await viewModel.requestPermissionsOnLaunch()
}
```

Hinweis: `.task` auf Scene-Ebene feuert nur einmal beim App-Start, nicht bei jedem Popover-Toggle.

## Schritt 3: SampleBufferMultiplexer absichern

**Datei:** `Service/SampleBufferMultiplexer.swift`

`nonisolated(unsafe)` Properties durch `OSAllocatedUnfairLock`-geschützten Zugriff ersetzen (gleich wie `AssetWriter` und `AudioTrackWriter`).

```swift
private let lock = OSAllocatedUnfairLock()
private var _assetWriter: AssetWriter?
private var _outputWavWriter: AudioTrackWriter?
private var _inputWavWriter: AudioTrackWriter?

var assetWriter: AssetWriter? {
    get { lock.withLockUnchecked { _assetWriter } }
    set { lock.withLockUnchecked { _assetWriter = newValue } }
}
// analog für outputWavWriter und inputWavWriter
```

## Schritt 4: Pre-Flight Permission Check in startRecording

**Datei:** `ViewModel/RecorderViewModel.swift`

Guard am Anfang von `startRecording()` vor der Setup-Logik:

```swift
guard CGPreflightScreenCaptureAccess() else {
    CGRequestScreenCaptureAccess()
    return
}
```

## Dateien

| Datei | Änderung |
|---|---|
| `Service/CaptureEngine.swift` | Picker-Setup lazy machen |
| `BetterCaptureApp.swift` | `.task` auf Scene-Ebene verschieben |
| `Service/SampleBufferMultiplexer.swift` | `OSAllocatedUnfairLock` hinzufügen |
| `ViewModel/RecorderViewModel.swift` | Pre-flight Permission Check |

## Verification

1. Clean Build → App starten → Menu-Bar-Icon klicken → Popover erscheint sofort
2. "Select Content" klicken → Picker erscheint (lazy init)
3. Recording starten/stoppen → Keine Crashes
4. Log prüfen: Keine `AppleEvent activation suspension` mehr
