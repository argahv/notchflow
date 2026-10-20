import SwiftUI
import SwiftData

@main struct NotchFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { SettingsView(model: delegate.model).environmentObject(delegate.preferences) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    lazy var model = AppModel(preferences: preferences)
    private var status: NSStatusItem?
    private var container: ModelContainer?
    private var settingsWindow: NSWindow?
    private var settingsObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            try AppFiles.prepare()
            let schema = Schema([Note.self, Todo.self, ShelfFile.self])
            let config = ModelConfiguration(schema: schema, url: AppFiles.root.appendingPathComponent("workspace.store"))
            let container = try ModelContainer(for: schema, configurations: [config])
            self.container = container
            model.shelf.context = container.mainContext
            model.context = container.mainContext
            settingsObserver = NotificationCenter.default.addObserver(forName: .openNotchFlowSettings, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settings() }
            }
            let windows = WindowManager(model: model, container: container)
            model.windows = windows; windows.start()
            createMenu()
        } catch {
            let alert = NSAlert(); alert.messageText = "NotchFlow could not open its workspace"
            alert.informativeText = error.localizedDescription + "\nYour data has not been reset."
            alert.runModal(); NSApp.terminate(nil)
        }
    }
    private func createMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status?.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchFlow")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open workspace", action: #selector(openWorkspace), keyEquivalent: "")
        menu.addItem(withTitle: "Show / hide overlay", action: #selector(toggleOverlay), keyEquivalent: "")
        menu.addItem(withTitle: "Toggle privacy", action: #selector(togglePrivacy), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit NotchFlow", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }; status?.menu = menu
    }
    @objc private func openWorkspace() { preferences.overlayEnabled = true; model.openWorkspace(); model.windows?.focus() }
    @objc private func toggleOverlay() { preferences.overlayEnabled.toggle() }
    @objc private func togglePrivacy() { preferences.privacy.toggle() }
    @objc func settings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 680),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "NotchFlow Settings"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model).environmentObject(preferences))
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { model.stop(); model.windows?.stop() }
}
