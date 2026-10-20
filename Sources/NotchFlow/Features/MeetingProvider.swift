import Foundation
import Combine

/// Upcoming calls with a recognized join link become activities: quiet ten minutes ahead, an alert
/// a minute before, "in progress" until the event ends. Events without a join link are left alone.
@MainActor final class MeetingProvider: ActivityProvider {
    let identifier = "meetings"
    let displayName = "Meeting reminders"
    private let calendar: CalendarService
    private var context: ProviderContext?
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private var published: [String: ActivityState] = [:]

    init(calendar: CalendarService) { self.calendar = calendar }

    func start(_ context: ProviderContext) {
        self.context = context
        guard calendar.connected else {
            context.report(.failed("Connect Calendar in Tools › Calendar to get meeting reminders"))
            return
        }
        calendar.refresh()
        subscription = calendar.$events.sink { [weak self] _ in DispatchQueue.main.async { self?.evaluate() } }
        context.report(.running("Following calls with a join link"))
    }

    func stop() {
        timer?.invalidate(); timer = nil
        subscription = nil; context = nil; published = [:]
    }

    private func evaluate() {
        guard let context else { return }
        let now = Date()
        var next: Date?
        for item in calendar.events {
            guard let join = item.joinURL, item.end > now else { continue }
            let untilStart = item.date.timeIntervalSince(now)
            let state: ActivityState? = untilStart <= 0 ? .running : untilStart <= 60 ? .waiting : untilStart <= 600 ? .queued : nil
            // Wake again at the next boundary: ten minutes before, one minute before, the start, the end.
            for boundary in [item.date.addingTimeInterval(-600), item.date.addingTimeInterval(-60), item.date, item.end] where boundary > now {
                next = min(next ?? boundary, boundary)
            }
            guard let state, published[item.id] != state else { continue }
            published[item.id] = state
            let time = item.date.formatted(date: .omitted, time: .shortened)
            let service = item.service ?? "Call"
            let summary = switch state {
            case .running: "In progress · \(service)"
            case .waiting: "Starting at \(time) · \(service)"
            default: "Starts at \(time) · \(service)"
            }
            context.deliver(ActivityEvent(source: "calendar", activityId: String(("meeting-" + item.id).prefix(128)), state: state,
                                          title: String(item.title.prefix(160)), category: .meeting, summary: summary,
                                          actionURL: join.absoluteString, expiresAt: max(item.end, now.addingTimeInterval(60))))
        }
        timer?.invalidate()
        // Re-check calendar changes at least every 15 minutes; otherwise sleep until the next boundary.
        let wake = min(next ?? now.addingTimeInterval(900), now.addingTimeInterval(900))
        let timer = Timer(timeInterval: max(1, wake.timeIntervalSince(now) + 0.5), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.calendar.refresh(); self?.evaluate() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
