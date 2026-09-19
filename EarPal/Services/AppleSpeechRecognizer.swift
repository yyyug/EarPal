import AVFAudio
import Foundation
import Speech

enum SpeechRecognizerError: LocalizedError {
    case recognizerUnavailable
    case audioEngineFailure

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition is unavailable for the selected language."
        case .audioEngineFailure:
            return "The microphone audio engine could not start."
        }
    }
}

@MainActor
final class AppleSpeechRecognizer {
    enum InputMode {
        case microphone
        case externalBuffers
    }

    var onText: ((String) -> Void)?
    var onStopped: (() -> Void)?

    private let audioEngine = AVAudioEngine()
    private let audioSessionCoordinator: AudioSessionCoordinator
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionTaskGeneration = 0
    private var captureSessionActive = false
    private var shouldContinueRecognition = false
    private var inputMode: InputMode = .microphone

    private var isRunning: Bool {
        switch inputMode {
        case .microphone:
            return audioEngine.isRunning
        case .externalBuffers:
            return shouldContinueRecognition
        }
    }

    init(audioSessionCoordinator: AudioSessionCoordinator = .shared) {
        self.audioSessionCoordinator = audioSessionCoordinator
    }

    func requestPermissions(requiresMicrophone: Bool = true) async -> Bool {
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        guard requiresMicrophone else { return speechAuthorized }

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return speechAuthorized
        case .undetermined:
            let microphoneAuthorized = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            return speechAuthorized && microphoneAuthorized
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func startRecognition(localeIdentifier: String) throws {
        stopRecognition(notify: false)

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw SpeechRecognizerError.recognizerUnavailable
        }

        speechRecognizer = recognizer
        shouldContinueRecognition = true
        inputMode = .microphone

        try audioSessionCoordinator.activateCaptureSession()
        captureSessionActive = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            cleanupCaptureSession()
            throw SpeechRecognizerError.audioEngineFailure
        }

        beginRecognitionTask(with: recognizer)
    }

    /// Transcribes caller-supplied buffers instead of the microphone. Used for
    /// screen audio, where samples come from ScreenCaptureKit rather than the mic.
    func startBufferRecognition(localeIdentifier: String) throws {
        stopRecognition(notify: false)

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw SpeechRecognizerError.recognizerUnavailable
        }

        speechRecognizer = recognizer
        shouldContinueRecognition = true
        inputMode = .externalBuffers
        beginRecognitionTask(with: recognizer)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    func append(samples: [Float], sampleRate: Double) {
        guard let recognitionRequest,
              !samples.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?.pointee {
            samples.withUnsafeBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else { return }
                channel.update(from: baseAddress, count: samples.count)
            }
        }
        recognitionRequest.append(buffer)
    }

    func stopRecognition() {
        stopRecognition(notify: true)
    }

    private func stopRecognition(notify: Bool) {
        shouldContinueRecognition = false
        recognitionTaskGeneration += 1
        if inputMode == .microphone {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        cleanupCaptureSession()
        if notify {
            onStopped?()
        }
    }

    private func beginRecognitionTask(with recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        recognitionTaskGeneration += 1
        let generation = recognitionTaskGeneration

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let bestText = result?.bestTranscription.formattedString {
                Task { @MainActor in
                    guard self?.recognitionTaskGeneration == generation else { return }
                    self?.onText?(bestText)
                }
            }

            guard error != nil || result?.isFinal == true else { return }

            Task { @MainActor in
                self?.handleRecognitionTaskCompletion(for: generation)
            }
        }
    }

    private func handleRecognitionTaskCompletion(for generation: Int) {
        guard generation == recognitionTaskGeneration else { return }

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask = nil

        guard shouldContinueRecognition,
              isRunning,
              let recognizer = speechRecognizer,
              recognizer.isAvailable else {
            stopRecognition()
            return
        }

        beginRecognitionTask(with: recognizer)
    }

    private func cleanupCaptureSession() {
        guard captureSessionActive else { return }
        captureSessionActive = false
        audioSessionCoordinator.deactivateCaptureSession()
    }
}
