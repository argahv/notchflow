import EventKit
import AppKit
import Combine

struct CalendarItem: Identifiable {
    var id: String; var title: String; var date: Date; var url: URL?
    var end: Date = .distantFuture
    /// A recognized video-call link from the event's URL, location or notes (see `MeetingLinks`).
    var joinURL: URL?
    var service: String?
}
@MainActor final class CalendarService: ObservableObject {
    @Published var events: [CalendarItem] = []
    @Published var reminders: [EKReminder] = []
    @Published var status = "Connect Calendar or Reminders to show your day."
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    var connected: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess || EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }
    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    func connectCalendar() {
        store.requestFullAccessToEvents { [weak self] granted, error in
            DispatchQueue.main.async { self?.status = error?.localizedDescription ?? (granted ? "Calendar connected" : "Calendar access denied. Change it in System Settings."); self?.refresh() }
        }
    }
    func connectReminders(then completion: ((Bool) -> Void)? = nil) {
        store.requestFullAccessToReminders { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.status = error?.localizedDescription ?? (granted ? "Reminders connected" : "Reminders access denied. Change it in System Settings.")
                self?.refresh()
                completion?(granted)
            }
        }
    }
    var remindersAllowed: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    /// Adds a reminder to the default list and returns its identifier, so it can be undone.
    func addReminder(title: String, due: Date) throws -> String {
        guard let list = store.defaultCalendarForNewReminders() else {
            throw NSError(domain: "NotchFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Reminders has no default list."])
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        reminder.addAlarm(EKAlarm(absoluteDate: due))
        try store.save(reminder, commit: true)
        refresh()
        return reminder.calendarItemIdentifier
    }

    /// Removes a reminder this app just added (Undo). Anything else is left alone.
    func removeReminder(_ identifier: String) {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return }
        do { try store.remove(reminder, commit: true); refresh() } catch { status = error.localizedDescription }
    }
    func refresh() {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let now = Date(), end = now.addingTimeInterval(86400)
            events = store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
                .filter { $0.endDate > now && !$0.isAllDay }.sorted { $0.startDate < $1.startDate }.prefix(8).map { event in
                    let join = MeetingLinks.join(in: [event.url?.absoluteString, event.location, event.notes])
                    return CalendarItem(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Event", date: event.startDate,
                                        url: event.url, end: event.endDate, joinURL: join?.url, service: join?.service)
                }
        } else { events = [] }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) { [weak self] items in
                DispatchQueue.main.async { self?.reminders = Array((items ?? []).prefix(12)) }
            }
        } else { reminders = [] }
    }
    func complete(_ reminder: EKReminder) {
        do { reminder.isCompleted = true; try store.save(reminder, commit: true); refresh() }
        catch { status = error.localizedDescription }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
