import AVFAudio
import Foundation

@MainActor
final class AppleSpeechPlaybackService {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(text: String, languageID: String, speechRate: Double, voiceLabel: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stopSpeaking()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = normalizedRate(from: speechRate)
        utterance.voice = resolveVoice(languageID: languageID, voiceLabel: voiceLabel)
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func normalizedRate(from sliderValue: Double) -> Float {
        let clamped = min(max(sliderValue, 0.2), 0.8)
        let normalized = Float((clamped - 0.2) / 0.6)
        let minRate = AVSpeechUtteranceMinimumSpeechRate
        let maxRate = AVSpeechUtteranceMaximumSpeechRate
        return minRate + ((maxRate - minRate) * normalized)
    }

    private func resolveVoice(languageID: String, voiceLabel: String) -> AVSpeechSynthesisVoice? {
        let candidates = candidateVoices(for: languageID)

        switch voiceLabel {
        case "Warm":
            return warmVoice(from: candidates) ?? defaultVoice(for: languageID, candidates: candidates)
        case "Clear":
            return clearVoice(from: candidates) ?? defaultVoice(for: languageID, candidates: candidates)
        default:
            return defaultVoice(for: languageID, candidates: candidates)
        }
    }

    private func candidateVoices(for languageID: String) -> [AVSpeechSynthesisVoice] {
        let normalized = languageID.lowercased()
        let prefix = normalized.split(separator: "-").first.map(String.init) ?? normalized

        let exact = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.lowercased() == normalized }
        if !exact.isEmpty {
            return exact
        }

        let prefixMatches = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(prefix)
        }
        return prefixMatches
    }

    private func defaultVoice(for languageID: String, candidates: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: languageID)
            ?? candidates.first(where: { $0.quality == .enhanced })
            ?? candidates.first
    }

    private func warmVoice(from candidates: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        candidates
            .sorted { scoreForWarmVoice($0) > scoreForWarmVoice($1) }
            .first
    }

    private func clearVoice(from candidates: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        candidates
            .sorted { scoreForClearVoice($0) > scoreForClearVoice($1) }
            .first
    }

    private func scoreForWarmVoice(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = 0
        let identifier = voice.identifier.lowercased()

        if voice.quality == .enhanced {
            score += 50
        }
        if identifier.contains("premium") || identifier.contains("siri") || identifier.contains("eloquence") {
            score += 20
        }
        if identifier.contains("compact") {
            score -= 10
        }

        return score
    }

    private func scoreForClearVoice(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = 0
        let identifier = voice.identifier.lowercased()

        if voice.quality == .default {
            score += 30
        }
        if identifier.contains("compact") {
            score += 20
        }
        if identifier.contains("premium") || identifier.contains("siri") || identifier.contains("eloquence") {
            score -= 10
        }

        return score
    }
}
