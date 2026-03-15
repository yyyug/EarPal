import AVFAudio
import Foundation

enum AudioCaptureRecorderError: LocalizedError {
    case microphonePermissionDenied
    case recordingUnavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is not available."
        case .recordingUnavailable:
            return "Audio recording is unavailable right now."
        }
    }
}

final class AudioCaptureRecorder {
    private let audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private let stateLock = NSLock()
    private var isRecording = false
    private var chunkHandler: (@Sendable ([Float], Int) -> Void)?

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

    func startRecording(onSamples: (@Sendable ([Float], Int) -> Void)? = nil) throws {
        stateLock.lock()
        if isRecording {
            stateLock.unlock()
            return
        }
        chunkHandler = onSamples
        stateLock.unlock()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            throw AudioCaptureRecorderError.recordingUnavailable
        }
        stateLock.lock()
        self.audioConverter = converter
        self.targetFormat = targetFormat
        stateLock.unlock()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processIncomingBuffer(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            stateLock.lock()
            isRecording = true
            stateLock.unlock()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioCaptureRecorderError.recordingUnavailable
        }
    }

    func stopRecording() throws {
        stateLock.lock()
        let currentlyRecording = isRecording
        isRecording = false
        chunkHandler = nil
        stateLock.unlock()

        guard currentlyRecording else {
            throw AudioCaptureRecorderError.recordingUnavailable
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        stateLock.lock()
        audioConverter = nil
        targetFormat = nil
        stateLock.unlock()
    }

    private func processIncomingBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convertToTargetBuffer(buffer) else { return }
        guard let channelData = converted.floatChannelData?.pointee else { return }
        let frameLength = Int(converted.frameLength)
        guard frameLength > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

        stateLock.lock()
        let handler = chunkHandler
        stateLock.unlock()
        handler?(samples, 16_000)
    }

    private func convertToTargetBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        stateLock.lock()
        let audioConverter = self.audioConverter
        let targetFormat = self.targetFormat
        stateLock.unlock()
        guard let audioConverter, let targetFormat else { return nil }

        let targetFrameCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate).rounded(.up)
        ) + 32

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCapacity) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard conversionError == nil else { return nil }
        guard status == .haveData || status == .inputRanDry else { return nil }
        return outputBuffer
    }
}
