import Combine
import Foundation

@MainActor
final class LiveTranslateViewModel: ObservableObject {
    struct AppleTranslationRequest: Equatable {
        let id = UUID()
        let generation: Int
        let text: String
        let sourceLanguageID: String
        let targetLanguageID: String
    }

    enum TranslationStatus: Equatable {
        case idle
        case waitingForStableInput
        case translating
        case failed(String)
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
    @Published var translationStatus: TranslationStatus = .idle
    @Published var appleTranslationRequest: AppleTranslationRequest?

    let languageOptions = TranslationLanguage.commonOptions
    let voiceOptions = ["Default", "Warm", "Clear"]

    private let modelManager: ModelManager
    private let speechRecognizer: AppleSpeechRecognizer
    private let audioRecorder: AudioCaptureRecorder
    private let localASRService: LocalASRService
    private let speechPlaybackService: AppleSpeechPlaybackService
    private var localStreamingSession: LocalASRStreamingSession?
    private var translationDebounceTask: Task<Void, Never>?
    private var activeTranslationTask: Task<Void, Never>?
    private var translationGeneration = 0
    private var pendingTranscriptText = ""
    private var lastCommittedTranscriptText = ""
    private var lastTranslatedTranscriptText = ""
    private var lastTranslatedSourceLanguageID = ""
    private var lastTranslatedTargetLanguageID = ""
    private var lastTranslatedEngineID = ""
    private var lastTranscriptChangeAt = Date.distantPast

    init(
        modelManager: ModelManager,
        speechRecognizer: AppleSpeechRecognizer? = nil,
        audioRecorder: AudioCaptureRecorder? = nil,
        localASRService: LocalASRService = LocalASRService(),
        speechPlaybackService: AppleSpeechPlaybackService? = nil
    ) {
        self.modelManager = modelManager
        self.speechRecognizer = speechRecognizer ?? AppleSpeechRecognizer()
        self.audioRecorder = audioRecorder ?? AudioCaptureRecorder()
        self.localASRService = localASRService
        self.speechPlaybackService = speechPlaybackService ?? AppleSpeechPlaybackService()

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
        let session = localStreamingSession
        localStreamingSession = nil
        Task {
            await session?.cancel()
        }
        cancelTranslationWork(clearAppleRequest: true)
        speechPlaybackService.stopSpeaking()
        transcriptText = ""
        translatedText = ""
        statusMessage = ""
        translationStatus = .idle
        pendingTranscriptText = ""
        lastCommittedTranscriptText = ""
        lastTranslatedTranscriptText = ""
        lastTranslatedSourceLanguageID = ""
        lastTranslatedTargetLanguageID = ""
        lastTranslatedEngineID = ""
    }

    func receiveAppleTranslation(_ translatedText: String, for request: AppleTranslationRequest) {
        guard request.generation == translationGeneration else { return }
        commitTranslation(translatedText, generation: request.generation)
    }

    func failAppleTranslation(_ error: Error, for request: AppleTranslationRequest) {
        guard request.generation == translationGeneration else { return }
        appleTranslationRequest = nil
        translationStatus = .failed(error.localizedDescription)
    }

    func appleTranslationUnavailable(for request: AppleTranslationRequest) {
        guard request.generation == translationGeneration else { return }
        appleTranslationRequest = nil
        translationStatus = .failed("Apple Translate requires iOS 18.0 or later.")
    }

    func refreshTranslationIfNeeded() {
        let normalizedTranscript = normalizeTranscript(transcriptText)
        pendingTranscriptText = normalizedTranscript
        lastTranscriptChangeAt = .now

        guard !normalizedTranscript.isEmpty else {
            cancelTranslationWork(clearAppleRequest: true)
            translationStatus = .idle
            return
        }

        let shouldTreatAsStable = !isListening || modelManager.selectedASREngine != .apple
        scheduleTranslationEvaluation(stable: shouldTreatAsStable)
    }

    var translationStatusMessage: String {
        switch translationStatus {
        case .idle:
            return ""
        case .waitingForStableInput:
            return "Waiting for stable speech..."
        case .translating:
            return "Translating..."
        case .failed(let message):
            return message
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
                statusMessage = "Loading \(modelManager.selectedASREngine.displayName)..."
                let session = try await localASRService.makeStreamingSession(
                    engine: modelManager.selectedASREngine,
                    progressHandler: { [weak self] _, status in
                        Task { @MainActor in
                            self?.statusMessage = status
                        }
                    },
                    transcriptHandler: { [weak self] update in
                        Task { @MainActor in
                            self?.handleLocalTranscriptUpdate(update)
                        }
                    }
                )
                localStreamingSession = session
                try audioRecorder.startRecording(onSamples: { samples, _ in
                    Task {
                        await session.append(samples: samples)
                    }
                })
                statusMessage = "Listening with \(modelManager.selectedASREngine.displayName) offline..."
                isListening = true
            } catch {
                let session = localStreamingSession
                localStreamingSession = nil
                Task {
                    await session?.cancel()
                }
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
                try audioRecorder.stopRecording()
                isListening = false
                statusMessage = "Finalizing offline transcription..."
                let session = localStreamingSession
                localStreamingSession = nil
                Task { [weak self] in
                    await session?.finish()
                    await MainActor.run {
                        self?.statusMessage = ""
                        self?.storeHistoryIfPossible()
                    }
                }
            } catch {
                isListening = false
                statusMessage = error.localizedDescription
            }
            return
        }

        speechRecognizer.stopRecognition()
        isListening = false
        if !pendingTranscriptText.isEmpty {
            scheduleTranslationEvaluation(stable: true)
        }

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
        pendingTranscriptText = normalizeTranscript(text)
        lastTranscriptChangeAt = .now
        scheduleTranslationEvaluation(stable: false)
    }

    private func handleLocalTranscriptUpdate(_ update: LocalASRTranscriptUpdate) {
        transcriptText = update.text
        statusMessage = update.statusMessage
        pendingTranscriptText = normalizeTranscript(update.text)
        lastTranscriptChangeAt = .now
        if update.isFinal {
            scheduleTranslationEvaluation(stable: true)
        } else {
            translationDebounceTask?.cancel()
            translationStatus = pendingTranscriptText.isEmpty ? .idle : .waitingForStableInput
        }
    }

    private func scheduleTranslationEvaluation(stable: Bool) {
        translationDebounceTask?.cancel()

        let sourceText = normalizeTranscript(pendingTranscriptText)
        guard !sourceText.isEmpty else {
            translationStatus = .idle
            return
        }

        if stable {
            translationStatus = .idle
            beginTranslation(for: sourceText)
            return
        }

        translationStatus = .waitingForStableInput
        translationDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            await self?.confirmStableAndTranslate(candidateText: sourceText)
        }
    }

    private func confirmStableAndTranslate(candidateText: String) {
        guard candidateText == normalizeTranscript(pendingTranscriptText) else { return }
        guard Date.now.timeIntervalSince(lastTranscriptChangeAt) >= 0.7 else { return }
        beginTranslation(for: candidateText)
    }

    private func beginTranslation(for sourceText: String) {
        let normalized = normalizeTranscript(sourceText)
        guard !normalized.isEmpty else { return }
        guard shouldTranslate(normalized) else {
            translationStatus = .idle
            return
        }

        translationDebounceTask?.cancel()
        activeTranslationTask?.cancel()
        appleTranslationRequest = nil
        translationGeneration += 1
        let generation = translationGeneration
        lastCommittedTranscriptText = normalized
        translationStatus = .translating

        switch modelManager.selectedTranslationEngine {
        case .apple:
            appleTranslationRequest = AppleTranslationRequest(
                generation: generation,
                text: normalized,
                sourceLanguageID: sourceLanguage.id,
                targetLanguageID: targetLanguage.id
            )
        case .translateGemma:
            activeTranslationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let translatedText = try await LocalInferenceRuntime(modelManager: self.modelManager)
                        .translateWithTranslateGemma(
                            text: normalized,
                            sourceLanguage: self.sourceLanguage,
                            targetLanguage: self.targetLanguage
                        )
                    await MainActor.run {
                        self.commitTranslation(translatedText, generation: generation)
                    }
                } catch is CancellationError {
                } catch {
                    await MainActor.run {
                        guard generation == self.translationGeneration else { return }
                        self.translationStatus = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func commitTranslation(_ translatedText: String, generation: Int) {
        guard generation == translationGeneration else { return }

        let normalizedTranslation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranslation.isEmpty else {
            translationStatus = .failed("Translation returned no text.")
            return
        }

        appleTranslationRequest = nil
        activeTranslationTask = nil
        self.translatedText = normalizedTranslation
        lastTranslatedTranscriptText = normalizeTranscript(lastCommittedTranscriptText)
        lastTranslatedSourceLanguageID = sourceLanguage.id
        lastTranslatedTargetLanguageID = targetLanguage.id
        lastTranslatedEngineID = modelManager.selectedTranslationEngine.rawValue
        translationStatus = .idle
        storeHistoryIfPossible()

        if autoSpeak {
            speechPlaybackService.speak(
                text: normalizedTranslation,
                languageID: targetLanguage.id,
                speechRate: speechRate,
                voiceLabel: selectedVoiceLabel
            )
        }
    }

    private func cancelTranslationWork(clearAppleRequest: Bool) {
        translationDebounceTask?.cancel()
        translationDebounceTask = nil
        activeTranslationTask?.cancel()
        activeTranslationTask = nil
        translationGeneration += 1
        if clearAppleRequest {
            appleTranslationRequest = nil
        }
    }

    private func normalizeTranscript(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func shouldTranslate(_ normalizedTranscript: String) -> Bool {
        guard normalizedTranscript != lastTranslatedTranscriptText else {
            return sourceLanguage.id != lastTranslatedSourceLanguageID
                || targetLanguage.id != lastTranslatedTargetLanguageID
                || modelManager.selectedTranslationEngine.rawValue != lastTranslatedEngineID
        }

        return true
    }

    private func storeHistoryIfPossible() {
        let transcript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !isListening else { return }
        guard !transcript.isEmpty, !translation.isEmpty else { return }
        guard history.first?.transcript != transcript || history.first?.translation != translation else { return }

        history.insert(
            HistoryItem(
                timestamp: .now,
                transcript: transcript,
                translation: translation
            ),
            at: 0
        )
    }
}
