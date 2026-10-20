import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject var preferences: Preferences
    @ObservedObject private var backdrop: BackdropService
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    init(model: AppModel) { self.model = model; self.backdrop = model.backdrop }
    var body: some View {
        Form {
            Section("Workspace") {
                Toggle("Show notch overlay", isOn: $preferences.overlayEnabled)
                Toggle("Simulate a notch on displays without one", isOn: $preferences.simulatedNotch)
                Picker("Display", selection: $preferences.selectedDisplay) {
                    Text("Automatic · Prefer built-in notch").tag("")
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        Text(screen.localizedName).tag(WindowManager.displayID(screen))
                    }
                }
                LabeledContent("Simulated notch width") {
                    HStack {
                        Slider(value: $preferences.notchWidth, in: 140...260).frame(maxWidth: 220)
                        Text("\(Int(preferences.notchWidth)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    }
                }
                .disabled(!preferences.simulatedNotch)
                Toggle("Hide private details", isOn: $preferences.privacy)
                Toggle(isOn: $preferences.quietMode) {
                    Text("Quiet mode")
                    Text("No automatic activity previews")
                }
                Toggle("Launch at login", isOn: $loginEnabled).onChange(of: loginEnabled) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch { loginError = error.localizedDescription }
                }
                if let loginError { Text(loginError).foregroundStyle(.orange).font(.caption) }
                Text("Control–Option–Space opens the workspace. Escape goes back, then closes. Command–1 to Command–5 switch features; Command–K searches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behavior") {
                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: $preferences.hoverDelay, in: 0...0.6, step: 0.04).frame(maxWidth: 220)
                        Text(preferences.hoverDelay == 0 ? "Instant" : "\(Int(preferences.hoverDelay * 1000)) ms")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                    }
                }
                Toggle(isOn: $preferences.showBattery) {
                    Text("Show battery beside the notch")
                    Text("With nothing to show, the resting notch hides entirely behind the camera housing.")
                }
                Picker("Keep history", selection: $preferences.historyRetentionDays) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("Until cleared").tag(0)
                }
            }
            Section("Quick apps") {
                ForEach(preferences.quickApps, id: \.self) { bundleID in
                    HStack {
                        if let app = QuickApp(bundleID: bundleID) {
                            Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
                            Text(app.name)
                        } else {
                            Image(systemName: "questionmark.app").foregroundStyle(.secondary)
                            Text(bundleID).foregroundStyle(.secondary)
                            Text("Not installed").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { preferences.quickApps.removeAll { $0 == bundleID } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove")
                    }
                }
                Button("Add App…") { addQuickApp() }
            }
            Section("Appearance") {
                Picker("Surface", selection: $preferences.visualMode) {
                    ForEach(VisualMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Text("Performance uses a solid surface. Balanced uses native material. Ultra refracts a captured top-center screen region while expanded.")
                    .font(.caption).foregroundStyle(.secondary)
                if preferences.visualMode == .ultra {
                    Button("Allow Screen Recording for Ultra…") { backdrop.requestPermission(); model.synchronizeServices() }
                    Text(backdrop.status).font(.caption).foregroundStyle(.secondary)
                }
                Text("Reduce Motion and Reduce Transparency follow macOS accessibility settings.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Integrations") {
                Toggle("Enable Music / Spotify controls", isOn: $preferences.mediaEnabled)
                Picker("Player", selection: $preferences.mediaPlayer) { Text("Music").tag("Music"); Text("Spotify").tag("Spotify") }
                    .disabled(!preferences.mediaEnabled)
                Text("Automation permission is requested only when the Music tab is used. This adapter does not use private MediaRemote APIs.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Accept local agent and build events", isOn: $preferences.bridgeEnabled)
                TextField("Shortcut name", text: $preferences.shortcutName)
                Text("Camera, Calendar and Reminders are connected explicitly from Tools. No microphone or Accessibility access is required.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                LabeledContent("Version", value: "0.1.0 · Developer preview")
                LabeledContent("Event bridge", value: model.bridge.status)
                LabeledContent("Stored activities", value: String(model.queue.records.count))
                Button("Open local data folder") { NSWorkspace.shared.open(AppFiles.root) }
                Button("Open privacy settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") { NSWorkspace.shared.open(url) }
                }
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
        }.formStyle(.grouped).frame(minWidth: 540, minHeight: 580)
            .onDisappear { model.synchronizeServices() }
    }
    private func addQuickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]; panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !preferences.quickApps.contains(id) { preferences.quickApps.append(id) }
        }
    }
}
