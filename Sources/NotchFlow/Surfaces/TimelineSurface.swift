import SwiftUI

/// Time Travel: one moment at a time, the present on the right, older moments to the left. The chosen
/// card sits in front; its neighbours step back with offset, scale and fade. Scroll, swipe or use ← and →.
struct TimelineSurface: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            BackHeader(title: "Time Travel", back: { model.back() }) {
                if !model.timeline.isEmpty {
                    Text("\(model.timelineCursor.index + 1) of \(model.timeline.count)")
                        .font(TypeScale.meta).monospacedDigit().foregroundStyle(Ink.secondary)
                    Button { model.moveTimeline(1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(IconButtonStyle(size: 24, tint: Ink.secondary)).disabled(model.timelineCursor.atOldest)
                        .help("Earlier · ←").accessibilityLabel("Earlier")
                    Button { model.moveTimeline(-1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(IconButtonStyle(size: 24, tint: Ink.secondary)).disabled(model.timelineCursor.atPresent)
                        .help("Later · →").accessibilityLabel("Later")
                    Button("Now") { model.timelineToPresent() }.buttonStyle(PillButtonStyle()).disabled(model.timelineCursor.atPresent)
                }
            }
            .frame(height: Metrics.header)
            if model.timeline.isEmpty {
                CompactEmptyState(symbol: "clock.arrow.circlepath", title: "Nothing to look back on yet",
                                  detail: "Finished work, shelf items and screenshots appear here.")
            } else {
                stage.frame(height: Metrics.timelineStage)
                if let entry = model.timelineEntry {
                    HStack(spacing: 6) {
                        Text(entry.date.formatted(.relative(presentation: .named)))
                            .font(TypeScale.meta).foregroundStyle(Ink.secondary)
                        Spacer()
                        ForEach(model.timelineActions(entry)) { action in
                            Button(action.title, action: action.perform).buttonStyle(PillButtonStyle(prominent: action.id == model.timelineActions(entry).first?.id))
                        }
                    }
                    .frame(height: 26)
                }
            }
        }
        .padding(Metrics.pad)
    }

    /// Up to two moments either side of the chosen one, receding with distance.
    private var stage: some View {
        let index = model.timelineCursor.index
        return ZStack {
            ForEach(Array(model.timeline.enumerated()), id: \.element.id) { offset, entry in
                let distance = offset - index
                if abs(distance) <= 2 {
                    MomentCard(entry: entry, chosen: distance == 0)
                        .frame(width: 230)
                        // Older moments sit to the left of the present.
                        .offset(x: CGFloat(-distance) * 150)
                        .scaleEffect(1 - 0.1 * CGFloat(abs(distance)))
                        .opacity(1 - 0.32 * Double(abs(distance)))
                        .blur(radius: Motion.reduced || Motion.lowPower ? 0 : CGFloat(abs(distance)) * 0.8)
                        .zIndex(Double(-abs(distance)))
                        .onTapGesture { model.moveTimeline(distance) }
                        .accessibilityHidden(distance != 0)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Earlier") { model.moveTimeline(1) }
        .accessibilityAction(named: "Later") { model.moveTimeline(-1) }
    }
}

private struct MomentCard: View {
    let entry: TimelineEntry
    let chosen: Bool
    var body: some View {
        HStack(spacing: 10) {
            ToneGlyph(symbol: Self.symbol(entry.kind), tone: chosen ? .silver : .neutral, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(TypeScale.cardTitle).foregroundStyle(Ink.primary).lineLimit(1).truncationMode(.middle)
                Text(entry.detail).font(TypeScale.secondary).foregroundStyle(Ink.secondary).lineLimit(1)
                Text(entry.date.formatted(date: .omitted, time: .shortened)).font(TypeScale.meta).monospacedDigit().foregroundStyle(Ink.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.timelineStage - 10)
        .nookMaterial(chosen ? .elevated : .ambient, radius: 14)
        .accessibilityElement(children: .combine)
    }

    static func symbol(_ kind: TimelineEntry.Kind) -> String {
        switch kind {
        case .agent: "sparkles"
        case .pipeline: "arrow.triangle.branch"
        case .download: "arrow.down.circle"
        case .timer: "timer"
        case .task: "bolt.horizontal"
        case .shelf: "tray"
        case .clipboard: "doc.on.clipboard"
        case .screenshot: "camera.viewfinder"
        }
    }
}
