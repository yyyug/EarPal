import AVFAudio
import Foundation

final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()

    private let audioSession = AVAudioSession.sharedInstance()
    private let stateLock = NSLock()
    private var captureSessionCount = 0
    private var speechPlaybackCount = 0
    private var screenCaptureCount = 0

    private init() {}

    func activateCaptureSession(
        mode: AVAudioSession.Mode = .measurement,
        options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
    ) throws {
        stateLock.lock()
        captureSessionCount += 1
        stateLock.unlock()

        do {
            try audioSession.setCategory(.playAndRecord, mode: mode, options: options)
            try audioSession.setActive(true)
        } catch {
            stateLock.lock()
            captureSessionCount = max(0, captureSessionCount - 1)
            stateLock.unlock()
            throw error
        }
    }

    func deactivateCaptureSession() {
        let shouldDeactivate: Bool
        let shouldRestorePlayback: Bool

        stateLock.lock()
        captureSessionCount = max(0, captureSessionCount - 1)
        shouldDeactivate = captureSessionCount == 0 && speechPlaybackCount == 0 && screenCaptureCount == 0
        shouldRestorePlayback = captureSessionCount == 0 && (speechPlaybackCount > 0 || screenCaptureCount > 0)
        stateLock.unlock()

        if shouldRestorePlayback {
            configurePlaybackSession()
            return
        }

        if shouldDeactivate {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Keeps the process alive while a screen-capture stream runs. ScreenCaptureKit
    /// stops delivering samples once the app is suspended in the background, and
    /// Picture in Picture also needs an active playback session.
    func activateScreenCaptureSession() throws {
        stateLock.lock()
        screenCaptureCount += 1
        let captureIsActive = captureSessionCount > 0
        stateLock.unlock()

        do {
            if captureIsActive {
                try audioSession.setActive(true)
            } else {
                try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
                try audioSession.setActive(true)
            }
        } catch {
            stateLock.lock()
            screenCaptureCount = max(0, screenCaptureCount - 1)
            stateLock.unlock()
            throw error
        }
    }

    func deactivateScreenCaptureSession() {
        let shouldDeactivate: Bool
        let shouldRestoreCapture: Bool

        stateLock.lock()
        screenCaptureCount = max(0, screenCaptureCount - 1)
        shouldRestoreCapture = screenCaptureCount == 0 && captureSessionCount > 0
        shouldDeactivate = screenCaptureCount == 0 && captureSessionCount == 0 && speechPlaybackCount == 0
        stateLock.unlock()

        if shouldRestoreCapture {
            try? audioSession.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try? audioSession.setActive(true)
            return
        }

        if shouldDeactivate {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func beginSpeechPlayback() {
        let captureIsActive: Bool

        stateLock.lock()
        speechPlaybackCount += 1
        captureIsActive = captureSessionCount > 0 || screenCaptureCount > 0
        stateLock.unlock()

        if captureIsActive {
            try? audioSession.setActive(true)
            return
        }

        configurePlaybackSession()
    }

    func endSpeechPlayback() {
        let captureIsActive: Bool
        let shouldDeactivate: Bool

        stateLock.lock()
        speechPlaybackCount = max(0, speechPlaybackCount - 1)
        captureIsActive = captureSessionCount > 0 || screenCaptureCount > 0
        shouldDeactivate = captureSessionCount == 0 && speechPlaybackCount == 0 && screenCaptureCount == 0
        stateLock.unlock()

        if captureIsActive {
            return
        }

        if shouldDeactivate {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }

        configurePlaybackSession()
    }

    private func configurePlaybackSession() {
        try? audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audioSession.setActive(true)
    }
}
