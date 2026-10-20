import AppKit
import ScreenCaptureKit
import CoreImage
import AVFoundation
import Combine

@MainActor final class BackdropService: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published var frame: CGImage?
    @Published var status = "Screen capture is off. Balanced mode needs no screen permission."
    private var stream: SCStream?
    private var starting = false
    private var generation = 0
    private let images = CIContext(options: [.cacheIntermediates: false])
    /// The captured top-centre region in points; the shader maps surface pixels into it.
    private(set) var captureSize = CGSize(width: 600, height: 600)
    func requestPermission() {
        let granted = CGRequestScreenCaptureAccess()
        status = granted ? "Permission granted. Expand the workspace in Ultra mode." : "Permission unavailable. Allow Screen Recording in System Settings; a relaunch may be needed."
    }
    func startIfAuthorized(screen: NSScreen) {
        guard stream == nil, !starting else { return }
        guard CGPreflightScreenCaptureAccess() else { status = "Enable Screen Recording explicitly to use Ultra. Balanced remains available."; return }
        starting = true; generation += 1; let request = generation
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard generation == request else { return }
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                guard let display = content.displays.first(where: { $0.displayID == id }) else { throw EventError.invalid("Selected display is unavailable") }
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                let config = SCStreamConfiguration()
                let width = min(600.0, screen.frame.width), height = min(600.0, screen.frame.height)
                captureSize = CGSize(width: width, height: height)
                config.sourceRect = CGRect(x: (screen.frame.width - width) / 2, y: 0, width: width, height: height)
                config.width = Int(width * screen.backingScaleFactor); config.height = Int(height * screen.backingScaleFactor)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
                config.queueDepth = 3; config.showsCursor = false; config.capturesAudio = false
                let candidate = SCStream(filter: filter, configuration: config, delegate: self)
                try candidate.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                stream = candidate
                try await candidate.startCapture()
                guard generation == request else { try? await candidate.stopCapture(); return }
                starting = false; status = "Ultra active · top-center region · 10 fps · no recording saved"
            } catch {
                guard generation == request else { return }
                starting = false; stream = nil; status = "Ultra unavailable: \(error.localizedDescription)"
            }
        }
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let buffer = sampleBuffer.imageBuffer else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            let image = CIImage(cvPixelBuffer: buffer)
            self.frame = self.images.createCGImage(image, from: image.extent)
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil; self.frame = nil; self.status = "Capture stopped: \(error.localizedDescription)"
        }
    }
    func stop() {
        generation += 1; starting = false
        let old = stream; stream = nil; frame = nil
        if let old { Task { try? await old.stopCapture() } }
    }
}
