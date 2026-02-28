//
//  TranscriptionService.swift
//  SuperCapture
//

import Foundation
import os

/// Manages the `supercapture-transcribe` CLI daemon process and sends
/// transcription requests over a stdin/stdout JSON-lines protocol.
@MainActor
@Observable
final class TranscriptionService {

    private(set) var isTranscribing = false
    private(set) var progress: Double = 0
    private(set) var lastError: String?

    nonisolated(unsafe) private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SuperCapture",
        category: "TranscriptionService"
    )

    /// Path to the CLI binary bundled alongside or installed separately.
    private var cliBinaryPath: URL {
        // Look next to the app bundle first, then fall back to /usr/local/bin
        let appSupport = URL.applicationSupportDirectory.appending(path: "SuperCapture")
        let bundledPath = appSupport.appending(path: "supercapture-transcribe")
        if FileManager.default.fileExists(atPath: bundledPath.path(percentEncoded: false)) {
            return bundledPath
        }
        return URL(filePath: "/usr/local/bin/supercapture-transcribe")
    }

    /// Path to the model directory.
    private var modelPath: URL {
        URL.applicationSupportDirectory
            .appending(path: "SuperCapture/models/parakeet-tdt-0.6b-v3-int8")
    }

    var isModelAvailable: Bool {
        FileManager.default.fileExists(atPath: modelPath.path(percentEncoded: false))
    }

    var isCLIAvailable: Bool {
        FileManager.default.fileExists(atPath: cliBinaryPath.path(percentEncoded: false))
    }

    // MARK: - Public API

    /// Transcribes the given WAV files sequentially.
    /// Returns a dictionary of filename → transcription text.
    func transcribe(files: [URL], idleTimeout: Int) async throws -> [String: String] {
        guard isCLIAvailable else {
            throw TranscriptionError.cliNotFound
        }
        guard isModelAvailable else {
            throw TranscriptionError.modelNotFound
        }

        isTranscribing = true
        progress = 0
        lastError = nil

        defer {
            isTranscribing = false
            progress = 0
        }

        do {
            try ensureDaemonRunning(idleTimeout: idleTimeout)
        } catch {
            lastError = "Failed to start transcription daemon: \(error.localizedDescription)"
            throw error
        }

        var results: [String: String] = [:]

        for (index, file) in files.enumerated() {
            let baseProgress = Double(index) / Double(files.count)
            let fileWeight = 1.0 / Double(files.count)

            do {
                let text = try await transcribeFile(file, baseProgress: baseProgress, fileWeight: fileWeight)
                let name = file.deletingPathExtension().lastPathComponent
                results[name] = text
            } catch {
                logger.error("Transcription failed for \(file.lastPathComponent): \(error)")
                lastError = "Failed to transcribe \(file.lastPathComponent): \(error.localizedDescription)"
            }
        }

        return results
    }

    /// Stops the daemon process.
    func stop() {
        sendCommand(["action": "quit"])
        process?.waitUntilExit()
        cleanup()
    }

    deinit {
        process?.terminate()
    }

    // MARK: - Private

    private func ensureDaemonRunning(idleTimeout: Int) throws {
        if let proc = process, proc.isRunning {
            return
        }

        cleanup()

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()

        proc.executableURL = cliBinaryPath
        proc.arguments = [
            "--model-path", modelPath.path(percentEncoded: false),
            "--idle-timeout", "\(idleTimeout)",
        ]
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        logger.info("Transcription daemon started (PID \(proc.processIdentifier))")

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
    }

    private func transcribeFile(_ url: URL, baseProgress: Double, fileWeight: Double) async throws -> String {
        let command: [String: Any] = [
            "action": "transcribe",
            "path": url.path(percentEncoded: false),
        ]

        sendCommand(command)

        // Read responses line by line until we get a final result
        guard let stdout = stdoutPipe else {
            throw TranscriptionError.daemonNotRunning
        }

        return try await withCheckedThrowingContinuation { continuation in
            Task.detached { [weak self] in
                let handle = stdout.fileHandleForReading
                var accumulated = ""

                while true {
                    guard let data = try? handle.availableData, !data.isEmpty else {
                        continuation.resume(throwing: TranscriptionError.daemonCrashed)
                        return
                    }

                    guard let line = String(data: data, encoding: .utf8) else { continue }

                    for jsonLine in line.components(separatedBy: "\n") where !jsonLine.isEmpty {
                        guard let json = try? JSONSerialization.jsonObject(with: Data(jsonLine.utf8)) as? [String: Any] else {
                            continue
                        }

                        // Progress message
                        if let chunkProgress = json["progress"] as? Double {
                            await MainActor.run {
                                self?.progress = baseProgress + chunkProgress * fileWeight
                            }
                            continue
                        }

                        // Final result
                        if json["ok"] as? Bool == true {
                            let text = json["text"] as? String ?? ""
                            continuation.resume(returning: text)
                            return
                        }

                        // Error
                        if let error = json["error"] as? String {
                            continuation.resume(throwing: TranscriptionError.engineError(error))
                            return
                        }
                    }

                    accumulated += line
                }
            }
        }
    }

    private func sendCommand(_ dict: [String: Any]) {
        guard let stdin = stdinPipe,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              var json = String(data: data, encoding: .utf8) else {
            return
        }
        json += "\n"
        stdin.fileHandleForWriting.write(Data(json.utf8))
    }

    private func cleanup() {
        stdinPipe = nil
        stdoutPipe = nil
        process = nil
    }
}

enum TranscriptionError: LocalizedError {
    case cliNotFound
    case modelNotFound
    case daemonNotRunning
    case daemonCrashed
    case engineError(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "Transcription CLI not found. Install supercapture-transcribe."
        case .modelNotFound:
            "Parakeet v3 model not found. Download to ~/Library/Application Support/SuperCapture/models/"
        case .daemonNotRunning:
            "Transcription daemon is not running."
        case .daemonCrashed:
            "Transcription daemon stopped unexpectedly."
        case .engineError(let msg):
            "Transcription engine error: \(msg)"
        }
    }
}
