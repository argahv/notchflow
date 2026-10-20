import SwiftUI

/// Live tasks as compact capsules. Choosing one grows it in place into a detail card; nothing
/// navigates away, and rows that finish while the workspace is open keep their position.
struct ActivitySurface: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let detail: String? = { if case .activity(let detail) = model.route { return detail }; return nil }()
        let rows = model.displayedActivities(detail: detail)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                if rows.isEmpty {
                    CompactEmptyState(symbol: "checkmark.circle", tone: .mint, title: "Nothing needs you",
                                      detail: "Agent and build events appear here as tasks publish updates.")
                        .frame(height: Metrics.emptyRow)
                        .reveal(.primary)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, record in
                    ActivityCapsule(model: model, record: record, expanded: detail == record.id)
                        .reveal(.primary, stagger: Double(min(index, 6)) * 0.03)
                        .transition(.row)
                }
                TimerStrip(model: model, clock: model.clock)
                    .padding(.top, 4)
                    .reveal(.secondary, stagger: 0.04)
            }
            .padding(.top, 10).padding(.bottom, Metrics.pad).padding(.horizontal, Metrics.pad)
        }
        .scrollIndicators(.automatic)
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
                    ToneGlyph(symbol: SourceGlyph.symbol(for: event.source), tone: event.phase.tone, size: 30)
                        .nookMatched("lead-\(record.id)", in: namespace)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title).font(TypeScale.cardTitle).foregroundStyle(Ink.primary).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(event.source)
                            Text("·")
                            Text(event.phase.label).foregroundStyle(event.phase.tone.color)
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
            .accessibilityLabel("\(event.title), \(event.source), \(event.phase.label)")
            .accessibilityHint(expanded ? "Collapses details" : "Shows details")

            if expanded {
                detail(event).transition(.opacity)
            }
        }
        .nookMaterial(expanded ? .elevated : .interactive, hovering: hovering && !expanded)
        .onHover { hovering = $0 }
        .animation(Motion.micro, value: hovering)
    }

    /// Determinate progress only when the publisher sends a real fraction; otherwise a spinner.
    @ViewBuilder private func status(_ event: ActivityEvent) -> some View {
        if !event.phase.terminal && event.phase != .waiting {
            if let progress = event.progress {
                Text("\(Int(progress * 100))%").font(TypeScale.numeral).foregroundStyle(Ink.blue)
            } else {
                ProgressView().controlSize(.mini).tint(Ink.blue)
            }
        }
    }

    private func detail(_ event: ActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress = event.progress, !event.phase.terminal {
                ProgressLine(value: progress, tone: .blue)
            }
            if let summary = event.summary, !summary.isEmpty {
                Text(summary).font(TypeScale.body).foregroundStyle(Ink.primary.opacity(0.92))
                    .lineLimit(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if event.actionURL != nil {
                    Button { model.openAction(record) } label: { Label("Return to task", systemImage: "arrow.up.forward") }
                        .buttonStyle(PillButtonStyle(prominent: true, tone: event.phase == .failed ? .coral : .iris))
                }
                if !event.phase.terminal {
                    Button("Snooze 10 min") { model.snooze(record) }.buttonStyle(PillButtonStyle())
                }
                Button("Remove") { model.removeRecord(record) }.buttonStyle(PillButtonStyle())
                Spacer(minLength: 0)
            }
            .frame(height: 26)
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
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
