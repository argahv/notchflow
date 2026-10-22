import Foundation

// Intent Switch: what the person is doing, as far as signals NotchFlow already has can tell (the app in
// front, a call in the activity queue, media playing). A mode changes which shortcuts the notch offers,
// which suggestions rank higher and which work ranks first. It never opens the notch by itself, and an
// explicit choice always wins over inference.

public enum WorkMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case general, developer, meeting, media, creative, study
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: "General"
        case .developer: "Developer"
        case .meeting: "Meeting"
        case .media: "Media"
        case .creative: "Creative"
        case .study: "Study"
        }
    }
    public var symbol: String {
        switch self {
        case .general: "circle.grid.2x2"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .meeting: "video"
        case .media: "music.note"
        case .creative: "paintbrush.pointed"
        case .study: "book"
        }
    }
    public var summary: String {
        switch self {
        case .general: "Music, Shelf and Tools at hand."
        case .developer: "Activity, Clipboard and Shelf at hand; agents, builds and CI rank first; JSON, paths and links are suggested more readily."
        case .meeting: "Calendar, Notes and Sound at hand; calls rank first; suggestions stay quieter, except dates and contacts."
        case .media: "Music, Sound and Shelf at hand."
        case .creative: "Shelf, Clipboard and Tools at hand; colors are suggested more readily."
        case .study: "Timer, Notes and Shelf at hand; long passages and links are suggested more readily. Only when you choose it."
        }
    }
    /// No signal tells studying from browsing, so Study is only ever chosen, never inferred.
    public var inferable: Bool { self != .study }

    /// The three shortcuts the resting notch offers on hover when nothing is live.
    public var shortcuts: [ModeShortcut] {
        switch self {
        case .general: [.music, .shelf, .tools]
        case .developer: [.activity, .clipboard, .shelf]
        case .meeting: [.calendar, .notes, .sound]
        case .media: [.music, .sound, .shelf]
        case .creative: [.shelf, .clipboard, .tools]
        case .study: [.timer, .notes, .shelf]
        }
    }

    /// Activity categories this mode ranks first, on top of what the app in front boosts.
    public var boosted: Set<ActivityCategory> {
        switch self {
        case .developer: [.agent, .build, .ci, .deploy]
        case .meeting: [.meeting]
        default: []
        }
    }

    /// How the mode tilts a kind of suggestion: a small lift where it fits, and quieter during calls.
    public func suggestionAdjustment(for category: SuggestionCategory) -> Double {
        switch self {
        case .developer: [SuggestionCategory.data: 0.08, .files: 0.05, .links: 0.03][category] ?? 0
        case .creative: category == .colors ? 0.08 : 0
        case .study: [SuggestionCategory.text: 0.12, .links: 0.04][category] ?? 0
        case .meeting: [SuggestionCategory.dates, .contacts].contains(category) ? 0.05 : -0.15
        case .media, .general: 0
        }
    }
}

public enum ModeShortcut: String, Sendable, CaseIterable {
    case activity, music, shelf, tools, clipboard, notes, calendar, timer, sound, history
}

/// The signals a person can switch off one by one.
public enum ModeDetector: String, Codable, Sendable, CaseIterable, Identifiable {
    case apps, meetings, media
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .apps: "The app in front"
        case .meetings: "Calls in progress"
        case .media: "Music or video playing"
        }
    }
}

/// What the detectors see right now.
public struct ModeSignals: Equatable, Sendable {
    public var appInFront: String?
    public var appName: String?
    /// The title of a call in progress or about to start.
    public var meeting: String?
    public var mediaPlaying: Bool
    public init(appInFront: String? = nil, appName: String? = nil, meeting: String? = nil, mediaPlaying: Bool = false) {
        self.appInFront = appInFront; self.appName = appName; self.meeting = meeting; self.mediaPlaying = mediaPlaying
    }
}

/// A mode and the plain reason for it.
public struct ModeReading: Equatable, Sendable {
    public var mode: WorkMode
    public var reason: String
    public init(_ mode: WorkMode, _ reason: String) { self.mode = mode; self.reason = reason }
    public static let none = ModeReading(.general, "Nothing points to a mode")
}

public enum ModeRules {
    static let creative: Set<String> = [
        "com.figma.Desktop", "com.bohemiancoding.sketch3", "com.seriflabs.affinitydesigner2", "com.seriflabs.affinityphoto2",
        "com.seriflabs.affinitypublisher2", "com.pixelmatorteam.pixelmator.x", "org.blenderfoundation.blender", "com.apple.FinalCut",
        "com.apple.logic10", "com.apple.motionapp", "com.apple.iMovieApp", "com.apple.garageband10", "com.linearity.vn",
    ]
    static let creativePrefixes = ["com.adobe.Photoshop", "com.adobe.illustrator", "com.adobe.AfterEffects", "com.adobe.PremierePro",
                                   "com.adobe.InDesign", "com.adobe.Lightroom"]
    static let players: Set<String> = ["com.apple.Music", "com.spotify.client", "com.apple.TV", "com.apple.podcasts", "org.videolan.vlc",
                                       "com.colliderli.iina"]

    /// Which mode the signals point to, and why. A call comes first, then the app in front, then media
    /// playing with nothing else to go on.
    public static func read(_ signals: ModeSignals, detectors: Set<ModeDetector>) -> ModeReading {
        if detectors.contains(.meetings), let meeting = signals.meeting {
            return ModeReading(.meeting, "“\(meeting)” is on")
        }
        if detectors.contains(.apps), let app = signals.appInFront {
            let name = signals.appName ?? app
            // Calling apps count; Calendar in front is planning, not a call.
            if ContextRules.meetings.contains(app), app != "com.apple.iCal" { return ModeReading(.meeting, "\(name) is in front") }
            if ContextRules.developer.contains(app) || ContextRules.developerPrefixes.contains(where: app.hasPrefix) {
                return ModeReading(.developer, "\(name) is in front")
            }
            if creative.contains(app) || creativePrefixes.contains(where: app.hasPrefix) { return ModeReading(.creative, "\(name) is in front") }
            if players.contains(app) { return ModeReading(.media, "\(name) is in front") }
        }
        if detectors.contains(.media), signals.mediaPlaying { return ModeReading(.media, "Music is playing") }
        return .none
    }
}

/// Keeps the mode steady: a different reading must hold for `settle` seconds before the mode changes, so a
/// glance at another app doesn't flip it. A call starting changes it at once.
public struct ModeTracker: Sendable {
    public private(set) var current = ModeReading.none
    private var candidate: (reading: ModeReading, since: Date)?
    public var settle: TimeInterval
    public init(settle: TimeInterval = 15) { self.settle = settle }

    /// Takes a reading; returns true when the mode changed.
    public mutating func observe(_ reading: ModeReading, at now: Date) -> Bool {
        if reading.mode == current.mode {
            current = reading            // same mode, perhaps a fresher reason
            candidate = nil
            return false
        }
        if reading.mode == .meeting {
            current = reading; candidate = nil
            return true
        }
        let since = candidate.flatMap { $0.reading.mode == reading.mode ? $0.since : nil } ?? now
        if now.timeIntervalSince(since) >= settle {
            current = reading; candidate = nil
            return true
        }
        candidate = (reading, since)
        return false
    }

    /// When a pending change would settle, so it can be checked again without a new signal.
    public var settlesAt: Date? { candidate.map { $0.since.addingTimeInterval(settle) } }
    public var pending: ModeReading? { candidate?.reading }
}
