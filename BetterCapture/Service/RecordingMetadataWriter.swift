//
//  RecordingMetadataWriter.swift
//  BetterCapture
//
//  Writes session metadata and hook result logs to the recording directory.
//

import Foundation
import OSLog

/// Writes JSON metadata files alongside recordings.
enum RecordingMetadataWriter {

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture", category: "RecordingMetadataWriter")

    /// Content for `{TS}_meta.json`.
    struct SessionMeta: Codable {
        let sessionID: String
        let timestampStart: String
        let timestampEnd: String
        let durationSeconds: Double
        let appVersion: String
        let inputWav: FileMeta?
        let outputWav: FileMeta?
        let videoFile: String?

        struct FileMeta: Codable {
            let path: String
            let sampleRate: Int
            let channels: Int
            let bitsPerSample: Int
        }
    }

    /// Writes `{TS}_meta.json` to the recording directory.
    static func writeSessionMeta(
        to directory: URL,
        timestamp: String,
        sessionID: UUID,
        timestampStart: String,
        timestampEnd: String,
        durationSeconds: Double,
        inputWavURL: URL?,
        outputWavURL: URL?,
        videoFileURL: URL?
    ) {
        let meta = SessionMeta(
            sessionID: sessionID.uuidString,
            timestampStart: timestampStart,
            timestampEnd: timestampEnd,
            durationSeconds: durationSeconds,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            inputWav: inputWavURL.map {
                .init(path: $0.path(), sampleRate: 48000, channels: 1, bitsPerSample: 16)
            },
            outputWav: outputWavURL.map {
                .init(path: $0.path(), sampleRate: 48000, channels: 2, bitsPerSample: 16)
            },
            videoFile: videoFileURL?.lastPathComponent
        )

        let url = directory.appending(path: "\(timestamp)_meta.json")
        writeJSON(meta, to: url)
    }

    /// Writes `{TS}_hooks.json` to the recording directory.
    static func writeHookResults(to directory: URL, timestamp: String, results: [HookResult]) {
        let url = directory.appending(path: "\(timestamp)_hooks.json")
        writeJSON(results, to: url)
    }

    // MARK: - Private

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            logger.info("Wrote \(url.lastPathComponent)")
        } catch {
            logger.error("Failed to write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
