//
//  AudioTrackWriter.swift
//  SuperCapture
//
//  WAV file writer for separate audio track output.
//

import AVFoundation
import OSLog
import os

/// Writes audio from CMSampleBuffer to a WAV file (16-bit PCM).
final class AudioTrackWriter: @unchecked Sendable {

    // MARK: - Properties

    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var dataByteCount: UInt32 = 0
    private var targetChannelCount: Int = 2
    private var isWriting = false

    private let lock = OSAllocatedUnfairLock()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SuperCapture", category: "AudioTrackWriter")

    // MARK: - Constants

    private static let sampleRate: UInt32 = 48000
    private static let bitsPerSample: UInt16 = 16
    private static let wavHeaderSize: UInt32 = 44

    // MARK: - Setup

    /// Prepares the writer to output a WAV file.
    /// - Parameters:
    ///   - url: Destination file URL (e.g. `…/2026-02-26_15-30-00_input.wav`)
    ///   - channelCount: 1 for mono (microphone), 2 for stereo (system audio)
    func setup(url: URL, channelCount: Int) throws {
        lock.withLockUnchecked {
            // Ensure output directory exists
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            // Remove existing file if present
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try? FileManager.default.removeItem(at: url)
            }

            // Create the file and open a handle
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
            guard let handle = FileHandle(forWritingAtPath: url.path(percentEncoded: false)) else {
                logger.error("Failed to open file handle for \(url.lastPathComponent)")
                return
            }

            fileHandle = handle
            fileURL = url
            targetChannelCount = channelCount
            dataByteCount = 0
            isWriting = true

            // Write placeholder WAV header (44 bytes)
            let header = Self.buildWAVHeader(
                channels: UInt16(channelCount),
                sampleRate: Self.sampleRate,
                bitsPerSample: Self.bitsPerSample,
                dataSize: 0 // placeholder — patched in finishWriting()
            )
            handle.write(header)

            logger.info("AudioTrackWriter configured: \(url.lastPathComponent), \(channelCount)ch")
        }
    }

    // MARK: - Writing

    /// Appends an audio sample buffer to the WAV file.
    ///
    /// The incoming buffer is expected to be Float32 interleaved stereo at 48 kHz
    /// (the default format from ScreenCaptureKit). This method converts to 16-bit
    /// PCM and, when `targetChannelCount == 1`, mixes stereo down to mono.
    func appendSample(_ sampleBuffer: CMSampleBuffer) {
        lock.withLockUnchecked {
            guard isWriting, let handle = fileHandle else { return }

            // Query the required buffer list size first
            var requiredSize: Int = 0
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: &requiredSize,
                bufferListOut: nil,
                bufferListSize: 0,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: nil
            )

            guard requiredSize > 0 else { return }

            // Allocate properly sized buffer and extract audio data
            let audioBufferListMemory = UnsafeMutablePointer<UInt8>.allocate(capacity: requiredSize)
            defer { audioBufferListMemory.deallocate() }

            let audioBufferListPointer = UnsafeMutableRawPointer(audioBufferListMemory)
                .bindMemory(to: AudioBufferList.self, capacity: 1)

            var blockBuffer: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: audioBufferListPointer,
                bufferListSize: requiredSize,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard status == noErr else {
                logger.warning("Failed to get audio buffer list: \(status)")
                return
            }

            let buffer = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)[0]
            guard let floatData = buffer.mData else { return }

            let floatPointer = floatData.assumingMemoryBound(to: Float.self)
            let sourceChannels = Int(buffer.mNumberChannels)
            let totalFloats = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let frameCount = sourceChannels > 0 ? totalFloats / sourceChannels : 0

            guard frameCount > 0 else { return }

            let pcmData: Data

            if targetChannelCount == 1 {
                // Mono: average all source channels per frame
                pcmData = convertToMonoInt16(
                    source: floatPointer,
                    frameCount: frameCount,
                    sourceChannels: sourceChannels
                )
            } else {
                // Stereo: convert Float32 → Int16, keep channels
                pcmData = convertToStereoInt16(
                    source: floatPointer,
                    frameCount: frameCount,
                    sourceChannels: sourceChannels
                )
            }

            handle.write(pcmData)
            dataByteCount += UInt32(pcmData.count)
        }
    }

    // MARK: - Finalization

    /// Patches the WAV header with the final data size and closes the file.
    func finishWriting() {
        lock.withLockUnchecked {
            guard isWriting, let handle = fileHandle else { return }

            // Patch RIFF chunk size at byte 4: (fileSize - 8)
            let riffSize = Self.wavHeaderSize - 8 + dataByteCount
            handle.seek(toFileOffset: 4)
            handle.write(withUnsafeBytes(of: riffSize.littleEndian) { Data($0) })

            // Patch data chunk size at byte 40
            handle.seek(toFileOffset: 40)
            handle.write(withUnsafeBytes(of: dataByteCount.littleEndian) { Data($0) })

            handle.closeFile()
            fileHandle = nil
            isWriting = false

            let megabytes = Double(Self.wavHeaderSize + dataByteCount) / 1_048_576
            logger.info("AudioTrackWriter finished: \(self.fileURL?.lastPathComponent ?? "?"), \(megabytes, format: .fixed(precision: 1)) MB")
        }
    }

    /// Cancels writing, closes the file, and deletes the partial output.
    func cancel() {
        lock.withLockUnchecked {
            fileHandle?.closeFile()
            fileHandle = nil
            isWriting = false
            dataByteCount = 0

            if let url = fileURL {
                try? FileManager.default.removeItem(at: url)
                logger.info("AudioTrackWriter cancelled, deleted \(url.lastPathComponent)")
            }
            fileURL = nil
        }
    }

    // MARK: - Conversion Helpers

    /// Converts Float32 interleaved audio to mono Int16 by averaging source channels.
    private func convertToMonoInt16(source: UnsafePointer<Float>, frameCount: Int, sourceChannels: Int) -> Data {
        var data = Data(capacity: frameCount * MemoryLayout<Int16>.size)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for ch in 0..<sourceChannels {
                sum += source[frame * sourceChannels + ch]
            }
            let avg = sum / Float(sourceChannels)
            let clamped = max(-1.0, min(1.0, avg))
            var sample = Int16(clamped * 32767)
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Converts Float32 interleaved audio to stereo Int16.
    /// If source is mono, duplicates the channel. If source has more than 2 channels, takes the first two.
    private func convertToStereoInt16(source: UnsafePointer<Float>, frameCount: Int, sourceChannels: Int) -> Data {
        var data = Data(capacity: frameCount * 2 * MemoryLayout<Int16>.size)
        for frame in 0..<frameCount {
            let left = source[frame * sourceChannels]
            let right = sourceChannels > 1 ? source[frame * sourceChannels + 1] : left

            var sampleL = Int16(max(-1.0, min(1.0, left)) * 32767)
            var sampleR = Int16(max(-1.0, min(1.0, right)) * 32767)

            withUnsafeBytes(of: &sampleL) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &sampleR) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: - WAV Header

    /// Builds a 44-byte RIFF/WAV header.
    private static func buildWAVHeader(channels: UInt16, sampleRate: UInt32, bitsPerSample: UInt16, dataSize: UInt32) -> Data {
        var header = Data(capacity: 44)

        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let riffSize = UInt32(36) + dataSize // 36 = header minus RIFF/size fields

        // RIFF chunk
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: riffSize.littleEndian) { Data($0) })
        header.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }) // chunk size
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })  // PCM format
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })

        // data sub-chunk
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        return header
    }
}
