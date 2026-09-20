import Foundation

enum ASREngine: String, CaseIterable, Identifiable {
    case apple
    case senseVoice
    case parakeet
    case qwen3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple:
            return "Apple Speech"
        case .senseVoice:
            return "SenseVoice"
        case .parakeet:
            return "NVIDIA Parakeet"
        case .qwen3:
            return "Qwen3-ASR"
        }
    }

    var shortName: String {
        switch self {
        case .apple:
            return "Apple"
        case .senseVoice:
            return "SenseVoice"
        case .parakeet:
            return "Parakeet"
        case .qwen3:
            return "Qwen3"
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

    var shortName: String {
        switch self {
        case .apple:
            return "Apple"
        case .translateGemma:
            return "TranslateGemma"
        }
    }
}

enum SenseVoiceLanguageOption: String, CaseIterable, Identifiable {
    case auto
    case english
    case chinese
    case cantonese
    case japanese
    case korean

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "Match Source Language"
        case .english:
            return "English"
        case .chinese:
            return "Mandarin Chinese"
        case .cantonese:
            return "Cantonese"
        case .japanese:
            return "Japanese"
        case .korean:
            return "Korean"
        }
    }

    var senseVoiceCode: String? {
        switch self {
        case .auto:
            return nil
        case .english:
            return "en"
        case .chinese:
            return "zh"
        case .cantonese:
            return "yue"
        case .japanese:
            return "ja"
        case .korean:
            return "ko"
        }
    }

    static func autoCode(for sourceLanguageID: String) -> String {
        switch sourceLanguageID.lowercased() {
        case "en":
            return "en"
        case "zh-hant", "zh-hans":
            return "zh"
        case "ja":
            return "ja"
        case "ko":
            return "ko"
        default:
            return "auto"
        }
    }

    func resolvedCode(for sourceLanguageID: String) -> String {
        senseVoiceCode ?? Self.autoCode(for: sourceLanguageID)
    }
}

enum SenseVoiceBackend: String, CaseIterable, Identifiable {
    case sherpaOnnx
    case ggmlMetal
    case coreML

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sherpaOnnx:
            return "ONNX Runtime"
        case .ggmlMetal:
            return "ggml + Metal"
        case .coreML:
            return "Core ML (Unofficial)"
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
