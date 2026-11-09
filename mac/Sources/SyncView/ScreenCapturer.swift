import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captura o monitor virtual via ScreenCaptureKit na taxa máxima do monitor.
/// O SCK só entrega quadros quando algo muda na tela, então em repouso o
/// custo é praticamente zero.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "syncview.capture", qos: .userInteractive)
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onStopped: ((Error) -> Void)?

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        await stop()
        // O monitor recém-criado pode demorar a aparecer na lista do SCK.
        var scDisplay: SCDisplay?
        for _ in 0..<30 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            scDisplay = content.displays.first { $0.displayID == displayID }
            if scDisplay != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let scDisplay else { throw NSError(domain: "SyncView", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Monitor virtual não encontrado no ScreenCaptureKit"]) }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = false
        config.scalesToFit = true
        config.captureResolution = .best

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.info("Captura iniciada: display \(displayID) → \(width)×\(height) @\(fps)")
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
        Log.info("Captura parada")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Captura interrompida: \(error.localizedDescription)")
        if self.stream === stream { self.stream = nil }
        onStopped?(error)
    }
}
