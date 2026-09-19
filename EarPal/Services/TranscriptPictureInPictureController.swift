import AVFAudio
import AVFoundation
import AVKit
import Combine
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

/// Renders the live transcript/translation into an `AVSampleBufferDisplayLayer`
/// so it can be shown as a Picture in Picture window while the user is sharing
/// another app's screen.
@MainActor
final class TranscriptPictureInPictureController: NSObject, ObservableObject {
    @Published private(set) var isActive = false

    let displayLayer = AVSampleBufferDisplayLayer()

    private static let renderSize = CGSize(width: 640, height: 360)
    private let placeholderText = "EarPal is listening…"

    private var pipController: AVPictureInPictureController?
    private var timebase: CMTimebase?
    private var possibilityObservation: NSKeyValueObservation?
    private var shouldStartWhenPossible = false
    private var currentText = ""

    override init() {
        super.init()
        configureDisplayLayer()
    }

    var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    func start() {
        guard isSupported else { return }

        if pipController == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            pipController = controller
            observePossibility(of: controller)
        }

        shouldStartWhenPossible = true
        renderAndEnqueue(currentText.isEmpty ? placeholderText : currentText)

        if pipController?.isPictureInPicturePossible == true {
            pipController?.startPictureInPicture()
        }
    }

    func stop() {
        shouldStartWhenPossible = false
        pipController?.stopPictureInPicture()
        isActive = false
    }

    func update(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != currentText else { return }
        currentText = trimmed
        guard pipController != nil else { return }
        renderAndEnqueue(trimmed.isEmpty ? placeholderText : trimmed)
    }

    // MARK: - Display layer

    private func configureDisplayLayer() {
        displayLayer.videoGravity = .resizeAspect

        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if let timebase {
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1.0)
            displayLayer.controlTimebase = timebase
            self.timebase = timebase
        }
    }

    private func observePossibility(of controller: AVPictureInPictureController) {
        possibilityObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] controller, _ in
            Task { @MainActor in
                guard let self,
                      self.shouldStartWhenPossible,
                      controller.isPictureInPicturePossible,
                      !controller.isPictureInPictureActive else { return }
                controller.startPictureInPicture()
            }
        }
    }

    private func renderAndEnqueue(_ text: String) {
        guard let timebase else { return }
        let presentationTime = CMTimebaseGetTime(timebase)
        guard let pixelBuffer = makePixelBuffer(text: text),
              let sampleBuffer = makeSampleBuffer(from: pixelBuffer, at: presentationTime) else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    // MARK: - Rendering

    private func makePixelBuffer(text: String) -> CVPixelBuffer? {
        let size = Self.renderSize
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            paragraphStyle.lineBreakMode = .byWordWrapping

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraphStyle
            ]

            let inset: CGFloat = 28
            let textRect = CGRect(
                x: inset,
                y: inset,
                width: size.width - inset * 2,
                height: size.height - inset * 2
            )
            (text as NSString).draw(
                with: textRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
        }

        guard let cgImage = image.cgImage else { return nil }
        return makePixelBuffer(from: cgImage, size: size)
    }

    private func makePixelBuffer(from cgImage: CGImage, size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: 3600, preferredTimescale: 600),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return nil
        }

        return sampleBuffer
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension TranscriptPictureInPictureController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        isActive = false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension TranscriptPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

// MARK: - SwiftUI host

/// Hosts the Picture in Picture display layer inside the view hierarchy, which
/// `AVPictureInPictureController` requires before it can present.
struct PictureInPictureHostView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        displayLayer.frame = view.bounds
        view.layer.addSublayer(displayLayer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        displayLayer.frame = uiView.bounds
    }
}
