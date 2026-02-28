//
//  SettingsView.swift
//  SuperCapture
//
//  Created by Joshua Sattler on 29.01.26.
//

import AppKit
import SwiftUI

/// The settings window for SuperCapture
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    var updaterService: UpdaterService
    var loginItemService: LoginItemService
    var transcriptionService: TranscriptionService
    var globalShortcut: GlobalShortcutService?

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView(settings: settings, updaterService: updaterService, loginItemService: loginItemService, globalShortcut: globalShortcut)
            }

            Tab("Video", systemImage: "video") {
                VideoSettingsView(settings: settings)
            }

            Tab("Audio", systemImage: "waveform") {
                AudioSettingsView(settings: settings)
            }

            Tab("Transcription", systemImage: "text.word.spacing") {
                TranscriptionSettingsView(settings: settings, transcriptionService: transcriptionService)
            }
        }
        .frame(width: 500, height: 420)
    }
}

// MARK: - Video Settings

struct VideoSettingsView: View {
    @Bindable var settings: SettingsStore

    private var alphaChannelHelpText: String {
        switch settings.videoCodec {
        case .proRes4444:
            return "ProRes 4444 always includes alpha channel support"
        case .hevc:
            return "Enable transparency support for HEVC"
        case .h264, .proRes422:
            return "Alpha channel not supported by this codec"
        }
    }

    private var hdrHelpText: String {
        if settings.videoCodec.supportsHDR {
            return "Enable 10-bit HDR capture for high dynamic range content"
        } else {
            return "HDR is only supported with ProRes 422 and ProRes 4444 codecs"
        }
    }

    var body: some View {
        Form {
            Section("Recording Mode") {
                Toggle("Record Video", isOn: $settings.recordVideo)
                    .help("When disabled, only audio WAV files are recorded")
            }

            Section("Recording") {
                Picker("Frame Rate", selection: $settings.frameRate) {
                    ForEach(FrameRate.allCases) { rate in
                        Text(rate.displayName).tag(rate)
                    }
                }

                Picker("Codec", selection: $settings.videoCodec) {
                    ForEach(VideoCodec.allCases) { codec in
                        let isSupported = settings.containerFormat.supportedVideoCodecs.contains(codec)
                        if isSupported {
                            Text(codec.rawValue).tag(codec)
                        } else {
                            Text("\(codec.rawValue) (not supported for \(settings.containerFormat.rawValue.uppercased()))")
                                .foregroundStyle(.secondary)
                                .tag(codec)
                        }
                    }
                }

                Picker("Container", selection: $settings.containerFormat) {
                    ForEach(ContainerFormat.allCases) { format in
                        Text(".\(format.rawValue)").tag(format)
                    }
                }
            }
            .disabled(!settings.recordVideo)

            Section("Advanced") {
                Toggle("Capture Alpha Channel", isOn: $settings.captureAlphaChannel)
                    .disabled(!settings.recordVideo || !settings.videoCodec.canToggleAlpha || !settings.containerFormat.supportsAlphaChannel)
                    .help(alphaChannelHelpText)

                Toggle("HDR Recording", isOn: $settings.captureHDR)
                    .disabled(!settings.recordVideo || !settings.videoCodec.supportsHDR)
                    .help(hdrHelpText)
            }

            Section("Display Elements") {
                Toggle("Show Cursor", isOn: $settings.showCursor)
                Toggle("Show Wallpaper", isOn: $settings.showWallpaper)
                Toggle("Show Menu Bar", isOn: $settings.showMenuBar)
                Toggle("Show Dock", isOn: $settings.showDock)
                Toggle("Show SuperCapture", isOn: $settings.showSuperCapture)
            }
            .disabled(!settings.recordVideo)

            Section("Window Capture") {
                Toggle("Show Window Shadows", isOn: $settings.showWindowShadows)
                    .help("Include window shadows when capturing individual windows")
            }
            .disabled(!settings.recordVideo)
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Audio Settings

struct AudioSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Sources") {
                Toggle("Capture System Audio", isOn: $settings.captureSystemAudio)
                    .help("Record audio from applications and system sounds")

                Toggle("Capture Microphone", isOn: $settings.captureMicrophone)
                    .help("Record audio from the default microphone input")
            }

            Section("Format") {
                Picker("Codec", selection: $settings.audioCodec) {
                    ForEach(AudioCodec.allCases) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
                .help("PCM saves as WAV (lossless), AAC saves as M4A (compressed)")
            }

            Section {
                Text("Audio tracks are saved as separate files for post-processing flexibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore
    var updaterService: UpdaterService
    var loginItemService: LoginItemService
    var globalShortcut: GlobalShortcutService?

    @State private var automaticallyChecksForUpdates: Bool
    @State private var isRecordingShortcut = false
    @State private var recordingMonitor: Any?
    @State private var showConflictWarning = false

    init(settings: SettingsStore, updaterService: UpdaterService, loginItemService: LoginItemService, globalShortcut: GlobalShortcutService? = nil) {
        self.settings = settings
        self.updaterService = updaterService
        self.loginItemService = loginItemService
        self.globalShortcut = globalShortcut
        self._automaticallyChecksForUpdates = State(initialValue: updaterService.automaticallyChecksForUpdates)
    }

    /// Formats the base output directory path for display
    private var displayPath: String {
        let path = settings.baseOutputDirectory.path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var body: some View {
        Form {
            Section("Output Location") {
                LabeledContent {
                    HStack {
                        Button("Change...") {
                            selectOutputDirectory()
                        }

                        if settings.hasCustomOutputDirectory {
                            Button("Reset", role: .destructive) {
                                settings.resetOutputDirectory()
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(displayPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                TextField("Subdirectory", text: $settings.outputSubdirectoryPattern, prompt: Text("e.g. $YEAR/$MONTH/$DAY"))
                    .help("Placeholders: $YEAR, $MONTH, $DAY")

                Picker("Minimum Duration", selection: $settings.minimumRecordingDuration) {
                    Text("Off").tag(0)
                    Text("1 second").tag(1)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                .help("Recordings shorter than this are automatically discarded")
            }

            if let globalShortcut {
                Section("Global Shortcut") {
                    LabeledContent("Toggle Recording") {
                        HStack {
                            Button(isRecordingShortcut ? "Press a key combo..." : globalShortcut.shortcutDescription) {
                                startRecordingShortcut()
                            }

                            if globalShortcut.isEnabled && !isRecordingShortcut {
                                Button("Clear", role: .destructive) {
                                    globalShortcut.clearShortcut()
                                    showConflictWarning = false
                                }
                            }
                        }
                    }
                    .help("Global keyboard shortcut to start/stop recording (requires a modifier key)")

                    if showConflictWarning {
                        Text("This shortcut may conflict with a system shortcut")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Menu Bar") {
                Toggle("Discreet Mode", isOn: $settings.discreetMenuBar)
                    .help("Show a microphone icon instead of the recording timer")
            }

            Section("Startup") {
                Toggle("Start on Login", isOn: Binding(
                    get: { loginItemService.isEnabled },
                    set: { _ in loginItemService.toggle() }
                ))
            }

            Section("Software Updates") {
                Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                    .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                        updaterService.automaticallyChecksForUpdates = newValue
                    }

                LabeledContent("Updates") {
                    Button("Check for Update") {
                        updaterService.checkForUpdates()
                    }
                    .disabled(!updaterService.canCheckForUpdates)
                }
            }

            AboutSection()
        }
        .formStyle(.grouped)
        .padding()
        .onDisappear {
            stopRecordingShortcut()
        }
    }

    // MARK: - Output Directory

    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Select Output Directory"
        panel.message = "Choose where recordings will be saved"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputDirectory

        if panel.runModal() == .OK, let url = panel.url {
            settings.setCustomOutputDirectory(url)
        }
    }

    // MARK: - Shortcut Recording

    private func startRecordingShortcut() {
        guard !isRecordingShortcut else { return }
        isRecordingShortcut = true

        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ESC cancels
            if event.keyCode == 53 {
                stopRecordingShortcut()
                return nil
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasModifier = !flags.intersection([.command, .option, .control, .shift]).isEmpty

            // Require at least one modifier key
            guard hasModifier else { return nil }

            globalShortcut?.updateShortcut(keyCode: event.keyCode, modifierFlags: flags)
            showConflictWarning = Self.isKnownSystemShortcut(keyCode: event.keyCode, flags: flags)
            stopRecordingShortcut()
            return nil
        }
    }

    private func stopRecordingShortcut() {
        if let monitor = recordingMonitor {
            NSEvent.removeMonitor(monitor)
        }
        recordingMonitor = nil
        isRecordingShortcut = false
    }

    // MARK: - Conflict Detection

    /// Known macOS system shortcuts (best-effort).
    private static let knownSystemShortcuts: [(keyCode: UInt16, flags: NSEvent.ModifierFlags)] = [
        (12, [.command]),           // Cmd+Q
        (13, [.command]),           // Cmd+W
        (4, [.command]),            // Cmd+H
        (46, [.command]),           // Cmd+M
        (8, [.command]),            // Cmd+C
        (9, [.command]),            // Cmd+V
        (7, [.command]),            // Cmd+X
        (6, [.command]),            // Cmd+Z
        (0, [.command]),            // Cmd+A
        (1, [.command]),            // Cmd+S
        (49, [.command]),           // Cmd+Space
        (48, [.command]),           // Cmd+Tab
    ]

    private static func isKnownSystemShortcut(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        knownSystemShortcuts.contains { $0.keyCode == keyCode && $0.flags == flags }
    }
}

// MARK: - About Section

struct AboutSection: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var gitSHA: String {
        Bundle.main.infoDictionary?["GitSHA"] as? String ?? "dev"
    }

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: "v\(appVersion) (supercharged)")

            LabeledContent("Source Code") {
                Link("github.com/ahoendgen/BetterCapture", destination: URL(string: "https://github.com/ahoendgen/BetterCapture")!)
            }
        }
    }
}

// MARK: - Transcription Settings

struct TranscriptionSettingsView: View {
    @Bindable var settings: SettingsStore
    var transcriptionService: TranscriptionService

    private let timeoutOptions: [(label: String, value: Int)] = [
        ("Immediately", 0),
        ("1 minute", 60),
        ("5 minutes", 300),
        ("15 minutes", 900),
        ("30 minutes", 1800),
    ]

    var body: some View {
        Form {
            Section("Transcription") {
                Toggle("Transcribe after recording", isOn: $settings.transcribeAfterRecording)
                    .help("Automatically transcribe audio tracks when recording stops")

                Picker("Unload model after", selection: $settings.transcriptionModelUnloadTimeout) {
                    ForEach(timeoutOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .disabled(!settings.transcribeAfterRecording)
            }

            Section("Status") {
                LabeledContent("CLI") {
                    if transcriptionService.isCLIAvailable {
                        Text("Installed")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not found")
                            .foregroundStyle(.red)
                    }
                }

                LabeledContent("Model") {
                    if transcriptionService.isModelAvailable {
                        Text("Parakeet v3 (int8)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not downloaded")
                            .foregroundStyle(.red)
                    }
                }
            }

            if !transcriptionService.isCLIAvailable || !transcriptionService.isModelAvailable {
                Section {
                    Text("Install the supercapture-transcribe binary and download the Parakeet v3 model to ~/Library/Application Support/SuperCapture/models/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Preview

#Preview {
    SettingsView(settings: SettingsStore(), updaterService: UpdaterService(), loginItemService: LoginItemService(), transcriptionService: TranscriptionService())
}
