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
    private let sampleQueue = DispatchQueue(label: "com.earpal.screen-audio.samples")
    private let stateLock = NSLock()
    private let sampleConverter = AudioSampleConverter()
    private var stream: SCStream?
    private var currentFilter: SCContentFilter?
    private var selectionContinuation: CheckedContinuation<Void, Error>?
    private var chunkHandler: (@Sendable ([Float], Int) -> Void)?

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
        let handler = chunkHandler
        self.stream = nil
        chunkHandler = nil
        stateLock.unlock()

        sampleQueue.sync {
            defer { sampleConverter.reset() }
            guard let handler else { return }
            let tail = sampleConverter.flush()
            guard !tail.isEmpty else { return }
            handler(tail, AudioSampleConverter.targetSampleRate)
        }

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
        let samples = sampleConverter.samples(from: pcmBuffer)
        guard !samples.isEmpty else { return }

        stateLock.lock()
        let handler = chunkHandler
        stateLock.unlock()
        handler?(samples, AudioSampleConverter.targetSampleRate)
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