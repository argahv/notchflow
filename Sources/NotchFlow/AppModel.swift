import SwiftUI
import SwiftData
import Combine
import CoreAudio

/// One-second clock that runs only while something on screen counts down. Views that show time
/// observe this instead of the model, so the rest of the surface never redraws on a tick.
@MainActor final class Clock: ObservableObject {
    @Published private(set) var now = Date()
    var onTick: ((Date) -> Void)?
    private var timer: Timer?
    func run(_ active: Bool) {
        if active, timer == nil {
            now = Date()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !active {
            timer?.invalidate(); timer = nil
        }
    }
    private func tick() { now = Date(); onTick?(now) }
}

struct CommandItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var hint: String?
    let run: () -> Void
}

@MainActor final class AppModel: ObservableObject {
    // MARK: Presentation — the single source of truth for what the surface is and how it is drawn.
    @Published private(set) var interaction = InteractionState()
    @Published private(set) var route: Route = .activity(detail: nil)
    @Published private(set) var openNoteID: UUID?
    @Published private(set) var form = SurfaceForm(size: CGSize(width: 208, height: 37.5), ear: 2, corner: 9)
    @Published private(set) var glance: GlanceSubject = .summary
    @Published private(set) var illumination: Illumination?
    @Published private(set) var dockBadge: Tone?
    @Published private(set) var dropTargeted = false
    @Published private(set) var lastArrival: UUID?
    @Published var geometry = DisplayGeometry(x: 0, y: 0, width: 1440, height: 900)
    @Published var commandQuery = "" { didSet { if route == .command { reflow() } } }
    @Published var commandSelection = 0
    func moveCommandSelection(_ delta: Int) {
        let count = min(Metrics.maxCommandRows, commandResults.count)
        guard count > 0 else { return }
        withAnimation(Motion.micro) { commandSelection = min(max(0, commandSelection + delta), count - 1) }
    }
    func runSelectedCommand() {
        let results = Array(commandResults.prefix(Metrics.maxCommandRows))
        guard results.indices.contains(commandSelection) else { return }
        results[commandSelection].run()
    }

    // MARK: Content
    @Published private(set) var queue = ActivityQueue()
    @Published private(set) var countdown = Countdown()
    @Published var message: String? {
        didSet { if oldValue != message { DispatchQueue.main.async { [weak self] in self?.reflow() } } }
    }
    @Published private var workspaceActivityIDs: [String] = []

    let preferences: Preferences
    let clock = Clock()
    let media = MediaService()
    let calendar = CalendarService()
    let camera = CameraService()
    let battery = BatteryService()
    let backdrop = BackdropService()
    let bridge = EventBridge()
    lazy var providers = ProviderHub(deliver: { [weak self] event in self?.ingest(event) })
    let shelf = ShelfService()
    var windows: WindowManager?
    var context: ModelContext?
    var servicesSuspended = false

    private var attention = AttentionCenter()
    private var routeMemory: [Feature: Route] = [:]
    private var routeBeforeCommand: Route = .activity(detail: nil)
    private var hoverWork: DispatchWorkItem?
    private var dismissWork: DispatchWorkItem?
    private var resumeWork: DispatchWorkItem?
    private var expiryWork: DispatchWorkItem?
    private var returnWork: DispatchWorkItem?
    private var openedByDrag = false
    private var subscriptions = Set<AnyCancellable>()
    private let queueURL = AppFiles.root.appendingPathComponent("activities.json")
    let approvals = AgentApprovals()
    let github = GitHubActionsProvider()
    let clipboard = ClipboardService()
    let downloads = DownloadsProvider()
    private(set) lazy var meetings = MeetingProvider(calendar: calendar)
    @Published private(set) var audioOutputs: [AudioOutput] = []
    @Published private(set) var defaultAudioOutput: AudioDeviceID?

    init(preferences: Preferences) {
        self.preferences = preferences
        do { try AppFiles.prepare() } catch { message = error.localizedDescription }
        if let data = try? Data(contentsOf: queueURL),
           let queue = try? ActivityEvent.decoder().decode(ActivityQueue.self, from: data) { self.queue = queue }
        if let data = UserDefaults.standard.data(forKey: "countdown"),
           let timer = try? JSONDecoder().decode(Countdown.self, from: data) { countdown = timer }
        applyRetention()
        let inbox = InboxProvider(bridge: bridge)
        inbox.onError = { [weak self] error in self?.message = error }
        providers.register(inbox)
        providers.setEnabled(inbox.identifier, preferences.bridgeEnabled)
        github.repositories = preferences.githubRepositories
        providers.register(github)
        providers.setEnabled(github.identifier, preferences.githubEnabled)
        preferences.$githubEnabled.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            self.providers.setEnabled(self.github.identifier, enabled)
        }.store(in: &subscriptions)
        preferences.$githubRepositories.dropFirst().sink { [weak self] repositories in
            self?.github.repositories = repositories
        }.store(in: &subscriptions)
        for provider in [downloads, meetings] as [any ActivityProvider] { providers.register(provider) }
        providers.setEnabled(downloads.identifier, preferences.downloadsEnabled)
        providers.setEnabled(meetings.identifier, preferences.meetingsEnabled)
        preferences.$downloadsEnabled.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            self.providers.setEnabled(self.downloads.identifier, enabled)
        }.store(in: &subscriptions)
        preferences.$meetingsEnabled.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            self.providers.setEnabled(self.meetings.identifier, enabled)
        }.store(in: &subscriptions)
        configureClipboard()
        preferences.$clipboardEnabled.combineLatest(preferences.$clipboardRetentionHours).dropFirst()
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.configureClipboard(); self?.reflow() } }
            .store(in: &subscriptions)
        clipboard.$items.map(\.count).removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { if self?.route == .tools(.clipboard) { self?.reflow() } } }
            .store(in: &subscriptions)
        battery.$percent.combineLatest(battery.$charging).scan((Int?.none, Int?.none, false)) { state, next in (state.1, next.0, next.1) }
            .sink { [weak self] previous, current, charging in self?.batteryChanged(from: previous, to: current, charging: charging) }
            .store(in: &subscriptions)
        clock.onTick = { [weak self] date in self?.tick(date) }
        clock.run(countdown.running)
        preferences.$bridgeEnabled.dropFirst().sink { [weak self] enabled in
            self?.providers.setEnabled("inbox", enabled)
        }.store(in: &subscriptions)
        approvals.sync(enabled: preferences.agentApprovals, wait: preferences.approvalWait)
        preferences.$agentApprovals.combineLatest(preferences.$approvalWait).dropFirst()
            .sink { [weak self] enabled, wait in self?.approvals.sync(enabled: enabled, wait: wait) }
            .store(in: &subscriptions)
        preferences.$privacy.dropFirst().sink { [weak self] privateMode in
            DispatchQueue.main.async { if privateMode { self?.send(.endEditing) }; self?.reflow() }
        }.store(in: &subscriptions)
        preferences.$historyRetentionDays.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyRetention(); self?.reflow() }
        }.store(in: &subscriptions)
        // Anything that changes what the resting notch shows changes its width.
        Publishers.Merge4(media.$playing.removeDuplicates().map { _ in () },
                          battery.$percent.map { $0 != nil }.removeDuplicates().map { _ in () },
                          preferences.$showBattery.dropFirst().map { _ in () },
                          preferences.$mediaEnabled.dropFirst().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.reflow() } }
            .store(in: &subscriptions)
        // The Music view reserves a row for an adapter error only while one is showing.
        media.$error.map { $0 != nil }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reflow() } }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.synchronizeServices(); self?.configureClipboard(); self?.objectWillChange.send() }
            .store(in: &subscriptions)
        scheduleExpiryRefresh()
    }

    // MARK: Derived content

    var visibleActivities: [ActivityRecord] { queue.visible(now: Date()) }
    /// Live work in presentation order (see `ActivityRanking`).
    var rankedActivities: [ActivityRecord] { ActivityRanking.rank(visibleActivities, context: rankingContext) }
    var rankingContext: RankingContext { RankingContext(now: Date(), boosted: contextBoost) }
    /// Categories the current context makes more relevant (set by the context engine).
    @Published var contextBoost: Set<ActivityCategory> = []
    var workspaceActivities: [ActivityRecord] {
        // Rows keep their place while the workspace is open, including a task that just finished.
        workspaceActivityIDs.compactMap { id in queue.records.first(where: { $0.id == id }) }
    }
    /// The open stack under the current filter, plus the record a notification opened (which may
    /// already be finished).
    func displayedActivities(detail: String?) -> [ActivityRecord] {
        var rows: [ActivityRecord]
        if activityFilter == .done {
            let since = Date().addingTimeInterval(-86_400)
            rows = Array(queue.records.filter { $0.event.lifecycle.terminal && $0.event.timestamp > since }.prefix(8))
        } else {
            rows = workspaceActivities.filter { activityFilter.includes($0.event.kind) }
        }
        if let detail, !rows.contains(where: { $0.id == detail }), let record = queue.records.first(where: { $0.id == detail }) {
            rows.insert(record, at: 0)
        }
        return rows
    }
    func record(_ id: String) -> ActivityRecord? { queue.records.first(where: { $0.id == id }) }

    struct ActivitySection: Identifiable { let id: String; let title: String?; let rows: [ActivityRecord] }
    /// Agents group by project once more than one project has sessions; projects keep the order of
    /// their most urgent session. Everything else is one untitled section.
    func activitySections(detail: String?) -> [ActivitySection] {
        let rows = displayedActivities(detail: detail)
        guard activityFilter == .agents else { return [ActivitySection(id: "all", title: nil, rows: rows)] }
        var order: [String] = [], groups: [String: [ActivityRecord]] = [:]
        for row in rows {
            let project = row.event.project ?? "Other"
            if groups[project] == nil { order.append(project) }
            groups[project, default: []].append(row)
        }
        guard order.count > 1 else { return [ActivitySection(id: "all", title: nil, rows: rows)] }
        return order.map { ActivitySection(id: "project-" + $0, title: $0, rows: groups[$0] ?? []) }
    }

    enum ActivityFilter: String, CaseIterable, Identifiable {
        case all, agents, pipelines, downloads, done
        var id: String { rawValue }
        var title: String {
            switch self { case .all: "All"; case .agents: "Agents"; case .pipelines: "CI"; case .downloads: "Downloads"; case .done: "Done" }
        }
        func includes(_ category: ActivityCategory) -> Bool {
            switch self {
            case .all, .done: true
            case .agents: category == .agent
            case .pipelines: [.ci, .build, .deploy].contains(category)
            case .downloads: category == .download
            }
        }
    }
    @Published private(set) var activityFilter: ActivityFilter = .all
    /// Bumps when a finished task retracts into History, so History's dock item can acknowledge it.
    @Published private(set) var historyPulse: UUID?
    private var retractions: [String: DispatchWorkItem] = [:]

    func setFilter(_ filter: ActivityFilter) {
        guard filter != activityFilter else { return }
        commit(snapshot, animation: Motion.quick, also: { self.activityFilter = filter })
    }

    /// Several live tasks share the band as one stacked indicator instead of competing for it.
    enum LeadingStatus: Equatable { case privacy, activities(top: ActivityRecord, tones: [Tone], count: Int), music }
    enum TrailingStatus: Equatable { case timer, battery(Int) }
    var leadingStatus: LeadingStatus? {
        if preferences.privacy { return .privacy }
        let ranked = rankedActivities
        let stack = ranked.first.map { LeadingStatus.activities(top: $0, tones: ranked.prefix(3).map(\.event.lifecycle.tone), count: ranked.count) }
        if let top = ranked.first, ActivityRanking.score(top, context: rankingContext) >= 600 { return stack }
        if preferences.mediaEnabled && media.playing { return .music }
        return stack
    }
    var stackCount: Int { rankedActivities.count }
    var trailingStatus: TrailingStatus? {
        if countdown.exists { return .timer }
        if preferences.showBattery, let percent = battery.percent { return .battery(percent) }
        return nil
    }
    var hasBandStatus: Bool { leadingStatus != nil || trailingStatus != nil }

    enum GlanceLead: Equatable { case privacy, notification(ActivityRecord), activity(ActivityRecord), music, timer, idle }
    var glanceLead: GlanceLead {
        if preferences.privacy { return .privacy }
        if case .notification(let id) = glance, let record = record(id) { return .notification(record) }
        let ranked = rankedActivities
        if let top = ranked.first, ActivityRanking.score(top, context: rankingContext) >= 600 { return .activity(top) }
        if preferences.mediaEnabled && media.playing { return .music }
        if countdown.exists { return .timer }
        if let top = ranked.first { return .activity(top) }
        return .idle
    }
    /// How many stacked layers peek out under the glance (the lead plus up to two more).
    var glanceStackDepth: Int {
        guard case .activity = glanceLead else { return 0 }
        return min(2, max(0, stackCount - 1))
    }

    func timerLabel(at date: Date) -> String {
        let seconds = Int(countdown.remaining(at: date).rounded(.up))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var noteCount: Int { (try? context?.fetchCount(FetchDescriptor<Note>())) ?? 0 }
    var todoCounts: (total: Int, completed: Int) {
        let total = (try? context?.fetchCount(FetchDescriptor<Todo>())) ?? 0
        let done = (try? context?.fetchCount(FetchDescriptor<Todo>(predicate: #Predicate { $0.completed }))) ?? 0
        return (total, done)
    }
    var shelfCount: Int { (try? context?.fetchCount(FetchDescriptor<ShelfFile>())) ?? 0 }
    func note(_ id: UUID) -> Note? {
        try? context?.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })).first
    }
    var quickApps: [QuickApp] { preferences.quickApps.compactMap(QuickApp.init(bundleID:)) }

    // MARK: Presentation transitions

    private var snapshot: PresentationSnapshot {
        PresentationSnapshot(interaction: interaction, route: route, openNoteID: openNoteID)
    }
    private var attentionContext: AttentionContext {
        AttentionContext(editing: interaction.editing, expanded: interaction.presentation == .expanded,
                         suppressed: preferences.quietMode || preferences.privacy)
    }

    func send(_ event: InteractionEvent) {
        var next = snapshot; next.interaction.send(event)
        commit(next)
    }

    /// Reopens the workspace exactly where the person left it.
    func openWorkspace() { navigate(route) }

    /// Opens a feature where the person left it; choosing the current feature again returns to its root.
    func open(_ feature: Feature) {
        let target: Route
        if interaction.presentation == .expanded, route.feature == feature { target = .root(feature) }
        else { target = routeMemory[feature] ?? .root(feature) }
        navigate(target)
    }

    func navigate(_ target: Route) {
        var next = snapshot
        if next.interaction.presentation != .expanded { next.interaction.send(.expand) }
        if target == .command, route != .command { routeBeforeCommand = route; commandQuery = ""; commandSelection = 0 }
        next.route = target
        commit(next)
    }

    func back() {
        if route == .command { navigate(routeBeforeCommand); return }
        if route == .tools(.notes), openNoteID != nil { closeNote(); return }
        if let parent = route.parent { navigate(parent) } else { windows?.close() }
    }

    /// Content changed in a way that may change the surface size.
    func reflow(animation: Animation? = nil) { commit(snapshot, animation: animation ?? Motion.quick) }

    /// The one path to any visual change: compute the next form from the snapshot, grow the panel
    /// first if needed, apply everything in a single animated transaction, trim the panel after.
    /// Springs retarget from their current value, so an interrupted transition reverses smoothly.
    private func commit(_ next: PresentationSnapshot, animation: Animation? = nil, also: (() -> Void)? = nil) {
        let previous = snapshot, previousForm = form
        // Opening the workspace freezes the stack's order first, so the form is sized for those rows.
        if next.interaction.presentation == .expanded, previous.interaction.presentation != .expanded {
            workspaceActivityIDs = rankedActivities.map(\.id)
        }
        var nextForm = SurfaceLayout.form(for: next, model: self, previous: previousForm)
        guard next != previous || nextForm != form || also != nil else { return }
        let opening = next.interaction.presentation.depth > previous.interaction.presentation.depth
            || (next.interaction.presentation == previous.interaction.presentation && nextForm.size.height >= form.size.height)
        if nextForm.size != form.size { windows?.prepare(for: nextForm.size) }
        let transition = windows?.beginTransition() ?? 0
        withAnimation(animation ?? Motion.fluid(opening: opening), completionCriteria: .removed) {
            interaction = next.interaction
            route = next.route
            openNoteID = next.openNoteID
            if let also {
                // `also` can change what the surface shows (rows, filter, glance), so the form is
                // resolved again from the state it leaves. The panel grows synchronously, before
                // SwiftUI draws this transaction.
                also()
                nextForm = SurfaceLayout.form(for: next, model: self, previous: previousForm)
                if nextForm.size != previousForm.size { windows?.prepare(for: nextForm.size) }
            }
            form = nextForm
        } completion: { [weak self] in
            self?.windows?.settle(transition)
        }
        // Completions can be held back while the window isn't drawn (Mission Control, occlusion). A timed
        // fallback still trims the panel, so it never lingers as an invisible block over the menu bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.windows?.settle(transition) }
        didCommit(from: previous)
    }

    private func didCommit(from previous: PresentationSnapshot) {
        let now = interaction.presentation, was = previous.interaction.presentation
        if now == .collapsed && was != .collapsed {
            if case .notification = glance { glance = .summary; _ = attention.dismissCurrent(now: Date(), context: attentionContext) }
            openedByDrag = false; dropTargeted = false
            resumeAttention()
        }
        if was == .expanded && now != .expanded { resumeAttention() }
        if previous.interaction.editing && !interaction.editing { resumeAttention() }
        if let feature = route.feature {
            routeMemory[feature] = route
            if feature == .activity && now == .expanded { dockBadge = nil }
        }
        windows?.updateFocus()
        synchronizeServices()
    }

    // MARK: Hover intent

    func hoverBegan() {
        hoverWork?.cancel(); hoverWork = nil
        guard interaction.presentation == .collapsed else { return }
        let work = DispatchWorkItem { [weak self] in self?.send(.enter) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, preferences.hoverDelay), execute: work)
    }
    func hoverEnded() { hoverWork?.cancel(); hoverWork = nil }
    /// The pointer stayed outside past the grace period.
    func pointerLeft() {
        if case .notification = glance, interaction.presentation == .preview { dismissNotification(); return }
        send(.leave)
    }

    // MARK: Activity and attention

    func ingest(_ event: ActivityEvent) {
        let prior = record(event.key)?.event
        do {
            try queue.ingest(event)
            persistQueue()
            let updated = record(event.key)?.event
            let order = interaction.presentation == .expanded ? stackPlacement(for: event.key, prior: prior) : nil
            if updated == event && event.isMaterialChange(from: prior) { deliver(event) }
            if let record = record(event.key), [.completed, .cancelled].contains(record.event.lifecycle),
               workspaceActivityIDs.contains(record.id), !record.isPinned { scheduleRetraction(record.id) }
            scheduleExpiryRefresh()
            if let order { commit(snapshot, animation: Motion.quick, also: { self.workspaceActivityIDs = order }) } else { reflow() }
        } catch { message = error.localizedDescription }
    }

    /// Where a changed record goes in the open stack, or nil to leave the order alone. Rows keep their
    /// place while the stack is open, except work that newly needs the person: it moves to the top so
    /// an answer is never waiting below the fold. The row being read stays put.
    private func stackPlacement(for id: String, prior: ActivityEvent?) -> [String]? {
        guard let record = record(id), visibleActivities.contains(where: { $0.id == id }) else { return nil }
        let urgent = [.needsInput, .failed].contains(record.event.lifecycle)
            && (prior?.lifecycle != record.event.lifecycle || record.event.request != prior?.request)
        var order = workspaceActivityIDs
        if case .activity(id) = route { return order.contains(id) ? nil : order + [id] }
        if urgent {
            order.removeAll { $0 == id }
            return [id] + order
        }
        return order.contains(id) ? nil : order + [id]
    }

    private func deliver(_ event: ActivityEvent) {
        let item = AttentionItem(id: event.key, priority: AttentionPriority(state: event.lifecycle), arrived: Date())
        switch attention.receive(item, context: attentionContext) {
        case .present(let item): present(item)
        case .queue: resumeAttention(after: max(0.6, (attention.nextEligible() ?? Date()).timeIntervalSinceNow + 0.05))
        case .indicate:
            illuminate(event.lifecycle.tone)
            if item.priority.interrupts, !(interaction.presentation == .expanded && route.feature == .activity) {
                dockBadge = item.priority.tone
            }
        case .ignore:
            if glance == .notification(item.id) { withAnimation(Motion.quick) { glance = .summary } }
        }
    }

    private func present(_ item: AttentionItem) {
        guard record(item.id) != nil else { attention.discard(id: item.id); return }
        illuminate(item.priority.tone)
        var next = snapshot
        if next.interaction.presentation == .collapsed { next.interaction.send(.attention) }
        // Notifications never take keyboard focus.
        commit(next, also: { self.glance = .notification(item.id) })
        scheduleDismiss(item)
    }

    private func scheduleDismiss(_ item: AttentionItem) {
        dismissWork?.cancel()
        let delay: TimeInterval = switch item.priority { case .critical: 9; case .actionRequired: 7; default: 4 }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.glance == .notification(item.id) else { return }
            if self.windows?.pointerInside == true { self.scheduleDismiss(item); return }
            self.dismissNotification()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func dismissNotification() {
        dismissWork?.cancel()
        guard case .notification = glance else { return }
        let next = attention.dismissCurrent(now: Date(), context: attentionContext)
        var snapshot = self.snapshot
        if snapshot.interaction.presentation == .preview, windows?.pointerInside != true { snapshot.interaction.send(.leave) }
        commit(snapshot, also: { self.glance = .summary })
        if let next { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.present(next) } }
    }

    func viewNotificationDetails() {
        guard case .notification(let id) = glance else { return }
        dismissWork?.cancel(); attention.discard(id: id)
        var next = snapshot; next.interaction.send(.expand); next.route = .activity(detail: id)
        commit(next, also: { self.glance = .summary })
        windows?.focus()
    }

    private func resumeAttention(after delay: TimeInterval = 0.6) {
        resumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.glance == .summary else { return }
            if let next = self.attention.resume(now: Date(), context: self.attentionContext) { self.present(next) }
            else if let eligible = self.attention.nextEligible(), eligible > Date() {
                self.resumeAttention(after: eligible.timeIntervalSinceNow + 0.05)
            }
        }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func illuminate(_ tone: Tone) { illumination = Illumination(tone: tone) }

    func toggleDetail(_ id: String) {
        guard case .activity(let detail) = route else { return }
        navigate(.activity(detail: detail == id ? nil : id))
    }
    /// A finished task shows its terminal state for a beat, then retracts into History.
    private func scheduleRetraction(_ id: String) {
        retractions[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retractions[id] = nil
            guard let record = self.record(id), [.completed, .cancelled].contains(record.event.lifecycle), !record.isPinned else { return }
            if case .activity(id) = self.route { return } // being read: leave it in place
            self.commit(self.snapshot, animation: Motion.quick, also: {
                self.workspaceActivityIDs.removeAll { $0 == id }
                self.historyPulse = UUID()
            })
        }
        retractions[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
    // MARK: Agents

    /// Sends Allow or Deny to the waiting hook. The request is withdrawn at once so it can't be
    /// answered twice; the hook reports the agent's next state.
    func answer(_ record: ActivityRecord, _ decision: AgentApprovals.Decision) {
        guard let request = record.actionableRequest() else {
            message = "That request is no longer waiting. Answer it in the terminal."; return
        }
        do {
            try approvals.respond(decision, to: request)
            queue.clearRequest(record.id)
            reflow()
        } catch { message = error.localizedDescription }
    }

    func host(for record: ActivityRecord) -> HostApp? { HostApp.resolve(record.event.agent?.terminal) }

    func openHost(_ record: ActivityRecord) {
        guard let app = host(for: record) else { return }
        windows?.close(restoringFocus: false)
        app.activate()
    }

    func togglePin(_ record: ActivityRecord) {
        queue.setPinned(record.id, !record.isPinned); persistQueue(); reflow()
    }
    /// Hides the task from the stack only: it stays in History and the task itself is unaffected.
    func hideFromStack(_ record: ActivityRecord) {
        queue.dismiss(record.id); attention.discard(id: record.id); persistQueue()
        if case .activity(record.id) = route {
            var next = snapshot; next.route = .activity(detail: nil)
            commit(next, also: { self.workspaceActivityIDs.removeAll { $0 == record.id } })
        } else {
            commit(snapshot, animation: Motion.quick, also: { self.workspaceActivityIDs.removeAll { $0 == record.id } })
        }
    }
    func snooze(_ record: ActivityRecord) {
        queue.snooze(record.id, until: Date().addingTimeInterval(600))
        workspaceActivityIDs.removeAll { $0 == record.id }
        persistQueue(); scheduleExpiryRefresh()
        if case .activity = route { navigate(.activity(detail: nil)) } else { reflow() }
    }
    func removeRecord(_ record: ActivityRecord) {
        queue.remove(record.id); attention.discard(id: record.id)
        workspaceActivityIDs.removeAll { $0 == record.id }
        persistQueue()
        switch route {
        case .activity(record.id): navigate(.activity(detail: nil))
        case .history(record.id): navigate(.history(detail: nil))
        default: reflow()
        }
    }
    func clearHistory() {
        queue.clear(); workspaceActivityIDs.removeAll(); persistQueue()
        if case .history = route { navigate(.history(detail: nil)) } else { reflow() }
    }
    func openAction(_ record: ActivityRecord) {
        guard let string = record.event.actionURL, let url = URL(string: string) else { return }
        do { try record.event.validate() } catch { message = error.localizedDescription; return }
        // Actions never run automatically. No arbitrary shell commands are accepted. A downloaded
        // file is revealed, not opened: opening an unknown download is the person's decision.
        if url.isFileURL, record.event.kind == .download {
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { message = "That file is no longer in Downloads." }
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// The action button's label, from what the action does.
    func actionTitle(_ record: ActivityRecord) -> String {
        switch record.event.kind {
        case .meeting: "Join"
        case .download: "Show in Finder"
        case .ci: "Open run"
        default: "Open"
        }
    }

    // MARK: System

    private func configureClipboard() {
        clipboard.configure(enabled: preferences.clipboardEnabled, retention: Double(max(1, preferences.clipboardRetentionHours)) * 3600,
                            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
    func clearClipboard() { clipboard.clear(); reflow() }

    func refreshAudioOutputs() {
        audioOutputs = AudioDevices.outputs()
        defaultAudioOutput = AudioDevices.defaultOutput()
        reflow()
    }
    func selectAudioOutput(_ device: AudioOutput) {
        if AudioDevices.setDefaultOutput(device.id) { defaultAudioOutput = device.id }
        else { message = "macOS didn't switch to \(device.name)." }
    }

    private func batteryChanged(from previous: Int?, to current: Int?, charging: Bool) {
        guard preferences.lowBatteryAlerts, let current else { return }
        let id = "battery-low"
        if charging, let record = record("system:" + id), !record.event.lifecycle.terminal {
            ingest(ActivityEvent(source: "system", activityId: id, state: .cancelled, title: record.event.title, category: .system, summary: "Charging"))
            return
        }
        guard let threshold = BatteryAlerts.crossed(from: previous, to: current, charging: charging) else { return }
        ingest(ActivityEvent(source: "system", activityId: id, state: .waiting, title: "Battery at \(current)%", category: .system,
                             summary: threshold <= 5 ? "Your Mac will sleep soon. Connect power." : "Connect power soon.",
                             expiresAt: Date().addingTimeInterval(1800)))
    }

    private func applyRetention() {
        let days = preferences.historyRetentionDays
        guard days > 0 else { return }
        queue.prune(before: Date().addingTimeInterval(-Double(days) * 86_400))
        persistQueue()
    }

    /// Wakes exactly when the next task expires or a snooze ends, instead of polling.
    private func scheduleExpiryRefresh() {
        expiryWork?.cancel()
        let now = Date()
        let boundaries = queue.records.compactMap { record -> Date? in
            guard !record.event.phase.terminal else { return nil }
            let expiry = record.event.expiresAt ?? record.event.timestamp.addingTimeInterval(3600)
            // A pending request's buttons disappear when it lapses, even if its hook never reports back.
            return [expiry, record.snoozedUntil, record.event.request?.expiresAt].compactMap { $0 }.filter { $0 > now }.min()
        }
        guard let next = boundaries.min() else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.objectWillChange.send(); self?.reflow(); self?.scheduleExpiryRefresh()
        }
        expiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + next.timeIntervalSince(now) + 0.5, execute: work)
    }

    // MARK: Shelf drag and drop

    func dragEntered() {
        returnWork?.cancel()
        if interaction.presentation != .expanded { openedByDrag = true }
        var next = snapshot; next.interaction.send(.beginDrag); next.route = .shelf
        commit(next, also: { self.dropTargeted = true })
    }
    func dragExited() {
        var next = snapshot; next.interaction.send(.endDrag)
        commit(next, also: { self.dropTargeted = false })
        windows?.scheduleLeave()
    }
    func didDrop(_ urls: [URL]) -> Bool {
        let added = urls.compactMap { shelf.add($0) }
        var next = snapshot; next.interaction.send(.endDrag)
        commit(next, animation: Motion.expressive, also: {
            self.dropTargeted = false
            self.lastArrival = added.last
        })
        if !added.isEmpty { illuminate(.mint) }
        if openedByDrag {
            // A drop that opened the shelf hands the notch back once the file has landed.
            returnWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.windows?.pointerInside != true, !self.interaction.pinned else { return }
                self.send(.leave)
            }
            returnWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
        }
        return !added.isEmpty
    }
    func removeFromShelf(_ item: ShelfFile) { shelf.remove(item); reflow() }
    func undoShelfRemoval() { shelf.undo(); reflow() }
    func chooseShelfFiles() { shelf.chooseFiles(); reflow() }

    // MARK: Notes and to-dos

    func newNote() {
        guard let context else { return }
        let note = Note(); context.insert(note); save()
        var next = snapshot
        if next.interaction.presentation != .expanded { next.interaction.send(.expand) }
        next.route = .tools(.notes); next.openNoteID = note.id
        commit(next)
    }
    func openNote(_ id: UUID) { var next = snapshot; next.openNoteID = id; commit(next) }
    func closeNote() {
        if let id = openNoteID, let note = note(id), note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context?.delete(note); save()
        }
        var next = snapshot; next.openNoteID = nil; next.interaction.send(.endEditing)
        commit(next)
    }
    func deleteNote(_ note: Note) {
        let wasOpen = openNoteID == note.id
        context?.delete(note); save()
        if wasOpen { var next = snapshot; next.openNoteID = nil; next.interaction.send(.endEditing); commit(next) } else { reflow() }
    }
    func addTodo(_ title: String) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let context else { return }
        withAnimation(Motion.quick) { context.insert(Todo(title: text)) }
        save(); reflow()
    }
    func toggle(_ todo: Todo) { withAnimation(Motion.quick) { todo.completed.toggle() }; save(); reflow() }
    func delete(_ todo: Todo) { withAnimation(Motion.quick) { context?.delete(todo) }; save(); reflow() }
    func clearCompletedTodos() {
        guard let context else { return }
        let done = (try? context.fetch(FetchDescriptor<Todo>(predicate: #Predicate { $0.completed }))) ?? []
        withAnimation(Motion.quick) { done.forEach(context.delete) }
        save(); reflow()
    }
    func save() {
        do { try context?.save() } catch { message = "Could not save: \(error.localizedDescription)" }
    }

    // MARK: Focus timer

    func startTimer(minutes: Int) {
        countdown.start(seconds: Double(minutes * 60)); persistTimer(); clock.run(true); reflow()
    }
    func toggleTimer() {
        if countdown.running { countdown.pause() } else { countdown.resume() }
        persistTimer(); clock.run(countdown.running); objectWillChange.send()
    }
    func cancelTimer() { countdown.cancel(); persistTimer(); clock.run(false); reflow() }
    private func tick(_ date: Date) {
        guard countdown.consumeCompletion(now: date) else { return }
        persistTimer(); clock.run(false)
        ingest(ActivityEvent(source: "timer", activityId: UUID().uuidString, phase: .completed,
                             title: "Focus session finished", timestamp: date))
        if !preferences.quietMode { NSSound(named: "Glass")?.play() }
    }
    private func persistTimer() { UserDefaults.standard.set(try? JSONEncoder().encode(countdown), forKey: "countdown") }
    private func persistQueue() {
        // History on disk never holds pending requests or sensitive summaries.
        do { try ActivityEvent.encoder().encode(queue.historySafe).write(to: queueURL, options: .atomic) }
        catch { message = "Could not save activity history: \(error.localizedDescription)" }
    }

    // MARK: Commands (⌘K)

    var commandResults: [CommandItem] {
        var items: [CommandItem] = [
            CommandItem(id: "note", title: "New note", symbol: "square.and.pencil", hint: "Notes") { [weak self] in self?.newNote() },
            CommandItem(id: "timer25", title: "Start a 25-minute focus timer", symbol: "timer") { [weak self] in self?.startTimer(minutes: 25); self?.navigate(.activity(detail: nil)) },
            CommandItem(id: "timer5", title: "Start a 5-minute timer", symbol: "timer") { [weak self] in self?.startTimer(minutes: 5); self?.navigate(.activity(detail: nil)) },
            CommandItem(id: "shelf", title: "Open shelf", symbol: Feature.shelf.symbol, hint: "⌘3") { [weak self] in self?.navigate(.shelf) },
            CommandItem(id: "music", title: "Music", symbol: Feature.music.symbol, hint: "⌘2") { [weak self] in self?.navigate(.music) },
            CommandItem(id: "activity", title: "Activity", symbol: Feature.activity.symbol, hint: "⌘1") { [weak self] in self?.navigate(.activity(detail: nil)) },
            CommandItem(id: "history", title: "History", symbol: Feature.history.symbol, hint: "⌘5") { [weak self] in self?.navigate(.history(detail: nil)) },
        ]
        items += Tool.allCases.map { tool in
            CommandItem(id: "tool-\(tool.rawValue)", title: tool.title, symbol: tool.symbol, hint: "Tools") { [weak self] in self?.navigate(.tools(tool)) }
        }
        items += quickApps.map { app in
            CommandItem(id: "app-\(app.id)", title: "Open \(app.name)", symbol: "arrow.up.forward.app", hint: "App") { app.open() }
        }
        items.append(CommandItem(id: "quiet", title: preferences.quietMode ? "Turn off quiet mode" : "Turn on quiet mode", symbol: "bell.slash") { [weak self] in self?.preferences.quietMode.toggle() })
        items.append(CommandItem(id: "privacy", title: preferences.privacy ? "Show private details" : "Hide private details", symbol: "eye.slash") { [weak self] in self?.preferences.privacy.toggle() })
        items.append(CommandItem(id: "settings", title: "Settings…", symbol: "gearshape", hint: "⌘,") { NotificationCenter.default.post(name: .openNotchFlowSettings, object: nil) })
        let query = commandQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        let activities = queue.records.filter { $0.event.title.lowercased().contains(query) }.prefix(4).map { record in
            CommandItem(id: "rec-\(record.id)", title: record.event.title, symbol: record.event.lifecycle.symbol, hint: record.event.source) { [weak self] in
                self?.navigate(.history(detail: record.id))
            }
        }
        return items.filter { $0.title.lowercased().contains(query) || ($0.hint?.lowercased().contains(query) ?? false) } + activities
    }

    // MARK: Services

    func synchronizeServices() {
        let expanded = interaction.presentation == .expanded && preferences.overlayEnabled && !preferences.privacy && !servicesSuspended
        media.configure(player: preferences.mediaPlayer, enabled: preferences.mediaEnabled && !servicesSuspended,
                        polling: expanded && route == .music)
        if !(expanded && route == .tools(.mirror)) { camera.stop() }
        if expanded && preferences.visualMode == .ultra && !Motion.lowPower,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            windows?.startBackdrop()
        } else { backdrop.stop() }
    }

    func stop() {
        clock.run(false); providers.stopAll(); approvals.withdraw()
        media.stop(); camera.stop(); backdrop.stop(); battery.stop()
    }
}

extension Notification.Name {
    static let openNotchFlowSettings = Notification.Name("io.notchflow.openSettings")
}
