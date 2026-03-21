import AVFAudio
import Foundation

@MainActor
final class AppleSpeechPlaybackService: NSObject, AVSpeechSynthesizerDelegate {
    struct VoiceOption: Identifiable, Hashable {
        let identifier: String
        let displayName: String
        let languageID: String
        let qualityDescription: String

        var id: String { identifier }

        var accessibilityLabel: String {
            displayName
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let audioSessionCoordinator: AudioSessionCoordinator

    init(audioSessionCoordinator: AudioSessionCoordinator = .shared) {
        self.audioSessionCoordinator = audioSessionCoordinator
        super.init()
        synthesizer.delegate = self
    }

    func availableVoices(for languageID: String) -> [VoiceOption] {
        candidateVoices(for: languageID).map { voice in
            VoiceOption(
                identifier: voice.identifier,
                displayName: voiceDisplayName(for: voice),
                languageID: voice.language,
                qualityDescription: qualityDescription(for: voice)
            )
        }
    }

    func defaultVoiceIdentifier(for languageID: String) -> String? {
        defaultVoice(for: languageID, candidates: candidateVoices(for: languageID))?.identifier
    }

    func speak(text: String, languageID: String, speechRate: Double, voiceIdentifier: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stopSpeaking()
        prepareAudioSessionForSpeech()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = normalizedRate(from: speechRate)
        utterance.voice = resolveVoice(languageID: languageID, voiceIdentifier: voiceIdentifier)
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        deactivateAudioSession()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        deactivateAudioSession()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        deactivateAudioSession()
    }

    private func normalizedRate(from sliderValue: Double) -> Float {
        let clamped = min(max(sliderValue, 0.2), 0.8)
        let normalized = Float((clamped - 0.2) / 0.6)

        // Bias the upper end so the slider's last third produces a more noticeable jump in speed.
        let curved = pow(normalized, 0.65)

        let minRate = AVSpeechUtteranceDefaultSpeechRate * 0.65
        let maxRate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * 1.9)
        return minRate + ((maxRate - minRate) * curved)
    }

    private func resolveVoice(languageID: String, voiceIdentifier: String?) -> AVSpeechSynthesisVoice? {
        let candidates = candidateVoices(for: languageID)

        if let voiceIdentifier,
           let matchingVoice = candidates.first(where: { $0.identifier == voiceIdentifier })
            ?? AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return matchingVoice
        }

        return defaultVoice(for: languageID, candidates: candidates)
    }

    private func candidateVoices(for languageID: String) -> [AVSpeechSynthesisVoice] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let normalized = languageID.lowercased()
        let preferredLanguages = preferredVoiceLanguages(for: normalized)

        let filtered = voices.filter { voice in
            preferredLanguages.contains(voice.language.lowercased())
        }
        if !filtered.isEmpty {
            return filtered.sorted { lhs, rhs in
                voiceMatchRank(for: lhs.language.lowercased(), preferredLanguages: preferredLanguages)
                    < voiceMatchRank(for: rhs.language.lowercased(), preferredLanguages: preferredLanguages)
            }
        }

        let prefix = normalized.split(separator: "-").first.map(String.init) ?? normalized
        let prefixMatches = voices.filter { $0.language.lowercased().hasPrefix(prefix) }
        return prefixMatches
    }

    private func defaultVoice(for languageID: String, candidates: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: languageID)
            ?? candidates.first(where: { $0.quality == .premium })
            ?? candidates.first(where: { $0.quality == .enhanced })
            ?? candidates.first
    }

    private func voiceDisplayName(for voice: AVSpeechSynthesisVoice) -> String {
        let baseDisplayName = voice.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackVoiceName(for: voice)
            : voice.name

        var suffixParts: [String] = []

        let localeSuffix = localeDisplaySuffix(for: voice.language)
        if !localeSuffix.isEmpty {
            suffixParts.append(localeSuffix)
        }

        let quality = qualityDescription(for: voice)
        if !quality.isEmpty {
            suffixParts.append(quality)
        }

        guard !suffixParts.isEmpty else {
            return baseDisplayName
        }

        return "\(baseDisplayName) (\(suffixParts.joined(separator: ", ")))"
    }

    private func qualityDescription(for voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium:
            return "Premium"
        case .enhanced:
            return "Enhanced"
        case .default:
            return "Standard"
        @unknown default:
            return "Standard"
        }
    }

    private func fallbackVoiceName(for voice: AVSpeechSynthesisVoice) -> String {
        let baseName = voice.identifier
            .split(separator: ".")
            .map(String.init)
            .filter { !$0.isEmpty }
            .last ?? voice.identifier

        let normalized = baseName
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        if normalized.caseInsensitiveCompare(voice.language) == .orderedSame {
            return voice.identifier
        }

        return normalized
            .split(separator: " ")
            .map { word in
                word.isEmpty ? "" : word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private func prepareAudioSessionForSpeech() {
        audioSessionCoordinator.beginSpeechPlayback()
    }

    private func deactivateAudioSession() {
        audioSessionCoordinator.endSpeechPlayback()
    }

    private func preferredVoiceLanguages(for normalizedLanguageID: String) -> [String] {
        switch normalizedLanguageID {
        case "zh-hant":
            return ["zh-hant", "zh-hk", "yue-hk", "zh-tw"]
        case "zh-hans":
            return ["zh-hans", "zh-cn", "zh-sg"]
        default:
            return [normalizedLanguageID]
        }
    }

    private func voiceMatchRank(for languageID: String, preferredLanguages: [String]) -> Int {
        preferredLanguages.firstIndex(of: languageID) ?? Int.max
    }

    private func localeDisplaySuffix(for languageID: String) -> String {
        switch languageID.lowercased() {
        case "yue-hk":
            return "Cantonese, Hong Kong"
        case "zh-hk":
            return "Hong Kong"
        case "zh-tw":
            return "Taiwan"
        case "zh-hant":
            return "Traditional Chinese"
        case "zh-cn":
            return "China"
        case "zh-sg":
            return "Singapore"
        case "zh-hans":
            return "Simplified Chinese"
        default:
            return ""
        }
    }
}
