import Foundation

enum LocalInferenceRuntimeError: LocalizedError {
    case runtimeUnavailable(String)
    case modelNotInstalled(String)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let name):
            return "\(name) is not available in this build. Make sure the MediaPipe runtime is linked and the model is installed."
        case .modelNotInstalled(let name):
            return "\(name) is not installed on this device."
        }
    }
}

@MainActor
struct LocalInferenceRuntime {
    let modelManager: ModelManager

    func translateWithTranslateGemma(
        text: String,
        sourceLanguage: TranslationLanguage,
        targetLanguage: TranslationLanguage
    ) async throws -> String {
        guard modelManager.canUse(.translateGemma) else {
            throw LocalInferenceRuntimeError.modelNotInstalled(TranslationEngine.translateGemma.displayName)
        }

        let modelURL = try modelManager.translateGemmaModelFileURL()
        return try await TranslateGemmaService.shared.translate(
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            modelPath: modelURL.path
        )
    }
}
