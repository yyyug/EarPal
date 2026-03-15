import Combine
import Foundation

@MainActor
final class LiveTranslateViewModel: ObservableObject {
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

    let languageOptions = TranslationLanguage.commonOptions
    let voiceOptions = ["Default", "Warm", "Clear"]

    private let modelManager: ModelManager
    private let speechRecognizer: AppleSpeechRecognizer
    private var translationTask: Task<Void, Never>?

    init(
        modelManager: ModelManager,
        speechRecognizer: AppleSpeechRecognizer? = nil
    ) {
        self.modelManager = modelManager
        self.speechRecognizer = speechRecognizer ?? AppleSpeechRecognizer()

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
            do {
                try LocalInferenceRuntime(modelManager: modelManager)
                    .startStreamingASR(engine: modelManager.selectedASREngine)
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

    private func translateCurrentTranscript() async {
        let sourceText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else {
            translatedText = ""
            return
        }

        switch modelManager.selectedTranslationEngine {
        case .apple:
            translatedText = "Apple Translate runtime is not wired in this build yet."
            statusMessage = translatedText
        case .translateGemma:
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
