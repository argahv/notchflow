import SwiftUI
import SwiftData
import EventKit

/// A compact launcher. Choosing a tile makes it the anchor: its background grows into the tool's
/// panel while the other tiles recede; going back folds the panel into the same tile.
struct ToolsSurface: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let selected: Tool? = { if case .tools(let tool) = model.route { return tool }; return nil }()
        ZStack(alignment: .top) {
            if let tool = selected {
                ToolPanel(model: model, tool: tool)
            } else {
                Launcher(model: model)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))))
            }
        }
        .padding(Metrics.pad)
    }
}

private struct Launcher: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let perRow = Metrics.tilesPerRow
        let rows = stride(from: 0, to: Tool.allCases.count, by: perRow).map { Array(Tool.allCases[$0..<min($0 + perRow, Tool.allCases.count)]) }
        VStack(spacing: Metrics.gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, tools in
                HStack(spacing: Metrics.gap) {
                    ForEach(Array(tools.enumerated()), id: \.element) { index, tool in
                        ToolTile(tool: tool) { model.navigate(.tools(tool)) }
                            .reveal(.primary, stagger: Double(rowIndex * perRow + index) * 0.022)
                    }
                    // Keep a short last row's tiles the same width as the others.
                    ForEach(0..<(perRow - tools.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
    }
}

private struct ToolTile: View {
    let tool: Tool
    let action: () -> Void
    @Environment(\.nookNamespace) private var namespace
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(Ink.iris)
                    .frame(height: 22)   // symbols differ in height; titles share one baseline
                    .scaleEffect(hovering ? 1.07 : 1)
                    .nookMatched("tile-icon-\(tool.rawValue)", in: namespace)
                Text(tool.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Ink.primary).lineLimit(1)
                    .fixedSize()
                    .nookMatched("tile-title-\(tool.rawValue)", in: namespace)
            }
            .frame(maxWidth: .infinity).frame(height: Metrics.tile)
            .background {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(hovering ? Ink.elevated : Ink.surface.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(hovering ? 0.1 : 0.05), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                    .nookMatched("tile-\(tool.rawValue)", in: namespace)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.micro, value: hovering)
        .accessibilityLabel(tool.title)
    }
}

private struct ToolPanel: View {
    @ObservedObject var model: AppModel
    let tool: Tool
    @Environment(\.nookNamespace) private var namespace
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Group {
                switch tool {
                case .notes: NotesBody(model: model)
                case .todos: TodosBody(model: model)
                case .calendar: CalendarBody(model: model, calendar: model.calendar)
                case .mirror: MirrorBody(model: model, camera: model.camera)
                case .apps: AppsBody(model: model)
                case .timer: TimerBody(model: model, clock: model.clock)
                case .shortcuts: ShortcutsBody()
                case .clipboard: ClipboardBody(model: model, clipboard: model.clipboard)
                case .sound: SoundBody(model: model)
                case .system: SystemBody()
                }
            }
            .reveal(.primary, stagger: 0.04)
        }
        .background {
            RoundedRectangle(cornerRadius: Radius.card + 4, style: .continuous)
                .fill(Ink.surface.opacity(0.7))
                .overlay(RoundedRectangle(cornerRadius: Radius.card + 4, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                .padding(-8)
                .nookMatched("tile-\(tool.rawValue)", in: namespace)
        }
    }

    /// The chosen tile's icon and title land here, so the panel visibly grows out of the tile.
    private var header: some View {
        HStack(spacing: 8) {
            Button { model.back() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(IconButtonStyle(size: 24, tint: Ink.secondary))
                .help("Back · Esc").accessibilityLabel("Back")
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.iris)
                .nookMatched("tile-icon-\(tool.rawValue)", in: namespace)
            // Sized by its own text so the title never truncates while it travels from the tile.
            Text(headerTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.primary).lineLimit(1)
                .fixedSize()
                .nookMatched("tile-title-\(tool.rawValue)", in: namespace)
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: Metrics.header)
    }

    private var headerTitle: String {
        if tool == .notes, let id = model.openNoteID, let note = model.note(id) { return NoteCard.title(for: note.text) }
        return tool.title
    }

    @ViewBuilder private var trailing: some View {
        switch tool {
        case .notes:
            if let id = model.openNoteID, let note = model.note(id) {
                Button { model.deleteNote(note) } label: { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle(size: 24, tint: Ink.secondary)).help("Delete note").accessibilityLabel("Delete note")
            } else {
                Button { model.newNote() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(IconButtonStyle(size: 24)).help("New note").accessibilityLabel("New note")
            }
        case .clipboard:
            if model.clipboard.enabled, !model.clipboard.items.isEmpty {
                Button("Clear") { model.clearClipboard() }.buttonStyle(PillButtonStyle()).help("Removes everything except pinned items")
            }
        case .calendar:
            if model.calendar.connected, EKEventStore.authorizationStatus(for: .reminder) != .fullAccess {
                Button("Add Reminders") { model.calendar.connectReminders() }.buttonStyle(PillButtonStyle())
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - To-dos

private struct TodosBody: View {
    @ObservedObject var model: AppModel
    @Query(sort: \Todo.createdAt) private var items: [Todo]
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            HStack(spacing: 6) {
                TextField("Add a task", text: $draft)
                    .textFieldStyle(.plain).font(TypeScale.body)
                    .padding(.horizontal, 10).frame(height: Metrics.field)
                    .nookMaterial(.interactive, radius: Radius.control, hovering: focused)
                    .focused($focused)
                    .onSubmit(add)
                Button(action: add) { Image(systemName: "plus") }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Add task")
            }
            if items.isEmpty {
                Text("Nothing on your list").font(TypeScale.secondary).foregroundStyle(Ink.secondary).frame(height: 22)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(items) { item in TodoRow(model: model, item: item).transition(.row) }
                    }
                }
                .frame(height: Double(min(items.count, Metrics.maxTodoRows)) * Metrics.todoRow + Double(max(0, min(items.count, Metrics.maxTodoRows) - 1)) * 2)
            }
            if items.contains(where: \.completed) {
                Button("Clear completed") { model.clearCompletedTodos() }
                    .font(TypeScale.meta).foregroundStyle(Ink.secondary)
                    .frame(height: 20)
            }
        }
        .onChange(of: focused) { _, value in model.send(value ? .beginEditing : .endEditing) }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.windows?.focus(); focused = true } }
    }
    private func add() { model.addTodo(draft); draft = "" }
}

private struct TodoRow: View {
    @ObservedObject var model: AppModel
    @Bindable var item: Todo
    @State private var hovering = false
    @State private var editing = false
    @FocusState private var fieldFocused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Button { model.toggle(item) } label: {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.completed ? Ink.mint : Ink.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .accessibilityLabel(item.completed ? "Mark incomplete" : "Complete task")
            if editing {
                TextField("Task", text: $item.title).textFieldStyle(.plain).font(TypeScale.body)
                    .focused($fieldFocused)
                    .onSubmit { editing = false; model.save() }
                    .onAppear { fieldFocused = true }
            } else {
                Text(item.title).font(TypeScale.body)
                    .strikethrough(item.completed, color: Ink.muted)
                    .foregroundStyle(item.completed ? Ink.secondary : Ink.primary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { editing = true }
            }
            Spacer(minLength: 4)
            Button { model.delete(item) } label: { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle(size: 22, tint: Ink.secondary))
                .opacity(hovering ? 1 : 0)
                .accessibilityLabel("Delete task")
        }
        .padding(.horizontal, 4).frame(height: Metrics.todoRow)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Ink.surface : .clear))
        .onHover { hovering = $0 }
        .animation(Motion.micro, value: hovering)
        .contextMenu {
            Button("Edit") { editing = true }
            Button("Delete", role: .destructive) { model.delete(item) }
        }
        .onChange(of: fieldFocused) { _, focused in if !focused && editing { editing = false; model.save() } }
    }
}

// MARK: - Calendar

private struct CalendarBody: View {
    @ObservedObject var model: AppModel
    @ObservedObject var calendar: CalendarService
    var body: some View {
        Group {
            if !calendar.connected {
                CompactEmptyState(symbol: "calendar", title: "Connect your calendar",
                                  detail: "Shows events and reminders for the next day.",
                                  actionTitle: "Connect") { calendar.connectCalendar() }
                    .frame(height: Metrics.emptyRow)
            } else if calendar.events.isEmpty && calendar.reminders.isEmpty {
                Text("Nothing in the next 24 hours").font(TypeScale.secondary).foregroundStyle(Ink.secondary).frame(height: 40)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !calendar.events.isEmpty {
                        SectionLabel("Upcoming")
                        ForEach(calendar.events.prefix(4)) { event in EventRow(event: event) }
                    }
                    if !calendar.reminders.isEmpty {
                        SectionLabel("Reminders").padding(.top, calendar.events.isEmpty ? 0 : Metrics.gap)
                        ForEach(calendar.reminders.prefix(5), id: \.calendarItemIdentifier) { reminder in
                            HStack(spacing: 8) {
                                Button { calendar.complete(reminder) } label: { Image(systemName: "circle").foregroundStyle(Ink.secondary) }
                                    .buttonStyle(IconButtonStyle(size: 22)).accessibilityLabel("Complete reminder")
                                Text(reminder.title ?? "Reminder").font(TypeScale.body).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(height: Metrics.reminderRow)
                        }
                    }
                }
            }
        }
        .onAppear { calendar.refresh() }
        .onChange(of: calendar.events.count) { _, _ in model.reflow() }
        .onChange(of: calendar.reminders.count) { _, _ in model.reflow() }
        .onChange(of: calendar.connected) { _, _ in model.reflow() }
    }
}

private struct EventRow: View {
    let event: CalendarItem
    var body: some View {
        HStack(spacing: 10) {
            Text(event.date, style: .time)
                .font(TypeScale.numeral).foregroundStyle(Ink.iris)
                .padding(.horizontal, 8).frame(height: 22)
                .background(Capsule().fill(Ink.iris.opacity(0.12)))
            Text(event.title).font(TypeScale.body).lineLimit(1)
            Spacer(minLength: 4)
            if let url = event.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                Link(destination: url) { Image(systemName: "arrow.up.forward") }
                    .buttonStyle(IconButtonStyle(size: 24, tint: Ink.iris)).help("Open event link")
            }
        }
        .frame(height: Metrics.eventRow)
    }
}

struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.secondary)
            .frame(height: Metrics.sectionLabel, alignment: .bottomLeading)
    }
}

// MARK: - Mirror

private struct MirrorBody: View {
    @ObservedObject var model: AppModel
    @ObservedObject var camera: CameraService
    var body: some View {
        Group {
            if camera.running {
                VStack(alignment: .leading, spacing: Metrics.gap) {
                    CameraPreview(session: camera.session)
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            Label("Camera on", systemImage: "circle.fill")
                                .font(TypeScale.badge).foregroundStyle(Ink.mint)
                                .padding(.horizontal, 8).frame(height: 22)
                                .background(Capsule().fill(Ink.void.opacity(0.7)))
                                .padding(8)
                        }
                    HStack {
                        Text("The camera stops when you leave this view.").font(TypeScale.secondary).foregroundStyle(Ink.secondary)
                        Spacer()
                        Button("Turn off") { camera.stop() }.buttonStyle(PillButtonStyle())
                    }
                    .frame(height: 26)
                }
            } else {
                CompactEmptyState(symbol: "camera", title: "Mirror", detail: camera.status, actionTitle: "Turn on") { camera.start() }
                    .frame(height: Metrics.emptyRow)
            }
        }
        .onChange(of: camera.running) { _, _ in model.reflow() }
    }
}

// MARK: - Quick apps

private struct AppsBody: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let apps = model.quickApps
        if apps.isEmpty {
            CompactEmptyState(symbol: "square.grid.3x2", title: "No apps yet", detail: "Choose apps in Settings.", actionTitle: "Settings") {
                NotificationCenter.default.post(name: .openNotchFlowSettings, object: nil)
            }
            .frame(height: Metrics.emptyRow)
        } else {
            let rows = stride(from: 0, to: apps.count, by: Metrics.appsPerRow).map { Array(apps[$0..<min($0 + Metrics.appsPerRow, apps.count)]) }
            VStack(spacing: Metrics.gap) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: Metrics.gap) {
                        ForEach(row) { app in AppTile(app: app) }
                        ForEach(0..<(Metrics.appsPerRow - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                    }
                }
            }
        }
    }
}

private struct AppTile: View {
    let app: QuickApp
    @State private var hovering = false
    var body: some View {
        Button(action: app.open) {
            VStack(spacing: 5) {
                Image(nsImage: app.icon).resizable().frame(width: 36, height: 36)
                    .scaleEffect(hovering ? 1.06 : 1)
                Text(app.name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Ink.primary).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: Metrics.appTile)
            .nookMaterial(.interactive, radius: 12, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.micro, value: hovering)
        .help("Open \(app.name)")
    }
}

// MARK: - Timer and Shortcuts

private struct TimerBody: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: Clock
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.countdown.exists {
                HStack(spacing: 10) {
                    Text(model.timerLabel(at: clock.now)).font(TypeScale.timer)
                        .contentTransition(.numericText(countsDown: true)).animation(Motion.micro, value: clock.now)
                    Spacer()
                    Button(model.countdown.running ? "Pause" : "Resume") { model.toggleTimer() }.buttonStyle(PillButtonStyle(prominent: true))
                    Button("Cancel") { model.cancelTimer() }.buttonStyle(PillButtonStyle())
                }
                .frame(height: 40)
                Text(model.countdown.running ? "Focus session in progress" : "Paused").font(TypeScale.secondary).foregroundStyle(Ink.secondary)
                    .frame(height: 20, alignment: .topLeading)
            } else {
                Text("Start a focus session").font(TypeScale.cardTitle).frame(height: 30, alignment: .bottomLeading)
                HStack(spacing: 8) {
                    ForEach([5, 15, 25, 50], id: \.self) { minutes in
                        Button("\(minutes) min") { model.startTimer(minutes: minutes) }.buttonStyle(PillButtonStyle(prominent: minutes == 25))
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 42, alignment: .top)
            }
        }
        .frame(height: 84, alignment: .top)
    }
}

private struct ShortcutsBody: View {
    @EnvironmentObject var preferences: Preferences
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            HStack(spacing: 8) {
                TextField("Shortcut name", text: $preferences.shortcutName)
                    .textFieldStyle(.plain).font(TypeScale.body)
                    .padding(.horizontal, 10).frame(height: Metrics.field)
                    .nookMaterial(.interactive, radius: Radius.control)
                Button("Run") { QuickAction.runShortcut(named: preferences.shortcutName) }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(preferences.shortcutName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Runs a shortcut from the Shortcuts app by its exact name.").font(TypeScale.secondary).foregroundStyle(Ink.secondary)
                .frame(height: 20, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .frame(height: 88, alignment: .top)
    }
}

// MARK: - Clipboard

private struct ClipboardBody: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clipboard: ClipboardService
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            if !clipboard.enabled {
                CompactEmptyState(symbol: "doc.on.clipboard", tone: .neutral, title: "Clipboard history is off",
                                  detail: "Text you copy is kept in memory only, and never from password managers.")
                    .frame(height: Metrics.emptyRow)
                Button("Turn on clipboard history") { model.preferences.clipboardEnabled = true }
                    .buttonStyle(PillButtonStyle(prominent: true)).frame(height: 26)
            } else if clipboard.items.isEmpty {
                Text("Copy some text and it appears here.").font(TypeScale.secondary).foregroundStyle(Ink.secondary).frame(height: 40)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 4) {
                        ForEach(clipboard.items) { item in ClipRow(model: model, item: item).transition(.row) }
                    }
                }
                .frame(height: min(Double(clipboard.items.count), Double(Metrics.maxClipRows)) * (Metrics.clipRow + 4) - 4)
            }
            if clipboard.enabled, clipboard.skipped > 0 || !clipboard.items.isEmpty {
                Text(clipboard.skipped > 0 ? "\(clipboard.skipped) skipped: password manager, concealed or likely secret. Detection is best effort."
                                           : "Click an item to copy it again. Kept for \(model.preferences.clipboardRetentionHours) h, in memory only.")
                    .font(TypeScale.meta).foregroundStyle(Ink.secondary).lineLimit(1).frame(height: 20)
            }
        }
        .animation(Motion.quick, value: clipboard.items.count)
    }
}

private struct ClipRow: View {
    @ObservedObject var model: AppModel
    let item: ClipItem
    @State private var hovering = false
    @State private var copied = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                    .font(item.kind == .code ? .system(size: 12, design: .monospaced) : TypeScale.body)
                    .foregroundStyle(Ink.primary).lineLimit(1)
                Text([item.source, item.date.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                    .font(TypeScale.meta).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if copied { Text("Copied").font(TypeScale.badge).foregroundStyle(Ink.mint).transition(.opacity) }
            if hovering || item.pinned {
                Button { model.clipboard.togglePin(item) } label: { Image(systemName: item.pinned ? "pin.fill" : "pin") }
                    .buttonStyle(IconButtonStyle(size: 24, tint: item.pinned ? Ink.primary : Ink.secondary))
                    .accessibilityLabel(item.pinned ? "Unpin" : "Pin")
            }
            if hovering {
                Button { model.clipboard.remove(item) } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 24, tint: Ink.secondary)).accessibilityLabel("Remove")
            }
        }
        .padding(.horizontal, 10).frame(height: Metrics.clipRow)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Ink.elevated : Ink.surface.opacity(0.6)))
        .contentShape(Rectangle())
        .onTapGesture {
            model.clipboard.copy(item)
            withAnimation(Motion.micro) { copied = true }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(Motion.micro) { copied = false }
        }
        .onHover { hovering = $0 }
        .animation(Motion.micro, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Copies this item to the clipboard")
        .accessibilityAddTraits(.isButton)
    }
    private var symbol: String {
        switch item.kind {
        case .link: "link"
        case .email: "envelope"
        case .color: "paintpalette"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .text: "text.alignleft"
        }
    }
}

// MARK: - Sound

private struct SoundBody: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 4) {
            if model.audioOutputs.isEmpty {
                Text("No sound output devices found.").font(TypeScale.secondary).foregroundStyle(Ink.secondary).frame(height: Metrics.deviceRow)
            }
            ForEach(model.audioOutputs.prefix(6)) { device in
                let selected = model.defaultAudioOutput == device.id
                Button { model.selectAudioOutput(device) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "speaker.wave.2")
                            .foregroundStyle(selected ? Ink.primary : Ink.secondary).frame(width: 18)
                        Text(device.name).font(TypeScale.body).foregroundStyle(Ink.primary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: Metrics.deviceRow)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Ink.elevated : Ink.surface.opacity(0.6)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .onAppear { model.refreshAudioOutputs() }
    }
}

// MARK: - System

/// Sampled every two seconds while visible; nothing runs when it's closed.
private struct SystemBody: View {
    @State private var metrics = SystemMetrics()
    @State private var sample: SystemSample?
    var body: some View {
        VStack(spacing: 4) {
            row("CPU", sample?.cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "Measuring…")
            row("Memory used", sample.map { "\(DownloadNames.size(Int64($0.memoryUsed))) of \(DownloadNames.size(Int64($0.memoryTotal)))" } ?? "…")
            row("Thermal state", sample.map { thermal($0.thermal) } ?? "…")
            row("Up for", sample.map { uptime($0.uptime) } ?? "…")
        }
        .task {
            while !Task.isCancelled {
                sample = metrics.sample()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(TypeScale.body).foregroundStyle(Ink.secondary)
            Spacer()
            Text(value).font(TypeScale.numeral).foregroundStyle(Ink.primary).contentTransition(.numericText())
        }
        .padding(.horizontal, 10).frame(height: Metrics.metricRow)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Ink.surface.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }
    private func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state { case .nominal: "Normal"; case .fair: "Warm"; case .serious: "Hot"; case .critical: "Critical"; @unknown default: "Unknown" }
    }
    private func uptime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        return hours >= 24 ? "\(hours / 24) d \(hours % 24) h" : "\(hours) h \(Int(seconds) % 3600 / 60) min"
    }
}
