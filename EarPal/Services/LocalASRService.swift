import AudioCommon
import Foundation
import ParakeetASR
import Qwen3ASR
import SpeechVAD

struct LocalASRTranscriptUpdate: Sendable {
    let text: String
    let isFinal: Bool
    let statusMessage: String
}

enum LocalASRServiceError: LocalizedError {
    case unsupportedEngine

    var errorDescription: String? {
        switch self {
        case .unsupportedEngine:
            return "The selected speech engine does not support local streaming."
        }
    }
}

struct LocalASRService {
    private let senseVoiceService = SenseVoiceASRService()

    func makeStreamingSession(
        engine: ASREngine,
        progressHandler: @escaping @Sendable (Double, String) -> Void,
        transcriptHandler: @escaping @Sendable (LocalASRTranscriptUpdate) -> Void
    ) async throws -> LocalASRStreamingSession {
        switch engine {
        case .apple:
            throw LocalASRServiceError.unsupportedEngine
        case .parakeet:
            let model = try await ParakeetASRModel.fromPretrained(
                modelId: ModelManager.parakeetModelID,
                progressHandler: progressHandler
            )
            let vadModel = try await SileroVADModel.fromPretrained(
                modelId: ModelManager.sileroVADModelID,
                engine: .coreml,
                progressHandler: progressHandler
            )
            return LocalASRStreamingSession(
                engine: .parakeet(model),
                vadModel: vadModel,
                transcriptHandler: transcriptHandler
            )
        case .senseVoice:
            progressHandler(0.1, "Preparing SenseVoice...")
            let runtime = try await senseVoiceService.makeRuntime()
            let vadModel = try await SileroVADModel.fromPretrained(
                modelId: ModelManager.sileroVADModelID,
                engine: .coreml,
                progressHandler: progressHandler
            )
            return LocalASRStreamingSession(
                engine: .senseVoice(runtime),
                vadModel: vadModel,
                transcriptHandler: transcriptHandler
            )
        case .qwen3:
            let model = try await Qwen3ASRModel.fromPretrained(
                modelId: ModelManager.qwen3ASRModelID,
                progressHandler: progressHandler
            )
            let vadModel = try await SileroVADModel.fromPretrained(
                modelId: ModelManager.sileroVADModelID,
                engine: .coreml,
                progressHandler: progressHandler
            )
            return LocalASRStreamingSession(
                engine: .qwen3(model),
                vadModel: vadModel,
                transcriptHandler: transcriptHandler
            )
        }
    }
}

actor LocalASRStreamingSession {
    enum EngineRuntime {
        case parakeet(ParakeetASRModel)
        case senseVoice(any SenseVoiceRuntime)
        case qwen3(Qwen3ASRModel)

        func transcribe(audio: [Float]) throws -> String {
            switch self {
            case .parakeet(let model):
                return try model.transcribeAudio(audio, sampleRate: 16_000, language: nil)
            case .senseVoice(let runtime):
                return try runtime.transcribe(audio: audio)
            case .qwen3(let model):
                return model.transcribe(audio: audio, sampleRate: 16_000, language: nil)
            }
        }

        func unload() {
            switch self {
            case .parakeet(let model):
                model.unload()
            case .senseVoice(let runtime):
                runtime.unload()
            case .qwen3(let model):
                model.unload()
            }
        }
    }

    private let engine: EngineRuntime
    private let vadProcessor: StreamingVADProcessor
    private let transcriptHandler: @Sendable (LocalASRTranscriptUpdate) -> Void
    private let partialResultInterval: Float = 0.9
    private let maxSegmentDuration: Float = 10.0

    private var fullAudio: [Float] = []
    private var activeSpeechStartSample: Int?
    private var lastPartialTime: Float = 0
    private var isClosed = false

    fileprivate init(
        engine: EngineRuntime,
        vadModel: SileroVADModel,
        transcriptHandler: @escaping @Sendable (LocalASRTranscriptUpdate) -> Void
    ) {
        self.engine = engine
        self.vadProcessor = StreamingVADProcessor(model: vadModel, config: .sileroDefault)
        self.transcriptHandler = transcriptHandler
    }

    func append(samples: [Float]) {
        guard !isClosed, !samples.isEmpty else { return }

        fullAudio.append(contentsOf: samples)
        let events = vadProcessor.process(samples: samples)

        for event in events {
            handle(event: event)
        }

        guard let speechStartSample = activeSpeechStartSample else { return }

        let currentTime = vadProcessor.currentTime
        let speechStartTime = Float(speechStartSample) / 16_000
        let speechDuration = currentTime - speechStartTime

        if currentTime - lastPartialTime >= partialResultInterval {
            emitTranscript(
                from: speechStartSample,
                to: fullAudio.count,
                isFinal: false
            )
            lastPartialTime = currentTime
        }

        if speechDuration >= maxSegmentDuration {
            emitTranscript(
                from: speechStartSample,
                to: fullAudio.count,
                isFinal: true
            )
            activeSpeechStartSample = fullAudio.count
            lastPartialTime = currentTime
        }
    }

    func finish() {
        guard !isClosed else { return }
        isClosed = true

        let events = vadProcessor.flush()
        for event in events {
            handle(event: event)
        }

        engine.unload()
    }

    func cancel() {
        guard !isClosed else { return }
        isClosed = true
        engine.unload()
    }

    private func handle(event: VADEvent) {
        switch event {
        case .speechStarted(let time):
            activeSpeechStartSample = min(Int(time * 16_000), fullAudio.count)
            lastPartialTime = time
        case .speechEnded(let segment):
            guard let speechStartSample = activeSpeechStartSample else { return }
            let endSample = min(Int(segment.endTime * 16_000), fullAudio.count)
            emitTranscript(
                from: speechStartSample,
                to: endSample,
                isFinal: true
            )
            activeSpeechStartSample = nil
        }
    }

    private func emitTranscript(
        from startSample: Int,
        to endSample: Int,
        isFinal: Bool
    ) {
        guard startSample >= 0, startSample < endSample, endSample <= fullAudio.count else { return }

        let slice = Array(fullAudio[startSample..<endSample])
        let text: String
        do {
            text = try engine.transcribe(audio: slice)
        } catch {
            transcriptHandler(
                LocalASRTranscriptUpdate(
                    text: "",
                    isFinal: false,
                    statusMessage: error.localizedDescription
                )
            )
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isFinal {
            transcriptHandler(
                LocalASRTranscriptUpdate(
                    text: trimmed,
                    isFinal: true,
                    statusMessage: ""
                )
            )
        } else {
            transcriptHandler(
                LocalASRTranscriptUpdate(
                    text: trimmed,
                    isFinal: false,
                    statusMessage: "Listening with \(engineName) offline..."
                )
            )
        }
    }

    private var engineName: String {
        switch engine {
        case .parakeet:
            return ASREngine.parakeet.displayName
        case .senseVoice:
            return ASREngine.senseVoice.displayName
        case .qwen3:
            return ASREngine.qwen3.displayName
        }
    }
}
