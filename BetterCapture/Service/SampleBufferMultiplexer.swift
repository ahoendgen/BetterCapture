//
//  SampleBufferMultiplexer.swift
//  BetterCapture
//
//  Forwards sample buffers from CaptureEngine to multiple delegates.
//

import ScreenCaptureKit

/// Fans out sample buffer callbacks to the main asset writer and optional WAV audio writers.
final class SampleBufferMultiplexer: CaptureEngineSampleBufferDelegate, @unchecked Sendable {

    /// The primary writer (video + container audio tracks).
    nonisolated(unsafe) var assetWriter: AssetWriter?

    /// WAV writer for system/meeting audio (output track).
    nonisolated(unsafe) var outputWavWriter: AudioTrackWriter?

    /// WAV writer for microphone audio (input track).
    nonisolated(unsafe) var inputWavWriter: AudioTrackWriter?

    // MARK: - CaptureEngineSampleBufferDelegate

    nonisolated func captureEngine(_ engine: CaptureEngine, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer) {
        assetWriter?.captureEngine(engine, didOutputVideoSampleBuffer: sampleBuffer)
    }

    nonisolated func captureEngine(_ engine: CaptureEngine, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer) {
        assetWriter?.captureEngine(engine, didOutputAudioSampleBuffer: sampleBuffer)
        outputWavWriter?.appendSample(sampleBuffer)
    }

    nonisolated func captureEngine(_ engine: CaptureEngine, didOutputMicrophoneSampleBuffer sampleBuffer: CMSampleBuffer) {
        assetWriter?.captureEngine(engine, didOutputMicrophoneSampleBuffer: sampleBuffer)
        inputWavWriter?.appendSample(sampleBuffer)
    }
}
