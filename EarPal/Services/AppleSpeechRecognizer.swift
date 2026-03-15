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
    var onText: ((String) -> Void)?
    var onStopped: (() -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func requestPermissions() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

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
        stopRecognition()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw SpeechRecognizerError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

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
            throw SpeechRecognizerError.audioEngineFailure
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let bestText = result?.bestTranscription.formattedString {
                Task { @MainActor in
                    self?.onText?(bestText)
                }
            }

            if error != nil || result?.isFinal == true {
                Task { @MainActor in
                    self?.stopRecognition()
                }
            }
        }
    }

    func stopRecognition() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onStopped?()
    }
}
