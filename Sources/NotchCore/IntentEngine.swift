import Foundation

// The Intent Engine: from one context event to at most one suggested next step. Rules first and
// deterministic. The score is a sum of named parts, so "Why this suggestion?" is the score itself, and
// every reason something was held back is reported too. No model, no network, no content kept.

/// Kinds of suggestion a person can turn off one at a time.
public enum SuggestionCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case links, colors, data, places, dates, contacts, files, text, downloads
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .links: "Links"
        case .colors: "Colors"
        case .data: "JSON"
        case .places: "Addresses"
        case .dates: "Dates"
        case .contacts: "Email and phone"
        case .files: "File paths"
        case .text: "Long text"
        case .downloads: "Downloads"
        }
    }
    public var summary: String {
        switch self {
        case .links: "Open a link, or copy it without tracking parameters"
        case .colors: "Copy a color as hex, RGB or HSL"
        case .data: "Copy JSON formatted or minified"
        case .places: "Open an address in Maps"
        case .dates: "Get a reminder for a date or time"
        case .contacts: "Write to an email address or call a number"
        case .files: "Show a copied path in Finder"
        case .text: "Keep a long passage on the shelf or as a note"
        case .downloads: "Extract a downloaded archive, or open Actions for a PDF, image or video"
        }
    }
}

public enum SuggestionSensitivity: String, Codable, Sendable, CaseIterable, Identifiable {
    case fewer, balanced, more
    public var id: String { rawValue }
    public var title: String {
        switch self { case .fewer: "Fewer"; case .balanced: "Balanced"; case .more: "More" }
    }
    /// The score a suggestion needs before it's shown.
    public var threshold: Double {
        switch self { case .fewer: 0.72; case .balanced: 0.6; case .more: 0.48 }
    }
}

/// One step the notch can offer. Each case has a declared capability in `ActionCatalog`.
public enum SuggestedAction: Hashable, Sendable {
    case openURL(URL)
    /// Puts text on the clipboard; `label` says what it is ("Copy Clean Link").
    case copyText(String, label: String)
    case openMaps(String)
    case composeEmail(String)
    case call(String)
    case remind(title: String, due: Date)
    case reveal(path: String)
    case openFile(path: String)
    case keepOnShelf(String)
    case newNote(String)
    /// Expands a downloaded archive next to itself with Archive Utility. The archive is kept.
    case extractArchive(path: String)
    /// Keeps a file on the shelf by reference and opens Notch Actions for it, starting `then` if given.
    case openActions(path: String, then: ContentAction?)
    /// Keeps text or a link on the shelf and opens Notch Actions for it, starting `then` (a link's QR code).
    case keepAndAct(String, then: ContentAction)

    public var title: String {
        switch self {
        case .openURL: "Open"
        case .copyText(_, let label): label
        case .openMaps: "Open in Maps"
        case .composeEmail: "New Email"
        case .call: "Call"
        case .remind: "Remind Me"
        case .reveal: "Show in Finder"
        case .openFile: "Open"
        case .keepOnShelf: "Keep on Shelf"
        case .newNote: "New Note"
        case .extractArchive: "Extract"
        case .openActions(_, let then): then?.title ?? "Actions…"
        case .keepAndAct(_, let then): then.title
        }
    }
    public var symbol: String {
        switch self {
        case .openURL: "arrow.up.forward.square"
        case .copyText: "doc.on.doc"
        case .openMaps: "map"
        case .composeEmail: "envelope"
        case .call: "phone"
        case .remind: "bell"
        case .reveal: "folder"
        case .openFile: "arrow.up.forward.app"
        case .keepOnShelf: "tray.and.arrow.down"
        case .newNote: "square.and.pencil"
        case .extractArchive: "archivebox"
        case .openActions: "wand.and.stars"
        case .keepAndAct(_, let then): then == .qrCode ? "qrcode" : "wand.and.stars"
        }
    }
}

public struct ScoreComponent: Equatable, Sendable {
    public var label: String
    public var value: Double
    public init(_ label: String, _ value: Double) { self.label = label; self.value = value }
}

public struct Suggestion: Equatable, Sendable, Identifiable {
    public let id: UUID
    /// The rule that made it; learning is kept per rule.
    public let rule: String
    public let category: SuggestionCategory
    public let title: String
    public let detail: String
    public let symbol: String
    /// One to three steps, the first is the primary one.
    public let actions: [SuggestedAction]
    /// "Why this suggestion?", in plain words.
    public let reason: String
    public let components: [ScoreComponent]
    public let created: Date
    /// After this, a suggestion still waiting for the surface is dropped.
    public let expires: Date
    /// A color shown as a swatch.
    public let swatch: ColorValue?
    let dedupeKey: Int

    public var score: Double { components.reduce(0) { $0 + $1.value } }
}

public enum HoldReason: Equatable, Sendable {
    case predictionsOff
    case detailsHidden
    case quiet
    case quietHours
    case focusSession
    case nothingToOffer
    case categoryOff(SuggestionCategory)
    case muted
    case coolingDown(until: Date)
    case alreadySuggested
    case hourlyLimit
    case belowThreshold(score: Double, threshold: Double)

    public var explanation: String {
        switch self {
        case .predictionsOff: "Suggestions are off"
        case .detailsHidden: "Private details are hidden"
        case .quiet: "Quiet mode is on"
        case .quietHours: "Quiet hours"
        case .focusSession: "A focus session is running"
        case .nothingToOffer: "Nothing useful to suggest"
        case .categoryOff(let category): "\(category.title) suggestions are off"
        case .muted: "Muted after repeated dismissals"
        case .coolingDown: "This kind of suggestion is cooling down"
        case .alreadySuggested: "Already suggested for this content"
        case .hourlyLimit: "Hourly limit reached"
        case .belowThreshold(let score, let threshold): String(format: "Score %.2f is below %.2f", score, threshold)
        }
    }
}

public enum IntentDecision: Equatable, Sendable {
    case suggest(Suggestion)
    /// Held back, with the rule and score that were considered when there was one.
    case hold(HoldReason, rule: String?, components: [ScoreComponent])
}

public enum SuggestionOutcome: String, Codable, Sendable {
    /// One of its actions was used.
    case accepted
    /// Closed with its dismiss button.
    case dismissed
    /// Left on its own without a choice.
    case ignored
    /// Replaced by something more important. Teaches nothing.
    case superseded
}

/// When suggestions stay away, by hour of day. `start == end` means never.
public struct QuietHours: Equatable, Codable, Sendable {
    public var start: Int, end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard start != end else { return false }
        let hour = calendar.component(.hour, from: date)
        return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }
}

/// What the person allows and is doing when an event arrives.
public struct IntentSituation: Sendable {
    public var enabled: Bool
    public var sensitivity: SuggestionSensitivity
    public var disabledCategories: Set<SuggestionCategory>
    public var quiet: Bool
    /// Private details hidden, for example while presenting. Content signals are ignored.
    public var privateMode: Bool
    public var quietHours: QuietHours?
    /// The work mode (see `WorkMode`): it tilts some kinds of suggestion up, and quiets them during calls.
    public var mode: WorkMode
    /// A focus session is running: suggestions wait for its end (see `FocusLedger`).
    public var focusing: Bool
    public var calendar: Calendar
    public init(enabled: Bool = true, sensitivity: SuggestionSensitivity = .balanced, disabledCategories: Set<SuggestionCategory> = [],
                quiet: Bool = false, privateMode: Bool = false, quietHours: QuietHours? = nil, mode: WorkMode = .general,
                focusing: Bool = false, calendar: Calendar = .current) {
        self.enabled = enabled; self.sensitivity = sensitivity; self.disabledCategories = disabledCategories
        self.quiet = quiet; self.privateMode = privateMode; self.quietHours = quietHours; self.mode = mode; self.focusing = focusing; self.calendar = calendar
    }
}

/// Per-rule counts, kept on this Mac and resettable. No content, no app names, no history of events.
public struct RuleStats: Codable, Equatable, Sendable {
    public var accepted = 0
    public var dismissed = 0
    public var ignored = 0
    public var consecutiveDismissals = 0
    public var lastDismissed: Date?
    public init() {}
}

public struct IntentLearning: Codable, Equatable, Sendable {
    public private(set) var rules: [String: RuleStats] = [:]
    /// Dismissed this many times in a row, a rule stays quiet until learning is reset.
    public static let muteAfter = 5
    public init() {}

    public func stats(_ rule: String) -> RuleStats { rules[rule] ?? RuleStats() }

    /// −0.3…+0.2 from what happened to this rule's suggestions before. Ignoring counts a third as much
    /// as dismissing; nothing at all counts zero.
    public func adjustment(for rule: String) -> Double {
        let stats = stats(rule)
        let negative = Double(stats.dismissed) + Double(stats.ignored) / 3
        let seen = Double(stats.accepted) + negative
        guard seen > 0 else { return 0 }
        return min(0.2, max(-0.3, (Double(stats.accepted) - negative) / (seen + 2) * 0.4))
    }

    /// How long a rule waits after being dismissed: 2, 4, 8, 16 minutes for one to four in a row.
    public func backoff(for rule: String) -> TimeInterval {
        let streak = stats(rule).consecutiveDismissals
        return streak == 0 ? 0 : 120 * pow(2, Double(min(streak, Self.muteAfter) - 1))
    }

    public func isMuted(_ rule: String) -> Bool { stats(rule).consecutiveDismissals >= Self.muteAfter }

    public mutating func record(_ outcome: SuggestionOutcome, rule: String, at date: Date) {
        var stats = stats(rule)
        switch outcome {
        case .accepted: stats.accepted += 1; stats.consecutiveDismissals = 0
        case .dismissed: stats.dismissed += 1; stats.consecutiveDismissals += 1; stats.lastDismissed = date
        case .ignored: stats.ignored += 1
        case .superseded: return
        }
        rules[rule] = stats
    }

    /// Brings a muted rule back by forgetting its dismissals; what was accepted is kept.
    public mutating func unmute(_ rule: String) {
        guard var stats = rules[rule] else { return }
        stats.dismissed = 0; stats.consecutiveDismissals = 0; stats.lastDismissed = nil
        rules[rule] = stats
    }
    public mutating func reset() { rules = [:] }
}

/// Recent prompts, for the hourly cap and repeats. Memory only: keys are hashes of content.
public struct IntentSession: Sendable {
    var shown: [Date] = []
    var keys: [Int: Date] = [:]
    var lastByRule: [String: Date] = [:]
    public init() {}
    mutating func prune(_ now: Date, keep window: TimeInterval) {
        shown.removeAll { now.timeIntervalSince($0) > 3600 }
        keys = keys.filter { now.timeIntervalSince($0.value) < window }
    }
    func shownInLastHour(_ now: Date) -> Int { shown.filter { now.timeIntervalSince($0) <= 3600 }.count }
}

public struct IntentEngine: Sendable {
    public var learning: IntentLearning
    public private(set) var session = IntentSession()
    /// Suggestions shown per hour at most.
    public var hourlyLimit = 6
    /// The same rule doesn't suggest again sooner than this.
    public var ruleRepeat: TimeInterval = 20
    /// The same content isn't suggested twice within this.
    public var dedupeWindow: TimeInterval = 600
    /// How long a suggestion may wait for the surface before it's dropped.
    public var lifetime: TimeInterval = 45

    public init(learning: IntentLearning = IntentLearning()) { self.learning = learning }

    public mutating func evaluate(_ event: ContextEvent, in situation: IntentSituation) -> IntentDecision {
        let now = event.timestamp
        session.prune(now, keep: dedupeWindow)
        guard situation.enabled else { return .hold(.predictionsOff, rule: nil, components: []) }
        if event.privacy == .content && situation.privateMode { return .hold(.detailsHidden, rule: nil, components: []) }
        if situation.quiet { return .hold(.quiet, rule: nil, components: []) }
        if let hours = situation.quietHours, hours.contains(now, calendar: situation.calendar) {
            return .hold(.quietHours, rule: nil, components: [])
        }
        if situation.focusing, event.privacy == .content { return .hold(.focusSession, rule: nil, components: []) }
        let found: IntentRules.Candidate? = switch event.signal {
        case .clipboard(let clip): IntentRules.candidate(for: clip, now: now, calendar: situation.calendar)
        case .download(let download): IntentRules.candidate(for: download)
        case .frontmostApp: nil
        }
        guard let candidate = found else { return .hold(.nothingToOffer, rule: nil, components: []) }
        let rule = candidate.rule
        var components = [ScoreComponent("Matches \(candidate.matchLabel)", candidate.base * candidate.confidence)] + candidate.adjustments
        let tilt = situation.mode.suggestionAdjustment(for: candidate.category)
        if tilt != 0 { components.append(ScoreComponent(situation.mode == .meeting ? "In a call" : "\(situation.mode.title) mode", tilt)) }
        let learned = learning.adjustment(for: rule)
        if learned != 0 { components.append(ScoreComponent(learned > 0 ? "You often use these" : "You often dismiss these", learned)) }
        let recent = session.shownInLastHour(now)
        if recent > 0 { components.append(ScoreComponent("\(recent) shown in the last hour", -0.05 * Double(recent))) }
        func hold(_ reason: HoldReason) -> IntentDecision { .hold(reason, rule: rule, components: components) }

        if situation.disabledCategories.contains(candidate.category) { return hold(.categoryOff(candidate.category)) }
        if learning.isMuted(rule) { return hold(.muted) }
        if let dismissed = learning.stats(rule).lastDismissed, now < dismissed.addingTimeInterval(learning.backoff(for: rule)) {
            return hold(.coolingDown(until: dismissed.addingTimeInterval(learning.backoff(for: rule))))
        }
        if let last = session.lastByRule[rule], now.timeIntervalSince(last) < ruleRepeat {
            return hold(.coolingDown(until: last.addingTimeInterval(ruleRepeat)))
        }
        if session.keys[candidate.dedupeKey] != nil { return hold(.alreadySuggested) }
        if recent >= hourlyLimit { return hold(.hourlyLimit) }
        let score = components.reduce(0) { $0 + $1.value }
        let threshold = situation.sensitivity.threshold
        guard score >= threshold else { return hold(.belowThreshold(score: score, threshold: threshold)) }

        session.keys[candidate.dedupeKey] = now
        session.lastByRule[rule] = now
        let reason = [candidate.reason, learningNote(rule, learned)].compactMap { $0 }.joined(separator: " ")
        return .suggest(Suggestion(id: UUID(), rule: rule, category: candidate.category, title: candidate.title,
                                   detail: candidate.detail, symbol: candidate.symbol, actions: candidate.actions,
                                   reason: reason, components: components, created: now,
                                   expires: now.addingTimeInterval(lifetime), swatch: candidate.swatch,
                                   dedupeKey: candidate.dedupeKey))
    }

    /// The suggestion reached the surface; it counts toward the hourly cap.
    public mutating func presented(_ suggestion: Suggestion, at date: Date) { session.shown.append(date) }

    public mutating func resolve(_ suggestion: Suggestion, _ outcome: SuggestionOutcome, at date: Date) {
        learning.record(outcome, rule: suggestion.rule, at: date)
    }

    /// Starts over: forgets what was learned and what was suggested recently.
    public mutating func reset() {
        learning.reset()
        session = IntentSession()
    }

    private func learningNote(_ rule: String, _ adjustment: Double) -> String? {
        let stats = learning.stats(rule)
        if adjustment > 0, stats.accepted > 0 { return "You've used \(stats.accepted) like it before." }
        if adjustment < 0 { return "Shown less often because you've closed similar ones." }
        return nil
    }
}

/// The rules. Each turns one detected entity into a candidate with a base score, the actions that fit,
/// and its reason. Context can lower or raise a candidate; it can't invent one.
enum IntentRules {
    struct Candidate {
        var rule: String
        var category: SuggestionCategory
        var base: Double
        var confidence: Double
        var matchLabel: String
        var adjustments: [ScoreComponent] = []
        var title: String
        var detail: String
        var symbol: String
        var actions: [SuggestedAction]
        var reason: String
        var swatch: ColorValue?
        var dedupeKey: Int
    }

    static let finder = "com.apple.finder"

    static func candidate(for clip: ClipboardSignal, now: Date, calendar: Calendar) -> Candidate? {
        let detection = ClipEntityDetector.detect(clip.text, calendar: calendar)
        let text = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let from = clip.sourceName.map { " in \($0)" } ?? ""
        let key = text.hashValue
        func make(_ rule: String, _ category: SuggestionCategory, base: Double, match: String, title: String, detail: String,
                  symbol: String, actions: [SuggestedAction], reason: String) -> Candidate {
            Candidate(rule: rule, category: category, base: base, confidence: detection.confidence, matchLabel: match, title: title,
                      detail: detail, symbol: symbol, actions: actions, reason: reason, dedupeKey: key)
        }
        switch detection.entity {
        case .link(let url):
            let cleaned = LinkCleaner.clean(url)
            let trackers = LinkCleaner.trackerCount(url)
            let inBrowser = clip.sourceApp.map(ContextRules.browsers.contains) ?? false
            var actions: [SuggestedAction] = []
            if let cleaned { actions.append(.copyText(cleaned.absoluteString, label: "Copy Clean Link")) }
            // Copied from a browser, the page is already open there.
            if !inBrowser { actions.append(.openURL(url)) }
            actions.append(.keepOnShelf(text))
            // QR Bridge: a code for the link, made on this Mac, to scan from a phone.
            actions.append(.keepAndAct(text, then: .qrCode))
            var candidate = make("clipboard.link", .links, base: 0.7, match: "a web link",
                                 title: cleaned == nil ? "Link copied" : "Link with \(trackers) \(trackers == 1 ? "tracker" : "trackers")",
                                 detail: shortLink(url) + (clip.sourceName.map { " · \($0)" } ?? ""), symbol: "link", actions: actions,
                                 reason: "You copied a web link\(from)." + (cleaned == nil ? "" : " It carries tracking parameters that Copy Clean Link removes."))
            if inBrowser && cleaned == nil { candidate.adjustments.append(ScoreComponent("Already open in the browser", -0.25)) }
            if cleaned != nil { candidate.adjustments.append(ScoreComponent("Has tracking parameters", 0.08)) }
            return candidate
        case .color(let color):
            var actions: [SuggestedAction] = []
            if color.notation != .hex { actions.append(.copyText(color.hex, label: "Copy as Hex")) }
            if color.notation != .rgb { actions.append(.copyText(color.rgb, label: "Copy as RGB")) }
            actions.append(.copyText(color.hsl, label: "Copy as HSL"))
            var candidate = make("clipboard.color", .colors, base: 0.75, match: "a color value", title: "Color \(color.hex)",
                                 detail: color.notation == .hex ? color.rgb : color.hex, symbol: "paintpalette", actions: actions,
                                 reason: "You copied a color\(from).")
            candidate.swatch = color
            return candidate
        case .json:
            guard let pretty = JSONFormatter.pretty(text), let minified = JSONFormatter.minified(text) else { return nil }
            var actions: [SuggestedAction] = []
            if pretty != text { actions.append(.copyText(pretty, label: "Copy Formatted")) }
            if minified != text { actions.append(.copyText(minified, label: "Copy Minified")) }
            guard !actions.isEmpty else { return nil }
            let count = JSONFormatter.topLevelCount(text) ?? 0
            let shape = text.hasPrefix("[") ? "\(count) \(count == 1 ? "item" : "items")" : "\(count) \(count == 1 ? "key" : "keys")"
            return make("clipboard.json", .data, base: 0.7, match: "a JSON document", title: "JSON copied",
                        detail: "\(shape) · \(text.count) characters", symbol: "curlybraces", actions: actions,
                        reason: "You copied valid JSON\(from). Formatting keeps every key in its order.")
        case .address(let address):
            return make("clipboard.address", .places, base: 0.68, match: "a street address", title: "Address copied",
                        detail: oneLine(address, limit: 60), symbol: "mappin.and.ellipse", actions: [.openMaps(oneLine(address, limit: 200))],
                        reason: "You copied what looks like an address\(from).")
        case .date(let date, let hasTime):
            guard date > now else { return nil }
            var candidate = make("clipboard.date", .dates, base: 0.55, match: "a date", title: "Date copied",
                                 detail: DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: hasTime ? .short : .none),
                                 symbol: "calendar.badge.clock", actions: [.remind(title: oneLine(text, limit: 80), due: date)],
                                 reason: "You copied a date\(from)" + (hasTime ? "." : ". Without a time, the reminder is set for 9:00."))
            if date.timeIntervalSince(now) <= 7 * 86_400 { candidate.adjustments.append(ScoreComponent("Within the next week", 0.1)) }
            return candidate
        case .email(let address):
            return make("clipboard.email", .contacts, base: 0.6, match: "an email address", title: "Email address copied",
                        detail: address, symbol: "envelope", actions: [.composeEmail(address)], reason: "You copied an email address\(from).")
        case .phone(let number):
            return make("clipboard.phone", .contacts, base: 0.55, match: "a phone number", title: "Phone number copied",
                        detail: number, symbol: "phone", actions: [.call(number)], reason: "You copied a phone number\(from).")
        case .filePath:
            guard let path = clip.existingPath else { return nil }
            var candidate = make("clipboard.path", .files, base: 0.65, match: "a path to an existing file", title: "Path copied",
                                 detail: (path as NSString).abbreviatingWithTildeInPath, symbol: "folder",
                                 actions: [.reveal(path: path), .openFile(path: path)], reason: "You copied the path of something on this Mac\(from).")
            // The observer found it on disk, so it's certainly a path.
            candidate.confidence = 1
            if clip.sourceApp == finder { candidate.adjustments.append(ScoreComponent("Already in Finder", -0.25)) }
            return candidate
        case .prose(let words):
            return make("clipboard.prose", .text, base: 0.62, match: "a long passage", title: "Long text copied",
                        detail: "\(words) words" + (clip.sourceName.map { " · \($0)" } ?? ""), symbol: "text.alignleft",
                        actions: [.keepOnShelf(text), .newNote(text)], reason: "You copied \(words) words\(from).")
        case .code, .plain:
            // Code and short text are copied constantly; suggesting something every time would be noise.
            return nil
        }
    }

    /// A finished download: an archive to expand, or a PDF, image or video for Notch Actions. Other files keep
    /// the download's own glance with Show in Finder, so nothing is offered twice.
    static func candidate(for download: DownloadSignal) -> Candidate? {
        let size = download.byteCount.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        let reveal = SuggestedAction.reveal(path: download.path)
        func make(_ rule: String, base: Double, title: String, symbol: String, actions: [SuggestedAction], reason: String) -> Candidate {
            Candidate(rule: rule, category: .downloads, base: base, confidence: 1, matchLabel: "a finished download", title: title,
                      detail: oneLine(download.name, limit: 40) + size, symbol: symbol, actions: actions, reason: reason,
                      dedupeKey: download.path.hashValue)
        }
        if download.isArchive {
            return make("download.archive", base: 0.75, title: "Archive downloaded", symbol: "archivebox",
                        actions: [.extractArchive(path: download.path), reveal],
                        reason: "A download just finished. Extract expands it next to the archive with Archive Utility and keeps the archive.")
        }
        switch download.kind {
        case .pdf:
            return make("download.pdf", base: 0.72, title: "PDF downloaded", symbol: "doc.richtext",
                        actions: [.openActions(path: download.path, then: .pdfText), reveal, .openActions(path: download.path, then: nil)],
                        reason: "A PDF just finished downloading. Its actions keep it on the shelf by reference and read it on this Mac.")
        case .image:
            return make("download.image", base: 0.68, title: "Image downloaded", symbol: "photo",
                        actions: [.openActions(path: download.path, then: nil), reveal],
                        reason: "An image just finished downloading. Actions can convert, resize, compress or read its text, on new copies.")
        case .video, .audio:
            return make("download.media", base: 0.62, title: download.kind == .video ? "Video downloaded" : "Audio downloaded",
                        symbol: download.kind == .video ? "film" : "waveform", actions: [.openActions(path: download.path, then: nil), reveal],
                        reason: "A download just finished. Actions can show its details, save a frame or compress a copy.")
        default:
            return nil
        }
    }

    static func shortLink(_ url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path == "/" ? "" : url.path
        return oneLine(host + path, limit: 48)
    }

    static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
