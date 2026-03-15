import Combine
import Foundation

@MainActor
final class ModelManager: ObservableObject {
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
        models = [
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
                isInstalled: installedIDs.contains("parakeet-asr"),
                isDownloading: false,
                downloadProgress: installedIDs.contains("parakeet-asr") ? 1 : 0,
                statusNote: "Download configured in app storage. Runtime wiring is pending."
            ),
            InferenceModel(
                id: "qwen3-asr",
                displayName: "Qwen3-ASR",
                task: .asr,
                engineID: ASREngine.qwen3.rawValue,
                supportsLanguages: TranslationLanguage.commonOptions.map(\.id),
                sizeDescription: "~2.0 GB",
                downloadURL: nil,
                isBuiltIn: false,
                isInstalled: installedIDs.contains("qwen3-asr"),
                isDownloading: false,
                downloadProgress: installedIDs.contains("qwen3-asr") ? 1 : 0,
                statusNote: "Download configured in app storage. Runtime wiring is pending."
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
                isInstalled: installedIDs.contains("translate-gemma"),
                isDownloading: false,
                downloadProgress: installedIDs.contains("translate-gemma") ? 1 : 0,
                statusNote: "Download configured in app storage. Runtime wiring is pending."
            )
        ]

        let storedASR = ASREngine(rawValue: defaults.string(forKey: selectedASRKey) ?? "") ?? .apple
        selectedASREngine = ModelManager.resolveASREngine(storedASR, with: models)

        let storedTranslation = TranslationEngine(rawValue: defaults.string(forKey: selectedTranslationKey) ?? "") ?? .apple
        selectedTranslationEngine = ModelManager.resolveTranslationEngine(storedTranslation, with: models)
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
        let resolved = ModelManager.resolveASREngine(engine, with: models)
        selectedASREngine = resolved
        defaults.set(resolved.rawValue, forKey: selectedASRKey)
    }

    func select(translation engine: TranslationEngine) {
        let resolved = ModelManager.resolveTranslationEngine(engine, with: models)
        selectedTranslationEngine = resolved
        defaults.set(resolved.rawValue, forKey: selectedTranslationKey)
    }

    func downloadModel(id: String) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        guard !models[index].isBuiltIn, !models[index].isInstalled, !models[index].isDownloading else { return }

        models[index].isDownloading = true
        models[index].downloadProgress = 0
        models[index].statusNote = "Preparing app storage..."

        Task {
            for step in 1...10 {
                try? await Task.sleep(for: .milliseconds(180))
                guard let liveIndex = self.models.firstIndex(where: { $0.id == id }) else { return }
                self.models[liveIndex].downloadProgress = Double(step) / 10
                self.models[liveIndex].statusNote = "Downloading..."
            }

            guard let liveIndex = self.models.firstIndex(where: { $0.id == id }) else { return }
            do {
                try self.installMarker(for: self.models[liveIndex])
                self.models[liveIndex].isInstalled = true
                self.models[liveIndex].isDownloading = false
                self.models[liveIndex].downloadProgress = 1
                self.models[liveIndex].statusNote = "Installed in app storage."
                self.persistInstalledModels()
            } catch {
                self.models[liveIndex].isDownloading = false
                self.models[liveIndex].downloadProgress = 0
                self.models[liveIndex].statusNote = "Install failed: \(error.localizedDescription)"
            }
        }
    }

    func deleteModel(id: String) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        guard !models[index].isBuiltIn, models[index].isInstalled else { return }

        do {
            try deleteMarker(for: models[index])
            let deletedModel = models[index]
            models[index].isInstalled = false
            models[index].isDownloading = false
            models[index].downloadProgress = 0
            models[index].statusNote = "Removed from app storage."
            persistInstalledModels()
            resetSelectionsIfNeeded(deletedModel: deletedModel)
        } catch {
            models[index].statusNote = "Delete failed: \(error.localizedDescription)"
        }
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
            .filter { !$0.isBuiltIn && $0.isInstalled }
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
