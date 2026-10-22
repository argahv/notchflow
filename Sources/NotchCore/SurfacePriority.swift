import Foundation

/// Who may have the notch, highest first: the person's own interaction, critical actionable work, task
/// progress, time-sensitive suggestions, passive news, idle.
public enum SurfaceTier: Int, Comparable, Sendable, CaseIterable {
    case idle = 0, passive, suggestion, progress, critical, interaction

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .idle: "Idle"
        case .passive: "Passive news"
        case .suggestion: "Suggestion"
        case .progress: "Task progress"
        case .critical: "Needs you"
        case .interaction: "You"
        }
    }
}

extension AttentionPriority {
    /// Where an activity's attention priority sits among the surface tiers.
    public var surfaceTier: SurfaceTier {
        switch self {
        case .critical, .actionRequired: .critical
        case .background: .progress
        case .informational: .passive
        case .silent: .idle
        }
    }
}

/// What has the surface right now.
public struct SurfaceOccupancy: Equatable, Sendable {
    /// The person is dragging, typing, looking at a drop's result or has the workspace open.
    public var interacting: Bool
    /// The tier of the glance on screen, or nil when nothing transient is showing.
    public var showing: SurfaceTier?
    public init(interacting: Bool = false, showing: SurfaceTier? = nil) {
        self.interacting = interacting; self.showing = showing
    }
}

public enum SurfaceAdmission: Equatable, Sendable {
    /// Take the surface now.
    case show
    /// Hold, and try again when the surface is free.
    case wait
}

/// The rules every transient glance follows:
/// 1. Nothing takes the surface from the person.
/// 2. Only critical, actionable work preempts another glance.
/// 3. Everything else waits its turn.
public enum SurfaceArbiter {
    public static func admit(_ tier: SurfaceTier, into occupancy: SurfaceOccupancy) -> SurfaceAdmission {
        if occupancy.interacting { return .wait }
        guard let showing = occupancy.showing else { return .show }
        return tier >= .critical && tier > showing ? .show : .wait
    }

    /// The lowest attention priority that may still present over a glance of this tier. Everything below
    /// it waits in the attention queue.
    public static func lowestPriorityAdmitted(over showing: SurfaceTier?) -> AttentionPriority {
        guard let showing else { return .silent }
        return AttentionPriority.allCases.first { admit($0.surfaceTier, into: SurfaceOccupancy(showing: showing)) == .show } ?? .critical
    }
}

/// Something that couldn't take the surface when it arrived and is waiting for it to be free.
public struct WaitingGlance: Equatable, Sendable {
    public enum Kind: String, Sendable { case attention, capture, suggestion, sound }
    public var kind: Kind
    public var tier: SurfaceTier
    public var arrived: Date
    /// Past this it's dropped rather than shown late.
    public var expires: Date
    public init(_ kind: Kind, tier: SurfaceTier, arrived: Date, expires: Date) {
        self.kind = kind; self.tier = tier; self.arrived = arrived; self.expires = expires
    }
}

extension SurfaceArbiter {
    /// Which waiting glance takes a free surface: the highest tier, then the most recent. Nothing expired.
    public static func next(_ waiting: [WaitingGlance], now: Date) -> WaitingGlance? {
        waiting.filter { $0.expires > now }.max { ($0.tier, $0.arrived) < ($1.tier, $1.arrived) }
    }
}

extension AttentionPriority: CaseIterable {
    public static var allCases: [AttentionPriority] { [.silent, .background, .informational, .actionRequired, .critical] }
}
