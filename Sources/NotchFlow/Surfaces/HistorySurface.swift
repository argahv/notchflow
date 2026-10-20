import SwiftUI

/// A timeline grouped by day: status marks on a quiet rail, one line per event, details inline.
struct HistorySurface: View {
    @ObservedObject var model: AppModel
    @State private var confirmingClear = false

    var body: some View {
        let detail: String? = { if case .history(let detail) = model.route { return detail }; return nil }()
        let groups = HistoryGrouping.groups(model.queue.records)
        Group {
            if groups.isEmpty {
                CompactEmptyState(symbol: "clock", title: "No history yet", detail: "Finished tasks and notifications collect here.")
                    .frame(height: Metrics.emptyRow)
                    .padding(Metrics.pad)
                    .reveal(.primary)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                            Text(group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.secondary)
                                .frame(height: Metrics.historyGroup, alignment: .bottomLeading)
                                .reveal(.secondary, stagger: Double(groupIndex) * 0.03)
                            ForEach(Array(group.records.enumerated()), id: \.element.id) { index, record in
                                HistoryRow(model: model, record: record, expanded: detail == record.id,
                                           first: index == 0, last: index == group.records.count - 1)
                                    .reveal(.primary, stagger: Double(min(index, 6)) * 0.025)
                            }
                        }
                        HStack {
                            Spacer()
                            Button(confirmingClear ? "Clear all history" : "Clear history") {
                                if confirmingClear { model.clearHistory(); confirmingClear = false }
                                else { withAnimation(Motion.quick) { confirmingClear = true } }
                            }
                            .buttonStyle(PillButtonStyle(prominent: confirmingClear, tone: .coral))
                            if confirmingClear {
                                Button("Cancel") { withAnimation(Motion.quick) { confirmingClear = false } }.buttonStyle(PillButtonStyle())
                            }
                        }
                        .frame(height: 28).padding(.top, 8)
                    }
                    .padding(Metrics.pad)
                }
                .scrollIndicators(.automatic)
            }
        }
    }
}

private struct HistoryRow: View {
    @ObservedObject var model: AppModel
    let record: ActivityRecord
    let expanded: Bool
    let first: Bool
    let last: Bool
    @State private var hovering = false

    var body: some View {
        let event = record.event
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.navigate(.history(detail: expanded ? nil : record.id))
            } label: {
                HStack(spacing: 10) {
                    rail(event)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.primary).lineLimit(1)
                        Text("\(event.source) · \(event.phase.label) · \(event.timestamp.formatted(date: .omitted, time: .shortened))")
                            .font(TypeScale.secondary).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let expiry = event.expiresAt, expiry < Date(), !event.phase.terminal {
                        Text("Stale").font(TypeScale.badge).foregroundStyle(Ink.amber)
                    }
                }
                .frame(height: Metrics.historyRow)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering || expanded ? Ink.surface : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.micro, value: hovering)
            .accessibilityLabel("\(event.title), \(event.source), \(event.phase.label)")

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let summary = event.summary, !summary.isEmpty {
                        Text(summary).font(TypeScale.body).foregroundStyle(Ink.primary.opacity(0.92)).lineLimit(4)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        if event.actionURL != nil {
                            Button { model.openAction(record) } label: { Label("Return to task", systemImage: "arrow.up.forward") }
                                .buttonStyle(PillButtonStyle(prominent: true))
                        }
                        Button("Remove") { model.removeRecord(record) }.buttonStyle(PillButtonStyle())
                    }
                    .frame(height: 26)
                }
                .padding(.leading, 34).padding(.trailing, 6).padding(.bottom, 12)
                .transition(.opacity)
            }
        }
    }

    /// The timeline rail: a 1 pt line joining a status mark per event.
    private func rail(_ event: ActivityEvent) -> some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle().fill(first ? .clear : Ink.hover).frame(width: 1)
                Rectangle().fill(last ? .clear : Ink.hover).frame(width: 1)
            }
            Circle().fill(event.phase.tone.color).frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(Ink.obsidian, lineWidth: 1.5).frame(width: 11, height: 11))
        }
        .frame(width: 18, height: Metrics.historyRow)
    }
}
