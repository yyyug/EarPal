import Foundation

#if canImport(MediaPipeTasksGenAI)
import MediaPipeTasksGenAI

@MainActor
final class TranslateGemmaService {
    static let shared = TranslateGemmaService()

    private var loadedModelPath: String?
    private var inference: LlmInference?

    private init() {}

    func translate(
        text: String,
        sourceLanguage: TranslationLanguage,
        targetLanguage: TranslationLanguage,
        modelPath: String
    ) async throws -> String {
        try loadModelIfNeeded(modelPath: modelPath)

        guard let inference else {
            throw LocalInferenceRuntimeError.runtimeUnavailable(TranslationEngine.translateGemma.displayName)
        }

        let sessionOptions = LlmInference.Session.Options()
        sessionOptions.topk = 20
        sessionOptions.topp = 0.8
        sessionOptions.temperature = 0.2

        let session = try LlmInference.Session(llmInference: inference, options: sessionOptions)
        try session.addQueryChunk(inputText: makePrompt(text: text, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage))

        let response = try session.generateResponse()
        let cleaned = response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")

        return cleaned.isEmpty ? response.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    private func loadModelIfNeeded(modelPath: String) throws {
        guard loadedModelPath != modelPath || inference == nil else { return }

        let options = LlmInference.Options(modelPath: modelPath)
        options.maxTokens = 256
        inference = try LlmInference(options: options)
        loadedModelPath = modelPath
    }

    private func makePrompt(
        text: String,
        sourceLanguage: TranslationLanguage,
        targetLanguage: TranslationLanguage
    ) -> String {
        """
        You are a translation engine.
        Translate the user's text from \(gemmaLanguageName(for: sourceLanguage)) to \(gemmaLanguageName(for: targetLanguage)).
        Return only the translated text with no explanation, no quotes, and no extra formatting.

        Text:
        \(text)
        """
    }

    private func gemmaLanguageName(for language: TranslationLanguage) -> String {
        switch language.id {
        case "en":
            return "English"
        case "zh-Hant":
            return "Traditional Chinese"
        case "zh-Hans":
            return "Simplified Chinese"
        case "ja":
            return "Japanese"
        case "ko":
            return "Korean"
        case "es":
            return "Spanish"
        case "fr":
            return "French"
        case "de":
            return "German"
        default:
            return language.displayName
        }
    }
}
#else
@MainActor
final class TranslateGemmaService {
    static let shared = TranslateGemmaService()

    private init() {}

    func translate(
        text: String,
        sourceLanguage: TranslationLanguage,
        targetLanguage: TranslationLanguage,
        modelPath: String
    ) async throws -> String {
        _ = text
        _ = sourceLanguage
        _ = targetLanguage
        _ = modelPath
        throw LocalInferenceRuntimeError.runtimeUnavailable(TranslationEngine.translateGemma.displayName)
    }
}
#endif
