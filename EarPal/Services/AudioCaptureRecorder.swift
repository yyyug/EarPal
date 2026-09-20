import AVFAudio
import Foundation

enum AudioCaptureRecorderError: LocalizedError {
    case microphonePermissionDenied
    case recordingUnavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is not available."
        case .recordingUnavailable:
            return "Audio recording is unavailable right now."
        }
    }
}

final class AudioCaptureRecorder {
    private let audioEngine = AVAudioEngine()
    private let audioSessionCoordinator: AudioSessionCoordinator
    private let sampleConverter = AudioSampleConverter()
    private let stateLock = NSLock()
    private var isRecording = false
    private var captureSessionActive = false
    private var chunkHandler: (@Sendable ([Float], Int) -> Void)?

    init(audioSessionCoordinator: AudioSessionCoordinator = .shared) {
        self.audioSessionCoordinator = audioSessionCoordinator
    }

    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func startRecording(onSamples: (@Sendable ([Float], Int) -> Void)? = nil) throws {
        stateLock.lock()
        if isRecording {
            stateLock.unlock()
            return
        }
        chunkHandler = onSamples
        stateLock.unlock()

        sampleConverter.reset()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              AudioSampleConverter.canConvert(from: inputFormat) else {
            throw AudioCaptureRecorderError.recordingUnavailable
        }

        try audioSessionCoordinator.activateCaptureSession()
        captureSessionActive = true

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processIncomingBuffer(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            stateLock.lock()
            isRecording = true
            stateLock.unlock()
        } catch {
            inputNode.removeTap(onBus: 0)
            cleanupCaptureSession()
            throw AudioCaptureRecorderError.recordingUnavailable
        }
    }

    func stopRecording() throws {
        stateLock.lock()
        let currentlyRecording = isRecording
        let handler = chunkHandler
        isRecording = false
        chunkHandler = nil
        stateLock.unlock()

        guard currentlyRecording else {
            throw AudioCaptureRecorderError.recordingUnavailable
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        flushPendingSamples(handler: handler)
        cleanupCaptureSession()
        sampleConverter.reset()
    }

    private func cleanupCaptureSession() {
        guard captureSessionActive else { return }
        captureSessionActive = false
        audioSessionCoordinator.deactivateCaptureSession()
    }

    private func flushPendingSamples(handler: (@Sendable ([Float], Int) -> Void)?) {
        guard let handler else { return }
        let tail = sampleConverter.flush()
        guard !tail.isEmpty else { return }
        handler(tail, AudioSampleConverter.targetSampleRate)
    }

    private func processIncomingBuffer(_ buffer: AVAudioPCMBuffer) {
        let samples = sampleConverter.samples(from: buffer)
        guard !samples.isEmpty else { return }

        stateLock.lock()
        let handler = chunkHandler
        stateLock.unlock()
        handler?(samples, AudioSampleConverter.targetSampleRate)
    }
}
