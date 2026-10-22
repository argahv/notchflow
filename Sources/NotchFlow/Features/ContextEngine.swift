import AppKit

/// One source of context. Observers start and stop with the features that need them, and only emit
/// typed signals; what happens next is the engine's and the intent rules' business.
@MainActor protocol ContextObserver: AnyObject {
    var source: ContextSource { get }
    func start(_ emit: @escaping @MainActor @Sendable (ContextSignal) -> Void)
    func stop()
}

/// The app in front, from activation notifications. No polling, no window titles, nothing on screen.
@MainActor final class FrontmostAppObserver: ContextObserver {
    let source = ContextSource.frontmostApp
    private var token: NSObjectProtocol?

    func start(_ emit: @escaping @MainActor @Sendable (ContextSignal) -> Void) {
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                  object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { Self.report(app, emit) }
        }
        if let app = NSWorkspace.shared.frontmostApplication { Self.report(app, emit) }
    }

    func stop() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }

    private static func report(_ app: NSRunningApplication, _ emit: @MainActor (ContextSignal) -> Void) {
        // NotchFlow taking focus (typing a note, the palette) keeps the previous context.
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        emit(.frontmostApp(bundleID: app.bundleIdentifier, name: app.localizedName))
    }
}

/// Copies that passed the clipboard service's filters. The service owns the one pasteboard check; this
/// observer only listens to it, and the app turns the check on while either history or this is running.
@MainActor final class ClipboardObserver: ContextObserver {
    let source = ContextSource.clipboard
    private let service: ClipboardService
    init(service: ClipboardService) { self.service = service }
    func start(_ emit: @escaping @MainActor @Sendable (ContextSignal) -> Void) { service.onCopy = { emit(.clipboard($0)) } }
    func stop() { service.onCopy = nil }
}

/// Runs the observers, coalesces what they report through `ContextGate`, and keeps the Context
/// Inspector's log. The log holds redacted summaries only: an app's name, or "copied 42 characters".
@MainActor final class ContextEngine: ObservableObject {
    struct SourceState: Equatable {
        var running = false
        var delivered = 0
        var coalesced = 0
        var last: Date?
    }
    struct LogEntry: Identifiable, Equatable {
        enum Kind: Equatable { case lifecycle, event, suggested, held, outcome, mode }
        let id = UUID()
        let date: Date
        let kind: Kind
        let text: String
        /// The score breakdown, for suggestions and for holds that got as far as scoring.
        var detail: String?
    }

    @Published private(set) var states: [ContextSource: SourceState] = [:]
    @Published private(set) var log: [LogEntry] = []
    var onEvent: ((ContextEvent) -> Void)?
    static let logLimit = 80

    private var observers: [ContextSource: any ContextObserver] = [:]
    private var gate = ContextGate()
    private var flushes: [ContextSource: DispatchWorkItem] = [:]

    func register(_ observer: any ContextObserver) {
        observers[observer.source] = observer
        states[observer.source] = SourceState()
    }

    func isRunning(_ source: ContextSource) -> Bool { states[source]?.running == true }

    func setEnabled(_ source: ContextSource, _ enabled: Bool) {
        guard let observer = observers[source], enabled != isRunning(source) else { return }
        states[source, default: SourceState()].running = enabled
        if enabled {
            append(.lifecycle, "\(source.title) started")
            observer.start { [weak self] signal in self?.receive(signal) }
        } else {
            observer.stop()
            flushes[source]?.cancel(); flushes[source] = nil
            gate.reset(source)
            append(.lifecycle, "\(source.title) stopped")
        }
    }

    func stopAll() { for source in ContextSource.allCases { setEnabled(source, false) } }

    private func receive(_ signal: ContextSignal, scripted: Bool = false) {
        #if DEBUG
        if debugScripted.contains(signal.source) && !scripted { return }
        #endif
        let event = ContextEvent(signal, at: Date())
        guard isRunning(event.source) else { return }
        switch gate.admit(event) {
        case .pass:
            deliver(event)
        case .duplicate:
            states[event.source]?.coalesced += 1
        case .deferred(let until):
            states[event.source]?.coalesced += 1
            scheduleFlush(event.source, at: until)
        }
    }

    private func scheduleFlush(_ source: ContextSource, at date: Date) {
        flushes[source]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let event = self.gate.flush(source, now: Date()) else { return }
            self.deliver(event)
        }
        flushes[source] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow) + 0.01, execute: work)
    }

    private func deliver(_ event: ContextEvent) {
        states[event.source]?.delivered += 1
        states[event.source]?.last = event.timestamp
        append(.event, event.redactedSummary)
        onEvent?(event)
    }

    /// What the intent engine decided about an event. Names the kind of suggestion and its score, never what it shows.
    func record(_ decision: IntentDecision) {
        switch decision {
        case .suggest(let suggestion):
            append(.suggested, "Suggested · \(suggestion.category.title) · \(String(format: "%.2f", suggestion.score))",
                   detail: Self.breakdown(suggestion.components))
        case .hold(.nothingToOffer, _, _):
            break
        case .hold(let reason, let rule, let components):
            append(.held, "Held · \(rule.map { "\($0) · " } ?? "")\(reason.explanation)",
                   detail: components.isEmpty ? nil : Self.breakdown(components))
        }
    }

    func record(_ outcome: SuggestionOutcome, for suggestion: Suggestion) {
        append(.outcome, "\(outcome.rawValue.capitalized) · \(suggestion.category.title)")
    }

    /// A work-mode change, so the inspector shows why the notch offers what it does.
    func noteMode(_ text: String) { append(.mode, text) }

    func clearLog() { log.removeAll() }

    #if DEBUG
    /// Scripted QA owns these sources: what the real observers report for them is ignored, so a test isn't
    /// thrown by someone using the Mac.
    var debugScripted: Set<ContextSource> = []
    /// Scripted QA: a signal as if an observer had reported it, through the same gate.
    func debugEmit(_ signal: ContextSignal) {
        debugScripted.insert(signal.source)
        receive(signal, scripted: true)
    }
    #endif

    private func append(_ kind: LogEntry.Kind, _ text: String, detail: String? = nil) {
        log.insert(LogEntry(date: Date(), kind: kind, text: text, detail: detail), at: 0)
        if log.count > Self.logLimit { log.removeLast(log.count - Self.logLimit) }
    }

    static func breakdown(_ components: [ScoreComponent]) -> String {
        components.map { "\($0.label) \(String(format: "%+.2f", $0.value))" }.joined(separator: " · ")
    }
}
