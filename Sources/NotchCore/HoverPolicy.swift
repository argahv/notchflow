import Foundation

/// How much a hover candidate matters right now. Lower is more important.
public enum HoverTier: Int, Comparable, Sendable, CaseIterable {
    /// An agent or workflow waiting on the person.
    case input = 1
    /// A failure worth acting on.
    case failure
    /// Something the person pinned.
    case pinned
    /// A running focus timer or a call that's about to start.
    case imminent
    /// Running work related to the app in front.
    case foreground
    /// A running agent or build.
    case running
    /// Music that's playing.
    case music
    /// Anything else that's live (downloads, paused work).
    case general

    public static func < (a: HoverTier, b: HoverTier) -> Bool { a.rawValue < b.rawValue }
    /// Arrivals that may replace what the person is looking at.
    public var isCritical: Bool { self <= .failure }
}

/// What kind of thing a candidate is. Split mode pairs an ambient family with an activity.
public enum HoverFamily: String, Sendable {
    case agent, pipeline, download, meeting, timer, music, other
    /// Music and timers sit beside work rather than competing with it.
    public var isAmbient: Bool { self == .music || self == .timer }
}

public struct HoverCandidate: Equatable, Sendable {
    public var id: String
    public var tier: HoverTier
    public var family: HoverFamily
    public var updated: Date
    public init(id: String, tier: HoverTier, family: HoverFamily, updated: Date) {
        self.id = id; self.tier = tier; self.family = family; self.updated = updated
    }
}

/// What the hover shows: one item, or two in a split, plus how many other activities there are.
public struct HoverChoice: Equatable, Sendable {
    public var primary: HoverCandidate?
    public var secondary: HoverCandidate?
    public var others: Int
    public init(primary: HoverCandidate? = nil, secondary: HoverCandidate? = nil, others: Int = 0) {
        self.primary = primary; self.secondary = secondary; self.others = others
    }
    public static let quickAccess = HoverChoice()
}

/// Picks what the hover shows. Deterministic, and stable on purpose:
/// - the most important tier wins; within a tier the newest wins, then the id;
/// - what's on screen stays while it's still present and nothing more important arrived (no reshuffling
///   between equals);
/// - while the pointer is on the preview only critical arrivals (input, failures) may replace it;
/// - while a control is in use nothing changes, as long as the shown item still exists.
public enum HoverPolicy {
    public struct Situation: Equatable, Sendable {
        public var hovered: Bool
        public var locked: Bool
        public var allowSplit: Bool
        /// The candidate the person pinned to stay on screen, if it's still live.
        public var pinned: String?
        public init(hovered: Bool = false, locked: Bool = false, allowSplit: Bool = true, pinned: String? = nil) {
            self.hovered = hovered; self.locked = locked; self.allowSplit = allowSplit; self.pinned = pinned
        }
    }

    public enum Side: Sendable { case primary, secondary }

    /// Moves one side of what's shown to the next candidate of the same kind (work for work, ambient for
    /// ambient) that still pairs with the other side. Order is the same ranking `choose` uses.
    public static func cycle(_ candidates: [HoverCandidate], current: HoverChoice, side: Side, step: Int) -> HoverChoice {
        guard let shown = side == .primary ? current.primary : current.secondary else { return current }
        let other = side == .primary ? current.secondary : current.primary
        let options = ranked(candidates).filter { candidate in
            candidate.family.isAmbient == shown.family.isAmbient
                && (other.map { candidate.id != $0.id && pairs(candidate, $0) } ?? true)
        }
        guard options.count > 1, let index = options.firstIndex(where: { $0.id == shown.id }) else { return current }
        let next = options[((index + step) % options.count + options.count) % options.count]
        var choice = current
        if side == .primary { choice.primary = next } else { choice.secondary = next }
        choice.others = others(in: ranked(candidates), primary: choice.primary, secondary: choice.secondary)
        return choice
    }

    /// How many alternatives one side has, so the view offers cycling only when there's somewhere to go.
    public static func alternatives(_ candidates: [HoverCandidate], current: HoverChoice, side: Side) -> Int {
        guard let shown = side == .primary ? current.primary : current.secondary else { return 0 }
        let other = side == .primary ? current.secondary : current.primary
        return candidates.filter { candidate in
            candidate.family.isAmbient == shown.family.isAmbient
                && (other.map { candidate.id != $0.id && pairs(candidate, $0) } ?? true)
        }.count - 1
    }

    static func ranked(_ candidates: [HoverCandidate]) -> [HoverCandidate] {
        candidates.sorted {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.updated != $1.updated { return $0.updated > $1.updated }
            return $0.id < $1.id
        }
    }

    static func others(in ranked: [HoverCandidate], primary: HoverCandidate?, secondary: HoverCandidate?) -> Int {
        ranked.filter { !$0.family.isAmbient && $0.id != primary?.id && $0.id != secondary?.id }.count
    }

    public static func choose(_ candidates: [HoverCandidate], current: HoverChoice?, situation: Situation) -> HoverChoice {
        let ranked = candidates.sorted {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.updated != $1.updated { return $0.updated > $1.updated }
            return $0.id < $1.id
        }
        guard let best = ranked.first else { return .quickAccess }
        let shown = current?.primary.flatMap { old in ranked.first { $0.id == old.id } }

        var primary = best
        if let shown {
            if situation.locked {
                primary = shown
            } else if situation.hovered {
                primary = best.tier.isCritical && best.tier < shown.tier ? best : shown
            } else {
                primary = best.tier < shown.tier ? best : shown
            }
        }

        var secondary: HoverCandidate?
        if situation.allowSplit {
            let keep = current?.secondary.flatMap { old in ranked.first { $0.id == old.id } }
            if let keep, keep.id != primary.id, pairs(primary, keep) {
                secondary = keep
            } else if !situation.locked {
                // A new secondary must not reshape the surface while the pointer is over its
                // controls. When a critical event replaces the lead, however, preserve the old
                // item as the second half if it pairs (e.g. Claude input + playing music).
                if let shown, shown.id != primary.id, pairs(primary, shown) {
                    secondary = shown
                } else if !situation.hovered || current?.primary == nil {
                    secondary = ranked.first { $0.id != primary.id && pairs(primary, $0) }
                }
            }
        }
        var choice = HoverChoice(primary: primary, secondary: secondary,
                                 others: others(in: ranked, primary: primary, secondary: secondary))
        // A pinned item stays on screen: beside the lead when they pair, as the lead otherwise, but never
        // in place of a request or a failure, which keep the surface until handled.
        if let id = situation.pinned, let pin = ranked.first(where: { $0.id == id }),
           choice.primary?.id != id, choice.secondary?.id != id {
            if primary.tier.isCritical {
                if situation.allowSplit, pairs(primary, pin) { choice.secondary = pin }
            } else {
                // The pin stays, with the most important item it pairs with beside it; work leads.
                let partner = situation.allowSplit ? ranked.first { $0.id != pin.id && pairs(pin, $0) } : nil
                if pin.family.isAmbient, let partner { choice.primary = partner; choice.secondary = pin }
                else { choice.primary = pin; choice.secondary = partner }
            }
            choice.others = others(in: ranked, primary: choice.primary, secondary: choice.secondary)
        }
        return choice
    }

    /// Two things share the surface only when one is ambient (music, a timer) and the other is work
    /// that matters: input, a failure, something pinned or imminent, or running work.
    public static func pairs(_ a: HoverCandidate, _ b: HoverCandidate) -> Bool {
        guard a.family.isAmbient != b.family.isAmbient else { return false }
        let work = a.family.isAmbient ? b : a
        return work.tier <= .running
    }
}
