import SwiftUI

/// Layout constants shared by the size contracts and the views that honor them. Views fix these
/// heights, so a contract computed from data matches what is drawn.
enum Metrics {
    static let statusWing = 58.0
    static let glanceWing = 118.0
    /// Each side of the band holds four 26 pt dock controls plus the ear: 142 pt, with slack.
    static let dockWing = 146.0
    static let workspaceWidth = 500.0
    static let glanceHeight = 64.0
    static let stackLayer = 5.0
    static let codeLine = 15.0
    static let sectionHeader = 16.0
    static let filterBar = 26.0
    static let pad = 14.0
    static let gap = 8.0
    static let header = 28.0
    static let emptyRow = 58.0
    static let activityRow = 52.0
    static let timerStrip = 40.0
    static let tile = 68.0
    static let noteRow = 48.0
    static let searchField = 30.0
    static let todoRow = 30.0
    static let field = 30.0
    static let fileTile = 84.0
    static let dropZone = 64.0
    static let historyRow = 44.0
    static let historyGroup = 24.0
    static let commandRow = 32.0
    static let eventRow = 42.0
    static let reminderRow = 28.0
    static let sectionLabel = 20.0
    static let appTile = 72.0
    static let appsPerRow = 5
    static let tilesPerRow = 5
    static let clipRow = 40.0
    static let maxClipRows = 6
    static let deviceRow = 34.0
    static let metricRow = 28.0
    static let filesPerRow = 5
    static let maxNoteRows = 5
    static let maxTodoRows = 8
    static let maxCommandRows = 7
}

/// Converts the presentation snapshot plus live data into a size contract, then lets the core
/// geometry engine resolve it against the display. Pure apart from reading model data.
@MainActor enum SurfaceLayout {
    static func form(for snapshot: PresentationSnapshot, model: AppModel, previous: SurfaceForm?) -> SurfaceForm {
        let display = model.geometry
        let prior = previous.map { SurfaceSize(width: Double($0.size.width), height: Double($0.size.height)) }
        func resolve(_ contract: SizeContract, wing: Double, ear: CGFloat, corner: CGFloat, inset: CGFloat = 0) -> SurfaceForm {
            let size = SurfaceGeometryEngine.resolve(contract, display: display, wing: wing, previous: prior)
            return SurfaceForm(size: CGSize(width: size.width, height: size.height), ear: ear, corner: corner, inset: inset)
        }
        let hardware = CGFloat(display.notchCorner)
        switch snapshot.interaction.presentation {
        case .collapsed:
            if snapshot.interaction.awareness == .drag {
                // A file is heading for the notch: open a drop target big enough to receive it.
                return resolve(.content(width: display.notchWidth + 2 * Metrics.glanceWing, height: 50),
                               wing: Metrics.glanceWing, ear: 10, corner: 20)
            }
            let status = model.hasBandStatus
            let aware = snapshot.interaction.awareness == .pointer
            let wing = status ? Metrics.statusWing : 0
            // With nothing to show, the surface is the hardware notch, drawn a point inside it so it
            // disappears into the housing. Hover stretches the lower edge slightly; a status widens it.
            return resolve(.content(width: display.notchWidth + 2 * wing + (aware ? 16 : 0), height: aware ? 5 : 0, maxHeight: 40),
                           wing: wing, ear: status || aware ? 6 : 3, corner: status || aware ? hardware + 3 : hardware,
                           inset: status || aware ? 0 : 1)
        case .preview:
            let depth = Double(model.glanceStackDepth)
            return resolve(.content(width: display.notchWidth + 2 * Metrics.glanceWing,
                                    height: Metrics.glanceHeight + (depth > 0 ? Metrics.stackLayer * depth + 4 : 0)),
                           wing: Metrics.glanceWing, ear: 10, corner: 22)
        case .expanded:
            let width = max(Metrics.workspaceWidth, display.notchWidth + 2 * Metrics.dockWing)
            return resolve(.content(width: width, height: workspaceHeight(snapshot, model), minHeight: 56, maxHeight: 420),
                           wing: Metrics.dockWing, ear: 14, corner: 28)
        }
    }

    static func workspaceHeight(_ snapshot: PresentationSnapshot, _ model: AppModel) -> Double {
        if model.preferences.privacy { return 124 }
        // A status message sits above the content; it adds its own row instead of overlapping.
        return contentHeight(snapshot, model) + (model.message == nil ? 0 : 40)
    }

    static func contentHeight(_ snapshot: PresentationSnapshot, _ model: AppModel) -> Double {
        let pad = Metrics.pad
        switch snapshot.route {
        case .activity(let detail):
            let sections = model.activitySections(detail: detail)
            let rows = sections.flatMap(\.rows)
            var height = 10.0 + Metrics.filterBar + Metrics.gap
            height += rows.isEmpty ? Metrics.emptyRow : stack(rows.count, Metrics.activityRow)
            height += Double(sections.filter { $0.title != nil }.count) * (Metrics.sectionHeader + Metrics.gap)
            if let detail, let record = rows.first(where: { $0.id == detail }) { height += detailHeight(record) }
            return height + 12 + Metrics.timerStrip + pad
        case .music:
            return pad + (model.preferences.mediaEnabled ? 64 + (model.media.error == nil ? 0 : 20) : Metrics.emptyRow) + pad
        case .shelf:
            let files = model.shelfCount
            var height = pad
            if files == 0 {
                height += Metrics.dropZone + Metrics.gap + 16
            } else {
                let rows = min(2, (files + Metrics.filesPerRow - 1) / Metrics.filesPerRow)
                height += Metrics.header + Metrics.gap + stack(rows, Metrics.fileTile)
                if model.dropTargeted { height += Metrics.gap + Metrics.dropZone }
            }
            if model.shelf.removed != nil || model.shelf.error != nil { height += Metrics.gap + 26 }
            return height + pad
        case .tools(nil):
            return pad + stack((Tool.allCases.count + Metrics.tilesPerRow - 1) / Metrics.tilesPerRow, Metrics.tile) + pad
        case .tools(let tool?):
            return pad + Metrics.header + 10 + toolHeight(tool, snapshot, model) + pad
        case .history(let detail):
            let groups = HistoryGrouping.groups(model.queue.records)
            guard !groups.isEmpty else { return pad + Metrics.emptyRow + pad }
            var height = pad
            for group in groups { height += Metrics.historyGroup + Double(group.records.count) * Metrics.historyRow }
            if let detail, let record = model.queue.records.first(where: { $0.id == detail }) { height += detailHeight(record) }
            return height + 8 + 28 + pad
        case .command:
            let rows = max(1, min(Metrics.maxCommandRows, model.commandResults.count))
            return pad + Metrics.field + Metrics.gap + Double(rows) * Metrics.commandRow + pad
        }
    }

    static func toolHeight(_ tool: Tool, _ snapshot: PresentationSnapshot, _ model: AppModel) -> Double {
        switch tool {
        case .notes:
            if let id = snapshot.openNoteID { return editorHeight(model.note(id)?.text ?? "") + 22 }
            let count = model.noteCount
            guard count > 0 else { return Metrics.emptyRow }
            return (count >= 4 ? Metrics.searchField + Metrics.gap : 0) + stack(min(count, Metrics.maxNoteRows), Metrics.noteRow, gap: 6)
        case .todos:
            let (total, completed) = model.todoCounts
            let list = total == 0 ? 22 : stack(min(total, Metrics.maxTodoRows), Metrics.todoRow, gap: 2)
            return Metrics.field + Metrics.gap + list + (completed > 0 ? 28 : 0)
        case .calendar:
            guard model.calendar.connected else { return Metrics.emptyRow }
            let events = model.calendar.events.count, reminders = model.calendar.reminders.count
            if events + reminders == 0 { return 40 }
            var height = 0.0
            if events > 0 { height += Metrics.sectionLabel + Double(min(events, 4)) * Metrics.eventRow }
            if reminders > 0 { height += (events > 0 ? Metrics.gap : 0) + Metrics.sectionLabel + Double(min(reminders, 5)) * Metrics.reminderRow }
            return height
        case .mirror:
            return model.camera.running ? 210 + Metrics.gap + 26 : Metrics.emptyRow
        case .apps:
            let count = model.quickApps.count
            guard count > 0 else { return Metrics.emptyRow }
            return stack((count + Metrics.appsPerRow - 1) / Metrics.appsPerRow, Metrics.appTile)
        case .timer:
            return 84
        case .shortcuts:
            return 88
        case .clipboard:
            guard model.clipboard.enabled else { return Metrics.emptyRow + Metrics.gap + 26 }
            let count = model.clipboard.items.count
            let list = count == 0 ? 40 : stack(min(count, Metrics.maxClipRows), Metrics.clipRow, gap: 4)
            return list + (model.clipboard.skipped > 0 || count > 0 ? Metrics.gap + 20 : 0)
        case .sound:
            return stack(max(1, min(model.audioOutputs.count, 6)), Metrics.deviceRow, gap: 4)
        case .system:
            return stack(4, Metrics.metricRow, gap: 4)
        }
    }

    /// Inline detail under an activity or history row: summary (up to four lines) and actions.
    static func detailHeight(_ record: ActivityRecord) -> Double {
        let summary = record.event.summary ?? ""
        let lines = summary.isEmpty ? 0 : min(4, Int((Double(summary.count) / 62).rounded(.up)))
        let request = record.actionableRequest().map { requestHeight($0) + 10 } ?? 0
        return request + Double(lines) * 16 + 10 + 26 + 12
    }

    /// The permission prompt: header, the command or path being authorized, and the answers.
    static func requestHeight(_ request: ActivityRequest) -> Double {
        let lines = requestLines(request.detail)
        return 10 + 18 + 8 + (lines > 0 ? Double(lines) * Metrics.codeLine + 16 + 8 : 0) + 26 + 10
    }
    static func requestLines(_ detail: String?) -> Int {
        guard let detail, !detail.isEmpty else { return 0 }
        return min(3, Int((Double(detail.count) / 56).rounded(.up)))
    }

    /// The note editor grows two lines at a time, between a compact and a focused height; beyond
    /// that the text scrolls inside it.
    static func editorHeight(_ text: String) -> Double {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int((Double($1.count) / 58).rounded(.up))) }
        let raw = Double(lines) * 17 + 20
        return min(272, max(136, (raw / 34).rounded(.up) * 34))
    }

    private static func stack(_ count: Int, _ height: Double, gap: Double = Metrics.gap) -> Double {
        count <= 0 ? 0 : Double(count) * height + Double(count - 1) * gap
    }
}

/// History grouped by day for the timeline and its size contract.
enum HistoryGrouping {
    struct Group: Identifiable { let id: String; let title: String; let records: [ActivityRecord] }
    static func groups(_ records: [ActivityRecord], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let sorted = records.sorted { $0.event.timestamp > $1.event.timestamp }
        var order: [String] = [], buckets: [String: [ActivityRecord]] = [:], titles: [String: String] = [:]
        for record in sorted {
            let day = calendar.startOfDay(for: record.event.timestamp)
            let key = String(Int(day.timeIntervalSince1970))
            if buckets[key] == nil {
                order.append(key)
                titles[key] = calendar.isDateInToday(day) ? "Today"
                    : calendar.isDateInYesterday(day) ? "Yesterday"
                    : day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            }
            buckets[key, default: []].append(record)
        }
        return order.map { Group(id: $0, title: titles[$0] ?? $0, records: buckets[$0] ?? []) }
    }
}
