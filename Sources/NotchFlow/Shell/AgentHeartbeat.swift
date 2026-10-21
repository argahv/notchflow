import SwiftUI

/// The resting notch's sign of agent life, beside the activity dots. Each pulse has its own shape, not
/// just its own colour. Movement runs for a few seconds after an agent reports a change, then the timeline
/// pauses outright, so an idle notch never redraws.
struct AgentHeartbeat: View {
    let pulse: AgentPulse
    let changed: Date
    /// How long motion lasts after a real change.
    static let window: TimeInterval = 8
    @State private var live = false

    var body: some View {
        let moving = live && pulse.moves && !Motion.reduced && !Motion.lowPower
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
            Canvas { graphics, size in
                draw(&graphics, size: size, time: moving ? context.date.timeIntervalSince(changed) : nil)
            }
        }
        .frame(width: 18, height: 10)
        .overlay { glyph }
        .task(id: changed) {
            live = Date().timeIntervalSince(changed) < Self.window
            guard live else { return }
            try? await Task.sleep(for: .seconds(max(0, Self.window - Date().timeIntervalSince(changed))))
            live = false
        }
        .accessibilityElement()
        .accessibilityLabel(Self.label(pulse))
    }

    /// States that read best as a symbol: waiting, finished, failed.
    @ViewBuilder private var glyph: some View {
        switch pulse {
        case .waiting:
            Image(systemName: "hand.raised.fill").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Ink.amber)
        case .completed:
            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(Ink.green)
                .keyframeAnimator(initialValue: 1.0, trigger: changed) { content, scale in content.scaleEffect(scale) } keyframes: { _ in
                    SpringKeyframe(Motion.reduced ? 1 : 1.35, duration: 0.16)
                    SpringKeyframe(1, duration: 0.3, spring: Spring(response: 0.3, dampingRatio: 0.6))
                }
        case .failed:
            Image(systemName: "exclamationmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(Ink.red)
        default:
            EmptyView()
        }
    }

    /// The drawn pulses. `time` is seconds since the change while moving, nil when holding still.
    private func draw(_ graphics: inout GraphicsContext, size: CGSize, time: TimeInterval?) {
        let mid = size.height / 2
        let track = Path(roundedRect: CGRect(x: 1, y: mid - 1.5, width: size.width - 2, height: 3), cornerRadius: 1.5)
        switch pulse {
        case .working:
            // A slow flow: a highlight drifting along a dim track.
            graphics.fill(track, with: .color(Ink.silver.opacity(0.25)))
            guard let time else { return }
            let phase = CGFloat((time / 1.6).truncatingRemainder(dividingBy: 1))
            let x = -6 + (size.width + 6) * phase
            graphics.fill(Path(roundedRect: CGRect(x: x, y: mid - 1.5, width: 7, height: 3), cornerRadius: 1.5),
                          with: .color(Ink.silver.opacity(0.85)))
        case .tool:
            // One short move to the right as a tool starts, then a still chevron.
            let progress = time.map { min(1, CGFloat($0 / 0.6)) } ?? 1
            var chevron = Path()
            let x = 4 + (size.width - 10) * progress
            chevron.move(to: CGPoint(x: x, y: mid - 3)); chevron.addLine(to: CGPoint(x: x + 4, y: mid)); chevron.addLine(to: CGPoint(x: x, y: mid + 3))
            graphics.fill(track, with: .color(Ink.silver.opacity(0.18)))
            graphics.stroke(chevron, with: .color(Ink.silver), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        case .tests:
            // A stepped rhythm: three steps lighting in turn.
            let lit = time.map { Int($0 / 0.35) % 3 }
            for index in 0..<3 {
                let rect = CGRect(x: 2 + CGFloat(index) * 5.5, y: mid - 2, width: 3.5, height: 4)
                graphics.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Ink.silver.opacity(lit == index ? 0.95 : 0.3)))
            }
        case .idle:
            graphics.fill(Path(ellipseIn: CGRect(x: size.width / 2 - 2, y: mid - 2, width: 4, height: 4)), with: .color(Ink.silver.opacity(0.5)))
        case .disconnected:
            graphics.stroke(Path(ellipseIn: CGRect(x: size.width / 2 - 2.5, y: mid - 2.5, width: 5, height: 5)),
                            with: .color(Ink.muted), lineWidth: 1)
        case .waiting, .completed, .failed:
            break
        }
    }

    static func label(_ pulse: AgentPulse) -> String {
        switch pulse {
        case .idle: "Agent session open"
        case .working: "Agent working"
        case .tool: "Agent running a tool"
        case .tests: "Agent running tests"
        case .waiting: "Agent waiting for you"
        case .completed: "Agent finished"
        case .failed: "Agent failed"
        case .disconnected: "Agent session ended"
        }
    }
}

/// Mission Complete: finished work earns a short, mechanical moment. The glyph settles into place, a
/// silver sheen crosses the lower edge once, and the real result and one next step appear.
struct CelebrationGlance: View {
    @ObservedObject var model: AppModel
    let record: ActivityRecord
    let celebration: AppModel.Celebration
    @State private var settled = false
    @State private var sheen: CGFloat = -0.4

    var body: some View {
        let reduced = Motion.reduced
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(Ink.green)
                .scaleEffect(settled || reduced ? 1 : 0.55).rotationEffect(.degrees(settled || reduced ? 0 : -24))
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(celebration.title).font(TypeScale.cardTitle).foregroundStyle(Ink.primary).lineLimit(1)
                if !celebration.detail.isEmpty {
                    Text(celebration.detail).font(TypeScale.secondary).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .reveal(.primary, stagger: 0.06)
            Spacer(minLength: 8)
            if celebration.batch.count == 1 {
                let next = model.notificationAction(record)
                Button("\(next.title) →") { next.perform() }.buttonStyle(PillButtonStyle(prominent: true)).fixedSize().reveal(.detail)
            } else {
                Button("View All") { model.navigate(.history(detail: nil)); model.windows?.focus() }
                    .buttonStyle(PillButtonStyle(prominent: true)).fixedSize().reveal(.detail)
            }
            Button { model.dismissNotification() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 24, tint: Ink.secondary)).accessibilityLabel("Dismiss")
        }
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, Ink.silver.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.35, height: 1.2)
                    .offset(x: proxy.size.width * sheen - proxy.size.width * 0.175)
            }
            .frame(height: 1.2)
            .opacity(reduced ? 0 : 1)
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .onAppear {
            withAnimation(reduced ? .easeOut(duration: 0.16) : .spring(response: 0.42, dampingFraction: 0.6)) { settled = true }
            guard !reduced else { return }
            withAnimation(.easeInOut(duration: 1.1).delay(0.1)) { sheen = 1.4 }
        }
    }
}
