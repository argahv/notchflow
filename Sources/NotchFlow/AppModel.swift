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
    /// Recent steps per agent session, from the states and tool names hooks already publish. Memory
    /// only: never written to History, gone when NotchFlow quits.
    struct AgentStep: Identifiable, Equatable { let id = UUID(); let date: Date; let label: String; let tone: Tone }
    @Published private(set) var agentSteps: [String: [AgentStep]] = [:]
    static let agentStepLimit = 6

    /// True while the silhouette is changing shape; the edge catches light, then settles.
    @Published private(set) var surfaceMoving = false
    @Published private(set) var form = SurfaceForm(size: CGSize(width: 208, height: 37.5), ear: 3, corner: 10, inset: 1)
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
        // Context: the frontmost app reorders the stack. Activation notifications only; no polling.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in self?.updateContext(app) }
            .store(in: &subscriptions)
        preferences.$contextAware.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateContext(NSWorkspace.shared.frontmostApplication) }
        }.store(in: &subscriptions)
        updateContext(NSWorkspace.shared.frontmostApplication)
        battery.$percent.combineLatest(battery.$charging).scan((Int?.none, Int?.none, false)) { state, next in (state.1, next.0, next.1) }
            .sink { [weak self] previous, current, charging in self?.batteryChanged(from: previous, to: current, charging: charging) }
            .store(in: &subscriptions)
        clock.onTick = { [weak self] date in self?.tick(date) }
        clock.run(countdown.running)
        screenshots.onCapture = { [weak self] capture in self?.captureArrived(capture) }
        screenshots.configure(enabled: preferences.screenshotsEnabled)
        preferences.$screenshotsEnabled.dropFirst().removeDuplicates().sink { [weak self] enabled in
            DispatchQueue.main.async { self?.screenshots.configure(enabled: enabled) }
        }.store(in: &subscriptions)
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

    // MARK: Hover

    /// One thing the hover can show. Activities are read live from the queue, so their text updates
    /// in place without changing which item is shown.
    enum HoverItem: Equatable { case activity(ActivityRecord), music, timer }
    enum GlanceLead: Equatable {
        case privacy
        case notification(ActivityRecord)
        /// A screenshot that just arrived, with its actions.
        case capture(Capture)
        /// The most relevant item and how many other activities there are.
        case single(HoverItem, others: Int)
        /// Ambient (music or a timer) on the left, work that matters on the right, one surface.
        case split(ambient: HoverItem, work: HoverItem, others: Int)
        /// Nothing live: shortcuts to features that need no integration or permission.
        case quickAccess
    }

    /// What the hover shows. Stored, not recomputed per render, so background updates don't
    /// reshuffle it; `refreshedHoverChoice` applies the stability rules in `HoverPolicy`.
    @Published private(set) var hoverChoice: HoverChoice = .quickAccess
    private var hoverLockedUntil = Date.distantPast

    var glanceLead: GlanceLead {
        if preferences.privacy { return .privacy }
        if case .notification(let id) = glance, let record = record(id) { return .notification(record) }
        if case .capture(let id) = glance, let capture, capture.id == id { return .capture(capture) }
        guard let primary = hoverChoice.primary, let item = hoverItem(primary) else { return .quickAccess }
        if let secondary = hoverChoice.secondary, let other = hoverItem(secondary) {
            return primary.family.isAmbient ? .split(ambient: item, work: other, others: hoverChoice.others)
                                            : .split(ambient: other, work: item, others: hoverChoice.others)
        }
        return .single(item, others: hoverChoice.others)
    }

    /// How many stacked layers peek out under a single activity (up to two).
    var glanceStackDepth: Int {
        guard case .single(.activity, let others) = glanceLead else { return 0 }
        return min(2, others)
    }

    private func hoverItem(_ candidate: HoverCandidate) -> HoverItem? {
        switch candidate.family {
        case .music: return preferences.mediaEnabled && media.playing && media.hasTrack ? .music : nil
        case .timer: return countdown.exists ? .timer : nil
        default: return record(candidate.id).map(HoverItem.activity)
        }
    }

    /// Every live thing that could be shown, from the existing providers. No polling: this is read
    /// when state changes (ingest, media, timer, context, expiry) and when a hover begins.
    var hoverCandidates: [HoverCandidate] {
        var list = visibleActivities.map { record in
            HoverCandidate(id: record.id, tier: hoverTier(record), family: hoverFamily(record.event), updated: record.event.timestamp)
        }
        if preferences.mediaEnabled, media.playing, media.hasTrack {
            list.append(HoverCandidate(id: "music", tier: .music, family: .music, updated: .distantPast))
        }
        if countdown.exists {
            list.append(HoverCandidate(id: "timer", tier: countdown.running ? .imminent : .general, family: .timer, updated: .distantPast))
        }
        return list
    }

    private func hoverTier(_ record: ActivityRecord) -> HoverTier {
        let event = record.event
        switch event.lifecycle {
        case .needsInput, .waiting: return .input
        case .failed: return .failure
        default: break
        }
        if record.isPinned { return .pinned }
        if event.kind == .meeting { return .imminent }
        guard [.running, .starting, .queued].contains(event.lifecycle) else { return .general }
        if contextBoost.contains(event.kind) { return .foreground }
        return [.agent, .build, .ci, .deploy, .task].contains(event.kind) ? .running : .general
    }

    private func hoverFamily(_ event: ActivityEvent) -> HoverFamily {
        switch event.kind {
        case .agent: .agent
        case .build, .ci, .deploy, .task: .pipeline
        case .download: .download
        case .meeting: .meeting
        case .timer: .timer
        case .system: .other
        }
    }

    private func refreshedHoverChoice(fresh: Bool = false) -> HoverChoice {
        let previewing = interaction.presentation == .preview
        let situation = HoverPolicy.Situation(hovered: !fresh && previewing && windows?.pointerInside == true,
                                              locked: !fresh && Date() < hoverLockedUntil,
                                              allowSplit: SurfaceLayout.splitFits(geometry))
        return HoverPolicy.choose(hoverCandidates, current: fresh ? nil : hoverChoice, situation: situation)
    }

    /// Same items in the same places: a refresh that changes nothing visible commits nothing.
    private func sameHover(_ a: HoverChoice, _ b: HoverChoice) -> Bool {
        a.primary?.id == b.primary?.id && a.secondary?.id == b.secondary?.id && a.others == b.others
    }

    /// A control in the preview is being used: keep what's shown for a moment.
    func lockHover(_ seconds: TimeInterval = 2) { hoverLockedUntil = Date().addingTimeInterval(seconds) }

    /// Opens what a hover item stands for, straight to its destination.
    func openHoverItem(_ item: HoverItem) {
        switch item {
        case .activity(let record): navigate(.activity(detail: record.id))
        case .music: navigate(.music)
        case .timer: navigate(.tools(.timer))
        }
        windows?.focus()
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
        // A drag on its way in, a drop's result or a screenshot just taken has the surface: passive
        // arrivals wait and light the rim.
        AttentionContext(editing: interaction.editing || interaction.portal != .closed || captureGlanceShowing,
                         expanded: interaction.presentation == .expanded,
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
    func reflow(animation: Animation? = nil) {
        let choice = refreshedHoverChoice()
        let changed = !sameHover(choice, hoverChoice)
        // Let geometry-changing reflows use the surface's interruptible spring. Explicit callers
        // may still request quick row updates without changing the outer shape.
        commit(snapshot, animation: animation, also: changed ? { self.hoverChoice = choice } : nil)
    }

    /// The one path to any visual change: compute the next form from the snapshot, grow the panel
    /// first if needed, apply everything in a single animated transaction, trim the panel after.
    /// Springs retarget from their current value, so an interrupted transition reverses smoothly.
    private func commit(_ next: PresentationSnapshot, animation: Animation? = nil, also: (() -> Void)? = nil) {
        let previous = snapshot, previousForm = form
        // A hover starting picks freshly from what's live now; what it shows then stays put while hovered.
        if next.interaction.presentation == .preview, previous.interaction.presentation == .collapsed {
            hoverChoice = refreshedHoverChoice(fresh: true)
        }
        // Opening the workspace freezes the stack's order first, so the form is sized for those rows.
        if next.interaction.presentation == .expanded, previous.interaction.presentation != .expanded {
            workspaceActivityIDs = rankedActivities.map(\.id)
        }
        var nextForm = SurfaceLayout.form(for: next, model: self, previous: previousForm)
        guard next != previous || nextForm != form || also != nil else { return }
        if nextForm.size != form.size { windows?.prepare(for: nextForm.size) }
        let transition = windows?.beginTransition() ?? 0
        let reshaping = nextForm.size != previousForm.size || next.interaction.presentation != previous.interaction.presentation
        let portalMoved = next.interaction.portal != previous.interaction.portal && next.interaction.presentation != .expanded
        let motion = animation ?? (portalMoved ? Motion.portal(to: next.interaction.portal)
            : Motion.surface(from: previous.interaction.presentation, to: next.interaction.presentation,
                             growing: nextForm.size.height >= previousForm.size.height))
        withAnimation(motion, completionCriteria: .removed) {
            if reshaping { surfaceMoving = true }
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
            if self?.windows?.isLatest(transition) ?? true { self?.surfaceMoving = false }
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
            if case .capture = glance { glance = .summary; captureWork?.cancel() }
            openedByDrag = false; dropTargeted = false
            resumeCapture(); resumeAttention()
        }
        if was == .expanded && now != .expanded { resumeCapture(); resumeAttention() }
        if previous.interaction.editing && !interaction.editing { resumeCapture(); resumeAttention() }
        if previous.interaction.portal != .closed && interaction.portal == .closed { resumeCapture(); resumeAttention() }
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
            recordAgentStep(event)
            let updated = record(event.key)?.event
            let order = interaction.presentation == .expanded ? stackPlacement(for: event.key, prior: prior) : nil
            if updated == event && event.isMaterialChange(from: prior) { deliver(event) }
            if let record = record(event.key), [.completed, .cancelled].contains(record.event.lifecycle),
               workspaceActivityIDs.contains(record.id), !record.isPinned { scheduleRetraction(record.id) }
            scheduleExpiryRefresh()
            if let order {
                commit(snapshot, animation: Motion.quick, also: { self.workspaceActivityIDs = order; self.hoverChoice = self.refreshedHoverChoice() })
            } else { reflow() }
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

    private func recordAgentStep(_ event: ActivityEvent) {
        guard let agent = event.agent, let state = agent.state, record(event.key)?.event == event else { return }
        let label = state.label(tool: agent.tool)
        var steps = agentSteps[event.key] ?? []
        guard steps.first?.label != label else { return }
        steps.insert(AgentStep(date: event.timestamp, label: label, tone: event.lifecycle.tone), at: 0)
        agentSteps[event.key] = Array(steps.prefix(Self.agentStepLimit))
    }

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

    struct NotificationAction { let title: String; let perform: () -> Void }
    func notificationAction(_ record: ActivityRecord) -> NotificationAction {
        if record.actionableRequest() != nil { return NotificationAction(title: "Review") { [weak self] in self?.viewNotificationDetails() } }
        if record.event.actionURL != nil, [.meeting, .download, .ci, .build, .deploy].contains(record.event.kind) {
            return NotificationAction(title: actionTitle(record)) { [weak self] in
                self?.openAction(record); self?.dismissNotification()
            }
        }
        return NotificationAction(title: "View") { [weak self] in self?.viewNotificationDetails() }
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

    // MARK: Context

    private func updateContext(_ app: NSRunningApplication?) {
        // NotchFlow taking focus (typing in a note, the palette) keeps the previous context.
        if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        let boost = preferences.contextAware ? ContextRules.boost(forFrontmost: app?.bundleIdentifier) : []
        guard boost != contextBoost else { return }
        contextBoost = boost
        if interaction.presentation != .expanded { reflow() }
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

    // MARK: Notch portal and shelf drops

    enum DragProximity { case away, near, close }
    /// What the drag heading for the notch carries, as the portal names it.
    @Published private(set) var portalCargo: PortalCargo?
    /// What the last drop became, shown while it's drawn in.
    @Published private(set) var portalResult: PortalResult?
    /// Changes once per kept drop, so the silhouette's absorption beat runs exactly then.
    @Published private(set) var portalPulse: UUID?
    struct PortalResult: Equatable {
        let id = UUID()
        let kept: Bool
        let title: String
        let detail: String
        let previews: [PortalPreview]
    }
    struct PortalPreview: Identifiable, Equatable { let id: UUID; let icon: NSImage?; let symbol: String }
    private var portalWork: DispatchWorkItem?
    private var lastDropSequence: Int?

    /// The portal has the surface: a target, an opening, or a drop's result instead of the band or glance.
    var portalShowing: Bool { interaction.presentation != .expanded && ![.closed, .aware].contains(interaction.portal) }

    /// A drag carrying something the notch can keep moved nearer or further. Off when the portal is.
    func dragProximity(_ proximity: DragProximity, cargo: PortalCargo?) {
        guard preferences.portalEnabled || proximity == .away else { return }
        var next = snapshot
        switch proximity {
        case .away: next.interaction.send(.retreat)
        case .near: next.interaction.send(.dragApproach)
        case .close: next.interaction.send(.dragAttract)
        }
        commit(next, also: proximity == .away ? nil : { if let cargo { self.portalCargo = cargo } })
    }

    func dragEntered(_ cargo: PortalCargo?) {
        returnWork?.cancel()
        var next = snapshot
        if next.interaction.presentation == .expanded || !preferences.portalEnabled {
            // An open workspace, or the portal turned off, takes the drop into the shelf itself.
            if next.interaction.presentation != .expanded { openedByDrag = true; next.interaction.send(.expand) }
            next.interaction.send(.beginDrag); next.route = .shelf
            commit(next, also: { self.dropTargeted = true })
            return
        }
        portalWork?.cancel()
        next.interaction.send(.beginDrag)
        commit(next, also: {
            self.dropTargeted = true; self.portalResult = nil
            if let cargo { self.portalCargo = cargo }
        })
    }
    func dragExited() {
        var next = snapshot; next.interaction.send(.endDrag)
        commit(next, also: { self.dropTargeted = false })
        windows?.scheduleLeave()
        // A drag the proximity monitor never saw (or one cancelled over the notch) leaves nothing behind.
        if interaction.portal.carrying, windows?.dragIsNear != true { send(.retreat) }
    }

    /// A drop on the notch. What it carries is read now; promised files and images arrive a moment later.
    func receiveDrop(_ pasteboard: NSPasteboard, sequence: Int) -> Bool {
        // AppKit can deliver one drop twice; the repeat is ignored so nothing is added twice.
        guard sequence != lastDropSequence else { return true }
        lastDropSequence = sequence
        switch PortalIntake.read(pasteboard, deliver: { [weak self] incoming, failures in self?.keep(incoming, failures: failures) }) {
        case .now: return true
        case .later: send(.receive); return true
        case .nothing: reject("Nothing in that drop can be kept on the shelf."); return false
        }
    }

    /// Stores what a drop carried, then shows it being drawn in, or why it couldn't be kept. The
    /// animation only starts once the shelf has actually stored the items.
    func keep(_ incoming: [ShelfIncoming], failures: [String] = []) {
        let result = shelf.intake(incoming, origin: "drop")
        let kept = !result.added.isEmpty || result.duplicates > 0
        if interaction.presentation == .expanded {
            var next = snapshot; next.interaction.send(kept ? .absorb : .rejectDrop)
            commit(next, animation: Motion.expressive, also: { self.dropTargeted = false; self.lastArrival = result.added.last })
            if !result.added.isEmpty { illuminate(.silver) }
            if !kept { shelf.error = result.message ?? failures.first ?? "Nothing in that drop could be kept." }
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
            return
        }
        guard kept else { reject(result.message ?? failures.first ?? "Nothing in that drop could be kept."); return }
        let all = shelf.items
        let added = result.added.compactMap { id in all.first { $0.id == id } }
        let cargo = PortalRules.cargo(files: added.map { ($0.name, portalKind($0)) })
        let skipped = result.refusals.count + failures.count
        let detail = added.isEmpty ? "Already on your shelf"
            : skipped > 0 ? "Kept \(added.count) of \(added.count + skipped) · on your shelf"
            : "Kept on your shelf · \(all.count) \(all.count == 1 ? "item" : "items")"
        let summary = PortalResult(kept: true, title: cargo?.title ?? portalCargo?.title ?? "Shelf", detail: detail,
                                   previews: added.prefix(3).map(portalPreview))
        var next = snapshot; next.interaction.send(.absorb)
        commit(next, also: {
            self.dropTargeted = false; self.lastArrival = result.added.last
            self.portalResult = summary
            if !added.isEmpty { self.portalPulse = summary.id }
        })
        illuminate(.silver)
        schedulePortalSettle(after: 1.6)
    }

    private func reject(_ message: String) {
        var next = snapshot; next.interaction.send(.rejectDrop)
        if next.interaction.presentation == .expanded {
            shelf.error = message
            commit(next, also: { self.dropTargeted = false })
            return
        }
        commit(next, also: {
            self.dropTargeted = false
            self.portalResult = PortalResult(kept: false, title: "Couldn't keep that", detail: message, previews: [])
        })
        illuminate(.amber)
        schedulePortalSettle(after: 2.8)
    }

    /// Hands the notch back after a drop's result. Someone reading it keeps it a little longer.
    private func schedulePortalSettle(after delay: TimeInterval, extensions: Int = 0) {
        portalWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, [.receiving, .absorbing, .failed].contains(self.interaction.portal) else { return }
            if self.windows?.pointerInside == true, extensions < 4 {
                self.schedulePortalSettle(after: 1, extensions: extensions + 1); return
            }
            var next = self.snapshot; next.interaction.send(.settlePortal)
            self.commit(next, also: { self.portalResult = nil; self.portalCargo = nil })
        }
        portalWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func portalKind(_ item: ShelfFile) -> PortalContentKind {
        switch item.kind {
        case .text: .text
        case .link: .link
        case .reference, .copy: shelf.resolve(item).map(PortalIntake.kind(of:)) ?? .file
        }
    }

    private func portalPreview(_ item: ShelfFile) -> PortalPreview {
        switch item.kind {
        case .text: PortalPreview(id: item.id, icon: nil, symbol: "text.alignleft")
        case .link: PortalPreview(id: item.id, icon: nil, symbol: "link")
        case .reference, .copy:
            PortalPreview(id: item.id, icon: shelf.resolve(item).map { NSWorkspace.shared.icon(forFile: $0.path) }, symbol: "doc")
        }
    }

    func removeFromShelf(_ item: ShelfFile) { shelf.remove(item); reflow() }
    func clearShelf() { shelf.clear(); reflow() }
    func undoShelfRemoval() { shelf.undo(); reflow() }
    func chooseShelfFiles() { shelf.chooseFiles(); reflow() }
    func copyShelfItem(_ item: ShelfFile) { shelf.copyToPasteboard(item); illuminate(.silver) }
    func quickLook(_ item: ShelfFile) {
        guard shelf.prepareQuickLook(item) else { return }
        windows?.showQuickLook()
    }

    // MARK: Screenshot Magnet

    let screenshots = ScreenshotService()
    /// The latest screenshot. Memory only; the file stays where macOS saved it.
    @Published private(set) var capture: Capture?
    enum CaptureText: Equatable { case idle, reading, done(String), failed(String) }
    @Published private(set) var captureText: CaptureText = .idle
    @Published var annotations = AnnotationDocument()
    @Published var annotationTool: AnnotationTool = .arrow
    /// Where the last annotated copy was saved.
    @Published private(set) var annotatedCopy: URL?
    @Published private(set) var captureBusy = false
    private var recognition: Task<Void, Never>?
    private var captureWork: DispatchWorkItem?
    private var captureWaiting = false

    var captureGlanceShowing: Bool { if case .capture = glance { return true }; return false }

    func captureArrived(_ capture: Capture) {
        // With private details hidden, a screenshot is exactly the kind of thing not to show.
        guard !preferences.privacy else { return }
        recognition?.cancel(); recognition = nil
        self.capture = capture
        captureText = .idle; annotatedCopy = nil; annotations = AnnotationDocument()
        if preferences.quietMode { illuminate(.silver); return }
        if captureMustWait { captureWaiting = true; illuminate(.silver); return }
        presentCapture()
    }

    /// A drag, an editor, an open workspace or another glance keeps the surface; the screenshot
    /// waits and appears when it's free, if it's still recent.
    private var captureMustWait: Bool {
        if interaction.portal != .closed || interaction.editing || interaction.dragging || interaction.presentation == .expanded { return true }
        if case .notification = glance { return true }
        return false
    }

    private func presentCapture() {
        guard let capture else { return }
        captureWaiting = false
        var next = snapshot
        if next.interaction.presentation == .collapsed { next.interaction.send(.attention) }
        commit(next, also: { self.glance = .capture(capture.id) })
        illuminate(.silver)
        scheduleCaptureDismiss()
    }

    private func resumeCapture() {
        guard captureWaiting, let capture, Date().timeIntervalSince(capture.taken) < 90 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.captureWaiting, !self.captureMustWait, self.glance == .summary else { return }
            self.presentCapture()
        }
    }

    /// The preview leaves on its own after a while, but never from under the pointer.
    private func scheduleCaptureDismiss(after delay: TimeInterval = 8) {
        captureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.captureGlanceShowing else { return }
            if self.windows?.pointerInside == true { self.scheduleCaptureDismiss(after: 2); return }
            self.dismissCapture()
        }
        captureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func dismissCapture() {
        captureWork?.cancel()
        guard captureGlanceShowing else { return }
        var next = snapshot
        if next.interaction.presentation == .preview, windows?.pointerInside != true { next.interaction.send(.leave) }
        commit(next, also: { self.glance = .summary })
    }

    func copyCapture() {
        guard let capture, let data = ImagePasteboard.pngData(of: capture.url) else {
            message = "That screenshot is no longer where macOS saved it."; return
        }
        ImagePasteboard.copy(png: data, file: capture.url)
        lockHover(); illuminate(.silver)
    }

    func saveCaptureToShelf() {
        guard let capture else { return }
        let result = shelf.intake([.reference(capture.url)], origin: "screenshot")
        if result.added.isEmpty && result.duplicates == 0 { message = result.message ?? "The screenshot couldn't be added to the shelf." }
        else { illuminate(.silver) }
        reflow()
    }

    func revealCapture() {
        guard let capture else { return }
        NSWorkspace.shared.activateFileViewerSelecting([capture.url])
    }

    func quickLookCapture() {
        guard let capture else { return }
        captureWork?.cancel()
        shelf.preview.urls = [capture.url]
        windows?.showQuickLook()
    }

    /// Reads the screenshot's text on this Mac, in the same surface. Leaving keeps the result.
    func readCaptureText() {
        guard let capture else { return }
        captureWork?.cancel()
        var next = snapshot; next.interaction.send(.expand); next.route = .capture(.text)
        commit(next, also: { self.glance = .summary })
        windows?.focus()
        switch captureText {
        case .reading, .done: return
        case .idle, .failed: break
        }
        captureText = .reading
        recognition = Task { [weak self] in
            do {
                let text = try await TextRecognition.text(in: capture.url)
                guard !Task.isCancelled, let self, self.capture?.id == capture.id else { return }
                self.captureText = .done(text); self.reflow()
            } catch is CancellationError {
            } catch {
                guard let self, self.capture?.id == capture.id else { return }
                self.captureText = .failed(error.localizedDescription); self.reflow()
            }
        }
    }

    func cancelCaptureText() {
        recognition?.cancel(); recognition = nil
        captureText = .idle; reflow()
    }

    func copyCaptureText() {
        guard case .done(let text) = captureText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        illuminate(.silver)
    }

    func saveCaptureTextToShelf() {
        guard case .done(let text) = captureText else { return }
        let result = shelf.intake([.text(text, rich: nil)], origin: "screenshot")
        if result.added.isEmpty && result.duplicates == 0 { message = result.message } else { illuminate(.silver) }
    }

    func annotateCapture() {
        guard capture != nil else { return }
        captureWork?.cancel()
        var next = snapshot; next.interaction.send(.expand); next.route = .capture(.annotate)
        commit(next, also: { self.glance = .summary })
        windows?.focus()
    }

    func changeAnnotations(_ change: (inout AnnotationDocument) -> Void) {
        change(&annotations); annotatedCopy = nil
    }

    /// Saves an annotated copy next to the original, off the main thread. The original isn't touched.
    func saveAnnotatedCopy() {
        guard let capture, !annotations.items.isEmpty, !captureBusy else { return }
        captureBusy = true
        let url = capture.url, items = annotations.items
        Task { [weak self] in
            let saved = await Task.detached(priority: .userInitiated) { Result { try AnnotationRenderer.saveCopy(of: url, items) } }.value
            guard let self else { return }
            self.captureBusy = false
            switch saved {
            case .success(let copy): self.annotatedCopy = copy; self.illuminate(.green)
            case .failure(let error): self.message = error.localizedDescription
            }
            self.reflow()
        }
    }

    /// Copies the annotated image without saving a file.
    func copyAnnotated() {
        guard let capture, !captureBusy else { return }
        captureBusy = true
        let url = capture.url, items = annotations.items
        Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) { try? AnnotationRenderer.png(AnnotationRenderer.render(url, items)) }.value
            guard let self else { return }
            self.captureBusy = false
            if let data { ImagePasteboard.copy(png: data, file: nil); self.illuminate(.silver) }
            else { self.message = AnnotationRenderer.Failure.unreadable.localizedDescription }
        }
    }

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
        persistTimer(); clock.run(countdown.running); reflow()
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
        for mode in ProductMode.allCases where preferences.mode != mode {
            items.append(CommandItem(id: "mode-\(mode.rawValue)", title: "Use \(mode.title) mode", symbol: "slider.horizontal.3", hint: "Mode") { [weak self] in
                self?.preferences.apply(mode)
            })
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
        clock.run(false); providers.stopAll(); approvals.withdraw(); screenshots.stop(); recognition?.cancel()
        media.stop(); camera.stop(); backdrop.stop(); battery.stop()
    }
}

extension Notification.Name {
    static let openNotchFlowSettings = Notification.Name("io.notchflow.openSettings")
}
