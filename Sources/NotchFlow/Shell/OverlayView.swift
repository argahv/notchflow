import SwiftUI
import SwiftData

/// The root: one silhouette whose size, ears and corners come from the model's form. Everything
/// else is drawn inside it, so a state change is always the same object changing shape.
struct OverlayView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject var preferences: Preferences
    @Namespace private var space
    var body: some View {
        let form = model.form
        let shape = NotchShape(ear: form.ear, corner: form.corner, inset: form.inset)
        let presentation = model.interaction.presentation
        let contentHeight = max(0, form.size.height - model.geometry.band)
        ZStack(alignment: .top) {
            ObsidianSurface(backdrop: model.backdrop, band: model.geometry.band, form: form)
            VStack(spacing: 0) {
                NotchBand(model: model, clock: model.clock, battery: model.battery, media: model.media)
                Group {
                    switch presentation {
                    case .collapsed:
                        if model.interaction.awareness == .drag { DropApproach() }
                    case .preview:
                        GlanceView(model: model, media: model.media, clock: model.clock)
                            .frame(width: form.size.width, height: contentHeight, alignment: .top)
                    case .expanded:
                        WorkspaceView(model: model)
                            .frame(width: form.size.width, height: contentHeight, alignment: .top)
                    }
                }
                .transition(.surfaceContent)
            }
        }
        .frame(width: form.size.width, height: form.size.height, alignment: .top)
        .clipShape(shape)
        .overlay { EdgeLight(shape: shape, presentation: presentation, awareness: model.interaction.awareness,
                             moving: model.surfaceMoving, band: model.geometry.band) }
        .overlay { RimIllumination(shape: shape, illumination: model.illumination, band: model.geometry.band) }
        .contentShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.nookNamespace, space)
        .foregroundStyle(Ink.primary)
        .tint(Ink.accent)
        .preferredColorScheme(.dark)
        .buttonStyle(.plain)
        .ignoresSafeArea()
    }
}

// MARK: - Band

/// The strip beside the camera housing. Resting: one status on each side. Open: the feature dock.
struct NotchBand: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: Clock
    @ObservedObject var battery: BatteryService
    @ObservedObject var media: MediaService
    @EnvironmentObject var preferences: Preferences
    @Environment(\.nookNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let expanded = model.interaction.presentation == .expanded
        HStack(spacing: 0) {
            Group { if expanded { leadingDock } else { leadingStatus } }.frame(maxWidth: .infinity)
            Color.clear.frame(width: CGFloat(model.geometry.notchWidth))
            Group { if expanded { trailingDock } else { trailingStatus } }.frame(maxWidth: .infinity)
        }
        .frame(height: model.geometry.band)
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded { model.windows?.close() } else { model.openWorkspace(); model.windows?.focus() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: expanded ? "Close workspace" : "Open workspace") {
            if expanded { model.windows?.close() } else { model.openWorkspace(); model.windows?.focus() }
        }
    }

    // Resting and glance: a single status each side, nothing when there is nothing to say.
    @ViewBuilder private var leadingStatus: some View {
        if model.interaction.presentation == .collapsed, let status = model.leadingStatus {
            switch status {
            case .privacy:
                Image(systemName: "eye.slash").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.secondary)
                    .accessibilityLabel("Private details hidden")
            case .activities(let top, let tones, let count):
                // One dot per live task (up to three), overlapping like a stack; the lead dot travels
                // into the glance. A count appears only when there is more than one.
                HStack(spacing: 4) {
                    HStack(spacing: -2) {
                        ForEach(Array(tones.enumerated()), id: \.offset) { index, tone in
                            Circle().fill(tone.color).frame(width: 7, height: 7)
                                .padding(1.5).background(Circle().fill(Color.black))
                                .zIndex(Double(-index))
                                .nookMatched("lead-\(top.id)", in: index == 0 ? namespace : nil)
                        }
                    }
                    if count > 1 {
                        Text("\(count)").font(TypeScale.badge).monospacedDigit().foregroundStyle(Ink.secondary)
                            .contentTransition(.numericText()).animation(Motion.micro, value: count)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(count > 1 ? "\(count) activities. Most urgent: \(top.event.title), \(top.event.lifecycle.label)"
                                              : "\(top.event.title), \(top.event.lifecycle.label)")
            case .music:
                Group {
                    if let artwork = media.artwork { ArtworkView(image: artwork, size: 18) }
                    else {
                        // Static while playing: a repeating effect would redraw the panel every frame for as
                        // long as music plays. A single cue marks a track change instead.
                        Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.silver)
                            .symbolEffect(.bounce, value: reduceMotion || Motion.lowPower ? "" : media.title)
                    }
                }
                .nookMatched("music-art", in: namespace)
                .accessibilityLabel("Playing \(media.title)")
            }
        }
    }

    @ViewBuilder private var trailingStatus: some View {
        let glanceShowsTimer: Bool = {
            guard model.interaction.presentation == .preview else { return false }
            switch model.glanceLead {
            case .single(.timer, _), .split(.timer, _, _), .split(_, .timer, _): return true
            default: return false
            }
        }()
        if let status = model.trailingStatus, !glanceShowsTimer {
            switch status {
            case .timer:
                Text(model.timerLabel(at: clock.now))
                    .font(TypeScale.numeral)
                    .foregroundStyle(model.countdown.running ? Ink.primary : Ink.secondary)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Motion.micro, value: clock.now)
                    .accessibilityLabel("Focus timer \(model.timerLabel(at: clock.now))")
            case .battery(let percent):
                HStack(spacing: 2) {
                    if battery.charging { Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold)) }
                    Text("\(percent)%").font(TypeScale.numeral)
                }
                .foregroundStyle(percent <= 15 && !battery.charging ? Ink.amber : Ink.primary.opacity(0.88))
                .accessibilityLabel("Battery \(percent) percent\(battery.charging ? ", charging" : "")")
            }
        }
    }

    // Open: features sit next to the camera; utilities at the outer edges.
    private var leadingDock: some View {
        HStack(spacing: 2) {
            dockButton(symbol: "magnifyingglass", help: "Search and commands · ⌘K", selected: model.route == .command, index: 0) {
                model.navigate(.command)
            }
            Spacer(minLength: 4)
            ForEach(Array([Feature.activity, .music, .shelf].enumerated()), id: \.element) { index, feature in
                featureButton(feature, index: index + 1)
            }
        }
        .padding(.leading, model.form.ear + 6).padding(.trailing, 6)
    }

    private var trailingDock: some View {
        HStack(spacing: 2) {
            ForEach(Array([Feature.tools, .history].enumerated()), id: \.element) { index, feature in
                featureButton(feature, index: index + 4)
            }
            Spacer(minLength: 4)
            // Fewer permanent controls: keeping the surface open lives in the menu, and the menu's
            // glyph shows a pin while it's kept open.
            Menu {
                Button(model.interaction.pinned ? "Stop keeping open" : "Keep open") { model.send(.togglePin) }
                Divider()
                Toggle("Quiet mode", isOn: $preferences.quietMode)
                Toggle("Hide private details", isOn: $preferences.privacy)
                Divider()
                Button("Search and commands") { model.navigate(.command) }
                Button("Settings…") { NotificationCenter.default.post(name: .openNotchFlowSettings, object: nil) }
                Divider()
                Button("Close") { model.windows?.close() }
            } label: {
                Image(systemName: model.interaction.pinned ? "pin.fill" : "ellipsis")
                    .font(.system(size: model.interaction.pinned ? 11 : 13, weight: .semibold))
                    .foregroundStyle(model.interaction.pinned ? Ink.primary : Ink.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tint(model.interaction.pinned ? Ink.silver : Ink.secondary)   // a state, not an action: no blue
            .frame(width: 26, height: 24)
            .help("More")
            .help(model.interaction.pinned ? "Kept open · More" : "More")
            .accessibilityLabel(model.interaction.pinned ? "More, kept open" : "More")
            .reveal(.secondary, stagger: 6 * 0.022)
        }
        .padding(.leading, 6).padding(.trailing, model.form.ear + 6)
    }

    private func featureButton(_ feature: Feature, index: Int) -> some View {
        dockButton(symbol: feature.symbol, help: "\(feature.title) · ⌘\(feature.shortcut)",
                   selected: model.route.feature == feature, badge: feature == .activity ? model.dockBadge : nil, index: index) {
            model.open(feature)
        }
        // A finished task retracting into History lands here with a small acknowledgement.
        .keyframeAnimator(initialValue: 1.0, trigger: feature == .history ? model.historyPulse : nil) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(Motion.reduced ? 1 : 1.22, duration: 0.14)
            SpringKeyframe(1, duration: 0.3)
        }
        .accessibilityLabel(feature.title)
    }

    private func dockButton(symbol: String, help: String, selected: Bool, badge: Tone? = nil, slides: Bool = true, index: Int,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(DockButtonStyle(selected: selected, badge: badge, slides: slides))
            .help(help)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .reveal(.secondary, stagger: Double(index) * 0.022)
    }
}

/// While a file drag approaches, the resting notch becomes a target big enough to receive it.
struct DropApproach: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(Ink.silver)
            Text("Drop to shelf").font(TypeScale.cardTitle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .reveal(.primary)
    }
}

// MARK: - Glance

/// The hover preview: whatever matters most right now (input needed, a failure, a running agent or
/// build, a focus session, music), two of them side by side in one surface when an ambient item sits
/// beside real work, or shortcuts when nothing is live. Every part opens its own destination.
struct GlanceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var media: MediaService
    @ObservedObject var clock: Clock
    @Environment(\.nookNamespace) private var namespace

    var body: some View {
        let lead = model.glanceLead
        Group {
            switch lead {
            case .privacy:
                HStack(spacing: 12) {
                    ToneGlyph(symbol: "eye.slash", tone: .neutral, size: 30).reveal(.primary)
                    GlanceText(title: "Details hidden", detail: "Activities continue quietly")
                    Spacer(minLength: 8)
                }
            case .notification(let record):
                notification(record)
            case .quickAccess:
                QuickAccessRow(model: model)
            case .single(let item, let others):
                single(item, others: others)
            case .split(let ambient, let work, let others):
                HStack(spacing: 0) {
                    SplitRegion(model: model, media: media, clock: clock, item: ambient, others: 0)
                    Rectangle().fill(Ink.titanium.opacity(0.5)).frame(width: 0.5, height: 30)
                        .reveal(.secondary)
                    SplitRegion(model: model, media: media, clock: clock, item: work, others: others)
                }
            }
        }
        .padding(.horizontal, model.form.ear + 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(identity(lead))
        .transition(.hoverSwap)
    }

    private func single(_ item: AppModel.HoverItem, others: Int) -> some View {
        let depth = model.glanceStackDepth
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.openHoverItem(item) } label: {
                    HoverItemLabel(model: model, media: media, clock: clock, item: item, compact: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help("\(HoverText.destination(item)) · ⌃⌥Space opens the workspace")
                .accessibilityHint("Opens \(HoverText.destination(item))")
                HoverItemTrailing(model: model, media: media, item: item, compact: false)
                if others > 0 { CountChip(model: model, others: others) }
            }
            .frame(maxHeight: .infinity)
            if depth > 0 {
                // The next tasks peek out beneath the lead like stacked cards; opening the stack
                // separates each layer into its own row.
                VStack(spacing: 2) {
                    ForEach(Array(model.rankedActivities.filter { "\($0.id)" != item.id }.prefix(depth).enumerated()), id: \.element.id) { index, record in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Ink.hover.opacity(index == 0 ? 0.95 : 0.6))
                            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(record.event.lifecycle.tone.color.opacity(index == 0 ? 0.28 : 0.18)))
                            .frame(height: 3)
                            .padding(.horizontal, 14 + CGFloat(index) * 14)
                            .nookMatched("stack-\(record.id)", in: namespace)
                    }
                }
                .frame(height: Metrics.stackLayer * Double(depth) + 4, alignment: .top)
            }
        }
    }

    private func notification(_ record: ActivityRecord) -> some View {
        HStack(spacing: 12) {
            // Severity reads first: the glyph, then the message, then its source, then the actions.
            ToneGlyph(symbol: record.event.lifecycle.symbol, tone: record.event.lifecycle.tone, size: 30)
                .nookMatched("lead-\(record.id)", in: namespace).reveal(.primary)
            GlanceText(title: record.event.title, detail: ActivityText.subtitle(record), stagger: 0.03)
            Spacer(minLength: 8)
            // The notification's own next step: Review a request (answered in the detail, never from
            // here), Join a call, Show a download, Open a failed run; otherwise View.
            let primary = model.notificationAction(record)
            Button(primary.title) { primary.perform() }
                .buttonStyle(PillButtonStyle(prominent: true))
                .help(primary.title == "View" ? "Show details" : primary.title)
                .reveal(.detail)
            Button { model.dismissNotification() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 24, tint: Ink.secondary)).accessibilityLabel("Dismiss")
                .reveal(.detail, stagger: 0.03)
        }
    }

    private func identity(_ lead: AppModel.GlanceLead) -> String {
        switch lead {
        case .privacy: "privacy"
        case .notification(let record): "n-\(record.id)"
        case .quickAccess: "quick"
        case .single(let item, _): "s-\(item.id)"
        case .split(let ambient, let work, _): "split-\(ambient.id)-\(work.id)"
        }
    }
}

extension AppModel.HoverItem {
    var id: String {
        switch self {
        case .activity(let record): record.id
        case .music: "music"
        case .timer: "timer"
        }
    }
}

extension AnyTransition {
    /// Preview A → B: the outgoing item lifts away, the next settles in from just below, inside the
    /// surface's mask. The surface itself only resizes if the new layout needs it.
    static var hoverSwap: AnyTransition {
        if Motion.reduced { return .opacity.animation(.easeOut(duration: 0.14)) }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.98, anchor: .top))
                                .animation(.spring(response: 0.26, dampingFraction: 0.9).delay(0.04)),
                           removal: .opacity.combined(with: .offset(y: -5)).animation(.easeOut(duration: 0.12)))
    }
}

/// Glyph and two lines for one hover item, from real state only.
private struct HoverItemLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var media: MediaService
    @ObservedObject var clock: Clock
    let item: AppModel.HoverItem
    let compact: Bool
    @Environment(\.nookNamespace) private var namespace

    var body: some View {
        let size: CGFloat = compact ? 26 : 30
        HStack(spacing: compact ? 9 : 12) {
            switch item {
            case .activity(let record):
                ToneGlyph(symbol: SourceGlyph.symbol(for: record.event), tone: record.event.lifecycle.tone, size: size)
                    .nookMatched("lead-\(record.id)", in: namespace).reveal(.primary)
                GlanceText(title: HoverText.title(record), detail: HoverText.subtitle(record),
                           since: HoverText.showsElapsed(record) ? (record.firstSeen ?? record.event.timestamp) : nil,
                           compact: compact, stagger: 0.03)
            case .music:
                ArtworkView(image: media.artwork, size: compact ? 30 : 36)
                    .nookMatched("music-art", in: namespace).reveal(.primary)
                GlanceText(title: media.title, detail: [media.artist.isEmpty ? nil : media.artist, "Playing"].compactMap { $0 }.joined(separator: " · "),
                           compact: compact, stagger: 0.03)
            case .timer:
                ToneGlyph(symbol: "timer", tone: .silver, size: size).nookMatched("timer-glyph", in: namespace).reveal(.primary)
                GlanceText(title: model.countdown.running ? "Focus session" : "Focus session · Paused",
                           detail: "\(model.timerLabel(at: clock.now)) remaining", compact: compact, stagger: 0.03, numeric: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The status mark and the one inline control an item offers. Controls never expand the surface
/// and briefly hold the preview still so it can't change under the pointer.
private struct HoverItemTrailing: View {
    @ObservedObject var model: AppModel
    @ObservedObject var media: MediaService
    let item: AppModel.HoverItem
    let compact: Bool
    var body: some View {
        let control: CGFloat = compact ? 26 : 30
        Group {
            switch item {
            case .activity(let record):
                let event = record.event
                switch event.lifecycle {
                case .needsInput, .waiting:
                    Circle().fill(Ink.amber).frame(width: 7, height: 7).accessibilityLabel("Needs you")
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.red).accessibilityLabel("Failed")
                case .running, .starting, .queued:
                    if event.kind == .meeting, let _ = event.actionURL {
                        Button("Join") { model.lockHover(); model.openAction(record) }.buttonStyle(PillButtonStyle(prominent: true))
                    } else if let progress = event.progress {
                        Text("\(Int(progress * 100))%").font(TypeScale.numeral).foregroundStyle(Ink.primary)
                    } else {
                        ProgressView().controlSize(.mini).tint(Ink.silver).accessibilityLabel("In progress")
                    }
                default:
                    EmptyView()
                }
            case .music:
                Button { model.lockHover(); media.command(.toggle) } label: {
                    Image(systemName: media.playing ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle(size: control)).accessibilityLabel(media.playing ? "Pause" : "Play")
            case .timer:
                Button { model.lockHover(); model.toggleTimer() } label: {
                    Image(systemName: model.countdown.running ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle(size: control)).accessibilityLabel(model.countdown.running ? "Pause timer" : "Resume timer")
            }
        }
        .reveal(.detail)
    }
}

/// "+2": the other activities. Opens the full stack.
private struct CountChip: View {
    @ObservedObject var model: AppModel
    let others: Int
    var body: some View {
        Button { model.navigate(.activity(detail: nil)); model.windows?.focus() } label: {
            Text("+\(others)").font(TypeScale.badge).monospacedDigit().foregroundStyle(Ink.primary)
                .padding(.horizontal, 8).frame(height: 20)
                .background(Capsule().fill(Ink.elevated))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .help(others == 1 ? "1 other activity" : "\(others) other activities")
        .accessibilityLabel(others == 1 ? "1 other activity, show all" : "\(others) other activities, show all")
        .reveal(.detail, stagger: 0.03)
    }
}

/// One half of the split island. Hovering highlights just this region; the surface doesn't move.
private struct SplitRegion: View {
    @ObservedObject var model: AppModel
    @ObservedObject var media: MediaService
    @ObservedObject var clock: Clock
    let item: AppModel.HoverItem
    let others: Int
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 8) {
            Button { model.openHoverItem(item) } label: {
                HoverItemLabel(model: model, media: media, clock: clock, item: item, compact: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .help("\(HoverText.destination(item)) · ⌃⌥Space opens the workspace")
            .accessibilityHint("Opens \(HoverText.destination(item))")
            HoverItemTrailing(model: model, media: media, item: item, compact: true)
            if others > 0 { CountChip(model: model, others: others) }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.elevated.opacity(hovering ? 0.6 : 0)).padding(.vertical, 8))
        .onHover { hovering = $0 }
        .animation(Motion.micro, value: hovering)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

/// Nothing live: three features that work without any integration or permission.
private struct QuickAccessRow: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            shortcut(.music, "Music", "music.note", 0)
            shortcut(.shelf, "Shelf", "tray", 1)
            shortcut(.tools(nil), "Tools", "square.grid.2x2", 2)
        }
        .frame(maxHeight: .infinity)
    }
    private func shortcut(_ route: Route, _ title: String, _ symbol: String, _ index: Int) -> some View {
        QuickShortcut(title: title, symbol: symbol) { model.navigate(route); model.windows?.focus() }
            .reveal(.primary, stagger: Double(index) * 0.03)
    }
}

private struct QuickShortcut: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15, weight: .regular)).frame(height: 18)
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(hovering ? Ink.primary : Ink.silver)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.elevated.opacity(hovering ? 0.8 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(Motion.micro, value: hovering)
        .help("Open \(title) · ⌃⌥Space opens the workspace")
        .accessibilityLabel("Open \(title)")
    }
}

/// Title and detail lines. Elapsed time is appended for running agents; numbers roll in place.
private struct GlanceText: View {
    let title: String
    let detail: String
    var since: Date?
    var compact = false
    var stagger: Double = 0
    var numeric = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 2) {
            Text(title).font(compact ? .system(size: 12.5, weight: .semibold) : TypeScale.cardTitle)
                .foregroundStyle(Ink.primary).lineLimit(1).truncationMode(.tail)
                .reveal(.primary, stagger: stagger)
            HStack(spacing: 4) {
                Text(detail).contentTransition(numeric ? .numericText(countsDown: true) : .identity)
                if let since {
                    Text("·")
                    ElapsedText(date: since)
                }
            }
            .font(compact ? .system(size: 11) : TypeScale.secondary).foregroundStyle(Ink.secondary).lineLimit(1)
            .reveal(.secondary)
        }
    }
}

/// Hover wording, from what the record actually says. Nothing is summarised or guessed.
enum HoverText {
    static func title(_ record: ActivityRecord) -> String {
        let event = record.event
        switch event.lifecycle {
        case .needsInput, .waiting:
            return event.agent != nil ? "Input required" : event.title
        case .failed:
            switch event.kind {
            case .ci: return "CI failed"
            case .build: return "Build failed"
            case .deploy: return "Deploy failed"
            case .download: return "Download failed"
            default: return "\(event.title) failed"
            }
        case .running, .starting, .queued:
            switch event.kind {
            case .build: return "Build in progress"
            case .ci: return "CI running"
            case .deploy: return "Deploying"
            default: return event.title
            }
        default:
            return event.title
        }
    }

    static func subtitle(_ record: ActivityRecord) -> String {
        let event = record.event
        if let agent = event.agent, [.needsInput, .waiting].contains(event.lifecycle) {
            let ask = agent.state == .awaitingAuthorization || event.request != nil
                ? "\(event.title) needs your approval" : "\(event.title) is waiting for you"
            return [ask, event.project].compactMap { $0 }.joined(separator: " · ")
        }
        if [.build, .ci, .deploy].contains(event.kind) {
            return [event.title, event.branch ?? event.project].compactMap { $0 }.joined(separator: " · ")
        }
        return ActivityText.subtitle(record)
    }

    /// Elapsed time is useful for live agent sessions, not for things that already say when.
    static func showsElapsed(_ record: ActivityRecord) -> Bool {
        record.event.agent != nil && [.running, .starting].contains(record.event.lifecycle)
    }

    static func destination(_ item: AppModel.HoverItem) -> String {
        switch item {
        case .activity(let record): "Open \(record.event.title)"
        case .music: "Open Music"
        case .timer: "Open the timer"
        }
    }
}

/// Album art, or a quiet placeholder when the player doesn't provide it locally.
struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Ink.elevated
                    Image(systemName: "music.note").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(Ink.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Workspace

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject var preferences: Preferences
    var body: some View {
        VStack(spacing: 0) {
            if let message = model.message, !preferences.privacy {
                MessageBanner(message: message) { model.message = nil }
                    .padding(.horizontal, Metrics.pad).padding(.top, 6)
                    .frame(height: 40)
            }
            Group {
                if preferences.privacy {
                    PrivacySurface()
                } else {
                    switch model.route {
                    case .activity: ActivitySurface(model: model)
                    case .music: MusicSurface(model: model, media: model.media)
                    case .shelf: ShelfSurface(model: model, service: model.shelf)
                    case .tools: ToolsSurface(model: model)
                    case .history: HistorySurface(model: model)
                    case .command: CommandSurface(model: model)
                    }
                }
            }
            .id(preferences.privacy ? "privacy" : model.route.surface)
            .transition(.surfaceContent)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, model.form.ear)
    }
}

struct MessageBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Ink.amber)
            Text(message).font(TypeScale.secondary).foregroundStyle(Ink.primary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 20, tint: Ink.secondary)).accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(Ink.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .reveal(.primary)
    }
}

struct PrivacySurface: View {
    @EnvironmentObject var preferences: Preferences
    var body: some View {
        VStack(spacing: 8) {
            ToneGlyph(symbol: "eye.slash", tone: .neutral, size: 32).reveal(.primary)
            Text("Details hidden").font(TypeScale.cardTitle).reveal(.primary, stagger: 0.03)
            Text("Activities continue quietly. Names, files and previews stay concealed.")
                .font(TypeScale.secondary).foregroundStyle(Ink.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
                .reveal(.secondary)
            Button("Show details") { withAnimation(Motion.quick) { preferences.privacy = false } }
                .buttonStyle(PillButtonStyle()).reveal(.detail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
