//
//  HookRunner.swift
//  SuperCapture
//
//  Executes post-recording hook commands sequentially.
//

import Foundation
import OSLog

/// Context passed to each hook via environment variables.
struct HookRunContext: Sendable {
    let inputWavURL: URL?
    let outputWavURL: URL?
    let recordingDirectory: URL
    let timestampStart: String
    let timestampEnd: String
    let sessionID: UUID
    let hookCount: Int
}

/// Result of executing a single hook command.
struct HookResult: Codable, Sendable {
    let index: Int
    let command: String
    let exitCode: Int32
    let durationSeconds: Double
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let skipped: Bool
}

/// Executes post-recording hooks as shell commands.
enum HookRunner {

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SuperCapture", category: "HookRunner")

    /// Maximum bytes captured per stdout/stderr stream.
    private static let outputTruncationLimit = 65_536

    /// Runs all enabled hooks from the configuration sequentially.
    ///
    /// Respects `stopOnError` and per-hook timeout from the configuration.
    /// This method is safe to call from a background `Task`.
    static func runHooks(_ config: HookConfiguration, context: HookRunContext) async -> [HookResult] {
        var results: [HookResult] = []
        var shouldStop = false

        for (index, hook) in config.hooks.enumerated() {
            guard !Task.isCancelled else {
                results.append(skippedResult(index: index, command: hook.command))
                continue
            }

            guard hook.isEnabled else {
                results.append(skippedResult(index: index, command: hook.command))
                continue
            }

            if shouldStop {
                results.append(skippedResult(index: index, command: hook.command))
                continue
            }

            logger.info("Running hook \(index + 1)/\(config.hooks.count): \(hook.command.prefix(80))")

            let result = await executeHook(
                command: hook.command,
                index: index,
                context: context,
                timeoutSeconds: config.timeoutSeconds
            )

            results.append(result)

            if result.exitCode != 0 && config.stopOnError {
                logger.warning("Hook \(index + 1) failed (exit \(result.exitCode)), stopping due to stopOnError")
                shouldStop = true
            }
        }

        return results
    }

    // MARK: - Private

    private static func executeHook(
        command: String,
        index: Int,
        context: HookRunContext,
        timeoutSeconds: Int
    ) async -> HookResult {
        let startTime = ContinuousClock.now

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.environment = buildEnvironment(index: index, context: context)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Read stdout/stderr asynchronously to avoid pipe deadlock
        let stdoutData = PipeReader(pipe: stdoutPipe, limit: outputTruncationLimit)
        let stderrData = PipeReader(pipe: stderrPipe, limit: outputTruncationLimit)

        do {
            try process.run()
        } catch {
            let duration = startTime.duration(to: .now)
            logger.error("Failed to launch hook \(index): \(error.localizedDescription)")
            return HookResult(
                index: index,
                command: command,
                exitCode: -1,
                durationSeconds: duration.seconds,
                stdout: "",
                stderr: "Failed to launch: \(error.localizedDescription)",
                timedOut: false,
                skipped: false
            )
        }

        // Timeout enforcement
        let timeoutTask = Task.detached {
            try await Task.sleep(for: .seconds(timeoutSeconds))
            if process.isRunning {
                logger.warning("Hook \(index) timed out after \(timeoutSeconds)s, terminating")
                process.terminate()
                // Give it a few seconds, then force kill
                try? await Task.sleep(for: .seconds(5))
                if process.isRunning {
                    process.interrupt()
                }
            }
        }

        // Wait for process to exit
        process.waitUntilExit()
        timeoutTask.cancel()

        let duration = startTime.duration(to: .now)
        let timedOut = duration.seconds >= Double(timeoutSeconds)

        let stdout = stdoutData.read()
        let stderr = stderrData.read()

        logger.info("Hook \(index) finished: exit=\(process.terminationStatus), duration=\(duration.seconds, format: .fixed(precision: 1))s")

        return HookResult(
            index: index,
            command: command,
            exitCode: process.terminationStatus,
            durationSeconds: duration.seconds,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut,
            skipped: false
        )
    }

    private static func buildEnvironment(index: Int, context: HookRunContext) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["BC_INPUT_WAV"] = context.inputWavURL?.path() ?? ""
        env["BC_OUTPUT_WAV"] = context.outputWavURL?.path() ?? ""
        env["BC_DIR"] = context.recordingDirectory.path()
        env["BC_TS_START"] = context.timestampStart
        env["BC_TS_END"] = context.timestampEnd
        env["BC_SESSION_ID"] = context.sessionID.uuidString
        env["BC_HOOK_INDEX"] = String(index)
        env["BC_HOOK_COUNT"] = String(context.hookCount)
        return env
    }

    private static func skippedResult(index: Int, command: String) -> HookResult {
        HookResult(
            index: index,
            command: command,
            exitCode: 0,
            durationSeconds: 0,
            stdout: "",
            stderr: "",
            timedOut: false,
            skipped: true
        )
    }
}

// MARK: - Duration Helper

private extension Duration {
    var seconds: Double {
        let (s, a) = components
        return Double(s) + Double(a) / 1_000_000_000_000
    }
}

// MARK: - Pipe Reader

/// Reads from a pipe on a background thread, truncating at `limit` bytes.
private final class PipeReader: Sendable {
    private let pipe: Pipe
    private let limit: Int
    private let storage: OSAllocatedUnfairLock<Data>

    init(pipe: Pipe, limit: Int) {
        self.pipe = pipe
        self.limit = limit
        self.storage = OSAllocatedUnfairLock(initialState: Data())

        // Read in a background thread to prevent pipe buffer deadlock
        let fileHandle = pipe.fileHandleForReading
        let storageLock = self.storage
        let readLimit = self.limit
        DispatchQueue.global(qos: .utility).async {
            let data = fileHandle.readDataToEndOfFile()
            storageLock.withLock { stored in
                if data.count > readLimit {
                    stored = data.prefix(readLimit)
                } else {
                    stored = data
                }
            }
        }
    }

    func read() -> String {
        let data = storage.withLock { $0 }
        return String(decoding: data, as: UTF8.self)
    }
}
