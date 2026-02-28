# feat: Start on Login

## Context
User wants a "Start on Login" toggle in settings so SuperCapture launches automatically at login.

## Approach
Use `SMAppService.mainApp` (ServiceManagement, macOS 13+). No UserDefaults needed - SMAppService manages its own state.

## Changes

### 1. New: `SuperCapture/Service/LoginItemService.swift`
- `@MainActor @Observable` class
- Wraps `SMAppService.mainApp` (same pattern as `UpdaterService` wrapping Sparkle)
- `isEnabled: Bool` computed from `SMAppService.mainApp.status == .enabled`
- `toggle()` method calling `register()` / `unregister()`

### 2. Modify: `SuperCapture/SuperCaptureApp.swift`
- Add `@State private var loginItemService = LoginItemService()`
- Pass to `SettingsView`

### 3. Modify: `SuperCapture/View/SettingsView.swift`
- Add `loginItemService` parameter to `SettingsView` and `GeneralSettingsView`
- Add "Startup" section in General tab between "Global Shortcut" and "Software Updates":
  - Toggle "Start on Login" bound to `loginItemService`

No entitlement changes needed (sandbox already disabled).

## Verification
- Build and launch
- Toggle "Start on Login" in Settings → General
- Verify in System Settings → General → Login Items that SuperCapture appears/disappears
