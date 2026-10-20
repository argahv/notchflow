import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject var preferences: Preferences
    @ObservedObject private var backdrop: BackdropService
    @ObservedObject private var providers: ProviderHub
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var newRepository = ""
    @State private var tokenDraft = ""
    @State private var tokenSaved = GitHubToken.exists
    @State private var githubError: String?
    init(model: AppModel) { self.model = model; self.backdrop = model.backdrop; self.providers = model.providers }
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
            Section("Agents") {
                Toggle(isOn: $preferences.agentApprovals) {
                    Text("Answer permission requests from the notch")
                    Text("Hooks wait up to \(preferences.approvalWait) seconds for Allow or Deny. With no answer, the agent's own prompt in the terminal decides. Off: hooks only report status.")
                }
                .disabled(!preferences.bridgeEnabled)
                Stepper(value: $preferences.approvalWait, in: AgentApprovals.waitRange, step: 5) {
                    LabeledContent("Wait before handing back to the terminal", value: "\(preferences.approvalWait) s")
                }
                .disabled(!preferences.agentApprovals || !preferences.bridgeEnabled)
                hookRow("Claude Code", detail: "Merge into ~/.claude/settings.json", text: HookSetup.claude(wait: preferences.approvalWait))
                hookRow("Codex hooks", detail: "Merge into ~/.codex/hooks.json, then trust them with /hooks in Codex",
                        text: HookSetup.codex(wait: preferences.approvalWait))
                hookRow("Codex notify", detail: "Completion only, for config.toml. Use it or the hooks, not both", text: HookSetup.codexNotify)
                Text("NotchFlow doesn't edit agent settings or type into terminals. Prompts, replies and tool input stay out of History; a pending request's command is shown only while it waits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("GitHub Actions") {
                Toggle(isOn: $preferences.githubEnabled) {
                    Text("Follow workflow runs")
                    Text("Polled over GitHub's REST API, read-only. With a token, running builds update every 15 seconds; without one, public repositories only, about once a minute.")
                }
                ForEach(preferences.githubRepositories, id: \.self) { repository in
                    LabeledContent(repository) {
                        Button("Remove") { preferences.githubRepositories.removeAll { $0 == repository } }
                    }
                }
                HStack {
                    TextField("owner/name or a github.com link", text: $newRepository).onSubmit(addRepository)
                    Button("Add", action: addRepository).disabled(GitHubSettings.repository(from: newRepository) == nil)
                }
                if tokenSaved {
                    LabeledContent("Token") {
                        HStack {
                            Text("Saved in Keychain").foregroundStyle(.secondary)
                            Button("Remove") { GitHubToken.delete(); tokenSaved = false; model.github.restart() }
                        }
                    }
                } else {
                    HStack {
                        SecureField("Token (optional)", text: $tokenDraft)
                        Button("Save to Keychain") {
                            do { try GitHubToken.save(tokenDraft); tokenDraft = ""; tokenSaved = true; githubError = nil; model.github.restart() }
                            catch { githubError = error.localizedDescription }
                        }
                        .disabled(tokenDraft.isEmpty)
                    }
                    Text("Use a fine-grained token limited to the repositories above, with read-only Actions access. It's kept in your login Keychain on this Mac and only sent to api.github.com.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let githubError { Text(githubError).font(.caption).foregroundStyle(.orange) }
                if preferences.githubEnabled, let status = providers.statuses["github"] {
                    LabeledContent("Status", value: status.label).foregroundStyle(status.isFailure ? .orange : .secondary)
                }
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
    @ViewBuilder private func hookRow(_ title: String, detail: String, text: String?) -> some View {
        LabeledContent {
            if let text {
                Button("Copy") { HookSetup.copy(text) }.help(text)
            } else {
                Text("Unavailable in this build").foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
    private func addRepository() {
        guard let repository = GitHubSettings.repository(from: newRepository) else { return }
        if !preferences.githubRepositories.contains(where: { $0.caseInsensitiveCompare(repository) == .orderedSame }) {
            preferences.githubRepositories.append(repository)
        }
        newRepository = ""
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

enum GitHubSettings {
    /// `owner/name` from what someone types or pastes: the pair itself, or a github.com URL.
    static func repository(from text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        let parts = value.split(separator: "/").prefix(2).map(String.init)
        guard parts.count == 2 else { return nil }
        let candidate = parts.joined(separator: "/")
        return GitHubRuns.isRepository(candidate) ? candidate : nil
    }
}
