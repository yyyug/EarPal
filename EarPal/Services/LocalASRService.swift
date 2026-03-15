import AudioCommon
import Foundation
import ParakeetASR
import Qwen3ASR

struct LocalASRService {
    func transcribe(
        audio: CapturedAudio,
        engine: ASREngine,
        progressHandler: @escaping @Sendable (Double, String) -> Void
    ) async throws -> String {
        switch engine {
        case .apple:
            return ""
        case .parakeet:
            let model = try await ParakeetASRModel.fromPretrained(
                modelId: ModelManager.parakeetModelID,
                progressHandler: progressHandler
            )
            defer { model.unload() }
            return try model.transcribeAudio(audio.samples, sampleRate: audio.sampleRate, language: nil)
        case .qwen3:
            let model = try await Qwen3ASRModel.fromPretrained(
                modelId: ModelManager.qwen3ASRModelID,
                progressHandler: progressHandler
            )
            defer { model.unload() }
            return model.transcribe(audio: audio.samples, sampleRate: audio.sampleRate, language: nil)
        }
    }
}
