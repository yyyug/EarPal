import AVFAudio
import Foundation
import ScreenCaptureKit

enum ScreenCaptureAudioSourceError: LocalizedError {
    case notPrepared
    case selectionCancelled

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "No screen was selected for audio capture."
        case .selectionCancelled:
            return "Screen sharing selection was cancelled."
        }
    }
}

final class ScreenCaptureAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate {
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private let sampleQueue = DispatchQueue(label: "com.earpal.screen-audio.samples")
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var currentFilter: SCContentFilter?
    private var selectionContinuation: CheckedContinuation<Void, Error>?
    private var chunkHandler: (@Sendable ([Float], Int) -> Void)?
    private var converter: AVAudioConverter?
    private var converterInputKey: (Double, Int)?

    var isPrepared: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentFilter != nil
    }

    func prepare() async throws {
        stateLock.lock()
        let alreadyPrepared = currentFilter != nil
        let hasPendingSelection = selectionContinuation != nil
        stateLock.unlock()

        if alreadyPrepared || hasPendingSelection {
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateLock.lock()
            selectionContinuation = continuation
            stateLock.unlock()

            Task { @MainActor in
                let picker = SCContentSharingPicker.shared
                var configuration = SCContentSharingPickerConfiguration()
                configuration.showsMicrophoneControl = false
                configuration.showsCameraControl = false
                picker.defaultConfiguration = configuration
                picker.add(self)
                picker.present()
            }
        }
    }

    func start(onSamples: (@Sendable ([Float], Int) -> Void)?) async throws {
        stateLock.lock()
        chunkHandler = onSamples
        let filter = currentFilter
        stateLock.unlock()

        guard let filter else {
            throw ScreenCaptureAudioSourceError.notPrepared
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.captureMicrophone = false

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        stateLock.lock()
        stream = newStream
        stateLock.unlock()
        try await newStream.startCapture()
    }

    func stop() throws {
        stateLock.lock()
        let stream = self.stream
        self.stream = nil
        chunkHandler = nil
        stateLock.unlock()

        if let stream {
            Task {
                try? await stream.stopCapture()
            }
        }
    }

    // MARK: - SCContentSharingPickerObserver

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        stateLock.lock()
        currentFilter = filter
        let continuation = selectionContinuation
        selectionContinuation = nil
        stateLock.unlock()
        continuation?.resume()
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        stateLock.lock()
        let continuation = selectionContinuation
        selectionContinuation = nil
        stateLock.unlock()
        continuation?.resume(throwing: ScreenCaptureAudioSourceError.selectionCancelled)
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        stateLock.lock()
        let continuation = selectionContinuation
        selectionContinuation = nil
        stateLock.unlock()
        continuation?.resume(throwing: error)
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else { return }
        guard sampleBuffer.isValid else { return }

        guard let pcmBuffer = makePCMBuffer(from: sampleBuffer) else { return }
        guard let converted = convertToTarget(pcmBuffer) else { return }
        guard let channelData = converted.floatChannelData?.pointee else { return }

        let frameLength = Int(converted.frameLength)
        guard frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

        stateLock.lock()
        let handler = chunkHandler
        stateLock.unlock()
        handler?(samples, 16_000)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stateLock.lock()
        selectionContinuation?.resume(throwing: error)
        selectionContinuation = nil
        self.stream = nil
        chunkHandler = nil
        stateLock.unlock()
    }

    // MARK: - Audio conversion

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard
            let formatDescription = sampleBuffer.formatDescription,
            let asbd = formatDescription.audioStreamBasicDescription,
            let format = AVAudioFormat(
                standardFormatWithSampleRate: asbd.mSampleRate,
                channels: asbd.mChannelsPerFrame
            )
        else {
            return nil
        }

        do {
            return try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
            }
        } catch {
            return nil
        }
    }

    private func convertToTarget(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inputKey = (buffer.format.sampleRate, Int(buffer.format.channelCount))
        if converterInputKey != inputKey {
            converterInputKey = inputKey
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }

        let frameCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate).rounded(.up)
        ) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard conversionError == nil else { return nil }
        guard status == .haveData || status == .inputRanDry else { return nil }
        return outputBuffer
    }
}