import Foundation
import Darwin
import Accelerate
import OSLog
@preconcurrency import CoreML

protocol SenseVoiceRuntime: Sendable {
    func transcribe(audio: [Float]) throws -> String
    func unload()
}

enum SenseVoiceASRServiceError: LocalizedError {
    case modelFilesMissing
    case recognizerCreationFailed
    case emptyRecognizerStream
    case ggmlRuntimeUnavailable
    case ggmlModelMissing
    case coreMLModelMissing
    case coreMLAssetsMissing
    case coreMLContractInvalid
    case coreMLOutputInvalid

    var errorDescription: String? {
        switch self {
        case .modelFilesMissing:
            return "SenseVoice model files are missing. Download the SenseVoice model from Models & Engines, then try again."
        case .recognizerCreationFailed:
            return "SenseVoice failed to initialize."
        case .emptyRecognizerStream:
            return "SenseVoice failed to create a decoder stream."
        case .ggmlRuntimeUnavailable:
            return "The ggml + Metal SenseVoice runtime is unavailable in this build."
        case .ggmlModelMissing:
            return "The SenseVoice GGUF model is missing. Download the ggml + Metal backend assets from Models & Engines, then try again."
        case .coreMLModelMissing:
            return "The SenseVoice Core ML model is missing. Install an extracted SenseVoiceSmall.mlmodelc bundle in Models & Engines, then try again."
        case .coreMLAssetsMissing:
            return "The SenseVoice Core ML support assets are missing. Install the SentencePiece and CMVN files for the Core ML backend, then try again."
        case .coreMLContractInvalid:
            return "The downloaded SenseVoice Core ML model does not match the expected runtime contract."
        case .coreMLOutputInvalid:
            return "SenseVoice Core ML returned an unexpected output shape."
        }
    }
}

struct SenseVoiceASRService {
    private static let logger = Logger(subsystem: "EarPal", category: "SenseVoice")
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func validateCoreMLAssets(in modelDirectory: URL) throws {
        guard let modelURL = resolveCoreMLModelDirectory(in: modelDirectory) else {
            throw SenseVoiceASRServiceError.coreMLModelMissing
        }

        guard let sentencePieceURL = resolveSentencePieceURL(in: modelDirectory),
              let cmvnURL = resolveCMVNURL(in: modelDirectory) else {
            throw SenseVoiceASRServiceError.coreMLAssetsMissing
        }

        _ = try CoreMLSenseVoiceRuntime(
            modelURL: modelURL,
            sentencePieceURL: sentencePieceURL,
            cmvnURL: cmvnURL,
            language: "auto"
        )
    }

    func validateBackend(backend: SenseVoiceBackend, language: String = "auto") throws {
        let runtime = try makeRuntimeSync(language: language, backend: backend)
        runtime.unload()
    }

    func makeRuntime(language: String, backend: SenseVoiceBackend) async throws -> any SenseVoiceRuntime {
        return try makeRuntimeSync(language: language, backend: backend)
    }

    private func makeRuntimeSync(language: String, backend: SenseVoiceBackend) throws -> any SenseVoiceRuntime {
        switch backend {
        case .sherpaOnnx:
            let modelDirectory = try ModelManager.senseVoiceModelDirectoryURL(fileManager: fileManager)
            let tokensURL = modelDirectory.appendingPathComponent("tokens.txt")
            let modelURL = resolveModelURL(in: modelDirectory)

            guard fileManager.fileExists(atPath: tokensURL.path),
                  let modelURL,
                  fileManager.fileExists(atPath: modelURL.path) else {
                throw SenseVoiceASRServiceError.modelFilesMissing
            }

            Self.logger.debug("Initializing SenseVoice ONNX runtime with language: \(language, privacy: .public)")
            return try SherpaOnnxSenseVoiceRuntime(modelURL: modelURL, tokensURL: tokensURL, language: language)
        case .ggmlMetal:
            let modelDirectory = try ModelManager.senseVoiceModelDirectoryURL(fileManager: fileManager)
            guard let modelURL = resolveGGUFModelURL(in: modelDirectory),
                  fileManager.fileExists(atPath: modelURL.path) else {
                throw SenseVoiceASRServiceError.ggmlModelMissing
            }

            Self.logger.debug("Initializing SenseVoice ggml runtime with model: \(modelURL.lastPathComponent, privacy: .public), language: \(language, privacy: .public)")
            return try GGMLSenseVoiceRuntime(modelURL: modelURL, language: language)
        case .coreML:
            let modelDirectory = try ModelManager.senseVoiceModelDirectoryURL(fileManager: fileManager)
            guard let modelURL = resolveCoreMLModelDirectory(in: modelDirectory) else {
                throw SenseVoiceASRServiceError.coreMLModelMissing
            }

            guard let sentencePieceURL = resolveSentencePieceURL(in: modelDirectory),
                  let cmvnURL = resolveCMVNURL(in: modelDirectory) else {
                throw SenseVoiceASRServiceError.coreMLAssetsMissing
            }

            Self.logger.debug("Initializing SenseVoice Core ML runtime with model: \(modelURL.lastPathComponent, privacy: .public), language: \(language, privacy: .public)")
            return try CoreMLSenseVoiceRuntime(
                modelURL: modelURL,
                sentencePieceURL: sentencePieceURL,
                cmvnURL: cmvnURL,
                language: language
            )
        }
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

    private func resolveGGUFModelURL(in directory: URL) -> URL? {
        let candidates = [
            "sense-voice-small-q4_k.gguf",
            "sense-voice-small-q8_0.gguf",
            "sense-voice-small-f16.gguf",
            "gguf-fp16-sense-voice-small.bin",
            "gguf-fp32-sense-voice-small.bin"
        ]

        for candidate in candidates {
            let url = directory.appendingPathComponent(candidate)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    private func resolveCoreMLModelDirectory(in directory: URL) -> URL? {
        let candidates = [
            directory.appendingPathComponent("SenseVoiceSmall.mlmodelc", isDirectory: true),
            directory.appendingPathComponent("coreml/SenseVoiceSmall.mlmodelc", isDirectory: true)
        ]

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }

        return nil
    }

    private func resolveSentencePieceURL(in directory: URL) -> URL? {
        let candidates = [
            "spm",
            "chn_jpn_yue_eng_ko_spectok.bpe.model",
            "coreml/spm",
            "coreml/chn_jpn_yue_eng_ko_spectok.bpe.model"
        ]

        for candidate in candidates {
            let url = directory.appendingPathComponent(candidate)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    private func resolveCMVNURL(in directory: URL) -> URL? {
        let candidates = [
            "cmvn_am.mvn",
            "am.mvn",
            "coreml/cmvn_am.mvn",
            "coreml/am.mvn"
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

private final class SherpaOnnxSenseVoiceRuntime: @unchecked Sendable, SenseVoiceRuntime {
    private let recognizer: SherpaOnnxOfflineRecognizerWrapper

    init(modelURL: URL, tokensURL: URL, language: String) throws {
        let config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(),
            model: sherpaOnnxOfflineModelConfig(
                tokens: tokensURL.path,
                senseVoice: sherpaOnnxOfflineSenseVoiceModelConfig(
                    model: modelURL.path,
                    useInverseTextNormalization: true,
                    language: language
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

private final class GGMLSenseVoiceRuntime: @unchecked Sendable, SenseVoiceRuntime {
    private let recognizer: SenseVoiceGGMLRecognizer

    init(modelURL: URL, language: String) throws {
        self.recognizer = try SenseVoiceGGMLRecognizer(
            modelPath: modelURL.path,
            language: language,
            useITN: true,
            threads: max(1, ProcessInfo.processInfo.processorCount / 2)
        )
    }

    func transcribe(audio: [Float]) throws -> String {
        guard !audio.isEmpty else { return "" }
        let data = audio.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }
        return try recognizer.transcribePCMFloat(data, sampleCount: audio.count)
    }

    func unload() {
        recognizer.unload()
    }
}

private final class CoreMLSenseVoiceRuntime: @unchecked Sendable, SenseVoiceRuntime {
    private struct Contract {
        let speechInput: String
        let speechLengthsInput: String
        let languageInput: String
        let textnormInput: String
        let logitsOutput: String
        let lengthsOutput: String?
    }

    private let model: MLModel
    private let decoder: SentencePieceDecoder
    private let featureExtractor: SenseVoiceCoreMLFeatureExtractor
    private let contract: Contract
    private let languageID: Int32
    private let textnormID: Int32

    init(modelURL: URL, sentencePieceURL: URL, cmvnURL: URL, language: String) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        self.model = try MLModel(contentsOf: modelURL, configuration: configuration)
        self.decoder = try SentencePieceDecoder(modelPath: sentencePieceURL.path)
        let cmvn = try SenseVoiceCMVN.load(from: cmvnURL)
        self.featureExtractor = SenseVoiceCoreMLFeatureExtractor(cmvn: cmvn)
        self.contract = try Self.resolveContract(for: model)
        self.languageID = Self.languageID(for: language)
        self.textnormID = Self.defaultTextnormID
    }

    func transcribe(audio: [Float]) throws -> String {
        guard !audio.isEmpty else { return "" }

        let extracted = try featureExtractor.extract(audio)
        let features = try makeFeatureArray(from: extracted.frames)
        let lengths = try makeVectorArray([Int32(extracted.frameCount)], dataType: .int32)
        let language = try makeVectorArray([languageID], dataType: .int32)
        let textnorm = try makeVectorArray([textnormID], dataType: .int32)

        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            contract.speechInput: MLFeatureValue(multiArray: features),
            contract.speechLengthsInput: MLFeatureValue(multiArray: lengths),
            contract.languageInput: MLFeatureValue(multiArray: language),
            contract.textnormInput: MLFeatureValue(multiArray: textnorm)
        ])

        let outputs = try model.prediction(from: inputs)
        guard let logits = outputs.featureValue(for: contract.logitsOutput)?.multiArrayValue else {
            throw SenseVoiceASRServiceError.coreMLOutputInvalid
        }

        let outputLength = contract.lengthsOutput
            .flatMap { outputs.featureValue(for: $0)?.multiArrayValue }
            .map { readFirstInt(from: $0) }
        let frameCount = max(0, min(extracted.frameCount, outputLength ?? extracted.frameCount))
        let tokenIDs = try greedyDecode(logits: logits, frameCount: frameCount)
        return decoder.decode(tokenIDs)
    }

    func unload() {}

    private func makeFeatureArray(from frames: [Float]) throws -> MLMultiArray {
        let frameCount = frames.count / SenseVoiceCoreMLFeatureExtractor.featureDimension
        let array = try MLMultiArray(
            shape: [1, frameCount as NSNumber, SenseVoiceCoreMLFeatureExtractor.featureDimension as NSNumber],
            dataType: .float32
        )
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: frames.count)
        frames.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            pointer.update(from: baseAddress, count: frames.count)
        }
        return array
    }

    private func makeVectorArray(_ values: [Int32], dataType: MLMultiArrayDataType) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [values.count as NSNumber], dataType: dataType)
        let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        values.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            pointer.update(from: baseAddress, count: values.count)
        }
        return array
    }

    private func readFirstInt(from array: MLMultiArray) -> Int {
        switch array.dataType {
        case .int32:
            return Int(array.dataPointer.bindMemory(to: Int32.self, capacity: 1).pointee)
        default:
            return Int(array[0].intValue)
        }
    }

    private func greedyDecode(logits: MLMultiArray, frameCount: Int) throws -> [Int32] {
        let shape = logits.shape.map(\.intValue)
        let dimensions = shape.filter { $0 > 1 }
        guard !dimensions.isEmpty else {
            throw SenseVoiceASRServiceError.coreMLOutputInvalid
        }

        let vocabAxis = shape.enumerated().max(by: { $0.element < $1.element })?.offset ?? (shape.count - 1)
        let nonBatchAxes = shape.enumerated().filter { $0.offset != vocabAxis && $0.element > 1 }.map(\.offset)
        let timeAxis = nonBatchAxes.last ?? (shape.count >= 2 ? shape.count - 2 : 0)
        let timeDimension = shape[timeAxis]
        let vocabDimension = shape[vocabAxis]
        let strides = logits.strides.map(\.intValue)

        guard vocabDimension > 1, timeDimension > 0 else {
            throw SenseVoiceASRServiceError.coreMLOutputInvalid
        }

        let validFrames = min(frameCount, timeDimension)
        let pointer = logits.dataPointer.bindMemory(to: Float.self, capacity: logits.count)
        var decoded = [Int32]()
        decoded.reserveCapacity(validFrames)
        var previousToken: Int32 = -1

        for time in 0..<validFrames {
            var bestToken = 0
            var bestScore = -Float.greatestFiniteMagnitude
            for vocab in 0..<vocabDimension {
                let index = linearIndex(
                    for: shape.count,
                    timeAxis: timeAxis,
                    time: time,
                    vocabAxis: vocabAxis,
                    vocab: vocab
                )
                let offset = zip(index, strides).reduce(0) { $0 + ($1.0 * $1.1) }
                let score = pointer[offset]
                if score > bestScore {
                    bestScore = score
                    bestToken = vocab
                }
            }

            let token = Int32(bestToken)
            guard token != 0, token != previousToken else {
                previousToken = token
                continue
            }

            decoded.append(token)
            previousToken = token
        }

        return decoded
    }

    private func linearIndex(
        for rank: Int,
        timeAxis: Int,
        time: Int,
        vocabAxis: Int,
        vocab: Int
    ) -> [Int] {
        var result = Array(repeating: 0, count: rank)
        result[timeAxis] = time
        result[vocabAxis] = vocab
        return result
    }

    private static func languageID(for language: String) -> Int32 {
        switch language.lowercased() {
        case "zh":
            return 3
        case "en":
            return 4
        case "yue":
            return 7
        case "ja":
            return 11
        case "ko":
            return 12
        default:
            return 0
        }
    }

    private static let defaultTextnormID: Int32 = 14

    private static func resolveContract(for model: MLModel) throws -> Contract {
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName

        guard let speechInput = resolveName(
            preferred: ["speech"],
            fallback: inputs,
            where: { type, name in
                guard case .multiArray = type else { return false }
                return name.localizedCaseInsensitiveContains("speech")
            }
        ),
        let lengthsInput = resolveName(
            preferred: ["speech_lengths", "speech_length", "lengths"],
            fallback: inputs,
            where: { type, name in
                guard case .multiArray = type else { return false }
                return name.localizedCaseInsensitiveContains("length")
            }
        ),
        let languageInput = resolveName(
            preferred: ["language", "lang"],
            fallback: inputs,
            where: { type, name in
                guard case .multiArray = type else { return false }
                return name.localizedCaseInsensitiveContains("lang")
            }
        ),
        let textnormInput = resolveName(
            preferred: ["textnorm", "text_norm", "itn"],
            fallback: inputs,
            where: { type, name in
                guard case .multiArray = type else { return false }
                return name.localizedCaseInsensitiveContains("norm") || name.localizedCaseInsensitiveContains("itn")
            }
        ),
        let logitsOutput = resolveName(
            preferred: ["ctc_logits", "logits"],
            fallback: outputs,
            where: { type, name in
                guard case .multiArray = type else { return false }
                return name.localizedCaseInsensitiveContains("logit")
            }
        ) else {
            throw SenseVoiceASRServiceError.coreMLContractInvalid
        }

        let lengthsOutput = resolveName(
            preferred: ["encoder_out_lens", "encoder_out_len", "output_lengths", "lengths"],
            fallback: outputs,
            where: { type, name in
                guard case .multiArray = type else { return false }
                return name.localizedCaseInsensitiveContains("len")
            }
        )

        return Contract(
            speechInput: speechInput,
            speechLengthsInput: lengthsInput,
            languageInput: languageInput,
            textnormInput: textnormInput,
            logitsOutput: logitsOutput,
            lengthsOutput: lengthsOutput
        )
    }

    private static func resolveName(
        preferred: [String],
        fallback: [String: MLFeatureDescription],
        where predicate: (MLFeatureType, String) -> Bool
    ) -> String? {
        for candidate in preferred where fallback[candidate] != nil {
            return candidate
        }

        for (name, description) in fallback where predicate(description.type, name) {
            return name
        }

        return nil
    }
}

private struct SenseVoiceCMVN {
    let means: [Float]
    let vars: [Float]

    static func load(from url: URL) throws -> SenseVoiceCMVN {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let bracketMatches = contents.matches(of: #/\[(.*?)\]/#)
        guard bracketMatches.count >= 2 else {
            throw SenseVoiceASRServiceError.coreMLAssetsMissing
        }

        let means = parseArray(String(bracketMatches[0].output.1))
        let vars = parseArray(String(bracketMatches[1].output.1))
        guard means.count == SenseVoiceCoreMLFeatureExtractor.featureDimension,
              vars.count == SenseVoiceCoreMLFeatureExtractor.featureDimension else {
            throw SenseVoiceASRServiceError.coreMLAssetsMissing
        }

        return SenseVoiceCMVN(means: means, vars: vars)
    }

    private static func parseArray(_ string: String) -> [Float] {
        string
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Float($0) }
    }
}

private struct SenseVoiceCoreMLFeatureExtractor: Sendable {
    static let sampleRate = 16_000
    static let frameSize = 400
    static let frameStep = 160
    static let featureDimension = 560
    private static let lfrM = 7
    private static let lfrN = 6
    private static let melBins = 80
    private static let fftSize = 512
    private static let fftBins = 256
    private static let logFloor: Float = 1.19e-7

    struct Result {
        let frames: [Float]
        let frameCount: Int
    }

    private let cmvn: SenseVoiceCMVN
    private let fftSetup: FFTSetup
    private let hammingWindow: [Float]

    init(cmvn: SenseVoiceCMVN) {
        self.cmvn = cmvn
        self.hammingWindow = (0..<Self.frameSize).map { i in
            0.54 - 0.46 * cos((2 * .pi * Float(i)) / Float(Self.frameSize))
        }
        guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(Self.fftSize))), FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create SenseVoice FFT setup")
        }
        self.fftSetup = fftSetup
    }

    func extract(_ audio: [Float]) throws -> Result {
        let samples = audio.count >= Self.frameSize ? audio : audio + Array(repeating: 0, count: Self.frameSize - audio.count)
        let frameCount = max(1, 1 + ((samples.count - Self.frameSize) / Self.frameStep))
        var melFrames = [Float](repeating: 0, count: frameCount * Self.melBins)

        var splitReal = [Float](repeating: 0, count: Self.fftSize / 2)
        var splitImag = [Float](repeating: 0, count: Self.fftSize / 2)
        var padded = [Float](repeating: 0, count: Self.fftSize)
        let filterBank = SenseVoiceCoreMLFilterBank.values

        for frame in 0..<frameCount {
            let start = frame * Self.frameStep
            let available = min(Self.frameSize, samples.count - start)
            for index in 0..<Self.fftSize {
                padded[index] = 0
            }
            for i in 0..<available {
                padded[i] = samples[start + i]
            }

            let mean = padded[..<Self.frameSize].reduce(0, +) / Float(Self.frameSize)
            for i in 0..<Self.frameSize {
                padded[i] -= mean
            }

            for i in stride(from: Self.frameSize - 1, through: 1, by: -1) {
                padded[i] -= 0.97 * padded[i - 1]
            }
            padded[0] -= 0.97 * padded[0]

            padded.withUnsafeMutableBufferPointer { paddedBuffer in
                hammingWindow.withUnsafeBufferPointer { windowBuffer in
                    vDSP_vmul(
                        paddedBuffer.baseAddress!,
                        1,
                        windowBuffer.baseAddress!,
                        1,
                        paddedBuffer.baseAddress!,
                        1,
                        vDSP_Length(Self.frameSize)
                    )
                }
            }
            for i in 0..<(Self.fftSize / 2) {
                splitReal[i] = padded[2 * i]
                splitImag[i] = padded[2 * i + 1]
            }

            splitReal.withUnsafeMutableBufferPointer { realBuffer in
                splitImag.withUnsafeMutableBufferPointer { imagBuffer in
                    var complex = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &complex, 1, vDSP_Length(log2(Float(Self.fftSize))), FFTDirection(kFFTDirection_Forward))
                }
            }

            var power = [Float](repeating: 0, count: Self.fftBins)
            for bin in 0..<Self.fftBins {
                power[bin] = splitReal[bin] * splitReal[bin] + splitImag[bin] * splitImag[bin]
            }

            for mel in 0..<Self.melBins {
                var sum: Float = 0
                let filterOffset = mel * Self.fftBins
                for bin in 0..<Self.fftBins {
                    sum += power[bin] * filterBank[filterOffset + bin]
                }
                melFrames[frame * Self.melBins + mel] = log(max(sum, Self.logFloor))
            }
        }

        let stacked = applyLFRAndCMVN(to: melFrames, frameCount: frameCount)
        return Result(frames: stacked, frameCount: stacked.count / Self.featureDimension)
    }

    private func applyLFRAndCMVN(to melFrames: [Float], frameCount: Int) -> [Float] {
        let stackedFrameCount = Int(ceil(Double(frameCount) / Double(Self.lfrN)))
        let leftPad = (Self.lfrM - 1) / 2
        let extendedFrameCount = frameCount + leftPad
        var output = [Float](repeating: 0, count: stackedFrameCount * Self.featureDimension)

        func frame(_ index: Int) -> ArraySlice<Float> {
            let clamped = min(max(index, 0), frameCount - 1)
            let start = clamped * Self.melBins
            return melFrames[start..<(start + Self.melBins)]
        }

        for stackedIndex in 0..<stackedFrameCount {
            var merged = [Float]()
            merged.reserveCapacity(Self.featureDimension)

            if stackedIndex == 0 {
                for _ in 0..<leftPad {
                    merged.append(contentsOf: frame(0))
                }
                for source in 0..<(Self.lfrM - leftPad) {
                    merged.append(contentsOf: frame(source))
                }
            } else {
                let startFrame = stackedIndex * Self.lfrN - leftPad
                if Self.lfrM <= extendedFrameCount - stackedIndex * Self.lfrN {
                    for source in startFrame..<(startFrame + Self.lfrM) {
                        merged.append(contentsOf: frame(source))
                    }
                } else {
                    let available = frameCount - stackedIndex * Self.lfrN
                    for source in 0..<max(available, 0) {
                        merged.append(contentsOf: frame(startFrame + source))
                    }
                    for _ in 0..<(Self.lfrM - max(available, 0)) {
                        merged.append(contentsOf: frame(frameCount - 1))
                    }
                }
            }

            let outputOffset = stackedIndex * Self.featureDimension
            for featureIndex in 0..<Self.featureDimension {
                output[outputOffset + featureIndex] = (merged[featureIndex] + cmvn.means[featureIndex]) * cmvn.vars[featureIndex]
            }
        }

        return output
    }
}

private struct SentencePieceDecoder: Sendable {
    private let vocabulary: [Int: String]

    init(modelPath: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: modelPath))
        var pieces = [String]()
        var offset = 0

        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = Self.readTag(data: data, offset: offset)
            offset = newOffset

            if fieldNumber == 1 && wireType == 2 {
                let (length, bodyOffset) = Self.readVarint(data: data, offset: offset)
                offset = bodyOffset
                let end = offset + length
                var piece: String?
                var subOffset = offset

                while subOffset < end {
                    let (subFieldNumber, subWireType, subNewOffset) = Self.readTag(data: data, offset: subOffset)
                    subOffset = subNewOffset

                    if subFieldNumber == 1 && subWireType == 2 {
                        let (stringLength, stringOffset) = Self.readVarint(data: data, offset: subOffset)
                        subOffset = stringOffset
                        if let string = String(data: data[subOffset..<(subOffset + stringLength)], encoding: .utf8) {
                            piece = string
                        }
                        subOffset += stringLength
                    } else {
                        subOffset = Self.skipField(data: data, offset: subOffset, wireType: subWireType)
                    }
                }

                pieces.append(piece ?? "")
                offset = end
            } else {
                offset = Self.skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        var vocabulary = [Int: String]()
        vocabulary.reserveCapacity(pieces.count)
        for (index, piece) in pieces.enumerated() {
            vocabulary[index] = piece
        }
        self.vocabulary = vocabulary
    }

    func decode(_ tokens: [Int32]) -> String {
        var text = ""
        for token in tokens {
            guard let piece = vocabulary[Int(token)] else { continue }
            if piece.hasPrefix("<") && piece.hasSuffix(">") {
                continue
            }
            text += piece
        }
        return text.replacingOccurrences(of: "\u{2581}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readVarint(data: Data, offset: Int) -> (Int, Int) {
        var result = 0
        var shift = 0
        var current = offset

        while current < data.count {
            let byte = Int(data[current])
            current += 1
            result |= (byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                break
            }
            shift += 7
        }

        return (result, current)
    }

    private static func readTag(data: Data, offset: Int) -> (Int, Int, Int) {
        let (tag, newOffset) = readVarint(data: data, offset: offset)
        return (tag >> 3, tag & 0x07, newOffset)
    }

    private static func skipField(data: Data, offset: Int, wireType: Int) -> Int {
        switch wireType {
        case 0:
            return readVarint(data: data, offset: offset).1
        case 1:
            return offset + 8
        case 2:
            let (length, newOffset) = readVarint(data: data, offset: offset)
            return newOffset + length
        case 5:
            return offset + 4
        default:
            return data.count
        }
    }
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
