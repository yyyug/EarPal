import Foundation
import Darwin

protocol SenseVoiceRuntime: Sendable {
    func transcribe(audio: [Float]) throws -> String
    func unload()
}

enum SenseVoiceASRServiceError: LocalizedError {
    case modelFilesMissing
    case recognizerCreationFailed
    case emptyRecognizerStream

    var errorDescription: String? {
        switch self {
        case .modelFilesMissing:
            return "SenseVoice model files are missing. Download the SenseVoice model from Models & Engines, then try again."
        case .recognizerCreationFailed:
            return "SenseVoice failed to initialize."
        case .emptyRecognizerStream:
            return "SenseVoice failed to create a decoder stream."
        }
    }
}

struct SenseVoiceASRService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func makeRuntime() async throws -> any SenseVoiceRuntime {
        let modelDirectory = try ModelManager.senseVoiceModelDirectoryURL(fileManager: fileManager)
        let tokensURL = modelDirectory.appendingPathComponent("tokens.txt")
        let modelURL = resolveModelURL(in: modelDirectory)

        guard fileManager.fileExists(atPath: tokensURL.path),
              let modelURL,
              fileManager.fileExists(atPath: modelURL.path) else {
            throw SenseVoiceASRServiceError.modelFilesMissing
        }

        return try SherpaOnnxSenseVoiceRuntime(modelURL: modelURL, tokensURL: tokensURL)
    }

    private func resolveModelURL(in directory: URL) -> URL? {
        let candidates = [
            "model.int8.onnx",
            "model.onnx",
            "sense-voice.onnx",
            "sense-voice-int8.onnx"
        ]

        for candidate in candidates {
            let url = directory.appendingPathComponent(candidate)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }
}

private final class SherpaOnnxSenseVoiceRuntime: SenseVoiceRuntime {
    private let recognizer: SherpaOnnxOfflineRecognizerWrapper

    init(modelURL: URL, tokensURL: URL) throws {
        let config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(),
            model: sherpaOnnxOfflineModelConfig(
                tokens: tokensURL.path,
                senseVoice: sherpaOnnxOfflineSenseVoiceModelConfig(
                    model: modelURL.path,
                    useInverseTextNormalization: true,
                    language: ""
                ),
                numThreads: max(1, ProcessInfo.processInfo.processorCount / 2),
                debug: false,
                provider: "cpu"
            )
        )

        let recognizer = try withUnsafePointer(to: config) { pointer in
            try SherpaOnnxOfflineRecognizerWrapper(config: pointer)
        }
        self.recognizer = recognizer
    }

    func transcribe(audio: [Float]) throws -> String {
        guard !audio.isEmpty else { return "" }
        let result = try recognizer.decode(samples: audio, sampleRate: 16_000)
        return result.text
    }

    func unload() {}
}

private func toCPointer(_ string: String) -> UnsafePointer<CChar>? {
    guard let pointer = strdup(string) else {
        return nil
    }
    return UnsafePointer(pointer)
}

private func sherpaOnnxFeatureConfig(sampleRate: Int32 = 16_000, featureDim: Int32 = 80) -> SherpaOnnxFeatureConfig {
    SherpaOnnxFeatureConfig(sample_rate: sampleRate, feature_dim: featureDim)
}

private func sherpaOnnxOfflineSenseVoiceModelConfig(
    model: String,
    useInverseTextNormalization: Bool,
    language: String
) -> SherpaOnnxOfflineSenseVoiceModelConfig {
    SherpaOnnxOfflineSenseVoiceModelConfig(
        model: toCPointer(model),
        language: toCPointer(language),
        use_itn: useInverseTextNormalization ? 1 : 0
    )
}

private func sherpaOnnxOfflineModelConfig(
    tokens: String,
    senseVoice: SherpaOnnxOfflineSenseVoiceModelConfig,
    numThreads: Int,
    debug: Bool,
    provider: String
) -> SherpaOnnxOfflineModelConfig {
    SherpaOnnxOfflineModelConfig(
        transducer: sherpaOnnxOfflineTransducerModelConfig(),
        paraformer: sherpaOnnxOfflineParaformerModelConfig(),
        nemo_ctc: sherpaOnnxOfflineNemoEncDecCtcModelConfig(),
        whisper: sherpaOnnxOfflineWhisperModelConfig(),
        tdnn: sherpaOnnxOfflineTdnnModelConfig(),
        tokens: toCPointer(tokens),
        num_threads: Int32(numThreads),
        debug: debug ? 1 : 0,
        provider: toCPointer(provider),
        model_type: toCPointer(""),
        modeling_unit: toCPointer("cjkchar"),
        bpe_vocab: toCPointer(""),
        telespeech_ctc: toCPointer(""),
        sense_voice: senseVoice,
        moonshine: sherpaOnnxOfflineMoonshineModelConfig(),
        fire_red_asr: sherpaOnnxOfflineFireRedAsrModelConfig(),
        dolphin: sherpaOnnxOfflineDolphinModelConfig(),
        zipformer_ctc: sherpaOnnxOfflineZipformerCtcModelConfig(),
        canary: sherpaOnnxOfflineCanaryModelConfig(),
        wenet_ctc: sherpaOnnxOfflineWenetCtcModelConfig(),
        omnilingual: sherpaOnnxOfflineOmnilingualAsrCtcModelConfig(),
        medasr: sherpaOnnxOfflineMedAsrCtcModelConfig(),
        funasr_nano: sherpaOnnxOfflineFunASRNanoModelConfig(),
        fire_red_asr_ctc: sherpaOnnxOfflineFireRedAsrCtcModelConfig()
    )
}

private func sherpaOnnxOfflineRecognizerConfig(
    featConfig: SherpaOnnxFeatureConfig,
    model: SherpaOnnxOfflineModelConfig
) -> SherpaOnnxOfflineRecognizerConfig {
    SherpaOnnxOfflineRecognizerConfig(
        feat_config: featConfig,
        model_config: model,
        lm_config: sherpaOnnxOfflineLMConfig(),
        decoding_method: toCPointer("greedy_search"),
        max_active_paths: 4,
        hotwords_file: toCPointer(""),
        hotwords_score: 1.5,
        rule_fsts: toCPointer(""),
        rule_fars: toCPointer(""),
        blank_penalty: 0,
        hr: sherpaOnnxHomophoneReplacerConfig()
    )
}

private func sherpaOnnxOfflineTransducerModelConfig() -> SherpaOnnxOfflineTransducerModelConfig {
    SherpaOnnxOfflineTransducerModelConfig(
        encoder: toCPointer(""),
        decoder: toCPointer(""),
        joiner: toCPointer("")
    )
}

private func sherpaOnnxOfflineParaformerModelConfig() -> SherpaOnnxOfflineParaformerModelConfig {
    SherpaOnnxOfflineParaformerModelConfig(model: toCPointer(""))
}

private func sherpaOnnxOfflineZipformerCtcModelConfig() -> SherpaOnnxOfflineZipformerCtcModelConfig {
    SherpaOnnxOfflineZipformerCtcModelConfig(model: toCPointer(""))
}

private func sherpaOnnxOfflineWenetCtcModelConfig() -> SherpaOnnxOfflineWenetCtcModelConfig {
    SherpaOnnxOfflineWenetCtcModelConfig(model: toCPointer(""))
}

private func sherpaOnnxOfflineOmnilingualAsrCtcModelConfig() -> SherpaOnnxOfflineOmnilingualAsrCtcModelConfig {
    SherpaOnnxOfflineOmnilingualAsrCtcModelConfig(model: toCPointer(""))
}

private func sherpaOnnxOfflineMedAsrCtcModelConfig() -> SherpaOnnxOfflineMedAsrCtcModelConfig {
    SherpaOnnxOfflineMedAsrCtcModelConfig(model: toCPointer(""))
}

private func sherpaOnnxOfflineNemoEncDecCtcModelConfig() -> SherpaOnnxOfflineNemoEncDecCtcModelConfig {
    SherpaOnnxOfflineNemoEncDecCtcModelConfig(model: toCPointer(""))
}

private func sherpaOnnxOfflineDolphinModelConfig() -> SherpaOnnxOfflineDolphinModelConfig {
    SherpaOnnxOfflineDolphinModelConfig(model: toCPointer(""))
}

private func sherpaOnnxOfflineWhisperModelConfig() -> SherpaOnnxOfflineWhisperModelConfig {
    SherpaOnnxOfflineWhisperModelConfig(
        encoder: toCPointer(""),
        decoder: toCPointer(""),
        language: toCPointer(""),
        task: toCPointer("transcribe"),
        tail_paddings: -1,
        enable_token_timestamps: 0,
        enable_segment_timestamps: 0
    )
}

private func sherpaOnnxOfflineCanaryModelConfig() -> SherpaOnnxOfflineCanaryModelConfig {
    SherpaOnnxOfflineCanaryModelConfig(
        encoder: toCPointer(""),
        decoder: toCPointer(""),
        src_lang: toCPointer("en"),
        tgt_lang: toCPointer("en"),
        use_pnc: 1
    )
}

private func sherpaOnnxOfflineFireRedAsrModelConfig() -> SherpaOnnxOfflineFireRedAsrModelConfig {
    SherpaOnnxOfflineFireRedAsrModelConfig(
        encoder: toCPointer(""),
        decoder: toCPointer("")
    )
}

private func sherpaOnnxOfflineMoonshineModelConfig() -> SherpaOnnxOfflineMoonshineModelConfig {
    SherpaOnnxOfflineMoonshineModelConfig(
        preprocessor: toCPointer(""),
        encoder: toCPointer(""),
        uncached_decoder: toCPointer(""),
        cached_decoder: toCPointer(""),
        merged_decoder: toCPointer("")
    )
}

private func sherpaOnnxOfflineTdnnModelConfig() -> SherpaOnnxOfflineTdnnModelConfig {
    SherpaOnnxOfflineTdnnModelConfig(model: toCPointer(""))
}

private func sherpaOnnxOfflineLMConfig() -> SherpaOnnxOfflineLMConfig {
    SherpaOnnxOfflineLMConfig(model: toCPointer(""), scale: 1.0)
}

private func sherpaOnnxOfflineFunASRNanoModelConfig() -> SherpaOnnxOfflineFunASRNanoModelConfig {
    SherpaOnnxOfflineFunASRNanoModelConfig(
        encoder_adaptor: toCPointer(""),
        llm: toCPointer(""),
        embedding: toCPointer(""),
        tokenizer: toCPointer(""),
        system_prompt: toCPointer("You are a helpful assistant."),
        user_prompt: toCPointer("Transcribe speech:"),
        max_new_tokens: 512,
        temperature: 1e-6,
        top_p: 0.8,
        seed: 42,
        language: toCPointer(""),
        itn: 1,
        hotwords: toCPointer("")
    )
}

private func sherpaOnnxHomophoneReplacerConfig() -> SherpaOnnxHomophoneReplacerConfig {
    SherpaOnnxHomophoneReplacerConfig(
        dict_dir: toCPointer(""),
        lexicon: toCPointer(""),
        rule_fsts: toCPointer("")
    )
}

private func sherpaOnnxOfflineFireRedAsrCtcModelConfig() -> SherpaOnnxOfflineFireRedAsrCtcModelConfig {
    SherpaOnnxOfflineFireRedAsrCtcModelConfig(model: toCPointer(""))
}

private final class SherpaOnnxOfflineRecognitionResultWrapper {
    private let result: UnsafePointer<SherpaOnnxOfflineRecognizerResult>

    init(result: UnsafePointer<SherpaOnnxOfflineRecognizerResult>) {
        self.result = result
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizerResult(result)
    }

    var text: String {
        guard let cString = result.pointee.text else {
            return ""
        }
        return String(cString: cString)
    }
}

private final class SherpaOnnxOfflineRecognizerWrapper {
    private let recognizer: OpaquePointer

    init(config: UnsafePointer<SherpaOnnxOfflineRecognizerConfig>) throws {
        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(config) else {
            throw SenseVoiceASRServiceError.recognizerCreationFailed
        }
        self.recognizer = recognizer
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    func decode(samples: [Float], sampleRate: Int) throws -> SherpaOnnxOfflineRecognitionResultWrapper {
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            throw SenseVoiceASRServiceError.emptyRecognizerStream
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), samples, Int32(samples.count))
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw SenseVoiceASRServiceError.emptyRecognizerStream
        }

        return SherpaOnnxOfflineRecognitionResultWrapper(result: result)
    }
}
