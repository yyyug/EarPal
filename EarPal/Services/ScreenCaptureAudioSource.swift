import AVFAudio
import Foundation

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

enum ScreenCaptureAudioSourceError: LocalizedError {
    case notPrepared
    case selectionCancelled
    case screenCaptureUnavailable
    case screenCaptureRequiresiOS27

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "No screen was selected for audio capture."
        case .selectionCancelled:
            return "Screen sharing selection was cancelled."
        case .screenCaptureUnavailable:
            return "Screen capture is not available on this device."
        case .screenCaptureRequiresiOS27:
            return "Screen audio capture requires iOS 27."
        }
    }
}

#if canImport(ScreenCaptureKit)

final class ScreenCaptureAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver {
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
    private var converterInputKey: AudioFormatKey?

    private struct AudioFormatKey: Equatable {
        let sampleRate: Double
        let channelCount: Int
    }

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
                guard picker.isAvailable else {
                    self.resumeSelection(with: .failure(ScreenCaptureAudioSourceError.screenCaptureUnavailable))
                    return
                }

                var configuration = SCContentSharingPickerConfiguration()
                configuration.showsMicrophoneControl = false
                configuration.showsCameraControl = false
                picker.defaultConfiguration = configuration
                picker.add(self)
                picker.isActive = true
                picker.present()
            }
        }
    }

    private func resumeSelection(with result: Result<Void, Error>) {
        stateLock.lock()
        let continuation = selectionContinuation
        selectionContinuation = nil
        stateLock.unlock()
        continuation?.resume(with: result)
    }

    private func deactivatePicker() {
        Task { @MainActor in
            let picker = SCContentSharingPicker.shared
            picker.remove(self)
            picker.isActive = false
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

    @objc(contentSharingPicker:didUpdateWithFilter:forStream:)
    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        stateLock.lock()
        currentFilter = filter
        stateLock.unlock()
        resumeSelection(with: .success(()))
        deactivatePicker()
    }

    @objc(contentSharingPicker:didCancelForStream:)
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        resumeSelection(with: .failure(ScreenCaptureAudioSourceError.selectionCancelled))
        deactivatePicker()
    }

    @objc(contentSharingPickerStartDidFailWithError:)
    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        resumeSelection(with: .failure(error))
        deactivatePicker()
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
        let inputKey = AudioFormatKey(
            sampleRate: buffer.format.sampleRate,
            channelCount: Int(buffer.format.channelCount)
        )
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

#else

final class ScreenCaptureAudioSource: NSObject, AudioSource {
    var isPrepared: Bool { false }

    func prepare() async throws {
        throw ScreenCaptureAudioSourceError.screenCaptureRequiresiOS27
    }

    func start(onSamples: (@Sendable ([Float], Int) -> Void)?) async throws {
        throw ScreenCaptureAudioSourceError.screenCaptureRequiresiOS27
    }

    func stop() throws {}
}

#endif