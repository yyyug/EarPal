import AudioCommon
import Combine
import Foundation
import ParakeetASR
import Qwen3ASR
import SpeechVAD

@MainActor
final class ModelManager: ObservableObject {
    static let parakeetModelID = ParakeetASRModel.defaultModelId
    static let qwen3ASRModelID = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    static let sileroVADModelID = SileroVADModel.defaultCoreMLModelId
    static let translateGemmaDownloadURL = URL(string: "https://huggingface.co/google/gemma-3n-E2B-it-litert-preview/resolve/main/gemma-3n-E2B-it-int4.task?download=true")!
    static let translateGemmaFileName = "gemma-3n-E2B-it-int4.task"

    @Published private(set) var models: [InferenceModel]
    @Published var selectedASREngine: ASREngine
    @Published var selectedTranslationEngine: TranslationEngine

    private let defaults = UserDefaults.standard
    private let installedModelsKey = "installed.model.ids"
    private let selectedASRKey = "selected.asr.engine"
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

        let storedTranslation = TranslationEngine(rawValue: defaults.string(forKey: selectedTranslationKey) ?? "") ?? .apple
        selectedTranslationEngine = Self.resolveTranslationEngine(storedTranslation, with: initialModels)
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

    func downloadModel(id: String) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        guard !models[index].isBuiltIn, !models[index].isInstalled, !models[index].isDownloading else { return }

        models[index].isDownloading = true
        models[index].downloadProgress = 0
        models[index].statusNote = "Preparing download..."

        let modelID = id
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
                if !Self.isQwenInstalled(fileManager: fileManager) {
                    try removeCachedModel(modelID: Self.sileroVADModelID)
                }
            case "qwen3-asr":
                try removeCachedModel(modelID: Self.qwen3ASRModelID)
                if !Self.isParakeetInstalled(fileManager: fileManager) {
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

    private func deleteTranslateGemmaModel() throws {
        let modelFolder = try modelFolderURL(for: "translate-gemma")
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
}
