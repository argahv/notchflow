import SwiftUI

/// The expanded task stack. Rows keep their place while it's open; choosing one grows it in place
/// into a detail card. Hide (stack only), Remove (History) and the task's own lifecycle are separate.
struct ActivitySurface: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let detail: String? = { if case .activity(let detail) = model.route { return detail }; return nil }()
        let sections = model.activitySections(detail: detail)
        VStack(alignment: .leading, spacing: 0) {
            // The filter stays put while the stack scrolls beneath it.
            FilterBar(model: model).reveal(.secondary)
                .padding(.top, 10).padding(.horizontal, Metrics.pad).padding(.bottom, Metrics.gap)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    rows(sections)
                }
                .scrollIndicators(.automatic)
                // Past the size cap the stack scrolls; its last row fades out instead of being cut off.
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: Metrics.pad)
                    }
                }
                .onChange(of: detail) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.quick) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder private func rows(_ sections: [AppModel.ActivitySection]) -> some View {
        let detail: String? = { if case .activity(let detail) = model.route { return detail }; return nil }()
        VStack(alignment: .leading, spacing: Metrics.gap) {
                if sections.allSatisfy(\.rows.isEmpty) {
                    emptyState.frame(height: Metrics.emptyRow).reveal(.primary)
                }
                ForEach(sections) { section in
                    if let title = section.title {
                        Text(title).font(TypeScale.meta).foregroundStyle(Ink.secondary).lineLimit(1)
                            .padding(.leading, 4).frame(height: Metrics.sectionHeader)
                            .accessibilityAddTraits(.isHeader)
                            .transition(.opacity)
                    }
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, record in
                        ActivityCapsule(model: model, record: record, expanded: detail == record.id)
                            .reveal(.primary, stagger: Double(min(index, 6)) * 0.03)
                            .transition(.row)
                    }
                }
                TimerStrip(model: model, clock: model.clock)
                    .padding(.top, 4)
                    .reveal(.secondary, stagger: 0.04)
        }
        .padding(.bottom, Metrics.pad).padding(.horizontal, Metrics.pad)
    }

    @ViewBuilder private var emptyState: some View {
        switch model.activityFilter {
        case .all:
            CompactEmptyState(symbol: "checkmark.circle", tone: .mint, title: "Nothing needs you",
                              detail: "Agent, build and download activity appears here as it happens.")
        case .agents:
            CompactEmptyState(symbol: "sparkles", tone: .iris, title: "No agents running",
                              detail: "Claude Code and Codex sessions appear here once their hooks are set up.")
        case .pipelines:
            CompactEmptyState(symbol: "hammer", tone: .blue, title: "No pipelines running",
                              detail: "Commands wrapped with notchflow run appear here while they run.")
        case .downloads:
            CompactEmptyState(symbol: "arrow.down.circle", tone: .blue, title: "No recent downloads",
                              detail: "Download tracking isn't available yet.")
        case .done:
            CompactEmptyState(symbol: "clock", tone: .neutral, title: "Nothing finished today",
                              detail: "Completed work collects here for a day, and in History for longer.")
        }
    }
}

/// Category filter; the selection pill slides between choices.
private struct FilterBar: View {
    @ObservedObject var model: AppModel
    @Namespace private var selection
    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppModel.ActivityFilter.allCases) { filter in
                let selected = model.activityFilter == filter
                Button { model.setFilter(filter) } label: {
                    Text(filter.title).font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(selected ? Ink.primary : Ink.secondary)
                        .padding(.horizontal, 10).frame(height: Metrics.filterBar - 4)
                        .background {
                            if selected {
                                Capsule().fill(Ink.elevated).matchedGeometryEffect(id: "filter", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(2)
        .frame(height: Metrics.filterBar)
        .background(Capsule().fill(Ink.obsidian.opacity(0.8)))
        .animation(Motion.selection, value: model.activityFilter)
    }
}

struct ActivityCapsule: View {
    @ObservedObject var model: AppModel
    let record: ActivityRecord
    let expanded: Bool
    @Environment(\.nookNamespace) private var namespace
    @State private var hovering = false

    var body: some View {
        let event = record.event
        VStack(alignment: .leading, spacing: 0) {
            Button { model.toggleDetail(record.id) } label: {
                HStack(spacing: 12) {
                    ToneGlyph(symbol: SourceGlyph.symbol(for: event), tone: event.lifecycle.tone, size: 30)
                        .nookMatched("lead-\(record.id)", in: namespace)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(event.title).font(TypeScale.cardTitle).foregroundStyle(Ink.primary).lineLimit(1)
                            if record.isPinned {
                                Image(systemName: "pin.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.iris)
                                    .accessibilityLabel("Pinned")
                            }
                        }
                        HStack(spacing: 4) {
                            Text(ActivityText.subtitle(record))
                            Text("·")
                            ElapsedText(date: event.timestamp)
                        }
                        .font(TypeScale.secondary).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    status(event)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.muted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 12).frame(height: Metrics.activityRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(event.title), \(ActivityText.subtitle(record))")
            .accessibilityHint(expanded ? "Collapses details" : "Shows details")

            if expanded {
                detail(event).transition(.opacity)
            }
        }
        .background {
            // The capsule's own surface is the shared element the glance's stack layers grow into.
            let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            shape.fill(expanded || hovering ? Ink.elevated : Ink.surface.opacity(0.92))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(hovering || expanded ? 0.1 : 0.055), .white.opacity(0.012)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                .shadow(color: .black.opacity(expanded ? 0.4 : 0), radius: 12, y: 6)
                .nookMatched("stack-\(record.id)", in: namespace)
        }
        .onHover { hovering = $0 }
        .animation(Motion.micro, value: hovering)
    }

    /// Determinate progress only when the publisher sends a real fraction; otherwise a spinner.
    @ViewBuilder private func status(_ event: ActivityEvent) -> some View {
        switch event.lifecycle {
        case .running, .starting:
            if let progress = event.progress {
                Text("\(Int(progress * 100))%").font(TypeScale.numeral).foregroundStyle(Ink.blue)
            } else {
                ProgressView().controlSize(.mini).tint(Ink.blue).accessibilityLabel("In progress")
            }
        case .completed, .failed, .needsInput, .waiting:
            Image(systemName: event.lifecycle.symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(event.lifecycle.tone.color).accessibilityLabel(event.lifecycle.label)
        default:
            EmptyView()
        }
    }

    private func detail(_ event: ActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let request = record.actionableRequest() {
                PermissionPrompt(model: model, record: record, request: request)
            }
            if let progress = event.progress, !event.lifecycle.terminal {
                ProgressLine(value: progress, tone: .blue)
            }
            if let summary = event.summary, !summary.isEmpty {
                Text(summary).font(TypeScale.body).foregroundStyle(Ink.primary.opacity(0.92))
                    .lineLimit(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if event.agent != nil, let host = model.host(for: record) {
                    Button { model.openHost(record) } label: { Label("Open \(host.name)", systemImage: "macwindow") }
                        .buttonStyle(PillButtonStyle(prominent: record.actionableRequest() == nil && event.lifecycle == .needsInput))
                        .help("Brings \(host.name) forward; NotchFlow can't pick the tab or type for you")
                }
                if event.actionURL != nil {
                    Button { model.openAction(record) } label: { Label(model.actionTitle(record), systemImage: event.kind == .download ? "folder" : "arrow.up.forward") }
                        .buttonStyle(PillButtonStyle(prominent: true, tone: event.lifecycle == .failed ? .coral : .iris))
                }
                if !event.lifecycle.terminal {
                    Button("Snooze 10 min") { model.snooze(record) }.buttonStyle(PillButtonStyle())
                }
                if event.lifecycle.terminal {
                    Button("Remove from History") { model.removeRecord(record) }.buttonStyle(PillButtonStyle())
                }
                Spacer(minLength: 0)
                Button { model.togglePin(record) } label: { Image(systemName: record.isPinned ? "pin.slash" : "pin") }
                    .buttonStyle(IconButtonStyle(size: 26, tint: record.isPinned ? Ink.iris : Ink.secondary))
                    .help(record.isPinned ? "Unpin" : "Pin to the stack").accessibilityLabel(record.isPinned ? "Unpin" : "Pin")
                Button { model.hideFromStack(record) } label: { Image(systemName: "eye.slash") }
                    .buttonStyle(IconButtonStyle(size: 26, tint: Ink.secondary))
                    .help("Hide from the stack — stays in History; the task itself is unaffected")
                    .accessibilityLabel("Hide from stack")
            }
            .frame(height: 26)
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }
}

/// A permission request a hook is waiting on. Allow takes two presses; Deny is one. If the time runs
/// out, the hook stands down and the agent's own prompt in the terminal decides.
private struct PermissionPrompt: View {
    @ObservedObject var model: AppModel
    let record: ActivityRecord
    let request: ActivityRequest
    @State private var confirming = false

    var body: some View {
        let lines = SurfaceLayout.requestLines(request.detail)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.amber)
                Text("\(record.event.title) wants to use \(request.tool)").font(TypeScale.cardTitle).foregroundStyle(Ink.primary).lineLimit(1)
                Spacer(minLength: 6)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(max(0, Int(request.expiresAt.timeIntervalSince(context.date).rounded(.up))))s")
                        .font(TypeScale.numeral).foregroundStyle(Ink.secondary)
                        .accessibilityLabel("Seconds left to answer")
                }
            }
            .frame(height: 18)
            if let detail = request.detail, lines > 0 {
                Text(detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Ink.primary.opacity(0.92))
                    .lineLimit(lines).textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: Double(lines) * Metrics.codeLine,
                           maxHeight: Double(lines) * Metrics.codeLine, alignment: .topLeading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.void.opacity(0.7)))
            }
            HStack(spacing: 8) {
                Button {
                    if confirming { model.answer(record, .allow) } else { confirming = true }
                } label: { Text(confirming ? "Confirm allow" : "Allow once").contentTransition(.opacity) }
                    .buttonStyle(PillButtonStyle(prominent: true, tone: confirming ? .mint : .iris))
                    .help(confirming ? "Allows this one request" : "Press again to confirm")
                Button("Deny") { model.answer(record, .deny) }.buttonStyle(PillButtonStyle())
                Spacer(minLength: 0)
            }
            .frame(height: 26)
        }
        .padding(10)
        .background {
            let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
            shape.fill(Ink.amber.opacity(0.07)).overlay(shape.strokeBorder(Ink.amber.opacity(0.22), lineWidth: 0.75))
        }
        .animation(Motion.micro, value: confirming)
        // An armed Allow disarms itself after a few seconds.
        .task(id: confirming) {
            guard confirming else { return }
            try? await Task.sleep(for: .seconds(4))
            confirming = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission request from \(record.event.title) for \(request.tool)")
    }
}

/// Coarse elapsed time that updates twice a minute while visible, not every second.
struct ElapsedText: View {
    let date: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Self.label(from: date, to: context.date)).monospacedDigit()
        }
    }
    static func label(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

struct TimerStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: Clock
    @Environment(\.nookNamespace) private var namespace
    var body: some View {
        HStack(spacing: 10) {
            ToneGlyph(symbol: "timer", tone: .iris, size: 26).nookMatched("timer-glyph", in: namespace)
            if model.countdown.exists {
                Text(model.timerLabel(at: clock.now))
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Motion.micro, value: clock.now)
                Text(model.countdown.running ? "Focus" : "Paused").font(TypeScale.secondary).foregroundStyle(Ink.secondary)
                Spacer(minLength: 8)
                Button { model.toggleTimer() } label: {
                    Image(systemName: model.countdown.running ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle(size: 28)).accessibilityLabel(model.countdown.running ? "Pause timer" : "Resume timer")
                Button { model.cancelTimer() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 28, tint: Ink.secondary)).accessibilityLabel("Cancel timer")
            } else {
                Text("Focus").font(TypeScale.cardTitle)
                Spacer(minLength: 8)
                ForEach([5, 25, 50], id: \.self) { minutes in
                    Button("\(minutes) min") { model.startTimer(minutes: minutes) }.buttonStyle(PillButtonStyle())
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.timerStrip)
        .nookMaterial(.ambient)
    }
}
