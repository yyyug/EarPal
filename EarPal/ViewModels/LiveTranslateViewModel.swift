import Combine
import Foundation

@MainActor
final class LiveTranslateViewModel: ObservableObject {
    struct AppleTranslationRequest: Equatable {
        let id = UUID()
        let text: String
        let sourceLanguageID: String
        let targetLanguageID: String
    }

    struct HistoryItem: Identifiable {
        let id = UUID()
        let timestamp: Date
        let transcript: String
        let translation: String
    }

    @Published var sourceLanguage = TranslationLanguage.english
    @Published var targetLanguage = TranslationLanguage.traditionalChinese
    @Published var transcriptText = ""
    @Published var translatedText = ""
    @Published var isListening = false
    @Published var autoSpeak = true
    @Published var speechRate: Double = 0.5
    @Published var selectedVoiceLabel = "Default"
    @Published var isShowingAudioOptions = false
    @Published var isShowingHistory = false
    @Published var isShowingModelManagement = false
    @Published var history: [HistoryItem] = []
    @Published var statusMessage = ""
    @Published var appleTranslationRequest: AppleTranslationRequest?

    let languageOptions = TranslationLanguage.commonOptions
    let voiceOptions = ["Default", "Warm", "Clear"]

    private let modelManager: ModelManager
    private let speechRecognizer: AppleSpeechRecognizer
    private let audioRecorder: AudioCaptureRecorder
    private let localASRService: LocalASRService
    private var translationTask: Task<Void, Never>?

    init(
        modelManager: ModelManager,
        speechRecognizer: AppleSpeechRecognizer? = nil,
        audioRecorder: AudioCaptureRecorder? = nil,
        localASRService: LocalASRService = LocalASRService()
    ) {
        self.modelManager = modelManager
        self.speechRecognizer = speechRecognizer ?? AppleSpeechRecognizer()
        self.audioRecorder = audioRecorder ?? AudioCaptureRecorder()
        self.localASRService = localASRService

        self.speechRecognizer.onText = { [weak self] text in
            self?.handleRecognizedText(text)
        }
        self.speechRecognizer.onStopped = { [weak self] in
            self?.isListening = false
        }
    }

    func toggleListening() async {
        if isListening {
            stopListening()
        } else {
            await startListening()
        }
    }

    func swapLanguages() {
        let currentSource = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = currentSource
        refreshTranslationIfNeeded()
    }

    func clearSession() {
        transcriptText = ""
        translatedText = ""
        statusMessage = ""
        appleTranslationRequest = nil
    }

    func receiveAppleTranslation(_ translatedText: String, for request: AppleTranslationRequest) {
        guard appleTranslationRequest == request else { return }
        self.translatedText = translatedText
        self.statusMessage = ""
    }

    func failAppleTranslation(_ error: Error, for request: AppleTranslationRequest) {
        guard appleTranslationRequest == request else { return }
        translatedText = ""
        statusMessage = error.localizedDescription
    }

    func appleTranslationUnavailable(for request: AppleTranslationRequest) {
        guard appleTranslationRequest == request else { return }
        translatedText = ""
        statusMessage = "Apple Translate requires iOS 18.0 or later."
    }

    func refreshTranslationIfNeeded() {
        guard !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        translationTask?.cancel()
        translationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            await self?.translateCurrentTranscript()
        }
    }

    private func startListening() async {
        if modelManager.selectedASREngine != .apple {
            guard modelManager.canUse(modelManager.selectedASREngine) else {
                statusMessage = "\(modelManager.selectedASREngine.displayName) is not installed on this device."
                return
            }

            let allowed = await audioRecorder.requestPermission()
            guard allowed else {
                statusMessage = "Microphone permission is not available."
                return
            }

            do {
                try audioRecorder.startRecording()
                statusMessage = "Recording for offline transcription..."
                isListening = true
            } catch {
                statusMessage = error.localizedDescription
            }
            return
        }

        let allowed = await speechRecognizer.requestPermissions()
        guard allowed else {
            statusMessage = "Microphone or speech recognition permission is not available."
            return
        }

        do {
            try speechRecognizer.startRecognition(localeIdentifier: sourceLanguage.id)
            statusMessage = ""
            isListening = true
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func stopListening() {
        if modelManager.selectedASREngine != .apple {
            do {
                let capturedAudio = try audioRecorder.stopRecording()
                isListening = false
                statusMessage = "Transcribing locally..."
                Task { [weak self] in
                    await self?.runLocalTranscription(capturedAudio)
                }
            } catch {
                isListening = false
                statusMessage = error.localizedDescription
            }
            return
        }

        speechRecognizer.stopRecognition()
        isListening = false

        if !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            history.insert(
                HistoryItem(
                    timestamp: .now,
                    transcript: transcriptText,
                    translation: translatedText
                ),
                at: 0
            )
        }
    }

    private func handleRecognizedText(_ text: String) {
        transcriptText = text
        refreshTranslationIfNeeded()
    }

    private func runLocalTranscription(_ capturedAudio: CapturedAudio) async {
        do {
            let transcript = try await localASRService.transcribe(
                audio: capturedAudio,
                engine: modelManager.selectedASREngine
            ) { [weak self] _, status in
                Task { @MainActor in
                    self?.statusMessage = status
                }
            }

            transcriptText = transcript
            statusMessage = ""
            refreshTranslationIfNeeded()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func translateCurrentTranscript() async {
        let sourceText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else {
            translatedText = ""
            appleTranslationRequest = nil
            return
        }

        switch modelManager.selectedTranslationEngine {
        case .apple:
            statusMessage = "Translating..."
            appleTranslationRequest = AppleTranslationRequest(
                text: sourceText,
                sourceLanguageID: sourceLanguage.id,
                targetLanguageID: targetLanguage.id
            )
        case .translateGemma:
            appleTranslationRequest = nil
            do {
                translatedText = try await LocalInferenceRuntime(modelManager: modelManager)
                    .translateWithTranslateGemma(text: sourceText)
                statusMessage = ""
            } catch {
                translatedText = ""
                statusMessage = error.localizedDescription
            }
        }
    }
}
