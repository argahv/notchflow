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
    @Published private(set) var glance: GlanceSubject = .summary {
        didSet {
            guard glance != oldValue else { return }
            // A transient glance ended: whatever waited gets its turn (see `resumeSurface`).
            if glance == .summary { resumeSurface() }
            // An alert took the surface from a screenshot just taken: it comes back afterwards, if still recent.
            if case .capture = oldValue, case .notification = glance { captureWaiting = true }
            // Something else took the surface from a suggestion: it was superseded.
            guard case .suggestion = oldValue else { return }
            if case .suggestion(let id) = glance, id == suggestion?.id { return }
            suggestionLeftSurface()
        }
    }
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
    private var surfaceWork: DispatchWorkItem?
    private var expiryWork: DispatchWorkItem?
    private var returnWork: DispatchWorkItem?
    private var openedByDrag = false
    private var subscriptions = Set<AnyCancellable>()
    private let queueURL = AppFiles.root.appendingPathComponent("activities.json")
    let approvals = AgentApprovals()
    let github = GitHubActionsProvider()
    let clipboard = ClipboardService()
    let contextEngine = ContextEngine()
    let downloadObserver = DownloadObserver()
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
        // Context: observers start and stop with the features that use them (see ContextEngine). The app in
        // front reorders the stack; copies can suggest a next step.
        contextEngine.register(FrontmostAppObserver())
        contextEngine.register(ClipboardObserver(service: clipboard))
        contextEngine.register(downloadObserver)
        contextEngine.onEvent = { [weak self] event in self?.contextEvent(event) }
        synchronizeContext()
        Publishers.Merge4(preferences.$contextAware.dropFirst().map { _ in () },
                          preferences.$suggestionsEnabled.dropFirst().map { _ in () },
                          preferences.$clipboardSuggestions.dropFirst().map { _ in () },
                          preferences.$downloadSuggestions.dropFirst().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.synchronizeContext() } }
            .store(in: &subscriptions)
        preferences.$clipboardExcludedApps.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.configureClipboard() } }
            .store(in: &subscriptions)
        // Work modes: a pin, the switch and the detectors change what's observed and what the notch offers.
        Publishers.Merge4(preferences.$workModesEnabled.dropFirst().map { _ in () },
                          preferences.$pinnedWorkMode.dropFirst().map { _ in () },
                          preferences.$modeDetectorsOff.dropFirst().map { _ in () },
                          preferences.$mediaEnabled.dropFirst().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.workModeSettingsChanged() } }
            .store(in: &subscriptions)
        media.$playing.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateWorkMode() } }
            .store(in: &subscriptions)
        battery.$percent.combineLatest(battery.$charging).scan((Int?.none, Int?.none, false)) { state, next in (state.1, next.0, next.1) }
            .sink { [weak self] previous, current, charging in self?.batteryChanged(from: previous, to: current, charging: charging) }
            .store(in: &subscriptions)
        // A focus timer kept across a relaunch starts a fresh ledger; what waited before the relaunch isn't known.
        if countdown.exists { focus.begin(at: Date()); if !countdown.running { focus.pause(at: Date()) } }
        clock.onTick = { [weak self] date in self?.tick(date) }
        clock.run(countdown.running)
        screenshots.onCapture = { [weak self] capture in self?.captureArrived(capture) }
        sound.onTransition = { [weak self] transition in self?.soundChanged(transition) }
        sound.start()
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
            DispatchQueue.main.async {
                // Hiding details (presenting, sharing a screen) also takes away anything suggested from what was copied.
                if privateMode { self?.send(.endEditing); self?.pendingSuggestion = nil; self?.closeSuggestion(.superseded) }
                self?.reflow()
            }
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
        /// Sound moved to another output: the device, its volume, and a quick switch.
        case sound(SoundTransition)
        /// A suggested next step for something just copied, with its actions.
        case suggestion(Suggestion)
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
        if glance == .sound, let soundTransition { return .sound(soundTransition) }
        if case .suggestion(let id) = glance, let suggestion, suggestion.id == id { return .suggestion(suggestion) }
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
        let candidates = hoverCandidates
        // A pin lapses when its item ends; it's never kept for something that isn't live.
        if let pin = hoverPin, !candidates.contains(where: { $0.id == pin }) { hoverPin = nil }
        let situation = HoverPolicy.Situation(hovered: !fresh && previewing && windows?.pointerInside == true,
                                              locked: !fresh && Date() < hoverLockedUntil,
                                              allowSplit: SurfaceLayout.splitFits(geometry), pinned: hoverPin)
        return HoverPolicy.choose(candidates, current: fresh ? nil : hoverChoice, situation: situation)
    }

    // MARK: Spatial Sound Island

    let sound = SoundService()
    @Published private(set) var soundTransition: SoundTransition?
    private var soundWork: DispatchWorkItem?

    /// When a sound change that had to wait arrived; it's shown within six seconds or not at all.
    private var soundWaitingSince: Date?

    /// Sound moved to another output: a short glance with the device, its volume and a quick switch,
    /// then the notch retracts. It's passive news: it waits behind anything showing or in use, and a newer
    /// change replaces it in place. Quiet mode only lights the rim.
    func soundChanged(_ transition: SoundTransition) {
        guard preferences.soundIslandEnabled, !preferences.privacy else { return }
        soundTransition = transition
        if preferences.quietMode { illuminate(.silver); return }
        if glance != .sound, SurfaceArbiter.admit(.passive, into: surfaceOccupancy) == .wait {
            soundWaitingSince = Date(); illuminate(.silver); return
        }
        showSound()
    }

    private func showSound() {
        soundWaitingSince = nil
        refreshAudioOutputs()
        var next = snapshot
        if next.interaction.presentation == .collapsed { next.interaction.send(.attention) }
        commit(next, also: { self.glance = .sound })
        illuminate(.silver)
        scheduleSoundDismiss()
    }

    private func scheduleSoundDismiss(after delay: TimeInterval = 5) {
        soundWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.glance == .sound else { return }
            if self.windows?.pointerInside == true { self.scheduleSoundDismiss(after: 2); return }
            self.dismissSound()
        }
        soundWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func dismissSound() {
        soundWork?.cancel()
        guard glance == .sound else { return }
        var next = snapshot
        if next.interaction.presentation == .preview, windows?.pointerInside != true { next.interaction.send(.leave) }
        commit(next, also: { self.glance = .summary })
    }

    func setSoundVolume(_ value: Float) { sound.setVolume(value); lockHover(); scheduleSoundDismiss(after: 4) }
    func toggleSoundMute() { sound.toggleMute(); lockHover(); scheduleSoundDismiss(after: 4) }
    func chooseSoundOutput(_ device: AudioOutput) { selectAudioOutput(device); lockHover(); scheduleSoundDismiss(after: 4) }

    // MARK: Time Travel

    /// Assembled when Time Travel opens, from what NotchFlow already keeps; nothing is stored for it.
    @Published private(set) var timeline: [TimelineEntry] = []
    @Published private(set) var timelineCursor = TimelineCursor(count: 0)
    var timelineEntry: TimelineEntry? { timeline.indices.contains(timelineCursor.index) ? timeline[timelineCursor.index] : nil }

    func openTimeline() {
        timeline = buildTimeline()
        timelineCursor = TimelineCursor(count: timeline.count)
        navigate(.timeline); windows?.focus()
    }

    func moveTimeline(_ step: Int) {
        var cursor = timelineCursor; cursor.move(step)
        guard cursor != timelineCursor else { return }
        withAnimation(Motion.selection) { timelineCursor = cursor }
    }
    func timelineToPresent() { withAnimation(Motion.selection) { timelineCursor = TimelineCursor(count: timeline.count) } }

    private func buildTimeline() -> [TimelineEntry] {
        let finished = queue.records.filter { $0.event.lifecycle.terminal }.map { record -> TimelineEntry in
            let kind: TimelineEntry.Kind = switch record.event.kind {
            case .agent: .agent
            case .ci, .build, .deploy: .pipeline
            case .download: .download
            case .timer: .timer
            default: record.event.source == "timer" ? .timer : .task
            }
            return TimelineEntry(id: "a:" + record.id, date: record.event.timestamp, kind: kind, title: record.event.title,
                                 detail: ActivityText.subtitle(record))
        }
        let kept = shelf.items.map {
            TimelineEntry(id: "s:" + $0.id.uuidString, date: $0.addedAt, kind: .shelf, title: $0.name,
                          detail: $0.origin == "screenshot" ? "Screenshot on your shelf" : "Kept on your shelf")
        }
        // The card shows its own time, so the detail is only the screenshot's pixel size.
        let screenshot: [TimelineEntry] = capture.map { shot -> [TimelineEntry] in
            let size = shot.pixelSize.width > 0 ? " · \(Int(shot.pixelSize.width)) × \(Int(shot.pixelSize.height))" : ""
            return [TimelineEntry(id: "p:" + shot.url.path, date: shot.taken, kind: .screenshot, title: shot.name, detail: "Screenshot" + size)]
        } ?? []
        // Clipboard text only when that feature is on, and never with private details hidden. Secrets are
        // never in it to begin with.
        let clips = preferences.clipboardEnabled && !preferences.privacy ? clipboard.items.map {
            TimelineEntry(id: "c:" + $0.id.uuidString, date: $0.date, kind: .clipboard,
                          title: ShelfPolicy.title(forText: $0.text), detail: "Copied" + ($0.source.map { " in \($0)" } ?? ""))
        } : []
        let days = preferences.historyRetentionDays
        return TimelineRules.merge([finished, kept, screenshot, clips], since: days > 0 ? Date().addingTimeInterval(-Double(days) * 86_400) : nil)
    }

    struct TimelineAction: Identifiable { let id: String; let title: String; let perform: () -> Void }
    /// What can be done with a moment, offered only while its source still exists.
    func timelineActions(_ entry: TimelineEntry) -> [TimelineAction] {
        let key = String(entry.id.dropFirst(2))
        switch entry.id.prefix(2) {
        case "a:":
            guard let record = record(key) else { return [] }
            var actions = [TimelineAction(id: "details", title: "Details") { [weak self] in self?.navigate(.history(detail: record.id)) }]
            if record.event.actionURL != nil, [.download, .ci, .build, .deploy].contains(record.event.kind) {
                if record.event.kind == .download, let url = record.event.actionURL.flatMap(URL.init(string:)),
                   !FileManager.default.fileExists(atPath: url.path) { return actions }
                actions.append(TimelineAction(id: "open", title: actionTitle(record)) { [weak self] in self?.openAction(record) })
            }
            return actions
        case "s:":
            guard let item = shelf.items.first(where: { $0.id.uuidString == key }) else { return [] }
            if item.isFile, shelf.resolve(item) == nil { return [] }
            return [TimelineAction(id: "actions", title: "Actions") { [weak self] in self?.openActions([item.id]) },
                    TimelineAction(id: "copy", title: "Copy") { [weak self] in self?.copyShelfItem(item) }]
        case "p:":
            guard let capture, capture.url.path == key, FileManager.default.fileExists(atPath: key) else { return [] }
            return [TimelineAction(id: "copy", title: "Copy") { [weak self] in self?.copyCapture() },
                    TimelineAction(id: "reveal", title: "Show in Finder") { [weak self] in self?.revealCapture() }]
        case "c:":
            guard let clip = clipboard.items.first(where: { $0.id.uuidString == key }) else { return [] }
            return [TimelineAction(id: "copy", title: "Copy Again") { [weak self] in self?.clipboard.copy(clip); self?.illuminate(.silver) }]
        default:
            return []
        }
    }

    // MARK: Living Split Island

    /// The hover item kept on the island, in memory only. Requests and failures still take the lead.
    @Published private(set) var hoverPin: String?
    /// The region just clicked, lit for a beat before the surface grows into it.
    @Published private(set) var splitFocus: String?

    func toggleHoverPin(_ item: HoverItem) {
        hoverPin = hoverPin == item.id ? nil : item.id
        lockHover(); reflow()
    }

    /// Shows the next (or previous) item of the same kind on one side of the island.
    func cycleHover(_ side: HoverPolicy.Side, step: Int) {
        let next = HoverPolicy.cycle(hoverCandidates, current: hoverChoice, side: side, step: step)
        guard !sameHover(next, hoverChoice) else { return }
        lockHover(3)
        commit(snapshot, animation: Motion.quick, also: { self.hoverChoice = next })
    }

    /// From a sideways swipe: the half under the pointer is the side that changes.
    func cycleHover(leftHalf: Bool, step: Int) {
        if case .split(let ambient, let work, _) = glanceLead {
            let item = leftHalf ? ambient : work
            cycleHover(hoverChoice.primary?.id == item.id ? .primary : .secondary, step: step)
        } else {
            cycleHover(.primary, step: step)
        }
    }

    func hoverSide(_ item: HoverItem) -> HoverPolicy.Side { hoverChoice.primary?.id == item.id ? .primary : .secondary }
    /// A live hover item by its id ("music", "timer", or an activity's id).
    func hoverItem(id: String) -> HoverItem? {
        hoverCandidates.first { $0.id == id }.flatMap(hoverItem)
    }
    func hoverAlternatives(_ item: HoverItem) -> Int {
        HoverPolicy.alternatives(hoverCandidates, current: hoverChoice, side: hoverSide(item))
    }

    /// Why an item is on the island, in a few words: the ranking made visible.
    func hoverReason(_ item: HoverItem) -> String {
        if hoverPin == item.id { return "Kept shown" }
        let tier = [hoverChoice.primary, hoverChoice.secondary].compactMap { $0 }.first { $0.id == item.id }?.tier
        switch tier {
        case .input?: return "Needs you"
        case .failure?: return "Failed recently"
        case .pinned?: return "Pinned"
        case .imminent?: return item.id == "timer" ? "Timer running" : "Starting soon"
        case .foreground?: return "Related to the app in front"
        case .running?: return "Running"
        case .music?: return "Playing"
        case .general?, nil: return "Live"
        }
    }

    /// Clicking a region: it lights for a beat, the other fades, then the surface grows into it.
    func openSplitRegion(_ item: HoverItem) {
        splitFocus = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.reduced ? 0 : 0.12)) { [weak self] in
            self?.openHoverItem(item); self?.splitFocus = nil
        }
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
        // A drag on its way in or a drop's result has the surface: everything waits and lights the rim. A screenshot,
        // a suggestion or a sound change holds it against passive news, not against work that needs the person.
        AttentionContext(editing: interaction.editing || interaction.portal != .closed,
                         expanded: interaction.presentation == .expanded,
                         suppressed: preferences.quietMode || preferences.privacy,
                         holdBelow: max(SurfaceArbiter.lowestPriorityAdmitted(over: transientTier),
                                        focusing ? FlowGuardian.lowestPriorityDuringFocus : .silent))
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
            if case .notification = glance { glance = .summary; celebration = nil; attention.closeCurrent() }
            if case .capture = glance { glance = .summary; captureWork?.cancel() }
            if glance == .sound { glance = .summary; soundWork?.cancel() }
            if suggestionShowing { retireSuggestion(.ignored); glance = .summary }
            openedByDrag = false; dropTargeted = false
            resumeSurface()
        }
        if was == .expanded && now != .expanded { resumeSurface() }
        if previous.interaction.editing && !interaction.editing { resumeSurface() }
        if previous.interaction.portal != .closed && interaction.portal == .closed { resumeSurface() }
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
        // Looked at and left alone: the suggestion goes, and counts as ignored rather than dismissed.
        if suggestionShowing, interaction.presentation == .preview { closeSuggestion(.ignored); return }
        send(.leave)
    }

    // MARK: Activity and attention

    func ingest(_ event: ActivityEvent) {
        let prior = record(event.key)?.event
        do {
            try queue.ingest(event)
            persistQueue()
            recordAgentStep(event)
            if record(event.key)?.event == event { trackAgent(event, prior: prior) }
            let updated = record(event.key)?.event
            let order = interaction.presentation == .expanded ? stackPlacement(for: event.key, prior: prior) : nil
            if updated == event && event.isMaterialChange(from: prior), !suggestForDownload(event) { deliver(event) }
            if let record = record(event.key), [.completed, .cancelled].contains(record.event.lifecycle),
               workspaceActivityIDs.contains(record.id), !record.isPinned { scheduleRetraction(record.id) }
            scheduleExpiryRefresh()
            if event.category == .meeting { updateWorkMode() }
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
        // Mission Complete: a meaningful finish right after another joins the moment already showing.
        if var shown = celebration, glance == .notification(shown.lead), let record = record(event.key),
           let completion = completion(for: record), completionPolicy.joins(completion, shownSince: shown.since),
           completionPolicy.importance(of: completion, in: .init()) == .celebrate {
            shown.batch.append(completion)
            (shown.title, shown.detail) = CompletionPolicy.headline(shown.batch)
            celebration = shown
            scheduleDismiss(AttentionItem(id: shown.lead, priority: .informational, arrived: Date()))
            return
        }
        let item = AttentionItem(id: event.key, priority: AttentionPriority(state: event.lifecycle), arrived: Date())
        switch attention.receive(item, context: attentionContext) {
        case .present(let item): present(item)
        case .queue: resumeSurface(after: max(0.6, (attention.nextEligible() ?? Date()).timeIntervalSinceNow + 0.05))
        case .indicate:
            if focusing, item.priority < FlowGuardian.lowestPriorityDuringFocus {
                // Held for the end of the focus session: no rim, no badge. The stack still has it.
                focus.note(id: item.id, kind: .update, title: event.title); return
            }
            illuminate(event.lifecycle.tone)
            if item.priority.interrupts, !(interaction.presentation == .expanded && route.feature == .activity) {
                dockBadge = item.priority.tone
            }
        case .ignore:
            if glance == .notification(item.id) { withAnimation(Motion.quick) { glance = .summary } }
        }
    }

    private func present(_ item: AttentionItem) {
        guard let record = record(item.id) else { attention.discard(id: item.id); return }
        // Finished work: a short celebration when it's meaningful and the moment is free, a plain glance
        // when it isn't meaningful or would land on typing, and only the rim in quiet situations.
        var moment: Celebration?
        if let completion = completion(for: record) {
            let situation = CompletionPolicy.Situation(quiet: preferences.quietMode, typing: Self.typingNow,
                                                       busy: interaction.presentation == .expanded || windows?.pointerInside == true)
            switch completionPolicy.importance(of: completion, in: situation) {
            case .indicate:
                illuminate(.green)
                attention.closeCurrent(); resumeSurface()
                return
            case .celebrate:
                moment = Celebration(lead: item.id, batch: [completion], since: Date(),
                                     title: celebrationTitle(record), detail: celebrationDetail(record, completion))
            case .glance:
                break
            }
        }
        illuminate(item.priority.tone)
        var next = snapshot
        if next.interaction.presentation == .collapsed { next.interaction.send(.attention) }
        // Notifications never take keyboard focus.
        commit(next, also: { self.glance = .notification(item.id); self.celebration = moment })
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
        attention.closeCurrent()
        var snapshot = self.snapshot
        if snapshot.interaction.presentation == .preview, windows?.pointerInside != true { snapshot.interaction.send(.leave) }
        commit(snapshot, also: { self.glance = .summary; self.celebration = nil })
        resumeSurface(after: 0.5)
    }

    func viewNotificationDetails() {
        guard case .notification(let id) = glance else { return }
        dismissWork?.cancel(); attention.discard(id: id)
        var next = snapshot; next.interaction.send(.expand); next.route = .activity(detail: id)
        commit(next, also: { self.glance = .summary })
        windows?.focus()
    }

    // MARK: Surface coordination

    /// The one place anything that had to wait gets the surface back: alerts, a screenshot, a suggestion, a
    /// sound change. `SurfaceArbiter.next` picks the most important, then the most recent; nothing stale.
    private func resumeSurface(after delay: TimeInterval = 0.4) {
        surfaceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.surfaceIsFree() }
        surfaceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func surfaceIsFree() {
        guard glance == .summary else { return }
        let now = Date()
        // Quiet or private since they started waiting: what came from the person's own content goes.
        if preferences.quietMode || preferences.privacy { pendingSuggestion = nil; captureWaiting = false; soundWaitingSince = nil }
        var waiting = waitingGlances
        while let next = SurfaceArbiter.next(waiting, now: now) {
            waiting.removeAll { $0.kind == next.kind }
            if next.kind == .attention {
                // The alert queue keeps its own pace; if it isn't time yet, something else may go first.
                if let item = attention.resume(now: now, context: attentionContext) { present(item); return }
                if let eligible = attention.nextEligible(), eligible > now { resumeSurface(after: eligible.timeIntervalSince(now) + 0.05) }
                continue
            }
            // Someone is using the notch; the transition that ends it calls back here.
            guard SurfaceArbiter.admit(next.tier, into: surfaceOccupancy) == .show else { return }
            switch next.kind {
            case .capture: presentCapture()
            case .suggestion: if let pending = pendingSuggestion { showSuggestion(pending) }
            case .sound: showSound()
            case .attention: break
            }
            return
        }
        pendingSuggestion = nil
        if let capture, now.timeIntervalSince(capture.taken) >= 90 { captureWaiting = false }
        soundWaitingSince = nil
    }

    /// Everything waiting for the surface, as the arbiter sees it.
    var waitingGlances: [WaitingGlance] {
        var waiting: [WaitingGlance] = []
        if let item = attention.pending.max(by: { ($0.priority, $1.arrived) < ($1.priority, $0.arrived) }) {
            waiting.append(WaitingGlance(.attention, tier: item.priority.surfaceTier, arrived: item.arrived, expires: .distantFuture))
        }
        if captureWaiting, let capture {
            waiting.append(WaitingGlance(.capture, tier: .suggestion, arrived: capture.taken, expires: capture.taken.addingTimeInterval(90)))
        }
        if let pendingSuggestion {
            waiting.append(WaitingGlance(.suggestion, tier: .suggestion, arrived: pendingSuggestion.created, expires: pendingSuggestion.expires))
        }
        if let soundWaitingSince {
            waiting.append(WaitingGlance(.sound, tier: .passive, arrived: soundWaitingSince, expires: soundWaitingSince.addingTimeInterval(6)))
        }
        return waiting
    }

    /// The tier of a transient glance on screen that isn't an alert: what alerts must outrank to replace it.
    private var transientTier: SurfaceTier? {
        switch glance {
        case .capture, .suggestion: .suggestion
        case .sound: .passive
        case .summary, .notification: nil
        }
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
        if let summary = focusSummary, summary.record == record.id, summary.waited > 0 {
            return NotificationAction(title: "Review") { [weak self] in self?.reviewFocusSession() }
        }
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

    /// The app in front, and the work mode, reorder the stack. The observer already ignores NotchFlow taking
    /// focus. An inferred mode adds to ranking only while ranking follows the app in front; a pinned one always does.
    private func applyContextBoost() {
        let fromApp = preferences.contextAware ? ContextRules.boost(forFrontmost: frontmostApp) : []
        let fromMode = preferences.contextAware || preferences.pinnedWorkMode != nil ? workMode.boosted : []
        let boost = fromApp.union(fromMode)
        guard boost != contextBoost else { return }
        contextBoost = boost
        if interaction.presentation != .expanded { reflow() }
    }

    // MARK: System

    private func configureClipboard() {
        clipboard.configure(enabled: preferences.clipboardEnabled, suggestions: contextEngine.isRunning(.clipboard),
                            retention: Double(max(1, preferences.clipboardRetentionHours)) * 3600,
                            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, excluded: Set(preferences.clipboardExcludedApps))
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
            // A call that ended expires its record, which can end the meeting mode.
            self?.objectWillChange.send(); self?.updateWorkMode(); self?.reflow(); self?.scheduleExpiryRefresh()
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
        /// The shelf items this drop added, and the actions offered for them right here.
        var items: [UUID] = []
        var actions: [ContentAction] = []
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
        // Someone who has dropped something knows the portal: the one-time tip retires.
        if kept, !preferences.portalHintSeen { preferences.portalHintSeen = true }
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
        // What can be done with it, offered in the result itself: the item's two most useful actions,
        // or Merge PDFs for several PDFs dropped together.
        let contexts = added.map { ContentInspector.context(for: $0, shelf: shelf) }
        let actions = contexts.count == 1 ? ActionRegistry.primary(for: contexts[0])
            : ActionRegistry.actions(for: ContentClassifier.collection(contexts.map(\.kind)))
        let summary = PortalResult(kept: true, title: cargo?.title ?? portalCargo?.title ?? "Shelf", detail: detail,
                                   previews: added.prefix(3).map(portalPreview), items: added.map(\.id), actions: actions)
        var next = snapshot; next.interaction.send(.absorb)
        commit(next, also: {
            self.dropTargeted = false; self.lastArrival = result.added.last
            self.portalResult = summary
            if !added.isEmpty { self.portalPulse = summary.id }
        })
        illuminate(.silver)
        // Long enough to reach for an action; the pointer resting on the result keeps it longer.
        schedulePortalSettle(after: actions.isEmpty ? 1.6 : 4.5)
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

    // MARK: Agent heartbeat and Mission Complete

    /// The band's agent pulse, from what the sessions themselves reported.
    var agentPulse: AgentPulse? { AgentPulseRules.pulse(for: agentRecords, now: Date()) }
    /// When an agent last reported a change, so the pulse moves for a fixed time after real news only.
    @Published private(set) var agentPulseChanged = Date.distantPast
    private var agentRecords: [ActivityRecord] { queue.records.filter { $0.event.agent != nil && $0.dismissedAt == nil } }
    private var pulseWork: DispatchWorkItem?
    /// When each session's current turn began (its prompt was submitted), to state how long it worked.
    private var turnStarted: [String: Date] = [:]
    let completionPolicy = CompletionPolicy()

    /// A celebration in the notch: one finish, or several that arrived together.
    struct Celebration: Equatable {
        let id = UUID()
        var lead: String
        var batch: [Completion]
        let since: Date
        var title: String
        var detail: String
    }
    @Published private(set) var celebration: Celebration?

    private func trackAgent(_ event: ActivityEvent, prior: ActivityEvent?) {
        guard let agent = event.agent else { return }
        let restarted = [AgentState.idle, .starting, .completed, .failed, .waitingForUser, .disconnected]
        if agent.state == .working, prior?.agent?.state.map(restarted.contains) ?? true { turnStarted[event.key] = event.timestamp }
        if event.lifecycle == .cancelled { turnStarted[event.key] = nil }
        if prior?.agent?.state != agent.state || prior?.agent?.tool != agent.tool { agentPulseChanged = Date() }
        refreshPulse()
    }

    /// A finish's mark and a silent session change with time alone; wake once at the next such moment.
    private func refreshPulse() {
        pulseWork?.cancel()
        let now = Date()
        let boundaries = agentRecords.compactMap { record -> Date? in
            let at = record.event.timestamp.addingTimeInterval(record.event.lifecycle.terminal
                ? AgentPulseRules.afterglow + 0.1 : AgentPulseRules.staleAfter + 0.1)
            return at > now ? at : nil
        }
        guard let next = boundaries.min() else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.objectWillChange.send(); self?.reflow(); self?.refreshPulse()
        }
        pulseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + next.timeIntervalSince(now), execute: work)
    }

    /// Finished work, with only what's known: its source, and how long an agent's turn ran when it was
    /// seen from prompt to finish. Downloads report their size from the file itself.
    private func completion(for record: ActivityRecord) -> Completion? {
        let event = record.event
        guard event.lifecycle == .completed else { return nil }
        let source: Completion.Source = switch event.kind {
        case .agent: .agent
        case .ci: .ci
        case .build: .build
        case .deploy: .deploy
        case .download: .download
        case .timer: .timer
        case .task, .meeting, .system: event.source == "timer" ? .timer : .other
        }
        let elapsed = event.agent != nil ? turnStarted[record.id].map { event.timestamp.timeIntervalSince($0) } : nil
        let size = event.kind == .download
            ? event.actionURL.flatMap(URL.init(string:)).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init) : nil
        return Completion(id: record.id, source: source, title: event.title, elapsed: elapsed, size: size, at: event.timestamp)
    }

    private func celebrationTitle(_ record: ActivityRecord) -> String {
        let event = record.event
        switch event.kind {
        case .ci: return "\(event.title) passed"
        case .build: return "\(event.title) succeeded"
        case .deploy: return "\(event.title) deployed"
        default: return event.title
        }
    }

    private func celebrationDetail(_ record: ActivityRecord, _ completion: Completion) -> String {
        let event = record.event
        var parts: [String] = []
        if event.kind == .ci { parts.append("All checks passed") }
        if let place = event.agent?.repository ?? event.project { parts.append(place) }
        if let branch = event.branch { parts.append(branch) }
        if let elapsed = completion.elapsed {
            parts.append("worked " + Duration.seconds(elapsed).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))
        }
        if let size = completion.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if event.source == "timer", let summary = event.summary { parts.append(summary) }
        return parts.joined(separator: " · ")
    }

    /// A key was pressed in the last moment and a half: time since the last key event only, never which key.
    static var typingNow: Bool { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 1.5 }

    // MARK: Notch Actions

    /// What the action surface is about: one shelf item, or several dropped together.
    @Published private(set) var actionItemIDs: [UUID] = []
    /// Worked out once when the surface opens, so views never touch the disk to draw it.
    @Published private(set) var actionContext: ContentContext?
    @Published private(set) var actionRun = ActionRun()
    /// Shelf items the last action made; Undo removes them and their files.
    @Published private(set) var actionCreated: [UUID] = []
    private var actionTask: Task<Void, Never>?

    var actionItems: [ShelfFile] {
        let all = shelf.items
        return actionItemIDs.compactMap { id in all.first { $0.id == id } }
    }

    /// Opens the actions for shelf items in the same surface, optionally starting one straight away.
    func openActions(_ ids: [UUID], then action: ContentAction? = nil) {
        if ids != actionItemIDs { actionTask?.cancel(); actionTask = nil; actionRun = ActionRun(); actionCreated = [] }
        actionItemIDs = ids
        let items = actionItems
        if items.count == 1 {
            actionContext = ContentInspector.context(for: items[0], shelf: shelf)
        } else if items.count > 1 {
            let kinds = items.map { ContentInspector.context(for: $0, shelf: shelf).kind }
            actionContext = ContentClassifier.collection(kinds)
        } else {
            actionContext = nil
        }
        portalWork?.cancel()
        var next = snapshot; next.interaction.send(.expand); next.route = .actions
        commit(next, also: { self.portalResult = nil; if case .capture = self.glance { self.glance = .summary } })
        windows?.focus()
        if let action { perform(action) }
    }

    func perform(_ action: ContentAction) {
        let items = actionItems
        guard let first = items.first, let context = actionContext, ActionRegistry.actions(for: context).contains(action) else { return }
        // The one capability check every action passes. Notch Actions need no permission and never change an
        // original, so this only ever refuses one that was declared otherwise without a confirmation step.
        guard ActionGuard.clearance(for: ActionCatalog.descriptor(for: action), granted: [], confirmed: false) == .run else {
            message = "\(action.title) needs a confirmation the notch can't ask for yet."; return
        }
        // Opening something elsewhere isn't a run with a result.
        switch action {
        case .quickLook: quickLook(first); return
        case .open: shelf.open(first); return
        case .reveal: shelf.reveal(first); return
        case .annotate: annotateFile(first); return
        default: break
        }
        guard let token = actionRun.start(action) else { return }
        actionCreated = []
        let text = textContent(of: first)
        switch action {
        case .copy:
            shelf.copyToPasteboard(first)
            actionRun.finish(.done("Copied to the clipboard"), token: token); reflow(); return
        case .createNote:
            guard let text, !context.sensitive, let store = self.context else {
                actionRun.fail("There's no text to keep as a note.", token: token); reflow(); return
            }
            store.insert(Note(text: text)); save()
            actionRun.finish(.done("Saved as a note in Tools › Notes"), token: token); reflow(); return
        default: break
        }
        reflow()
        let urls = items.compactMap { shelf.resolve($0) }
        let link = first.linkURL
        actionTask = Task { [weak self] in
            do {
                let output = try await Self.execute(action, kind: context.kind, urls: urls, link: link, text: text) { value in
                    Task { @MainActor in self?.actionRun.progress(value, token: token) }
                }
                self?.finishAction(output, token: token)
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                self.actionRun.fail(error.localizedDescription, token: token); self.reflow()
            }
        }
    }

    private nonisolated static func execute(_ action: ContentAction, kind: ContentKind, urls: [URL], link: URL?, text: String?,
                                            progress: @escaping ActionExecutor.Progress) async throws -> ActionExecutor.Output {
        switch action {
        case .mergePDFs:
            return try await ActionExecutor.merge(urls, progress: progress)
        case .linkPreview:
            guard let link else { throw ActionExecutor.Failure.unsupported }
            return try await ActionExecutor.linkTitle(link)
        case .pdfText, .exportPages, .splitPages:
            guard let url = urls.first else { throw ActionExecutor.Failure.unreadable }
            return try await ActionExecutor.pdf(action, url: url, progress: progress)
        case .mediaInfo, .extractFrame, .convertM4A, .compressVideo:
            guard let url = urls.first else { throw ActionExecutor.Failure.unreadable }
            return try await ActionExecutor.media(action, url: url, progress: progress)
        case .extractText, .removeBackground, .convertPNG, .convertJPEG, .convertHEIC, .resizeHalf, .compress:
            guard let url = urls.first else { throw ActionExecutor.Failure.unreadable }
            return try await ActionExecutor.image(action, url: url)
        case .uppercase, .lowercase, .titleCase, .cleanWhitespace, .wordCount, .detectLanguage:
            guard let text else { throw ActionExecutor.Failure.noText }
            return try ActionExecutor.text(action, text)
        default:
            throw ActionExecutor.Failure.unsupported
        }
    }

    /// New files join the shelf as copies; a run that was cancelled or replaced meanwhile leaves nothing.
    private func finishAction(_ output: ActionExecutor.Output, token: Int) {
        guard actionRun.token == token, actionRun.isProcessing else { output.files.forEach(ShelfService.deleteCopy); return }
        if !output.files.isEmpty {
            let result = shelf.intake(output.files.map(ShelfIncoming.copy), origin: "action")
            actionCreated = result.added
            guard !result.added.isEmpty else {
                actionRun.fail(result.message ?? "The result couldn't be added to the shelf.", token: token); reflow(); return
            }
        }
        actionRun.finish(output.outcome, token: token)
        illuminate(.green)
        reflow()
    }

    func cancelAction() { actionTask?.cancel(); actionTask = nil; actionRun.cancel(); reflow() }
    func dismissActionResult() { actionRun.reset(); actionCreated = []; reflow() }

    /// Removes what the last action created, files and all.
    func undoAction() {
        shelf.discardCreated(actionCreated)
        actionCreated = []; actionRun.reset(); reflow()
    }

    func copyActionText() {
        guard case .completed(_, .text(let text)) = actionRun.phase, !text.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        illuminate(.silver)
    }

    func keepActionText(asNote: Bool) {
        guard case .completed(_, .text(let text)) = actionRun.phase, !text.isEmpty else { return }
        if asNote, let context {
            context.insert(Note(text: text)); save()
        } else {
            let result = shelf.intake([.text(text, rich: nil)], origin: "action")
            if result.added.isEmpty && result.duplicates == 0 { message = result.message; return }
        }
        illuminate(.green)
    }

    /// The text an item holds: its own text, or a small text file's contents.
    private func textContent(of item: ShelfFile) -> String? {
        switch item.kind {
        case .text: item.text
        case .link: item.text
        case .reference, .copy: shelf.resolve(item).flatMap(ContentInspector.text(of:))
        }
    }

    /// Opens an image file in the annotation editor used for screenshots.
    private func annotateFile(_ item: ShelfFile) {
        guard let url = shelf.resolve(item) else { message = "That file is no longer available."; return }
        Task { [weak self] in
            let described = await Task.detached(priority: .userInitiated) { ScreenshotService.describe(url) }.value
            guard let self, let described else { self?.message = "That image couldn't be read."; return }
            self.recognition?.cancel()
            self.capture = Capture(url: url, taken: item.addedAt, pixelSize: described.size,
                                   thumbnail: described.thumbnail.map { NSImage(cgImage: $0, size: .zero) })
            self.captureText = .idle; self.annotatedCopy = nil; self.annotations = AnnotationDocument()
            self.annotateCapture()
        }
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
        // A drag, an editor, the open workspace, the pointer or another glance keeps the surface; the screenshot
        // waits and appears when it's free, if it's still recent (see `resumeSurface`).
        if SurfaceArbiter.admit(.suggestion, into: surfaceOccupancy) == .wait { captureWaiting = true; illuminate(.silver); return }
        presentCapture()
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
            case .success(let copy):
                self.annotatedCopy = copy; self.illuminate(.green)
                // Annotating a shelf copy saves beside it, inside the shelf's folder: it joins the shelf
                // rather than being swept as an orphan at the next launch.
                if copy.standardizedFileURL.path.hasPrefix(ShelfService.folder.standardizedFileURL.path + "/") {
                    self.shelf.intake([.copy(copy)], origin: "action")
                }
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

    func startTimer(minutes: Int) { startFocus(seconds: Double(minutes * 60)) }
    func startFocus(seconds: TimeInterval) {
        countdown.start(seconds: seconds); focus.begin(at: Date()); persistTimer(); clock.run(true); reflow()
    }
    func toggleTimer() {
        if countdown.running { countdown.pause(); focus.pause(at: Date()) } else { countdown.resume(); focus.resume(at: Date()) }
        persistTimer(); clock.run(countdown.running); reflow()
    }
    /// Stopping early says what waited, if anything did; otherwise it ends quietly as before.
    func cancelTimer() {
        countdown.cancel(); persistTimer(); clock.run(false)
        if let summary = focus.end(at: Date(), completed: false), summary.waited > 0 { finishFocus(summary, at: Date()) }
        reflow()
    }
    private func tick(_ date: Date) {
        guard countdown.consumeCompletion(now: date) else { return }
        persistTimer(); clock.run(false)
        let summary = focus.end(at: date, completed: true) ?? FocusSummary(focused: 0, completed: true, updates: [], suggestions: 0)
        finishFocus(summary, at: date)
        if !preferences.quietMode { NSSound(named: "Glass")?.play() }
    }
    private func persistTimer() { UserDefaults.standard.set(try? JSONEncoder().encode(countdown), forKey: "countdown") }
    private func persistQueue() {
        // History on disk never holds pending requests or sensitive summaries.
        do { try ActivityEvent.encoder().encode(queue.historySafe).write(to: queueURL, options: .atomic) }
        catch { message = "Could not save activity history: \(error.localizedDescription)" }
    }

    // MARK: Work modes (Intent Switch)

    /// The inferred mode once it has settled (see `ModeTracker`), with its reason.
    @Published private(set) var modeReading = ModeReading.none
    private var modeTracker = ModeTracker()
    private var modeWork: DispatchWorkItem?
    private var frontmostName: String?

    /// What the notch is set up for: the pinned mode, else the inferred one, else General.
    var workMode: WorkMode { preferences.pinnedWorkMode ?? (preferences.workModesEnabled ? modeReading.mode : .general) }
    var workModeReason: String {
        if preferences.pinnedWorkMode != nil { return "Pinned" }
        return preferences.workModesEnabled ? modeReading.reason : "Following what you do is off"
    }
    /// A different reading that hasn't held long enough yet.
    var pendingModeReading: ModeReading? { modeTracker.pending }
    /// The resting hover says which mode it's in, when it isn't General and the drop tip isn't showing.
    var showsModeLine: Bool { workMode != .general && !(preferences.portalEnabled && !preferences.portalHintSeen) }

    /// Reads the signals the person allows and lets the tracker decide whether the mode changes now, later
    /// (it checks again when a pending change would settle), or not at all.
    private func updateWorkMode() {
        modeWork?.cancel(); modeWork = nil
        let previous = workMode
        if preferences.workModesEnabled, preferences.pinnedWorkMode == nil {
            let detectors = Set(ModeDetector.allCases).subtracting(preferences.modeDetectorsOff)
            let live: Set<ActivityState> = [.running, .waiting]
            let meeting = visibleActivities.first { $0.event.category == .meeting && live.contains($0.event.lifecycle) }?.event.title
            let signals = ModeSignals(appInFront: frontmostApp, appName: frontmostName, meeting: meeting,
                                      mediaPlaying: preferences.mediaEnabled && media.playing)
            _ = modeTracker.observe(ModeRules.read(signals, detectors: detectors), at: Date())
            if modeReading != modeTracker.current { modeReading = modeTracker.current }
            if let settles = modeTracker.settlesAt {
                let work = DispatchWorkItem { [weak self] in self?.updateWorkMode() }
                modeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, settles.timeIntervalSinceNow) + 0.1, execute: work)
            }
        }
        if workMode != previous { workModeChanged() }
    }

    private func workModeSettingsChanged() {
        let previous = workMode
        synchronizeContext()
        if workMode != previous { workModeChanged() } else { reflow() }
    }

    private func workModeChanged() {
        contextEngine.noteMode("Mode · \(workMode.title) · \(workModeReason)")
        applyContextBoost()
        if interaction.presentation != .expanded { reflow() }
    }

    /// Keeps the current mode, or goes back to following what the person does.
    func togglePinnedWorkMode() {
        preferences.pinnedWorkMode = preferences.pinnedWorkMode == nil ? workMode : nil
    }

    #if DEBUG
    func debugSetModeSettle(_ seconds: TimeInterval) { modeTracker.settle = seconds }
    #endif

    // MARK: Suggestions

    /// What a suggestion's action left behind, shown in the same glance for a few seconds.
    struct SuggestionResult: Equatable {
        let title: String
        let detail: String?
        let failed: Bool
        let canUndo: Bool
    }
    @Published private(set) var suggestion: Suggestion?
    @Published private(set) var suggestionResult: SuggestionResult?
    /// "Why this suggestion?" is open.
    @Published private(set) var suggestionWhy = false
    private var suggestionUndo: (() -> Void)?
    /// One suggestion waits at most, until the surface is free or it expires; a newer one replaces it.
    private(set) var pendingSuggestion: Suggestion?
    private var suggestionWork: DispatchWorkItem?
    private var intent = IntentEngine(learning: AppModel.storedLearning())
    private var frontmostApp: String?
    private lazy var suggestionRunner = SuggestionActionRunner(clipboard: clipboard, shelf: shelf, calendar: calendar,
                                                              notes: { [weak self] in self?.context }, save: { [weak self] in self?.save() })

    var suggestionShowing: Bool { if case .suggestion = glance { return true }; return false }
    /// Per-rule counts, for Settings.
    var learnedRules: [String: RuleStats] { intent.learning.rules }

    /// Starts and stops observers to match what's turned on. Nothing is observed for a feature that's off.
    private func synchronizeContext() {
        let suggesting = preferences.suggestionsEnabled && preferences.clipboardSuggestions
        let modesWatchApps = preferences.workModesEnabled && preferences.pinnedWorkMode == nil && !preferences.modeDetectorsOff.contains(.apps)
        contextEngine.setEnabled(.frontmostApp, preferences.contextAware || modesWatchApps)
        contextEngine.setEnabled(.clipboard, suggesting)
        contextEngine.setEnabled(.downloads, preferences.suggestionsEnabled && preferences.downloadSuggestions)
        configureClipboard()
        if !contextEngine.isRunning(.frontmostApp) { frontmostApp = nil; frontmostName = nil }
        updateWorkMode()
        applyContextBoost()
        if !suggesting { pendingSuggestion = nil; closeSuggestion(.superseded) }
    }

    private func contextEvent(_ event: ContextEvent) {
        switch event.signal {
        case .frontmostApp(let bundleID, let name):
            frontmostApp = bundleID; frontmostName = name
            updateWorkMode()
            applyContextBoost()
        case .clipboard:
            let decision = intent.evaluate(event, in: intentSituation)
            contextEngine.record(decision)
            if case .suggest(let suggestion) = decision { offer(suggestion) }
            if case .hold(.focusSession, _, _) = decision { focus.note(id: event.id.uuidString, kind: .suggestion, title: event.redactedSummary) }
        case .download:
            // A download held by a focus session is counted as the update it also is, not twice.
            let decision = intent.evaluate(event, in: intentSituation)
            contextEngine.record(decision)
            if case .suggest(let suggestion) = decision { offer(suggestion); downloadSuggested = true }
        }
    }

    private var intentSituation: IntentSituation {
        IntentSituation(enabled: preferences.suggestionsEnabled, sensitivity: preferences.suggestionSensitivity,
                        disabledCategories: preferences.suggestionCategoriesOff, quiet: preferences.quietMode, privateMode: preferences.privacy,
                        quietHours: preferences.quietHoursEnabled ? QuietHours(start: preferences.quietHoursStart, end: preferences.quietHoursEnd) : nil,
                        mode: workMode, focusing: focusing)
    }

    /// Who has the surface, in `SurfaceArbiter`'s terms.
    private var surfaceOccupancy: SurfaceOccupancy {
        let interacting = interaction.dragging || interaction.editing || interaction.portal != .closed
            || interaction.presentation == .expanded || windows?.pointerInside == true
        let showing: SurfaceTier? = switch glance {
        case .summary: nil
        case .notification(let id): record(id).map { AttentionPriority(state: $0.event.lifecycle).surfaceTier } ?? .passive
        case .capture, .suggestion: .suggestion
        case .sound: .passive
        }
        return SurfaceOccupancy(interacting: interacting, showing: showing)
    }

    private func offer(_ suggestion: Suggestion) {
        // A newer copy replaces the suggestion on screen in place; the older one was superseded, not dismissed.
        if suggestionShowing, let current = self.suggestion {
            if suggestionResult == nil { resolve(current, .superseded) }
            showSuggestion(suggestion)
            return
        }
        switch SurfaceArbiter.admit(.suggestion, into: surfaceOccupancy) {
        case .show: showSuggestion(suggestion)
        case .wait: pendingSuggestion = suggestion
        }
    }

    private func showSuggestion(_ suggestion: Suggestion) {
        pendingSuggestion = nil
        suggestionWork?.cancel()
        intent.presented(suggestion, at: Date())
        var next = snapshot
        if next.interaction.presentation == .collapsed { next.interaction.send(.attention) }
        // Set before the glance changes, so replacing one suggestion with another isn't read as being superseded.
        commit(next, also: {
            self.suggestion = suggestion; self.suggestionResult = nil; self.suggestionUndo = nil; self.suggestionWhy = false
            self.glance = .suggestion(suggestion.id)
        })
        illuminate(.silver)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(suggestion.title). Suggested: \(suggestion.actions.first?.title ?? "")",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        scheduleSuggestionClose(after: 7)
    }

    /// The glance leaves on its own after a while, but never from under the pointer.
    private func scheduleSuggestionClose(after delay: TimeInterval) {
        suggestionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.suggestionShowing else { return }
            if self.windows?.pointerInside == true { self.scheduleSuggestionClose(after: 2); return }
            self.closeSuggestion(.ignored)
        }
        suggestionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func dismissSuggestion() { closeSuggestion(.dismissed) }

    /// Closes the glance. What happened is learned only if no action was chosen yet; nil means it already was.
    private func closeSuggestion(_ outcome: SuggestionOutcome?) {
        suggestionWork?.cancel()
        guard suggestionShowing else { return }
        var next = snapshot
        if next.interaction.presentation == .preview, windows?.pointerInside != true { next.interaction.send(.leave) }
        commit(next, also: { self.retireSuggestion(outcome); self.glance = .summary })
    }

    /// Records the outcome and clears the suggestion, without touching the surface.
    private func retireSuggestion(_ outcome: SuggestionOutcome?) {
        if let outcome, let suggestion, suggestionResult == nil { resolve(suggestion, outcome) }
        suggestion = nil; suggestionResult = nil; suggestionUndo = nil; suggestionWhy = false
    }

    /// Something else took the glance (see `glance`).
    private func suggestionLeftSurface() {
        suggestionWork?.cancel()
        retireSuggestion(.superseded)
    }

    /// Set while a finished download is evaluated, when it produced a suggestion.
    private var downloadSuggested = false

    /// A finished download that a suggestion fits shows that suggestion instead of its plain notice, so it's
    /// offered once. Otherwise (no rule fits, cooling down, suggestions off) the notice shows as before.
    private func suggestForDownload(_ event: ActivityEvent) -> Bool {
        guard event.kind == .download, event.lifecycle == .completed, contextEngine.isRunning(.downloads),
              let string = event.actionURL, let url = URL(string: string), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return false }
        downloadSuggested = false
        defer { downloadSuggested = false }
        downloadObserver.finished(DownloadInspector.signal(for: url))
        return downloadSuggested
    }

    private func resolve(_ suggestion: Suggestion, _ outcome: SuggestionOutcome) {
        intent.resolve(suggestion, outcome, at: Date())
        contextEngine.record(outcome, for: suggestion)
        if outcome != .superseded { persistLearning() }
    }

    func toggleSuggestionWhy() {
        guard suggestionShowing, suggestionResult == nil else { return }
        commit(snapshot, also: { self.suggestionWhy.toggle() })
        scheduleSuggestionClose(after: 10)
    }

    /// Runs one of the suggestion's actions, after `ActionGuard` clears it. A missing permission is asked
    /// for here, in context, and the action continues once it's granted.
    func runSuggestion(_ action: SuggestedAction) {
        guard let suggestion, suggestion.actions.contains(action), suggestionResult == nil else { return }
        switch ActionGuard.clearance(for: ActionCatalog.descriptor(for: action), granted: grantedActionPermissions, confirmed: false) {
        case .needsPermission(let missing):
            suggestionWork?.cancel()
            requestPermissions(missing) { [weak self] granted in
                guard let self, self.suggestion?.id == suggestion.id else { return }
                if granted { self.runSuggestion(action); return }
                let names = missing.map(\.title).sorted().joined(separator: ", ")
                self.showSuggestionResult(.failed("NotchFlow needs access to \(names). Allow it in System Settings › Privacy & Security."))
            }
            return
        case .needsConfirmation:
            // No suggested action needs it today. One that ever does is refused rather than run unasked.
            showSuggestionResult(.failed("That needs a confirmation the notch can't ask for yet."))
            return
        case .run:
            break
        }
        resolve(suggestion, .accepted)
        showSuggestionResult(suggestionRunner.run(action))
    }

    private func showSuggestionResult(_ result: SuggestionActionRunner.Result) {
        switch result {
        case .handedOff:
            // Another app has it now; the acceptance was already recorded.
            illuminate(.green)
            closeSuggestion(nil)
        case .done(let title, let detail, let undo):
            illuminate(.green)
            suggestionUndo = undo
            commit(snapshot, also: { self.suggestionWhy = false
                self.suggestionResult = SuggestionResult(title: title, detail: detail, failed: false, canUndo: undo != nil) })
            scheduleSuggestionClose(after: undo == nil ? 2.5 : 5)
        case .openActions(let ids, let then):
            // On the shelf now; its actions open in the workspace, as they do for a drop.
            closeSuggestion(nil)
            openActions(ids, then: then)
        case .failed(let message):
            commit(snapshot, also: { self.suggestionWhy = false
                self.suggestionResult = SuggestionResult(title: "Couldn't do that", detail: message, failed: true, canUndo: false) })
            scheduleSuggestionClose(after: 6)
        }
    }

    func undoSuggestion() {
        guard let undo = suggestionUndo else { return }
        suggestionUndo = nil
        undo()
        commit(snapshot, also: { self.suggestionResult = SuggestionResult(title: "Undone", detail: nil, failed: false, canUndo: false) })
        scheduleSuggestionClose(after: 1.6)
    }

    private var grantedActionPermissions: Set<ActionPermission> {
        calendar.remindersAllowed ? [.reminders] : []
    }

    /// Only Reminders is asked for from a suggestion; other permissions are asked where their feature lives.
    private func requestPermissions(_ missing: Set<ActionPermission>, then completion: @escaping (Bool) -> Void) {
        guard missing == [.reminders] else { completion(false); return }
        calendar.connectReminders(then: completion)
    }

    func resetSuggestionLearning() { intent.reset(); persistLearning(); objectWillChange.send() }
    func unmuteSuggestions(_ rule: String) { intent.learning.unmute(rule); persistLearning(); objectWillChange.send() }

    private nonisolated static func storedLearning() -> IntentLearning {
        guard let data = UserDefaults.standard.data(forKey: "intentLearning"),
              let learning = try? JSONDecoder().decode(IntentLearning.self, from: data) else { return IntentLearning() }
        return learning
    }
    private func persistLearning() {
        UserDefaults.standard.set(try? JSONEncoder().encode(intent.learning), forKey: "intentLearning")
    }

    // MARK: Flow Guardian

    /// What waited during the current focus session (see `FocusLedger`).
    private(set) var focus = FocusLedger()
    /// The last session's summary and the History record that carries it.
    private(set) var focusSummary: (record: String, waited: Int, updates: [String], detail: String)?
    /// Holding back what doesn't need the person: a focus timer is running and Flow Guardian is on.
    var focusing: Bool { preferences.flowGuardian && focus.focusing }

    /// The session's end, as the existing "Focus session finished" moment, now saying what waited. What waited
    /// isn't replayed one glance at a time: it's in the stack and History, and Review goes there.
    private func finishFocus(_ summary: FocusSummary, at date: Date) {
        for id in summary.updates { attention.discard(id: id) }
        let id = UUID().uuidString
        focusSummary = ("timer:" + id, summary.waited, summary.updates, summary.detail)
        contextEngine.noteMode("Focus · \(summary.title) · \(summary.detail)")
        ingest(ActivityEvent(source: "timer", activityId: id, phase: .completed, title: summary.title, summary: summary.detail, timestamp: date))
    }

    /// Opens what waited: the stack if any of it is still going, otherwise History.
    func reviewFocusSession() {
        let live = Set(visibleActivities.map(\.id))
        let target: Route = focusSummary?.updates.contains(where: live.contains) == true ? .activity(detail: nil) : .history(detail: nil)
        dismissNotification()
        navigate(target)
        windows?.focus()
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
            CommandItem(id: "timeline", title: "Time Travel", symbol: "clock.arrow.circlepath", hint: "⌘Y") { [weak self] in self?.openTimeline() },
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
        for mode in WorkMode.allCases where preferences.pinnedWorkMode != mode {
            items.append(CommandItem(id: "workmode-\(mode.rawValue)", title: "Pin \(mode.title) work mode", symbol: mode.symbol, hint: "Work mode") { [weak self] in
                self?.preferences.pinnedWorkMode = mode
            })
        }
        if preferences.pinnedWorkMode != nil {
            items.append(CommandItem(id: "workmode-auto", title: "Follow what I'm doing", symbol: "wand.and.rays", hint: "Work mode") { [weak self] in
                self?.preferences.pinnedWorkMode = nil
            })
        }
        let suggesting = preferences.suggestionsEnabled && preferences.clipboardSuggestions
        items.append(CommandItem(id: "suggestions", title: suggesting ? "Turn off copy suggestions" : "Turn on copy suggestions",
                                 symbol: "sparkles", hint: "Suggestions") { [weak self] in
            guard let preferences = self?.preferences else { return }
            if suggesting { preferences.clipboardSuggestions = false } else { preferences.suggestionsEnabled = true; preferences.clipboardSuggestions = true }
        })
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
        clock.run(false); providers.stopAll(); contextEngine.stopAll(); approvals.withdraw(); screenshots.stop(); recognition?.cancel(); sound.stop()
        media.stop(); camera.stop(); backdrop.stop(); battery.stop()
    }
}

extension Notification.Name {
    static let openNotchFlowSettings = Notification.Name("io.notchflow.openSettings")
}
