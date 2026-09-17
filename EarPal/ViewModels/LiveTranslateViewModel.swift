import Combine
import Foundation

@MainActor
final class LiveTranslateViewModel: ObservableObject {
    private static let speechSegmentationPauseThreshold: TimeInterval = 1.0
    private static let translationEnabledKey = "live.translation.enabled"
    private static let audioSourceKey = "live.audio.source"

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

    @Published var sourceLanguage = TranslationLanguage.english
    @Published var targetLanguage = TranslationLanguage.traditionalChinese
    @Published var isTranslationEnabled = true
    @Published var audioSource = AudioCaptureSourceOption.microphone
    @Published var isScreenCapturePrepared = false
    @Published var isPreparingScreenCapture = false
    @Published var transcriptText = ""
    @Published var translatedText = ""
    @Published var isListening = false
    @Published var autoSpeak = true
    @Published var speechRate: Double = 0.5
    @Published var selectedVoiceIdentifier = ""
    @Published private(set) var availableVoices: [AppleSpeechPlaybackService.VoiceOption] = []
    @Published var isShowingAudioOptions = false
    @Published var isShowingModelManagement = false
    @Published var statusMessage = ""
    @Published var translationStatus: TranslationStatus = .idle
    @Published var appleTranslationRequest: AppleTranslationRequest?

    let languageOptions = TranslationLanguage.commonOptions

    private let modelManager: ModelManager
    private let defaults = UserDefaults.standard
    private let speechRecognizer: AppleSpeechRecognizer
    private let audioRecorder: AudioCaptureRecorder
    private let microphoneSource: MicrophoneAudioSource
    private let screenAudioSource: ScreenCaptureAudioSource
    private let localASRService: LocalASRService
    private let speechPlaybackService: AppleSpeechPlaybackService
    private let jobRepository: JobRepository
    private let inferenceRuntime: LocalInferenceRuntime
    private var currentJob: Job?
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
    private var lastCompletedDisplayTranscript = ""
    private var lastSpokenTranscriptText = ""
    private var lastSpokenLanguageID = ""

    init(
        modelManager: ModelManager,
        speechRecognizer: AppleSpeechRecognizer? = nil,
        audioRecorder: AudioCaptureRecorder? = nil,
        localASRService: LocalASRService = LocalASRService(),
        speechPlaybackService: AppleSpeechPlaybackService? = nil,
        jobRepository: JobRepository = .shared
    ) {
        self.modelManager = modelManager
        self.speechRecognizer = speechRecognizer ?? AppleSpeechRecognizer()
        self.audioRecorder = audioRecorder ?? AudioCaptureRecorder()
        self.microphoneSource = MicrophoneAudioSource(recorder: self.audioRecorder)
        self.screenAudioSource = ScreenCaptureAudioSource()
        self.localASRService = localASRService
        self.speechPlaybackService = speechPlaybackService ?? AppleSpeechPlaybackService()
        self.jobRepository = jobRepository
        self.inferenceRuntime = LocalInferenceRuntime(modelManager: modelManager)
        self.isTranslationEnabled = defaults.object(forKey: Self.translationEnabledKey) as? Bool ?? true
        let restoredSource = AudioCaptureSourceOption(rawValue: defaults.string(forKey: Self.audioSourceKey) ?? "")
            ?? .microphone
        self.audioSource = (restoredSource == .screenAudio && !Self.screenAudioSupported)
            ? .microphone
            : restoredSource

        self.speechRecognizer.onText = { [weak self] text in
            self?.handleRecognizedText(text)
        }
        self.speechRecognizer.onStopped = { [weak self] in
            self?.isListening = false
        }

        refreshAvailableVoices()
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
        refreshAvailableVoices()
        refreshTranslationIfNeeded()
    }

    func refreshAvailableVoices() {
        let spokenLanguageID = spokenLanguage.id
        availableVoices = speechPlaybackService.availableVoices(for: spokenLanguageID)

        if availableVoices.contains(where: { $0.identifier == selectedVoiceIdentifier }) {
            return
        }

        selectedVoiceIdentifier = speechPlaybackService.defaultVoiceIdentifier(for: spokenLanguageID)
            ?? availableVoices.first?.identifier
            ?? ""
    }

    func setTranslationEnabled(_ isEnabled: Bool) {
        guard isTranslationEnabled != isEnabled else { return }
        isTranslationEnabled = isEnabled
        defaults.set(isEnabled, forKey: Self.translationEnabledKey)
        refreshAvailableVoices()

        if !isEnabled {
            cancelTranslationWork(clearAppleRequest: true)
            translatedText = ""
            translationStatus = .idle
        } else {
            refreshTranslationIfNeeded()
        }
    }

    func setAudioSource(_ source: AudioCaptureSourceOption) {
        guard source != audioSource else { return }
        if source == .screenAudio, !screenAudioSupported {
            statusMessage = "Screen audio capture requires iOS 27."
            return
        }
        if isListening {
            stopListening()
        }
        audioSource = source
        defaults.set(source.rawValue, forKey: Self.audioSourceKey)

        if source == .screenAudio {
            Task { await prepareScreenCapture() }
        } else {
            isScreenCapturePrepared = false
        }
    }

    func prepareScreenCapture() async {
        guard audioSource == .screenAudio else { return }
        guard !isScreenCapturePrepared else { return }
        guard !isPreparingScreenCapture else { return }

        isPreparingScreenCapture = true
        defer { isPreparingScreenCapture = false }

        do {
            try await screenAudioSource.prepare()
            isScreenCapturePrepared = screenAudioSource.isPrepared
        } catch is CancellationError {
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private var activeAudioSource: AudioSource {
        audioSource == .screenAudio ? screenAudioSource : microphoneSource
    }

    func clearSession() {
        finalizeCurrentJob()
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
        lastCompletedDisplayTranscript = ""
        lastSpokenTranscriptText = ""
        lastSpokenLanguageID = ""
    }

    private func createNewJob() {
        do {
            let job = try jobRepository.createJob(
                name: sourceLanguage.displayName + " → " + targetLanguage.displayName
            )
            var updated = job
            updated.sourceLanguage = sourceLanguage.id
            updated.targetLanguage = targetLanguage.id
            updated.asrEngine = modelManager.selectedASREngine.rawValue
            updated.translationEngine = modelManager.selectedTranslationEngine.rawValue
            updated.status = .recording
            try jobRepository.updateJob(updated)
            currentJob = updated
        } catch {
            statusMessage = "Failed to save recording: \(error.localizedDescription)"
        }
    }

    private func finalizeCurrentJob() {
        guard let job = currentJob else { return }
        do {
            if !transcriptText.isEmpty || job.status == .recording {
                try jobRepository.updateJobTranscript(id: job.id, text: transcriptText)
                try jobRepository.updateJobStatus(id: job.id, status: .completed)
            } else {
                try jobRepository.deleteJob(id: job.id)
            }
        } catch {
            statusMessage = "Failed to save: \(error.localizedDescription)"
        }
        currentJob = nil
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
        guard isTranslationEnabled else {
            cancelTranslationWork(clearAppleRequest: true)
            translatedText = ""
            translationStatus = .idle
            return
        }

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
        guard isTranslationEnabled else { return "" }
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

    var screenAudioSupported: Bool {
        Self.screenAudioSupported
    }

    static var screenAudioSupported: Bool {
#if canImport(ScreenCaptureKit)
        return true
#else
        return false
#endif
    }

    private func startListening() async {
        clearSession()
        createNewJob()

        if modelManager.selectedASREngine != .apple {
            guard modelManager.canUse(modelManager.selectedASREngine) else {
                statusMessage = "\(modelManager.selectedASREngine.displayName) is not installed on this device."
                return
            }

            switch audioSource {
            case .microphone:
                let allowed = await audioRecorder.requestPermission()
                guard allowed else {
                    statusMessage = "Microphone permission is not available."
                    return
                }
            case .screenAudio:
                if !isScreenCapturePrepared {
                    await prepareScreenCapture()
                }
                guard isScreenCapturePrepared else {
                    statusMessage = "Choose a screen to capture before listening."
                    return
                }
            }

            do {
                statusMessage = "Loading \(modelManager.selectedASREngine.displayName)..."
                let session = try await localASRService.makeStreamingSession(
                    engine: modelManager.selectedASREngine,
                    sourceLanguageID: sourceLanguage.id,
                    senseVoiceLanguage: modelManager.selectedSenseVoiceLanguage,
                    senseVoiceBackend: modelManager.selectedSenseVoiceBackend,
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
                try await activeAudioSource.start(onSamples: { samples, _ in
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

        guard audioSource != .screenAudio else {
            statusMessage = AudioSourceError.screenAudioRequiresOfflineASR.localizedDescription
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
                try activeAudioSource.stop()
                isListening = false
                statusMessage = "Finalizing offline transcription..."
                let session = localStreamingSession
                localStreamingSession = nil
                Task { [weak self] in
                    await session?.finish()
                    await MainActor.run {
                        self?.statusMessage = ""
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
    }

    private func handleRecognizedText(_ text: String) {
        let now = Date.now
        let startedAfterPause = now.timeIntervalSince(lastTranscriptChangeAt) >= Self.speechSegmentationPauseThreshold
        let latestSentence = latestDisplayTranscript(from: text, startedAfterPause: startedAfterPause)
        transcriptText = latestSentence
        pendingTranscriptText = normalizeTranscript(latestSentence)
        lastTranscriptChangeAt = now
        if pendingTranscriptText.isEmpty {
            translationDebounceTask?.cancel()
            translationStatus = .idle
        } else {
            scheduleTranslationEvaluation(stable: false)
        }
    }

    private func handleLocalTranscriptUpdate(_ update: LocalASRTranscriptUpdate) {
        let now = Date.now
        let startedAfterPause = now.timeIntervalSince(lastTranscriptChangeAt) >= Self.speechSegmentationPauseThreshold
        let latestSegment = latestDisplayTranscript(from: update.text, startedAfterPause: startedAfterPause)
        transcriptText = latestSegment
        statusMessage = update.statusMessage
        pendingTranscriptText = normalizeTranscript(latestSegment)
        lastTranscriptChangeAt = now
        if update.isFinal {
            scheduleTranslationEvaluation(stable: true)
        } else {
            translationDebounceTask?.cancel()
            translationStatus = isTranslationEnabled && !pendingTranscriptText.isEmpty ? .waitingForStableInput : .idle
        }
    }

    private func scheduleTranslationEvaluation(stable: Bool) {
        translationDebounceTask?.cancel()

        let sourceText = normalizeTranscript(pendingTranscriptText)
        guard !sourceText.isEmpty else {
            translationStatus = .idle
            return
        }

        guard isTranslationEnabled else {
            if stable {
                translationStatus = .idle
                speakTranscriptIfNeeded(sourceText)
            } else {
                translationStatus = .waitingForStableInput
                translationDebounceTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.speechSegmentationPauseThreshold))
                    await self?.confirmStableAndSpeak(candidateText: sourceText)
                }
            }
            return
        }

        if stable {
            translationStatus = .idle
            beginTranslation(for: sourceText)
            return
        }

        translationStatus = .waitingForStableInput
        translationDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.speechSegmentationPauseThreshold))
            await self?.confirmStableAndTranslate(candidateText: sourceText)
        }
    }

    private func confirmStableAndTranslate(candidateText: String) {
        guard candidateText == normalizeTranscript(pendingTranscriptText) else { return }
        guard Date.now.timeIntervalSince(lastTranscriptChangeAt) >= Self.speechSegmentationPauseThreshold else { return }
        beginTranslation(for: candidateText)
    }

    private func confirmStableAndSpeak(candidateText: String) {
        guard candidateText == normalizeTranscript(pendingTranscriptText) else { return }
        guard Date.now.timeIntervalSince(lastTranscriptChangeAt) >= Self.speechSegmentationPauseThreshold else { return }
        translationStatus = .idle
        speakTranscriptIfNeeded(candidateText)
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
                    let translatedText = try await self.inferenceRuntime
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
        lastCompletedDisplayTranscript = lastTranslatedTranscriptText
        translationStatus = .idle

        if let job = currentJob {
            do {
                try jobRepository.updateJobTranslation(
                    id: job.id,
                    translatedText: normalizedTranslation,
                    language: targetLanguage.id
                )
            } catch {
                translationStatus = .failed("Failed to save translation: \(error.localizedDescription)")
            }
        }

        if autoSpeak {
            speechPlaybackService.speak(
                text: normalizedTranslation,
                languageID: targetLanguage.id,
                speechRate: speechRate,
                voiceIdentifier: selectedVoiceIdentifier
            )
        }
    }

    private func speakTranscriptIfNeeded(_ transcript: String) {
        guard autoSpeak else { return }

        let normalized = normalizeTranscript(transcript)
        guard !normalized.isEmpty else { return }
        guard normalized != lastSpokenTranscriptText || sourceLanguage.id != lastSpokenLanguageID else { return }

        lastSpokenTranscriptText = normalized
        lastSpokenLanguageID = sourceLanguage.id

        speechPlaybackService.speak(
            text: normalized,
            languageID: sourceLanguage.id,
            speechRate: speechRate,
            voiceIdentifier: selectedVoiceIdentifier
        )
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

    private func latestDisplayTranscript(from recognizedText: String, startedAfterPause: Bool) -> String {
        let normalized = normalizeTranscript(recognizedText)
        guard !normalized.isEmpty else { return "" }

        if startedAfterPause,
           let suffixAfterCompleted = suffixAfterPrefix(normalized, prefix: lastCompletedDisplayTranscript),
           !suffixAfterCompleted.isEmpty {
            return suffixAfterCompleted
        }

        if !lastCompletedDisplayTranscript.isEmpty,
           normalized == lastCompletedDisplayTranscript {
            return lastCompletedDisplayTranscript
        }

        if let suffixAfterCompleted = suffixAfterPrefix(normalized, prefix: lastCompletedDisplayTranscript),
           !suffixAfterCompleted.isEmpty {
            return suffixAfterCompleted
        }

        let separators = CharacterSet(charactersIn: ".!?。！？\n")
        let segments = normalized
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let latestSegment = segments.last {
            return latestSegment
        }

        return normalized
    }

    private func suffixAfterPrefix(_ text: String, prefix: String) -> String? {
        guard !prefix.isEmpty, text.hasPrefix(prefix) else { return nil }

        let suffixStart = text.index(text.startIndex, offsetBy: prefix.count)
        return String(text[suffixStart...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?;:"))
    }

    private func shouldTranslate(_ normalizedTranscript: String) -> Bool {
        guard isTranslationEnabled else { return false }
        guard normalizedTranscript != lastTranslatedTranscriptText else {
            return sourceLanguage.id != lastTranslatedSourceLanguageID
                || targetLanguage.id != lastTranslatedTargetLanguageID
                || modelManager.selectedTranslationEngine.rawValue != lastTranslatedEngineID
        }

        return true
    }

    private var spokenLanguage: TranslationLanguage {
        isTranslationEnabled ? targetLanguage : sourceLanguage
    }
}
