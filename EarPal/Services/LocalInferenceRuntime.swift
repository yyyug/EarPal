import Foundation

enum LocalInferenceRuntimeError: LocalizedError {
    case runtimeNotIntegrated(String)
    case modelNotInstalled(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotIntegrated(let name):
            return "\(name) is selected and stored locally, but its on-device runtime is not integrated into this build yet."
        case .modelNotInstalled(let name):
            return "\(name) is not installed on this device."
        }
    }
}

@MainActor
struct LocalInferenceRuntime {
    let modelManager: ModelManager

    func translateWithTranslateGemma(text: String) async throws -> String {
        guard modelManager.canUse(.translateGemma) else {
            throw LocalInferenceRuntimeError.modelNotInstalled(TranslationEngine.translateGemma.displayName)
        }

        throw LocalInferenceRuntimeError.runtimeNotIntegrated(TranslationEngine.translateGemma.displayName)
    }
}
