import AppKit
import IOKit.ps
import AVFoundation
import SwiftUI

@MainActor final class BatteryService: ObservableObject {
    @Published var percent: Int?
    @Published var charging = false
    private var source: CFRunLoopSource?
    init() {
        refresh()
        // IOKit calls back when any power source changes; nothing wakes while the battery is steady.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = source
        }
    }
    private func refresh() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in sources {
            guard let values = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = values[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            percent = current * 100 / maximum; charging = values[kIOPSIsChargingKey] as? Bool ?? false; return
        }
        percent = nil
    }
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }
}

@MainActor final class CameraService: ObservableObject {
    let session = AVCaptureSession()
    @Published var running = false
    @Published var status = "Camera stays off until you enable Mirror."
    private let work = DispatchQueue(label: "io.notchflow.camera")
    private var generation = 0
    func start() {
        generation += 1; let request = generation
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                guard allowed else { self.status = "Camera access denied. Change it in System Settings."; return }
                let session = self.session
                self.work.async {
                    do {
                        if session.inputs.isEmpty {
                            guard let device = AVCaptureDevice.default(for: .video) else { throw EventError.invalid("No camera available") }
                            let input = try AVCaptureDeviceInput(device: device)
                            session.beginConfiguration(); session.sessionPreset = .medium
                            if session.canAddInput(input) { session.addInput(input) }
                            session.commitConfiguration()
                        }
                        session.startRunning()
                        DispatchQueue.main.async {
                            guard self.generation == request else { return }
                            self.running = session.isRunning; self.status = "Mirror is on"
                        }
                    } catch { DispatchQueue.main.async { self.status = error.localizedDescription } }
                }
            }
        }
    }
    func stop() {
        generation += 1
        let session = self.session
        work.async { if session.isRunning { session.stopRunning() } }
        running = false
    }
}
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspectFill
        view.layer = layer; return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

enum QuickAction {
    static func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    static func runShortcut(named name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var components = URLComponents(); components.scheme = "shortcuts"; components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
