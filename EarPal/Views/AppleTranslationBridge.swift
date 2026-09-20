import SwiftUI

#if canImport(Translation)
import Translation

enum AppleTranslationError: LocalizedError {
    case unsupportedLanguagePair

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguagePair:
            return "Apple Translate does not support this language pair."
        }
    }
}

@available(iOS 18.0, *)
struct AppleTranslationBridge: View {
    let request: LiveTranslateViewModel.AppleTranslationRequest
    let onTranslated: (String) -> Void
    let onFailure: (Error) -> Void

    @State private var configuration: TranslationSession.Configuration

    init(
        request: LiveTranslateViewModel.AppleTranslationRequest,
        onTranslated: @escaping (String) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.request = request
        self.onTranslated = onTranslated
        self.onFailure = onFailure
        _configuration = State(
            initialValue: TranslationSession.Configuration(
                source: Locale.Language(identifier: request.sourceLanguageID),
                target: Locale.Language(identifier: request.targetLanguageID)
            )
        )
    }

    var body: some View {
        Color.clear
            .task(id: request.id) {
                configuration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: request.sourceLanguageID),
                    target: Locale.Language(identifier: request.targetLanguageID)
                )
                configuration.invalidate()
            }
            .translationTask(configuration) { session in
                let availability = await LanguageAvailability().status(
                    from: Locale.Language(identifier: request.sourceLanguageID),
                    to: Locale.Language(identifier: request.targetLanguageID)
                )
                guard availability != .unsupported else {
                    await MainActor.run {
                        onFailure(AppleTranslationError.unsupportedLanguagePair)
                    }
                    return
                }

                do {
                    let response = try await session.translate(request.text)
                    await MainActor.run {
                        onTranslated(response.targetText)
                    }
                } catch {
                    await MainActor.run {
                        onFailure(error)
                    }
                }
            }
    }
}
#endif
