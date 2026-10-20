import SwiftUI
import SwiftData
import Combine
import Carbon

@MainActor final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .statusBar; hidesOnDeactivate = false; isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
    }
}

@MainActor final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    var model: AppModel?
    private var tracking: NSTrackingArea?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { model?.windows?.cancelDismissal(); model?.hoverBegan() }
    override func mouseExited(with event: NSEvent) { model?.hoverEnded(); model?.windows?.scheduleLeave() }
    override func scrollWheel(with event: NSEvent) {
        guard let model, model.interaction.presentation != .expanded else { super.scrollWheel(with: event); return }
        // A deliberate two-finger pull on the resting notch opens it; momentum and small deltas don't.
        if event.momentumPhase.isEmpty, abs(event.scrollingDeltaY) > 4 { model.openWorkspace(); model.windows?.focus() }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
              model?.preferences.privacy == false else { return [] }
        model?.windows?.cancelDismissal(); model?.dragEntered(); return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { model?.dropTargeted == true ? .copy : [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { model?.dragExited() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let model else { return false }
        return model.didDrop(urls)
    }
}

/// Owns the AppKit side: one long-lived panel whose frame always covers the drawn silhouette. The
/// frame is never animated; it grows before a transition and is trimmed after, so SwiftUI draws the
/// whole morph and the panel never blocks input outside the visible surface once settled.
@MainActor final class WindowManager {
    private let model: AppModel
    private let container: ModelContainer
    private let panel = NotchPanel()
    private var host: NSView?
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var monitors: [Any] = []
    private var dismissal: DispatchWorkItem?
    private var shortcut: EventHotKeyRef?
    private var shortcutHandler: EventHandlerRef?
    private var previousApp: NSRunningApplication?
    private var suspended = false
    private var transitions = 0
    private var pointerNear = false
    private var dragNear = false
    private var dragCarriesFiles: Bool?
    private var dragChangeCount = -1
    private(set) var screen: NSScreen?

    init(model: AppModel, container: ModelContainer) { self.model = model; self.container = container }

    func start() {
        let root = OverlayView(model: model).environmentObject(model.preferences).modelContainer(container)
        let host = TrackingHostingView(rootView: root)
        host.model = model; host.registerForDraggedTypes([.fileURL]); host.sizingOptions = []
        // Host inside a plain container: as the content view, NSHostingView re-requests window
        // constraint passes during frame changes until AppKit throws.
        let content = NSView(frame: .zero)
        host.frame = content.bounds; host.autoresizingMask = [.width, .height]
        content.addSubview(host); panel.contentView = content; self.host = host
        model.preferences.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.synchronize(); self?.model.synchronizeServices() }
        }.store(in: &subscriptions)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronize() }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            })
        }
        let center = DistributedNotificationCenter.default()
        // Immediate delivery: an inactive accessory app otherwise receives lock/unlock late, and the
        // camera and screen capture must stop the moment the screen locks.
        center.addObserver(self, selector: #selector(locked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(unlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, suspensionBehavior: .deliverImmediately)
        installKeyboard()
        installPointerTracking()
        installShortcut()
        #if DEBUG
        DebugChannel.install(model: model, windows: self)
        #endif
        synchronize()
    }

    static func displayID(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "unknown"
    }

    /// Re-measures the display and places the panel for the current form without animation.
    /// Runs on launch, preference changes and display changes (including mid-transition).
    func synchronize() {
        guard !suspended else { return }
        let screens = NSScreen.screens
        screen = screens.first(where: { Self.displayID($0) == model.preferences.selectedDisplay })
            ?? screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first
        guard let screen else { panel.orderOut(nil); return }
        let frame = screen.frame
        let realNotch = screen.safeAreaInsets.top > 0
        let notchWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, realNotch {
            notchWidth = max(100, right.minX - left.maxX)
        } else { notchWidth = model.preferences.notchWidth }
        let measured = DisplayGeometry(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                                       notchWidth: notchWidth, notchHeight: max(30, screen.safeAreaInsets.top))
        if model.geometry != measured { model.geometry = measured }
        guard model.preferences.overlayEnabled, realNotch || model.preferences.simulatedNotch else {
            panel.orderOut(nil); model.backdrop.stop(); return
        }
        transitions += 1
        model.reflow()
        panel.setFrame(self.frame(for: model.form.size), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
        updateFocus()
    }

    private func frame(for size: CGSize) -> NSRect {
        let origin = model.geometry.origin(panelWidth: size.width, panelHeight: size.height)
        return NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    /// Before a transition, grow the panel to hold both the current and the next silhouette. The
    /// drawing stays centred on the notch, so the resize itself is invisible.
    func prepare(for size: CGSize) {
        guard panel.isVisible, !suspended else { return }
        let current = panel.frame
        guard size.width > current.width || size.height > current.height else { return }
        panel.setFrame(frame(for: CGSize(width: max(current.width, size.width), height: max(current.height, size.height))), display: false)
        host?.layoutSubtreeIfNeeded()
    }
    func beginTransition() -> Int { transitions += 1; return transitions }
    /// After the latest transition settles, trim the panel back to the silhouette.
    func settle(_ transition: Int) {
        guard transition == transitions, panel.isVisible, !suspended else { return }
        let target = frame(for: model.form.size)
        if panel.frame != target { panel.setFrame(target, display: true) }
    }

    func updateFocus() {
        let expanded = model.interaction.presentation == .expanded
        if expanded && previousApp == nil { previousApp = NSWorkspace.shared.frontmostApplication }
        if !expanded { panel.resignKey() }
    }
    /// Only explicit actions call this; passive notifications never take focus.
    func focus() { panel.makeKey(); panel.makeFirstResponder(host) }
    func close() {
        model.send(.dismiss); panel.resignKey()
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(options: [])
        }
        previousApp = nil
    }

    /// The pointer counts as inside a little beyond the edge, so a natural move toward a control
    /// near the rim doesn't collapse the surface.
    var pointerInside: Bool {
        panel.isVisible && panel.frame.insetBy(dx: -10, dy: -10).contains(NSEvent.mouseLocation)
    }
    func scheduleLeave() {
        cancelDismissal()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerInside else { return }
            self.model.pointerLeft()
        }
        dismissal = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
    func cancelDismissal() { dismissal?.cancel(); dismissal = nil }
    func startBackdrop() {
        guard let screen else { return }
        model.backdrop.startIfAuthorized(screen: screen)
    }

    // MARK: Input

    private var notchRect: NSRect {
        let g = model.geometry
        return NSRect(x: g.x + (g.width - g.notchWidth) / 2, y: g.y + g.height - g.notchHeight,
                      width: g.notchWidth, height: g.notchHeight)
    }

    /// Passive monitors (no Accessibility permission, nothing intercepted): the pointer nearing the
    /// notch lights it, and a file drag heading for it opens a drop target.
    private func installPointerTracking() {
        if let moved = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(moved) }
        if let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerDragged() }
        }) { monitors.append(dragged) }
        if let released = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dragFinished() }
        }) { monitors.append(released) }
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.interaction.presentation == .expanded, !self.pointerInside, !self.model.interaction.pinned else { return }
                self.close()
            }
        }) { monitors.append(outside) }
    }

    private func pointerMoved() {
        guard !suspended, panel.isVisible, model.interaction.presentation == .collapsed else {
            if pointerNear { pointerNear = false }
            return
        }
        let near = notchRect.insetBy(dx: -56, dy: -40).contains(NSEvent.mouseLocation)
        guard near != pointerNear else { return }
        pointerNear = near
        model.send(near ? .approach : .retreat)
    }

    private func pointerDragged() {
        let pasteboard = NSPasteboard(name: .drag)
        if pasteboard.changeCount != dragChangeCount {
            // Only the type list is read, never the dragged contents.
            dragChangeCount = pasteboard.changeCount
            dragCarriesFiles = pasteboard.types?.contains(.fileURL) == true
        }
        guard dragCarriesFiles == true, !model.preferences.privacy,
              model.interaction.presentation == .collapsed || dragNear else { return }
        let near = notchRect.insetBy(dx: -150, dy: -120).contains(NSEvent.mouseLocation)
        guard near != dragNear else { return }
        dragNear = near
        model.send(near ? .dragApproach : .retreat)
    }

    private func dragFinished() {
        dragCarriesFiles = nil
        guard dragNear else { return }
        dragNear = false
        model.send(.retreat)
    }

    private func installKeyboard() {
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            // Never steal keys from an input method mid-composition.
            let composing = (self.panel.firstResponder as? NSTextView)?.hasMarkedText() == true
            if event.keyCode == 53 {
                if composing { return event }
                self.model.back(); return nil
            }
            if self.model.route == .command, !composing, [125, 126].contains(event.keyCode) {
                self.model.moveCommandSelection(event.keyCode == 125 ? 1 : -1); return nil
            }
            guard event.modifierFlags.contains(.command), !composing else { return event }
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if key == "k" { self.model.navigate(.command); return nil }
            if let number = Int(key), (1...Feature.allCases.count).contains(number) {
                self.model.open(Feature.allCases[number - 1]); return nil
            }
            return event
        }) { monitors.append(local) }
    }

    private func installShortcut() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<WindowManager>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if manager.model.interaction.presentation == .expanded { manager.close() }
                    else { manager.model.preferences.overlayEnabled = true; manager.model.openWorkspace(); manager.focus() }
                }
            }
            return noErr
        }, 1, &type, pointer, &shortcutHandler)
        let identifier = EventHotKeyID(signature: 0x4E464C57, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), identifier,
                                         GetApplicationEventTarget(), 0, &shortcut)
        if result != noErr { model.message = "Control–Option–Space is unavailable. Use the menu bar to open NotchFlow." }
    }

    // MARK: Lifecycle

    @objc private func locked() { suspend() }
    @objc private func unlocked() { resume() }
    private func suspend() {
        suspended = true; model.servicesSuspended = true
        panel.orderOut(nil); model.media.stop(); model.camera.stop(); model.backdrop.stop()
    }
    private func resume() {
        suspended = false; model.servicesSuspended = false
        model.send(.dismiss); synchronize()
    }
    func stop() {
        cancelDismissal(); panel.orderOut(nil)
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        DistributedNotificationCenter.default().removeObserver(self)
        if let shortcut { UnregisterEventHotKey(shortcut) }
        if let shortcutHandler { RemoveEventHandler(shortcutHandler) }
    }
}
