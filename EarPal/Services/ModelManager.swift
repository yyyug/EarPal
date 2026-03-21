import AudioCommon
import Combine
import Foundation
import ParakeetASR
import Qwen3ASR
import SpeechVAD

@MainActor
final class ModelManager: ObservableObject {
    static let parakeetModelID = ParakeetASRModel.defaultModelId
    static let senseVoiceRepositoryURL = URL(string: "https://github.com/FunAudioLLM/SenseVoice")!
    static let senseVoiceModelDownloadURL = URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/resolve/main/model.int8.onnx?download=true")!
    static let senseVoiceTokensDownloadURL = URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/resolve/main/tokens.txt?download=true")!
    static let senseVoiceGGUFRepositoryURL = URL(string: "https://huggingface.co/lovemefan/sense-voice-gguf")!
    static let senseVoiceGGUFDownloadURL = URL(string: "https://huggingface.co/lovemefan/sense-voice-gguf/resolve/main/sense-voice-small-q4_k.gguf?download=true")!
    static let senseVoiceCoreMLRepositoryURL = URL(string: "https://huggingface.co/mefengl/SenseVoiceSmall-coreml")!
    static let qwen3ASRModelID = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    static let sileroVADModelID = SileroVADModel.defaultCoreMLModelId
    static let translateGemmaDownloadURL = URL(string: "https://huggingface.co/google/gemma-3n-E2B-it-litert-preview/resolve/main/gemma-3n-E2B-it-int4.task?download=true")!
    static let translateGemmaFileName = "gemma-3n-E2B-it-int4.task"

    @Published private(set) var models: [InferenceModel]
    @Published var selectedASREngine: ASREngine
    @Published var selectedSenseVoiceLanguage: SenseVoiceLanguageOption
    @Published var selectedSenseVoiceBackend: SenseVoiceBackend
    @Published var selectedTranslationEngine: TranslationEngine

    private let defaults = UserDefaults.standard
    private let installedModelsKey = "installed.model.ids"
    private let selectedASRKey = "selected.asr.engine"
    private let selectedSenseVoiceLanguageKey = "selected.sensevoice.language"
    private let selectedSenseVoiceBackendKey = "selected.sensevoice.backend"
    private let selectedTranslationKey = "selected.translation.engine"
    private let fileManager = FileManager.default

    init() {
        let installedIDs = Set(defaults.stringArray(forKey: installedModelsKey) ?? [])
        let initialModels = Self.makeInitialModels(
            installedIDs: installedIDs,
            fileManager: FileManager.default
        )
        models = initialModels

        let storedASR = ASREngine(rawValue: defaults.string(forKey: selectedASRKey) ?? "") ?? .apple
        selectedASREngine = Self.resolveASREngine(storedASR, with: initialModels)
        selectedSenseVoiceLanguage = SenseVoiceLanguageOption(
            rawValue: defaults.string(forKey: selectedSenseVoiceLanguageKey) ?? ""
        ) ?? .auto
        selectedSenseVoiceBackend = SenseVoiceBackend(
            rawValue: defaults.string(forKey: selectedSenseVoiceBackendKey) ?? ""
        ) ?? .sherpaOnnx

        let storedTranslation = TranslationEngine(rawValue: defaults.string(forKey: selectedTranslationKey) ?? "") ?? .apple
        selectedTranslationEngine = Self.resolveTranslationEngine(storedTranslation, with: initialModels)
        refreshSenseVoiceModelState()
        selectedASREngine = Self.resolveASREngine(selectedASREngine, with: models)
    }

    var asrModels: [InferenceModel] {
        models.filter { $0.task == .asr }
    }

    var translationModels: [InferenceModel] {
        models.filter { $0.task == .translation }
    }

    func canUse(_ engine: ASREngine) -> Bool {
        if engine == .apple { return true }
        return models.contains(where: { $0.engineID == engine.rawValue && $0.isInstalled })
    }

    func canUse(_ engine: TranslationEngine) -> Bool {
        if engine == .apple { return true }
        return models.contains(where: { $0.engineID == engine.rawValue && $0.isInstalled })
    }

    func select(asr engine: ASREngine) {
        let resolved = Self.resolveASREngine(engine, with: models)
        selectedASREngine = resolved
        defaults.set(resolved.rawValue, forKey: selectedASRKey)
    }

    func select(translation engine: TranslationEngine) {
        let resolved = Self.resolveTranslationEngine(engine, with: models)
        selectedTranslationEngine = resolved
        defaults.set(resolved.rawValue, forKey: selectedTranslationKey)
    }

    func selectSenseVoiceLanguage(_ option: SenseVoiceLanguageOption) {
        selectedSenseVoiceLanguage = option
        defaults.set(option.rawValue, forKey: selectedSenseVoiceLanguageKey)
    }

    func selectSenseVoiceBackend(_ backend: SenseVoiceBackend) {
        selectedSenseVoiceBackend = backend
        defaults.set(backend.rawValue, forKey: selectedSenseVoiceBackendKey)
        refreshSenseVoiceModelState()
        select(asr: selectedASREngine)
    }

    var selectedSenseVoiceBackendStatus: String {
        switch selectedSenseVoiceBackend {
        case .sherpaOnnx:
            return Self.isSenseVoiceInstalled(fileManager: fileManager, backend: .sherpaOnnx)
                ? "Installed and ready with the current SherpaOnnx runtime."
                : "Download the SenseVoice ONNX model to use this backend."
        case .ggmlMetal:
            return Self.isSenseVoiceInstalled(fileManager: fileManager, backend: .ggmlMetal)
                ? "Installed and ready with the ggml + Metal runtime."
                : "Download the SenseVoice GGUF model to use this backend."
        case .coreML:
            return Self.isSenseVoiceInstalled(fileManager: fileManager, backend: .coreML)
                ? "Installed and ready with the experimental Core ML runtime."
                : "Experimental. Install an extracted SenseVoiceSmall.mlmodelc bundle plus the SentencePiece and CMVN assets to use this backend."
        }
    }

    func downloadModel(id: String) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        guard !models[index].isBuiltIn, !models[index].isInstalled, !models[index].isDownloading else { return }

        models[index].isDownloading = true
        models[index].downloadProgress = 0
        models[index].statusNote = "Preparing download..."

        let modelID = id
        let selectedSenseVoiceBackend = self.selectedSenseVoiceBackend
        Task {
            do {
                switch modelID {
                case "parakeet-asr":
                    let model = try await ParakeetASRModel.fromPretrained(modelId: Self.parakeetModelID) { [weak self] progress, status in
                        Task { @MainActor in
                            self?.updateDownloadState(id: modelID, progress: progress, note: status)
                        }
                    }
                    model.unload()
                    _ = try await SileroVADModel.fromPretrained(
                        modelId: Self.sileroVADModelID,
                        engine: .coreml
                    ) { [weak self] progress, status in
                        Task { @MainActor in
                            self?.updateDownloadState(id: modelID, progress: progress, note: status)
                        }
                    }
                    await MainActor.run {
                        self.markInstalled(id: modelID, note: "Parakeet and live VAD downloaded to local cache.")
                    }
                case "sensevoice-asr":
                    try await downloadSenseVoiceModel(for: selectedSenseVoiceBackend) { [weak self] progress, status in
                        Task { @MainActor in
                            self?.updateDownloadState(id: modelID, progress: progress, note: status)
                        }
                    }
                    await MainActor.run {
                        let note: String
                        switch self.selectedSenseVoiceBackend {
                        case .sherpaOnnx:
                            note = "SenseVoice ONNX model downloaded to app storage."
                        case .ggmlMetal:
                            note = "SenseVoice GGUF model downloaded to app storage."
                        case .coreML:
                            note = "SenseVoice assets downloaded to app storage."
                        }
                        self.markInstalled(id: modelID, note: note)
                    }
                case "qwen3-asr":
                    let model = try await Qwen3ASRModel.fromPretrained(modelId: Self.qwen3ASRModelID) { [weak self] progress, status in
                        Task { @MainActor in
                            self?.updateDownloadState(id: modelID, progress: progress, note: status)
                        }
                    }
                    model.unload()
                    _ = try await SileroVADModel.fromPretrained(
                        modelId: Self.sileroVADModelID,
                        engine: .coreml
                    ) { [weak self] progress, status in
                        Task { @MainActor in
                            self?.updateDownloadState(id: modelID, progress: progress, note: status)
                        }
                    }
                    await MainActor.run {
                        self.markInstalled(id: modelID, note: "Qwen3-ASR and live VAD downloaded to local cache.")
                    }
                case "translate-gemma":
                    try await downloadTranslateGemmaModel { [weak self] progress, status in
                        Task { @MainActor in
                            self?.updateDownloadState(id: modelID, progress: progress, note: status)
                        }
                    }
                    await MainActor.run {
                        self.markInstalled(id: modelID, note: "TranslateGemma downloaded to app storage.")
                    }
                default:
                    break
                }
            } catch {
                await MainActor.run {
                    self.markDownloadFailed(id: modelID, note: "Install failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func deleteModel(id: String) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        guard !models[index].isBuiltIn, models[index].isInstalled else { return }

        do {
            switch id {
            case "parakeet-asr":
                try removeCachedModel(modelID: Self.parakeetModelID)
                if !Self.isQwenInstalled(fileManager: fileManager),
                   !Self.isSenseVoiceInstalled(fileManager: fileManager) {
                    try removeCachedModel(modelID: Self.sileroVADModelID)
                }
            case "sensevoice-asr":
                try deleteSenseVoiceModel()
                if !Self.isParakeetInstalled(fileManager: fileManager),
                   !Self.isQwenInstalled(fileManager: fileManager) {
                    try removeCachedModel(modelID: Self.sileroVADModelID)
                }
            case "qwen3-asr":
                try removeCachedModel(modelID: Self.qwen3ASRModelID)
                if !Self.isParakeetInstalled(fileManager: fileManager),
                   !Self.isSenseVoiceInstalled(fileManager: fileManager) {
                    try removeCachedModel(modelID: Self.sileroVADModelID)
                }
            case "translate-gemma":
                try deleteTranslateGemmaModel()
            default:
                break
            }

            let deletedModel = models[index]
            models[index].isInstalled = false
            models[index].isDownloading = false
            models[index].downloadProgress = 0
            models[index].statusNote = "Removed from device."
            persistInstalledModels()
            resetSelectionsIfNeeded(deletedModel: deletedModel)
        } catch {
            models[index].statusNote = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func updateDownloadState(id: String, progress: Double, note: String) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        models[index].downloadProgress = progress
        models[index].statusNote = note
    }

    private func refreshSenseVoiceModelState() {
        guard let index = models.firstIndex(where: { $0.id == "sensevoice-asr" }) else { return }

        let installed = Self.isSenseVoiceInstalled(fileManager: fileManager, backend: selectedSenseVoiceBackend)
        models[index].isInstalled = installed
        models[index].isDownloading = false
        models[index].downloadProgress = installed ? 1 : 0

        switch selectedSenseVoiceBackend {
        case .sherpaOnnx:
            models[index].statusNote = installed
                ? "SenseVoice ONNX backend is ready for offline transcription."
                : "Downloads the current sherpa-onnx SenseVoice int8 model to app storage."
        case .ggmlMetal:
            models[index].statusNote = installed
                ? "SenseVoice ggml + Metal backend is ready for offline transcription."
                : "Downloads the SenseVoice GGUF model for the ggml + Metal runtime."
        case .coreML:
            models[index].statusNote = installed
                ? "SenseVoice Core ML backend is ready for offline transcription."
                : "Experimental. Manual install required: extracted SenseVoiceSmall.mlmodelc, spm, and cmvn_am.mvn."
        }
    }

    private func markInstalled(id: String, note: String) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        models[index].isInstalled = true
        models[index].isDownloading = false
        models[index].downloadProgress = 1
        models[index].statusNote = note
        persistInstalledModels()
    }

    private func markDownloadFailed(id: String, note: String) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        models[index].isDownloading = false
        models[index].downloadProgress = 0
        models[index].statusNote = note
    }

    private static func makeInitialModels(installedIDs: Set<String>, fileManager: FileManager) -> [InferenceModel] {
        let parakeetInstalled = isParakeetInstalled(fileManager: fileManager)
        let senseVoiceInstalled = isSenseVoiceInstalled(fileManager: fileManager)
        let qwenInstalled = isQwenInstalled(fileManager: fileManager)
        let translateGemmaInstalled = isTranslateGemmaInstalled(fileManager: fileManager) || installedIDs.contains("translate-gemma")

        return [
            InferenceModel(
                id: "apple-speech",
                displayName: "Apple Speech",
                task: .asr,
                engineID: ASREngine.apple.rawValue,
                supportsLanguages: TranslationLanguage.commonOptions.map(\.id),
                sizeDescription: "Built in",
                downloadURL: nil,
                isBuiltIn: true,
                isInstalled: true,
                isDownloading: false,
                downloadProgress: 1,
                statusNote: "Available with iOS."
            ),
            InferenceModel(
                id: "parakeet-asr",
                displayName: "NVIDIA Parakeet",
                task: .asr,
                engineID: ASREngine.parakeet.rawValue,
                supportsLanguages: ["en"],
                sizeDescription: "~1.5 GB",
                downloadURL: nil,
                isBuiltIn: false,
                isInstalled: parakeetInstalled,
                isDownloading: false,
                downloadProgress: parakeetInstalled ? 1 : 0,
                statusNote: parakeetInstalled ? "Ready for offline transcription." : "Downloads CoreML weights for on-device ASR."
            ),
            InferenceModel(
                id: "sensevoice-asr",
                displayName: "SenseVoice",
                task: .asr,
                engineID: ASREngine.senseVoice.rawValue,
                supportsLanguages: TranslationLanguage.commonOptions.map(\.id),
                sizeDescription: "~0.23 GB",
                downloadURL: Self.senseVoiceRepositoryURL,
                isBuiltIn: false,
                isInstalled: senseVoiceInstalled,
                isDownloading: false,
                downloadProgress: senseVoiceInstalled ? 1 : 0,
                statusNote: senseVoiceInstalled
                    ? "Ready for offline transcription."
                    : "Downloads the currently selected SenseVoice backend assets to app storage."
            ),
            InferenceModel(
                id: "qwen3-asr",
                displayName: "Qwen3-ASR",
                task: .asr,
                engineID: ASREngine.qwen3.rawValue,
                supportsLanguages: TranslationLanguage.commonOptions.map(\.id),
                sizeDescription: "~0.4 GB",
                downloadURL: nil,
                isBuiltIn: false,
                isInstalled: qwenInstalled,
                isDownloading: false,
                downloadProgress: qwenInstalled ? 1 : 0,
                statusNote: qwenInstalled ? "Ready for offline transcription." : "Downloads MLX weights for on-device ASR."
            ),
            InferenceModel(
                id: "apple-translate",
                displayName: "Apple Translate",
                task: .translation,
                engineID: TranslationEngine.apple.rawValue,
                supportsLanguages: TranslationLanguage.commonOptions.map(\.id),
                sizeDescription: "Built in",
                downloadURL: nil,
                isBuiltIn: true,
                isInstalled: true,
                isDownloading: false,
                downloadProgress: 1,
                statusNote: "Available with supported iOS versions."
            ),
            InferenceModel(
                id: "translate-gemma",
                displayName: "TranslateGemma",
                task: .translation,
                engineID: TranslationEngine.translateGemma.rawValue,
                supportsLanguages: ["en", "zh-Hant", "zh-Hans", "ja", "ko"],
                sizeDescription: "~1.2 GB",
                downloadURL: Self.translateGemmaDownloadURL,
                isBuiltIn: false,
                isInstalled: translateGemmaInstalled,
                isDownloading: false,
                downloadProgress: translateGemmaInstalled ? 1 : 0,
                statusNote: translateGemmaInstalled ? "Ready for on-device translation." : "Downloads a Gemma .task model for on-device translation."
            )
        ]
    }

    private static func isParakeetInstalled(fileManager: FileManager) -> Bool {
        guard let cacheDir = try? HuggingFaceDownloader.getCacheDirectory(for: parakeetModelID) else {
            return false
        }
        return fileManager.fileExists(atPath: cacheDir.appendingPathComponent("encoder.mlmodelc").path)
            && fileManager.fileExists(atPath: cacheDir.appendingPathComponent("decoder.mlmodelc").path)
            && fileManager.fileExists(atPath: cacheDir.appendingPathComponent("joint.mlmodelc").path)
            && fileManager.fileExists(atPath: cacheDir.appendingPathComponent("vocab.json").path)
    }

    private static func isSenseVoiceInstalled(fileManager: FileManager) -> Bool {
        isSenseVoiceInstalled(fileManager: fileManager, backend: .sherpaOnnx)
            || isSenseVoiceInstalled(fileManager: fileManager, backend: .ggmlMetal)
    }

    private static func isSenseVoiceInstalled(fileManager: FileManager, backend: SenseVoiceBackend) -> Bool {
        guard let modelDir = try? senseVoiceModelDirectoryURL(fileManager: fileManager) else {
            return false
        }

        switch backend {
        case .sherpaOnnx:
            let hasTokens = fileManager.fileExists(atPath: modelDir.appendingPathComponent("tokens.txt").path)
            let candidates = [
                "model.int8.onnx",
                "model.onnx",
                "sense-voice.onnx",
                "sense-voice-int8.onnx"
            ]
            let hasModel = candidates.contains { fileManager.fileExists(atPath: modelDir.appendingPathComponent($0).path) }
            return hasTokens && hasModel
        case .ggmlMetal:
            let candidates = [
                "sense-voice-small-q4_k.gguf",
                "sense-voice-small-q8_0.gguf",
                "sense-voice-small-f16.gguf",
                "gguf-fp16-sense-voice-small.bin",
                "gguf-fp32-sense-voice-small.bin"
            ]
            return candidates.contains { fileManager.fileExists(atPath: modelDir.appendingPathComponent($0).path) }
        case .coreML:
            let modelCandidates = [
                modelDir.appendingPathComponent("SenseVoiceSmall.mlmodelc"),
                modelDir.appendingPathComponent("coreml/SenseVoiceSmall.mlmodelc")
            ]
            let sentencePieceCandidates = [
                modelDir.appendingPathComponent("spm"),
                modelDir.appendingPathComponent("chn_jpn_yue_eng_ko_spectok.bpe.model"),
                modelDir.appendingPathComponent("coreml/spm"),
                modelDir.appendingPathComponent("coreml/chn_jpn_yue_eng_ko_spectok.bpe.model")
            ]
            let cmvnCandidates = [
                modelDir.appendingPathComponent("cmvn_am.mvn"),
                modelDir.appendingPathComponent("am.mvn"),
                modelDir.appendingPathComponent("coreml/cmvn_am.mvn"),
                modelDir.appendingPathComponent("coreml/am.mvn")
            ]

            let hasModel = modelCandidates.contains {
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            let hasSentencePiece = sentencePieceCandidates.contains { fileManager.fileExists(atPath: $0.path) }
            let hasCMVN = cmvnCandidates.contains { fileManager.fileExists(atPath: $0.path) }
            return hasModel && hasSentencePiece && hasCMVN
        }
    }

    private static func isQwenInstalled(fileManager: FileManager) -> Bool {
        guard let cacheDir = try? HuggingFaceDownloader.getCacheDirectory(for: qwen3ASRModelID) else {
            return false
        }
        return HuggingFaceDownloader.weightsExist(in: cacheDir)
            && fileManager.fileExists(atPath: cacheDir.appendingPathComponent("vocab.json").path)
    }

    private static func isTranslateGemmaInstalled(fileManager: FileManager) -> Bool {
        guard let modelURL = try? translateGemmaModelFileURL(fileManager: fileManager) else {
            return false
        }
        return fileManager.fileExists(atPath: modelURL.path)
    }

    private static func resolveASREngine(_ engine: ASREngine, with models: [InferenceModel]) -> ASREngine {
        if engine == .apple { return .apple }
        return models.contains(where: { $0.engineID == engine.rawValue && $0.isInstalled }) ? engine : .apple
    }

    private static func resolveTranslationEngine(_ engine: TranslationEngine, with models: [InferenceModel]) -> TranslationEngine {
        if engine == .apple { return .apple }
        return models.contains(where: { $0.engineID == engine.rawValue && $0.isInstalled }) ? engine : .apple
    }

    private func persistInstalledModels() {
        let installedIDs = models
            .filter { !$0.isBuiltIn && $0.isInstalled && $0.task == .translation }
            .map(\.id)
            .sorted()
        defaults.set(installedIDs, forKey: installedModelsKey)
    }

    private func resetSelectionsIfNeeded(deletedModel: InferenceModel) {
        if deletedModel.task == .asr,
           deletedModel.engineID == selectedASREngine.rawValue {
            select(asr: .apple)
        }

        if deletedModel.task == .translation,
           deletedModel.engineID == selectedTranslationEngine.rawValue {
            select(translation: .apple)
        }
    }

    func translateGemmaModelFileURL() throws -> URL {
        try Self.translateGemmaModelFileURL(fileManager: fileManager)
    }

    private func downloadTranslateGemmaModel(
        progressHandler: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        progressHandler(0.05, "Starting TranslateGemma download...")
        let (temporaryURL, _) = try await URLSession.shared.download(from: Self.translateGemmaDownloadURL)
        let modelURL = try Self.translateGemmaModelFileURL(fileManager: fileManager)
        let modelFolder = modelURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: modelFolder.path) {
            try fileManager.createDirectory(at: modelFolder, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: modelURL.path) {
            try fileManager.removeItem(at: modelURL)
        }
        progressHandler(0.9, "Saving TranslateGemma model...")
        try fileManager.moveItem(at: temporaryURL, to: modelURL)
        progressHandler(1.0, "TranslateGemma ready.")
    }

    private func downloadSenseVoiceModel(
        for backend: SenseVoiceBackend,
        progressHandler: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let modelFolder = try Self.senseVoiceModelDirectoryURL(fileManager: fileManager)
        if !fileManager.fileExists(atPath: modelFolder.path) {
            try fileManager.createDirectory(at: modelFolder, withIntermediateDirectories: true)
        }

        switch backend {
        case .sherpaOnnx:
            let destinationModelURL = modelFolder.appendingPathComponent("model.int8.onnx")
            let destinationTokensURL = modelFolder.appendingPathComponent("tokens.txt")

            progressHandler(0.05, "Downloading SenseVoice ONNX model...")
            let (temporaryModelURL, _) = try await URLSession.shared.download(from: Self.senseVoiceModelDownloadURL)
            if fileManager.fileExists(atPath: destinationModelURL.path) {
                try fileManager.removeItem(at: destinationModelURL)
            }
            try fileManager.moveItem(at: temporaryModelURL, to: destinationModelURL)

            progressHandler(0.92, "Downloading SenseVoice vocabulary...")
            let (temporaryTokensURL, _) = try await URLSession.shared.download(from: Self.senseVoiceTokensDownloadURL)
            if fileManager.fileExists(atPath: destinationTokensURL.path) {
                try fileManager.removeItem(at: destinationTokensURL)
            }
            try fileManager.moveItem(at: temporaryTokensURL, to: destinationTokensURL)
        case .ggmlMetal:
            let destinationModelURL = modelFolder.appendingPathComponent("sense-voice-small-q4_k.gguf")
            progressHandler(0.05, "Downloading SenseVoice GGUF model...")
            let (temporaryModelURL, _) = try await URLSession.shared.download(from: Self.senseVoiceGGUFDownloadURL)
            if fileManager.fileExists(atPath: destinationModelURL.path) {
                try fileManager.removeItem(at: destinationModelURL)
            }
            try fileManager.moveItem(at: temporaryModelURL, to: destinationModelURL)
        case .coreML:
            throw NSError(
                domain: "ModelManager",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The experimental SenseVoice Core ML backend currently supports manual installs only. Place an extracted SenseVoiceSmall.mlmodelc bundle, spm, and cmvn_am.mvn in Application Support/EarPalModels/sensevoice."
                ]
            )
        }

        progressHandler(1.0, "SenseVoice ready.")
    }

    private func deleteTranslateGemmaModel() throws {
        let modelFolder = try modelFolderURL(for: "translate-gemma")
        if fileManager.fileExists(atPath: modelFolder.path) {
            try fileManager.removeItem(at: modelFolder)
        }
    }

    private func deleteSenseVoiceModel() throws {
        let modelFolder = try Self.senseVoiceModelDirectoryURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: modelFolder.path) {
            try fileManager.removeItem(at: modelFolder)
        }
    }

    private func removeCachedModel(modelID: String) throws {
        let cacheDir = try HuggingFaceDownloader.getCacheDirectory(for: modelID)
        if fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.removeItem(at: cacheDir)
        }
    }

    private func modelFolderURL(for modelID: String) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let modelsURL = baseURL.appendingPathComponent("EarPalModels", isDirectory: true)
        if !fileManager.fileExists(atPath: modelsURL.path) {
            try fileManager.createDirectory(at: modelsURL, withIntermediateDirectories: true)
        }
        return modelsURL.appendingPathComponent(modelID, isDirectory: true)
    }

    private static func translateGemmaModelFileURL(fileManager: FileManager) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let modelsURL = baseURL.appendingPathComponent("EarPalModels", isDirectory: true)
        if !fileManager.fileExists(atPath: modelsURL.path) {
            try fileManager.createDirectory(at: modelsURL, withIntermediateDirectories: true)
        }
        let gemmaFolder = modelsURL.appendingPathComponent("translate-gemma", isDirectory: true)
        if !fileManager.fileExists(atPath: gemmaFolder.path) {
            try fileManager.createDirectory(at: gemmaFolder, withIntermediateDirectories: true)
        }
        return gemmaFolder.appendingPathComponent(translateGemmaFileName, isDirectory: false)
    }

    nonisolated static func senseVoiceModelDirectoryURL(fileManager: FileManager = .default) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let modelsURL = baseURL.appendingPathComponent("EarPalModels", isDirectory: true)
        if !fileManager.fileExists(atPath: modelsURL.path) {
            try fileManager.createDirectory(at: modelsURL, withIntermediateDirectories: true)
        }
        return modelsURL.appendingPathComponent("sensevoice", isDirectory: true)
    }
}
