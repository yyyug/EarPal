import AVFAudio
import Foundation

struct CapturedAudio {
    let samples: [Float]
    let sampleRate: Int
}

enum AudioCaptureRecorderError: LocalizedError {
    case microphonePermissionDenied
    case recordingUnavailable
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is not available."
        case .recordingUnavailable:
            return "Audio recording is unavailable right now."
        case .emptyRecording:
            return "No audio was captured."
        }
    }
}

@MainActor
final class AudioCaptureRecorder {
    private let audioEngine = AVAudioEngine()
    private var capturedSamples: [Float] = []
    private var currentSampleRate = 16_000
    private var isRecording = false

    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func startRecording() throws {
        guard !isRecording else { return }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        currentSampleRate = Int(inputFormat.sampleRate)
        capturedSamples.removeAll(keepingCapacity: true)

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData?.pointee else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }
            self.capturedSamples.append(contentsOf: UnsafeBufferPointer(start: channelData, count: frameLength))
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioCaptureRecorderError.recordingUnavailable
        }
    }

    func stopRecording() throws -> CapturedAudio {
        guard isRecording else {
            throw AudioCaptureRecorderError.recordingUnavailable
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false

        let output = CapturedAudio(samples: capturedSamples, sampleRate: currentSampleRate)
        capturedSamples.removeAll(keepingCapacity: false)

        guard !output.samples.isEmpty else {
            throw AudioCaptureRecorderError.emptyRecording
        }

        return output
    }
}
