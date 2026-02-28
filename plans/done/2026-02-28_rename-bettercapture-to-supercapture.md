# Rename BetterCapture → SuperCapture (komplett)

## Context
Die App wurde bereits als "SuperCapture" (Display Name) umbenannt, aber der Xcode-Projektname, Targets, Verzeichnisse, Source-Code und Bundle Identifier tragen noch den alten Namen "BetterCapture". Ziel: Vollständige Umbenennung.

## Scope
Alles innerhalb des Projekts wird umbenannt. **Ausgenommen:**
- Das Git-Repository-Verzeichnis (`/Users/andre/projects/opensource/BetterCapture/`) - bleibt als lokaler Pfad
- Website-Dateien (`website/`) - referenzieren das Original-Upstream-Projekt
- Docs (`docs/`) - referenzieren das Original-Upstream-Projekt
- Plan-Dateien in `plans/done/` - historisch

## Schritte

### 1. Verzeichnisse umbenennen (git mv)
- `BetterCapture/` → `SuperCapture/`
- `BetterCaptureTests/` → `SuperCaptureTests/`
- `BetterCaptureUITests/` → `SuperCaptureUITests/`
- `BetterCapture.xcodeproj/` → `SuperCapture.xcodeproj/`
- `SuperCapture/BetterCaptureApp.swift` → `SuperCapture/SuperCaptureApp.swift`
- `SuperCapture/BetterCapture.entitlements` → `SuperCapture/SuperCapture.entitlements`
- `SuperCapture/Assets.xcassets/BetterCapture.appiconset/` → `SuperCapture/Assets.xcassets/SuperCapture.appiconset/`

### 2. project.pbxproj aktualisieren
- Alle `BetterCapture` → `SuperCapture` Referenzen (Targets, Product Names, Pfade, Build Settings)
- Bundle Identifier: `de.a9g.betterCaptureSupercharged` → `de.a9g.superCapture`
- Entitlements-Pfad, Info.plist-Pfad, Usage-Strings
- `ASSETCATALOG_COMPILER_APPICON_NAME` → `SuperCapture`

### 3. Info.plist
- `CFBundleURLName`: `de.a9g.superCapture`
- Usage-Strings: "SuperCapture needs access..."
- SUFeedURL bleibt (upstream GitHub)

### 4. Source-Code-Dateien
- Struct/Class-Namen: `BetterCaptureTests` → `SuperCaptureTests`, etc.
- `@testable import BetterCapture` → `@testable import SuperCapture`
- Logger-Fallback-Strings: `"BetterCapture"` → `"SuperCapture"`
- File-Header-Kommentare: `//  BetterCapture` → `//  SuperCapture`
- SettingsStore: `showBetterCapture` → `showSuperCapture`
- SettingsStore: Default-Pfad `Movies/BetterCapture` → `Movies/SuperCapture`
- SettingsStore: Default-Filename `BetterCapture_` → `SuperCapture_`
- HookStore: App Support-Pfad `BetterCapture` → `SuperCapture`
- UI-Labels: `"Show BetterCapture"` → `"Show SuperCapture"`
- ContentFilterService: Kommentare und Log-Messages

### 5. GitHub Workflows
- `APP_NAME: SuperCapture`
- `SCHEME: SuperCapture`
- PlistBuddy-Pfade anpassen

### 6. Scheme-Datei
- `xcschememanagement.plist`: Key umbenennen

### 7. Alfred Workflow
- `dist/BetterCapture.alfredworkflow/` → `dist/SuperCapture.alfredworkflow/`

## Verifikation
- `xcodebuild -scheme SuperCapture -configuration Release build` muss erfolgreich sein
- App starten und prüfen dass Icon, Name und Funktionalität korrekt sind
