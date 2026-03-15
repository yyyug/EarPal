import AudioCommon
import Combine
import Foundation
import ParakeetASR
import Qwen3ASR

@MainActor
final class ModelManager: ObservableObject {
    static let parakeetModelID = ParakeetASRModel.defaultModelId
    static let qwen3ASRModelID = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"

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
                    await MainActor.run {
                        self.markInstalled(id: modelID, note: "Parakeet downloaded to local cache.")
                    }
                case "qwen3-asr":
                    let model = try await Qwen3ASRModel.fromPretrained(modelId: Self.qwen3ASRModelID) { [weak self] progress, status in
                        Task { @MainActor in
                            self?.updateDownloadState(id: modelID, progress: progress, note: status)
                        }
                    }
                    model.unload()
                    await MainActor.run {
                        self.markInstalled(id: modelID, note: "Qwen3-ASR downloaded to local cache.")
                    }
                case "translate-gemma":
                    try installMarker(for: models[index])
                    markInstalled(id: modelID, note: "Placeholder install saved in app storage.")
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
            case "qwen3-asr":
                try removeCachedModel(modelID: Self.qwen3ASRModelID)
            case "translate-gemma":
                try deleteMarker(for: models[index])
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
        let translateGemmaInstalled = installedIDs.contains("translate-gemma")

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
                downloadURL: nil,
                isBuiltIn: false,
                isInstalled: translateGemmaInstalled,
                isDownloading: false,
                downloadProgress: translateGemmaInstalled ? 1 : 0,
                statusNote: "Download lifecycle is wired. Runtime is still pending."
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

    private func installMarker(for model: InferenceModel) throws {
        let modelFolder = try modelFolderURL(for: model.id)
        try fileManager.createDirectory(at: modelFolder, withIntermediateDirectories: true)
        let markerURL = modelFolder.appendingPathComponent("metadata.json")
        let data = try JSONEncoder().encode([
            "id": model.id,
            "displayName": model.displayName,
            "installedAt": ISO8601DateFormatter().string(from: .now)
        ])
        try data.write(to: markerURL, options: .atomic)
    }

    private func deleteMarker(for model: InferenceModel) throws {
        let modelFolder = try modelFolderURL(for: model.id)
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
}
