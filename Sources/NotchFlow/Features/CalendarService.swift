import EventKit
import AppKit
import Combine

struct CalendarItem: Identifiable {
    var id: String; var title: String; var date: Date; var url: URL?
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
    func connectReminders() {
        store.requestFullAccessToReminders { [weak self] granted, error in
            DispatchQueue.main.async { self?.status = error?.localizedDescription ?? (granted ? "Reminders connected" : "Reminders access denied. Change it in System Settings."); self?.refresh() }
        }
    }
    func refresh() {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let now = Date(), end = now.addingTimeInterval(86400)
            events = store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
                .filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }.prefix(8).map {
                    CalendarItem(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Event", date: $0.startDate, url: $0.url)
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
