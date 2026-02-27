//
//  SampleBufferMultiplexer.swift
//  BetterCapture
//
//  Forwards sample buffers from CaptureEngine to multiple delegates.
//

import ScreenCaptureKit
import os

/// Fans out sample buffer callbacks to the main asset writer and optional WAV audio writers.
final class SampleBufferMultiplexer: CaptureEngineSampleBufferDelegate, @unchecked Sendable {

    private let lock = OSAllocatedUnfairLock()

    /// The primary writer (video + container audio tracks).
    private var _assetWriter: AssetWriter?

    /// WAV writer for system/meeting audio (output track).
    private var _outputWavWriter: AudioTrackWriter?

    /// WAV writer for microphone audio (input track).
    private var _inputWavWriter: AudioTrackWriter?

    var assetWriter: AssetWriter? {
        get { lock.withLockUnchecked { _assetWriter } }
        set { lock.withLockUnchecked { _assetWriter = newValue } }
    }

    var outputWavWriter: AudioTrackWriter? {
        get { lock.withLockUnchecked { _outputWavWriter } }
        set { lock.withLockUnchecked { _outputWavWriter = newValue } }
    }

    var inputWavWriter: AudioTrackWriter? {
        get { lock.withLockUnchecked { _inputWavWriter } }
        set { lock.withLockUnchecked { _inputWavWriter = newValue } }
    }

    // MARK: - CaptureEngineSampleBufferDelegate

    nonisolated func captureEngine(_ engine: CaptureEngine, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer) {
        lock.withLockUnchecked {
            _assetWriter?.captureEngine(engine, didOutputVideoSampleBuffer: sampleBuffer)
        }
    }

    nonisolated func captureEngine(_ engine: CaptureEngine, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer) {
        lock.withLockUnchecked {
            _assetWriter?.captureEngine(engine, didOutputAudioSampleBuffer: sampleBuffer)
            _outputWavWriter?.appendSample(sampleBuffer)
        }
    }

    nonisolated func captureEngine(_ engine: CaptureEngine, didOutputMicrophoneSampleBuffer sampleBuffer: CMSampleBuffer) {
        lock.withLockUnchecked {
            _assetWriter?.captureEngine(engine, didOutputMicrophoneSampleBuffer: sampleBuffer)
            _inputWavWriter?.appendSample(sampleBuffer)
        }
    }
}
