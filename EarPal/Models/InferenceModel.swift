import Foundation

enum ASREngine: String, CaseIterable, Identifiable {
    case apple
    case parakeet
    case qwen3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple:
            return "Apple Speech"
        case .parakeet:
            return "NVIDIA Parakeet"
        case .qwen3:
            return "Qwen3-ASR"
        }
    }
}

enum TranslationEngine: String, CaseIterable, Identifiable {
    case apple
    case translateGemma

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple:
            return "Apple Translate"
        case .translateGemma:
            return "TranslateGemma"
        }
    }
}

struct InferenceModel: Identifiable, Hashable {
    enum TaskKind: String {
        case asr
        case translation
    }

    let id: String
    let displayName: String
    let task: TaskKind
    let engineID: String
    let supportsLanguages: [String]
    let sizeDescription: String
    let downloadURL: URL?
    let isBuiltIn: Bool
    var isInstalled: Bool
    var isDownloading: Bool
    var downloadProgress: Double
    var statusNote: String
}
