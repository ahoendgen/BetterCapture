//
//  RecorderViewModel.swift
//  SuperCapture
//
//  Created by Joshua Sattler on 29.01.26.
//

import Foundation
import ScreenCaptureKit
import AppKit
import OSLog

/// The main view model managing recording state and coordination between services
@MainActor
@Observable
final class RecorderViewModel {

    // MARK: - Recording State

    enum RecordingState {
        case idle
        case recording
        case stopping
        case transcribing
        case executingHooks
    }

    // MARK: - Published Properties

    private(set) var state: RecordingState = .idle
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var lastError: Error?
    private(set) var selectedContentFilter: SCContentFilter?

    /// The source rectangle for area selection (in display points, top-left origin)
    private(set) var selectedSourceRect: CGRect?

    /// The selected area in screen coordinates (bottom-left origin), used for the border frame overlay
    private var selectedScreenRect: CGRect?

    /// Whether the current selection is an area selection (as opposed to a picker selection)
    var isAreaSelection: Bool {
        selectedSourceRect != nil
    }

    var isRecording: Bool {
        state == .recording
    }

    var canStartRecording: Bool {
        state == .idle && (selectedContentFilter != nil || !settings.recordVideo)
    }

    var hasContentSelected: Bool {
        selectedContentFilter != nil
    }

    var formattedDuration: String {
        let hours = Int(recordingDuration) / 3600
        let minutes = (Int(recordingDuration) % 3600) / 60
        let seconds = Int(recordingDuration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    /// Whether Presenter Overlay is currently active (camera composited into stream)
    private(set) var isPresenterOverlayActive = false

    // MARK: - Dependencies

    let settings: SettingsStore
    let audioDeviceService: AudioDeviceService
    let cameraDeviceService: CameraDeviceService
    let previewService: PreviewService
    let notificationService: NotificationService
    let permissionService: PermissionService
    let hookStore: HookStore
    let globalShortcut: GlobalShortcutService
    let transcriptionService: TranscriptionService
    private let captureEngine: CaptureEngine
    private let assetWriter: AssetWriter
    private let cameraSession = CameraSession()

    // WAV audio writers
    private let outputWavWriter = AudioTrackWriter()
    private let inputWavWriter = AudioTrackWriter()
    private let multiplexer: SampleBufferMultiplexer

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SuperCapture", category: "RecorderViewModel")

    // MARK: - Private Properties

    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var videoSize: CGSize = .zero
    private let areaSelectionOverlay = AreaSelectionOverlay()
    private let selectionBorderFrame = SelectionBorderFrame()

    // Recording session tracking
    private var recordingTimestamp: String?
    private var recordingSessionID: UUID?
    private var recordingStartDate: Date?
    private var inputWavURL: URL?
    private var outputWavURL: URL?
    private var hookTask: Task<Void, Never>?
    private var isRecordingVideo = false

    // MARK: - Initialization

    init() {
        self.settings = SettingsStore()
        self.audioDeviceService = AudioDeviceService()
        self.cameraDeviceService = CameraDeviceService()
        self.previewService = PreviewService()
        self.notificationService = NotificationService(settings: settings)
        self.permissionService = PermissionService()
        self.hookStore = HookStore()
        self.globalShortcut = GlobalShortcutService()
        self.transcriptionService = TranscriptionService()
        self.captureEngine = CaptureEngine()
        self.assetWriter = AssetWriter()

        let mux = SampleBufferMultiplexer()
        mux.outputWavWriter = outputWavWriter
        mux.inputWavWriter = inputWavWriter
        self.multiplexer = mux

        captureEngine.delegate = self
        captureEngine.sampleBufferDelegate = multiplexer
        previewService.delegate = self

        // Wire global shortcut to toggle recording
        globalShortcut.onToggle = { [weak self] in
            guard let self else { return }
            Task {
                await self.toggleRecording()
            }
        }
    }

    // MARK: - Permission Methods

    /// Requests required permissions on app launch
    /// Only requests microphone permission if microphone capture is enabled
    func requestPermissionsOnLaunch() async {
        await permissionService.requestPermissions(includeMicrophone: settings.captureMicrophone)
    }

    /// Refreshes the current permission states
    func refreshPermissions() {
        permissionService.updatePermissionStates()
    }

    // MARK: - Public Methods

    /// Presents the system content sharing picker
    func presentPicker() {
        captureEngine.presentPicker()
    }

    /// Presents the area selection overlay on the display under the cursor
    func presentAreaSelection() async {
        // Dismiss any existing border frame so it doesn't overlap the selection overlay
        selectionBorderFrame.dismiss()

        // Check screen recording permission before proceeding
        guard CGPreflightScreenCaptureAccess() else {
            logger.warning("Screen recording permission not granted, requesting access")
            CGRequestScreenCaptureAccess()
            return
        }

        guard let result = await areaSelectionOverlay.present() else {
            logger.info("Area selection cancelled")
            return
        }

        // Show the border frame immediately so the user sees the selection outline
        selectionBorderFrame.show(screenRect: result.screenRect)

        // Find the corresponding SCDisplay for the selected screen
        do {
            let content = try await SCShareableContent.current
            let screenNumber = result.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

            guard let display = content.displays.first(where: { $0.displayID == screenNumber }) else {
                logger.error("Could not find SCDisplay for selected screen")
                return
            }

            // Create a content filter for the full display
            let filter = SCContentFilter(display: display, excludingWindows: [])

            // Convert screen rect (NSScreen coordinates, bottom-left origin) to
            // sourceRect (display coordinates, top-left origin)
            let displayHeight = CGFloat(display.height)
            let screenOrigin = result.screen.frame.origin

            let localX = result.screenRect.origin.x - screenOrigin.x
            let localY = result.screenRect.origin.y - screenOrigin.y

            // Flip Y: NSScreen has origin at bottom-left, sourceRect uses top-left
            let flippedY = displayHeight - localY - result.screenRect.height

            // Snap dimensions to even pixel counts for codec compatibility
            let scale = result.screen.backingScaleFactor
            let pixelWidth = result.screenRect.width * scale
            let pixelHeight = result.screenRect.height * scale
            let evenPixelWidth = ceil(pixelWidth / 2) * 2
            let evenPixelHeight = ceil(pixelHeight / 2) * 2

            let sourceRect = CGRect(
                x: localX,
                y: flippedY,
                width: evenPixelWidth / scale,
                height: evenPixelHeight / scale
            )

            // Clear any existing picker selection (mutually exclusive)
            captureEngine.clearSelection()

            // Store the area selection and set the filter on the capture engine
            selectedSourceRect = sourceRect
            selectedScreenRect = result.screenRect
            selectedContentFilter = filter
            try await captureEngine.updateFilter(filter)

            logger.info("Area selected: sourceRect=\(sourceRect.debugDescription), display=\(display.displayID)")

            // Update preview with the display filter and source rect
            await previewService.setContentFilter(filter, sourceRect: sourceRect)

        } catch {
            selectionBorderFrame.dismiss()
            logger.error("Failed to get shareable content for area selection: \(error.localizedDescription)")
        }
    }

    /// Starts a new recording session
    func startRecording() async {
        guard canStartRecording else {
            logger.warning("Cannot start recording: no content selected or already recording")
            return
        }

        guard CGPreflightScreenCaptureAccess() else {
            logger.warning("Screen recording permission not granted, requesting access")
            CGRequestScreenCaptureAccess()
            return
        }

        do {
            state = .recording
            lastError = nil
            isRecordingVideo = settings.recordVideo

            logger.info("Starting recording sequence (video: \(self.isRecordingVideo))...")

            // Generate session identifiers
            let timestamp = Self.generateTimestamp()
            recordingTimestamp = timestamp
            recordingSessionID = UUID()
            recordingStartDate = Date()

            // Stop any active live preview before starting recording
            logger.info("Stopping any active live preview...")
            await previewService.stopPreview()
            logger.info("Live preview stopped")

            // Access security-scoped output directory before writing
            _ = settings.startAccessingOutputDirectory()

            let outputDir = settings.outputDirectory

            if isRecordingVideo {
                // Determine video size from filter
                if let filter = selectedContentFilter {
                    videoSize = await getContentSize(from: filter)
                }
                logger.info("Video size: \(self.videoSize.width)x\(self.videoSize.height)")

                // Setup asset writer and wire to multiplexer
                let videoOutputURL = settings.generateOutputURL()
                try assetWriter.setup(url: videoOutputURL, config: AssetWriterConfig(from: settings), videoSize: videoSize)
                try assetWriter.startWriting()
                multiplexer.assetWriter = assetWriter
                logger.info("AssetWriter ready")

                // Start camera for Presenter Overlay before capture so the system detects it
                if settings.presenterOverlayEnabled {
                    await cameraSession.start(deviceID: settings.selectedCameraID)
                }
            } else {
                multiplexer.assetWriter = nil
            }

            // Setup WAV writers for enabled audio sources
            if settings.captureSystemAudio {
                let wavURL = Self.uniqueURL(directory: outputDir, name: "\(timestamp)_output", ext: "wav")
                try outputWavWriter.setup(url: wavURL, channelCount: 2)
                outputWavURL = wavURL
                logger.info("Output WAV writer ready: \(wavURL.lastPathComponent)")
            } else {
                outputWavURL = nil
            }

            if settings.captureMicrophone {
                let wavURL = Self.uniqueURL(directory: outputDir, name: "\(timestamp)_input", ext: "wav")
                try inputWavWriter.setup(url: wavURL, channelCount: 1)
                inputWavURL = wavURL
                logger.info("Input WAV writer ready: \(wavURL.lastPathComponent)")
            } else {
                inputWavURL = nil
            }

            // For audio-only without a content selection, create a minimal display filter
            if selectedContentFilter == nil && !isRecordingVideo {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else {
                    throw CaptureError.noContentFilterSelected
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                try await captureEngine.updateFilter(filter)
                logger.info("Auto-created display filter for audio-only recording")
            }

            // Start capture (video size only matters when recording video)
            let captureSize = isRecordingVideo ? videoSize : CGSize(width: 2, height: 2)
            logger.info("Starting capture engine...")
            try await captureEngine.startCapture(with: settings, videoSize: captureSize, sourceRect: isRecordingVideo ? selectedSourceRect : nil)

            // Start timer
            startTimer()

            logger.info("Recording started")

        } catch {
            state = .idle
            lastError = error
            if isRecordingVideo {
                assetWriter.cancel()
                multiplexer.assetWriter = nil
                cameraSession.stop()
            }
            outputWavWriter.cancel()
            inputWavWriter.cancel()
            selectionBorderFrame.dismiss()
            settings.stopAccessingOutputDirectory()
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Stops the current recording session
    func stopRecording() async {
        guard isRecording else { return }

        state = .stopping
        stopTimer()
        selectionBorderFrame.dismiss()

        let endTimestamp = Self.generateTimestamp()
        let duration = recordingStartDate.map { Date().timeIntervalSince($0) } ?? recordingDuration

        do {
            // Stop capture and camera session
            try await captureEngine.stopCapture()
            if isRecordingVideo {
                cameraSession.stop()
                isPresenterOverlayActive = false
            }

            // Finalize video file (only when video was recorded)
            var videoURL: URL?
            if isRecordingVideo {
                videoURL = try await assetWriter.finishWriting()
                multiplexer.assetWriter = nil
            }

            // Finalize WAV files
            outputWavWriter.finishWriting()
            inputWavWriter.finishWriting()

            logger.info("Recording stopped\(videoURL.map { " and saved to: \($0.lastPathComponent)" } ?? " (audio-only)")")

            // Write session metadata
            let outputDir = settings.outputDirectory
            if let ts = recordingTimestamp, let sessionID = recordingSessionID {
                let startTS = ts
                RecordingMetadataWriter.writeSessionMeta(
                    to: outputDir,
                    timestamp: ts,
                    sessionID: sessionID,
                    timestampStart: startTS,
                    timestampEnd: endTimestamp,
                    durationSeconds: duration,
                    inputWavURL: inputWavURL,
                    outputWavURL: outputWavURL,
                    videoFileURL: videoURL
                )
            }

            // Brief delay to ensure screen sharing mode has fully stopped before sending notification
            try? await Task.sleep(for: .milliseconds(100))

            // The notification references either the video file or the output directory
            let notificationFileURL = videoURL ?? outputDir

            // Run transcription if enabled
            if settings.transcribeAfterRecording {
                state = .transcribing
                recordingDuration = 0

                var wavFiles: [URL] = []
                if let url = outputWavURL { wavFiles.append(url) }
                if let url = inputWavURL { wavFiles.append(url) }

                if !wavFiles.isEmpty, let ts = recordingTimestamp {
                    do {
                        let results = try await transcriptionService.transcribe(
                            files: wavFiles,
                            idleTimeout: settings.transcriptionModelUnloadTimeout
                        )
                        saveTranscriptionResults(results, to: outputDir, timestamp: ts)
                        logger.info("Transcription completed: \(results.count) tracks")
                    } catch {
                        logger.error("Transcription failed: \(error.localizedDescription)")
                    }
                }
            }

            // Run hooks if any are configured
            let config = hookStore.configuration
            let enabledHooks = config.hooks.filter(\.isEnabled)
            if !enabledHooks.isEmpty,
               let ts = recordingTimestamp,
               let sessionID = recordingSessionID {

                state = .executingHooks
                recordingDuration = 0

                let context = HookRunContext(
                    inputWavURL: inputWavURL,
                    outputWavURL: outputWavURL,
                    recordingDirectory: outputDir,
                    timestampStart: ts,
                    timestampEnd: endTimestamp,
                    sessionID: sessionID,
                    hookCount: enabledHooks.count
                )

                hookTask = Task {
                    let results = await HookRunner.runHooks(config, context: context)
                    RecordingMetadataWriter.writeHookResults(to: outputDir, timestamp: ts, results: results)
                    logger.info("Hooks completed: \(results.filter { !$0.skipped }.count) executed")

                    state = .idle
                    notificationService.sendRecordingSavedNotification(fileURL: notificationFileURL)
                    settings.stopAccessingOutputDirectory()
                    clearSessionState()
                }
            } else {
                state = .idle
                recordingDuration = 0
                notificationService.sendRecordingSavedNotification(fileURL: notificationFileURL)
                settings.stopAccessingOutputDirectory()
                clearSessionState()
            }

        } catch {
            state = .idle
            lastError = error
            if isRecordingVideo {
                assetWriter.cancel()
                multiplexer.assetWriter = nil
            }
            outputWavWriter.cancel()
            inputWavWriter.cancel()
            settings.stopAccessingOutputDirectory()
            clearSessionState()
            notificationService.sendRecordingFailedNotification(error: error)
            logger.error("Failed to stop recording: \(error.localizedDescription)")
        }
    }

    /// Cancels any running hooks and returns to idle state.
    func cancelHooks() {
        hookTask?.cancel()
        hookTask = nil
        state = .idle
        settings.stopAccessingOutputDirectory()
        clearSessionState()
        logger.info("Hooks cancelled by user")
    }

    /// Toggles recording on/off (for global shortcut).
    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else if canStartRecording {
            await startRecording()
        }
    }

    /// Clears the current content selection
    func clearSelection() {
        captureEngine.clearSelection()
    }

    /// Resets the area selection, removing the border frame and clearing state
    func resetAreaSelection() async {
        selectedSourceRect = nil
        selectedScreenRect = nil
        selectedContentFilter = nil
        selectionBorderFrame.dismiss()
        await previewService.stopPreview()
        previewService.clearPreview()
    }

    /// Starts the live preview stream (call when menu bar window opens)
    func startPreview() async {
        guard !isRecording else { return }
        await previewService.startPreview()
    }

    /// Stops the live preview stream (call when menu bar window closes)
    func stopPreview() async {
        await previewService.stopPreview()
    }

    // MARK: - Timer Management

    private func startTimer() {
        recordingStartTime = Date()
        recordingDuration = 0

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
    }

    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
    }

    // MARK: - Transcription Helpers

    /// Saves transcription results as JSON and plain text files alongside the recording.
    private func saveTranscriptionResults(_ results: [String: String], to directory: URL, timestamp: String) {
        // Save structured JSON
        let jsonURL = Self.uniqueURL(directory: directory, name: "\(timestamp)_transcription", ext: "json")
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: jsonURL)
        }

        // Save individual plain text files
        for (name, text) in results where !text.isEmpty {
            let txtURL = Self.uniqueURL(directory: directory, name: "\(timestamp)_\(name)", ext: "txt")
            try? text.write(to: txtURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Session Helpers

    private func clearSessionState() {
        recordingTimestamp = nil
        recordingSessionID = nil
        recordingStartDate = nil
        inputWavURL = nil
        outputWavURL = nil
        hookTask = nil
        isRecordingVideo = false
    }

    /// Generates a timestamp string in `yyyy-MM-dd_HH-mm-ss` format.
    static func generateTimestamp(from date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    /// Returns a unique file URL, appending `_01`, `_02`, etc. if a file already exists.
    static func uniqueURL(directory: URL, name: String, ext: String) -> URL {
        let base = directory.appending(path: "\(name).\(ext)")
        guard FileManager.default.fileExists(atPath: base.path()) else { return base }

        for i in 1...99 {
            let suffixed = directory.appending(path: "\(name)_\(String(format: "%02d", i)).\(ext)")
            if !FileManager.default.fileExists(atPath: suffixed.path()) {
                return suffixed
            }
        }
        return base // fallback
    }

    // MARK: - Content Size

    private func getContentSize(from filter: SCContentFilter) async -> CGSize {
        // If area selection is active, use the source rect dimensions.
        // The sourceRect is already snapped to even pixel counts in presentAreaSelection().
        if let sourceRect = selectedSourceRect {
            let scale = CGFloat(filter.pointPixelScale)
            return CGSize(width: sourceRect.width * scale, height: sourceRect.height * scale)
        }

        // Get the content rect from the filter
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)

        if rect.width > 0 && rect.height > 0 {
            return CGSize(
                width: rect.width * scale,
                height: rect.height * scale
            )
        }

        // Fallback to main screen size
        if let screen = NSScreen.main {
            return CGSize(
                width: screen.frame.width * screen.backingScaleFactor,
                height: screen.frame.height * screen.backingScaleFactor
            )
        }

        return CGSize(width: 1920, height: 1080)
    }
}

// MARK: - CaptureEngineDelegate

extension RecorderViewModel: CaptureEngineDelegate {

    func captureEngine(_ engine: CaptureEngine, didUpdateFilter filter: SCContentFilter) {
        // Clear any area selection (picker and area selections are mutually exclusive)
        selectedSourceRect = nil
        selectedScreenRect = nil
        selectionBorderFrame.dismiss()

        selectedContentFilter = filter
        logger.info("Content filter updated")

        // Capture a static thumbnail for the preview
        Task {
            await previewService.setContentFilter(filter)
        }
    }

    func captureEngine(_ engine: CaptureEngine, didStopWithError error: Error?) {
        // Check if user clicked "Stop Sharing" in the menu bar
        let isUserStopped = (error as? SCStreamError)?.code == .userStopped

        if let error, !isUserStopped {
            lastError = error
            logger.error("Capture stopped with error: \(error.localizedDescription)")
        }

        // Clean up if we were recording
        if isRecording {
            if isUserStopped {
                // User clicked "Stop Sharing" - gracefully save the recording
                logger.info("User stopped sharing via system UI, saving recording...")
                Task {
                    await stopRecording()
                }
            } else {
                // Stream error during recording - try to save what we have
                logger.warning("Stream stopped unexpectedly, attempting to save recording...")
                Task {
                    await stopRecording()
                }
            }
        }
    }

    func captureEngine(_ engine: CaptureEngine, presenterOverlayDidChange isActive: Bool) {
        isPresenterOverlayActive = isActive
        logger.info("Presenter Overlay \(isActive ? "activated" : "deactivated")")
    }

    func captureEngineDidCancelPicker(_ engine: CaptureEngine) {
        logger.info("Picker was cancelled, clearing selection and preview")

        // Clear the selected content filter
        selectedContentFilter = nil

        // Stop and clear the preview
        Task {
            await previewService.cancelCapture()
            previewService.clearPreview()
        }
    }
}

// MARK: - PreviewServiceDelegate

extension RecorderViewModel: PreviewServiceDelegate {

    func previewServiceDidStopByUser(_ service: PreviewService) {
        logger.info("User stopped sharing via system UI, clearing selection")

        // Clear the selection
        selectedContentFilter = nil

        // Clear the content filter in capture engine and deactivate picker
        captureEngine.clearSelection()
        captureEngine.deactivatePicker()
    }
}
