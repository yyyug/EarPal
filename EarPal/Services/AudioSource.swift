import AVFAudio
import Foundation
import OSLog

enum AudioCaptureSourceOption: String, CaseIterable, Identifiable {
    case microphone
    case screenAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .screenAudio:
            return "Screen Audio"
        }
    }

    var iconName: String {
        switch self {
        case .microphone:
            return "mic.fill"
        case .screenAudio:
            return "display"
        }
    }
}

protocol AudioSource: AnyObject {
    func start(onSamples: (@Sendable ([Float], Int) -> Void)?) async throws
    func stop() throws
}

/// Converts captured audio buffers into the 16 kHz mono Float32 samples the ASR engines expect.
///
/// The converter runs at the highest sample-rate conversion quality, is skipped entirely when the
/// input already matches the target format, logs conversion failures instead of dropping audio
/// silently, applies a conservative peak normalisation so quiet sources stay intelligible, and can
/// flush whatever the resampler still holds when capture stops.
final class AudioSampleConverter {
    static let targetSampleRate = 16_000

    private static let logger = Logger(subsystem: "EarPal", category: "AudioSampleConverter")
    private static let quietPeakThreshold: Float = 0.1
    private static let targetPeak: Float = 0.5
    private static let maximumGain: Float = 8
    private static let gainSmoothing: Float = 0.25
    private static let flushFrameCapacity: AVAudioFrameCount = 8_192

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private struct FormatKey: Equatable {
        let sampleRate: Double
        let channelCount: Int
    }

    private var converter: AVAudioConverter?
    private var inputKey: FormatKey?
    private var smoothedGain: Float = 1

    static func canConvert(from format: AVAudioFormat) -> Bool {
        matchesTargetFormat(format) || AVAudioConverter(from: format, to: targetFormat) != nil
    }

    func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }

        let output: AVAudioPCMBuffer
        if Self.matchesTargetFormat(buffer.format) {
            output = buffer
        } else {
            guard let converted = convert(buffer) else { return [] }
            output = converted
        }

        guard let channel = output.floatChannelData?.pointee else { return [] }
        var samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        applyGain(to: &samples)
        return samples
    }

    /// Drains samples the resampler still holds, so the tail of a capture is not lost.
    func flush() -> [Float] {
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: Self.flushFrameCapacity) else {
            return []
        }

        var suppliedEndOfStream = false
        var conversionError: NSError?
        _ = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if suppliedEndOfStream {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedEndOfStream = true
            outStatus.pointee = .endOfStream
            return nil
        }

        guard conversionError == nil,
              output.frameLength > 0,
              let channel = output.floatChannelData?.pointee else {
            return []
        }

        var samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        applyGain(to: &samples)
        return samples
    }

    func reset() {
        converter?.reset()
        converter = nil
        inputKey = nil
        smoothedGain = 1
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let key = FormatKey(
            sampleRate: buffer.format.sampleRate,
            channelCount: Int(buffer.format.channelCount)
        )
        if inputKey != key {
            inputKey = key
            let newConverter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
            newConverter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = newConverter
        }
        guard let converter else { return nil }

        let frameCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * Self.targetFormat.sampleRate / buffer.format.sampleRate).rounded(.up)
        ) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            Self.logger.error("Audio conversion failed: \(conversionError.localizedDescription, privacy: .public)")
            return nil
        }

        guard status == .haveData || status == .inputRanDry, output.frameLength > 0 else { return nil }

        if status == .haveData, output.frameLength >= output.frameCapacity {
            Self.logger.debug("Sample-rate conversion saturated its output buffer; trailing input may be dropped.")
        }

        return output
    }

    private static func matchesTargetFormat(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatFloat32
            && !format.isInterleaved
            && format.channelCount == targetFormat.channelCount
            && abs(format.sampleRate - targetFormat.sampleRate) < 0.5
    }

    private func applyGain(to samples: inout [Float]) {
        guard !samples.isEmpty else { return }

        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }

        let desiredGain: Float
        if peak >= Self.quietPeakThreshold {
            desiredGain = 1
        } else if peak > 0 {
            desiredGain = min(Self.targetPeak / peak, Self.maximumGain)
        } else {
            desiredGain = smoothedGain
        }

        smoothedGain += (desiredGain - smoothedGain) * Self.gainSmoothing

        guard smoothedGain > 1 else { return }

        let safeGain = peak > 0 ? min(smoothedGain, 0.95 / peak) : smoothedGain
        guard safeGain > 1 else { return }

        for index in samples.indices {
            samples[index] *= safeGain
        }
    }
}

final class MicrophoneAudioSource: AudioSource {
    private let recorder: AudioCaptureRecorder

    init(recorder: AudioCaptureRecorder = AudioCaptureRecorder()) {
        self.recorder = recorder
    }

    var underlyingRecorder: AudioCaptureRecorder { recorder }

    func requestPermission() async -> Bool {
        await recorder.requestPermission()
    }

    func start(onSamples: (@Sendable ([Float], Int) -> Void)?) async throws {
        try recorder.startRecording(onSamples: onSamples)
    }

    func stop() throws {
        try recorder.stopRecording()
    }
}
