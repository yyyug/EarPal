import Foundation

enum AudioCaptureSourceOption: String, CaseIterable, Identifiable {
    case microphone
    case screenAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .screenAudio:
            return "Screen Audio"
        }
    }

    var iconName: String {
        switch self {
        case .microphone:
            return "mic.fill"
        case .screenAudio:
            return "display"
        }
    }
}

protocol AudioSource: AnyObject {
    func start(onSamples: (@Sendable ([Float], Int) -> Void)?) async throws
    func stop() throws
}

final class MicrophoneAudioSource: AudioSource {
    private let recorder: AudioCaptureRecorder

    init(recorder: AudioCaptureRecorder = AudioCaptureRecorder()) {
        self.recorder = recorder
    }

    var underlyingRecorder: AudioCaptureRecorder { recorder }

    func requestPermission() async -> Bool {
        await recorder.requestPermission()
    }

    func start(onSamples: (@Sendable ([Float], Int) -> Void)?) async throws {
        try recorder.startRecording(onSamples: onSamples)
    }

    func stop() throws {
        try recorder.stopRecording()
    }
}
