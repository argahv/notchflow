import Foundation

/// How strongly an event may interrupt foreground work.
public enum AttentionPriority: Int, Comparable, Codable, Sendable {
    case silent = 0, background, informational, actionRequired, critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(phase: ActivityPhase) {
        switch phase {
        case .failed: self = .critical
        case .waiting: self = .actionRequired
        case .completed: self = .informational
        case .started, .progress: self = .background
        case .cancelled: self = .silent
        }
    }

    /// Whether this priority may raise a glance by itself.
    public var interrupts: Bool { self >= .informational }
}

public struct AttentionItem: Equatable, Sendable {
    public var id: String
    public var priority: AttentionPriority
    public var arrived: Date
    public init(id: String, priority: AttentionPriority, arrived: Date) {
        self.id = id; self.priority = priority; self.arrived = arrived
    }
}

/// What the person is doing when an event arrives.
public struct AttentionContext: Equatable, Sendable {
    public var editing: Bool
    public var expanded: Bool
    public var suppressed: Bool
    /// Another kind of glance (a suggestion) has the surface: items below this priority wait behind it,
    /// items at or above it may take the surface (see `SurfaceArbiter`).
    public var holdBelow: AttentionPriority
    public init(editing: Bool = false, expanded: Bool = false, suppressed: Bool = false, holdBelow: AttentionPriority = .silent) {
        self.editing = editing; self.expanded = expanded; self.suppressed = suppressed; self.holdBelow = holdBelow
    }
}

public enum AttentionDecision: Equatable, Sendable {
    /// Show this item now as the glance.
    case present(AttentionItem)
    /// Hold it; something at least as important is showing, or interruptions are throttled.
    case queue
    /// Do not open anything; light the notch edge so the change is still noticed.
    case indicate
    /// Nothing to show.
    case ignore
}

/// Decides which event may present itself and when. Deterministic so it can be unit-tested:
/// higher priority preempts, equal or lower waits, repeated updates of one task never stack,
/// interruptions are throttled, and nothing opens over editing or an open workspace.
public struct AttentionCenter: Sendable {
    public private(set) var current: AttentionItem?
    public private(set) var pending: [AttentionItem] = []
    public var minimumInterval: TimeInterval
    public var capacity: Int
    private var lastPresented: Date = .distantPast

    public init(minimumInterval: TimeInterval = 3, capacity: Int = 20) {
        self.minimumInterval = minimumInterval; self.capacity = capacity
    }

    public mutating func receive(_ item: AttentionItem, context: AttentionContext) -> AttentionDecision {
        pending.removeAll { $0.id == item.id }
        if current?.id == item.id {
            // The same task changed; refresh in place rather than stacking a second glance.
            guard item.priority.interrupts else { current = nil; return .ignore }
            current = item; return .present(item)
        }
        guard item.priority.interrupts else { return .ignore }
        if context.suppressed { return .indicate }
        if context.editing || context.expanded { enqueue(item); return .indicate }
        if item.priority < context.holdBelow { enqueue(item); return .indicate }
        if let current, current.priority >= item.priority { enqueue(item); return .queue }
        if item.priority < .critical, item.arrived.timeIntervalSince(lastPresented) < minimumInterval, current == nil {
            enqueue(item); return .queue
        }
        if let current { enqueue(current) }
        return present(item)
    }

    /// The glance closed. Returns the next item to present, if the context allows one now.
    public mutating func dismissCurrent(now: Date, context: AttentionContext) -> AttentionItem? {
        current = nil
        return resume(now: now, context: context)
    }

    /// Called when the person stops editing or closes the workspace. Only items that still matter are replayed.
    public mutating func resume(now: Date, context: AttentionContext) -> AttentionItem? {
        guard current == nil, !context.suppressed, !context.editing, !context.expanded else { return nil }
        guard now.timeIntervalSince(lastPresented) >= minimumInterval || pending.contains(where: { $0.priority == .critical }) else { return nil }
        pending.removeAll { $0.priority < .actionRequired && now.timeIntervalSince($0.arrived) > 30 }
        guard let next = pending.filter({ $0.priority >= context.holdBelow })
            .max(by: { ($0.priority, $1.arrived) < ($1.priority, $0.arrived) }) else { return nil }
        pending.removeAll { $0.id == next.id }
        _ = present(AttentionItem(id: next.id, priority: next.priority, arrived: now))
        return current
    }

    /// When a queued item may next be shown without breaking the throttle.
    public func nextEligible() -> Date? {
        pending.isEmpty ? nil : lastPresented.addingTimeInterval(minimumInterval)
    }

    public mutating func discard(id: String) {
        pending.removeAll { $0.id == id }
        if current?.id == id { current = nil }
    }

    private mutating func present(_ item: AttentionItem) -> AttentionDecision {
        current = item; lastPresented = item.arrived
        return .present(item)
    }

    private mutating func enqueue(_ item: AttentionItem) {
        pending.removeAll { $0.id == item.id }
        pending.append(item)
        if pending.count > capacity {
            if let drop = pending.enumerated().min(by: { ($0.element.priority, $0.element.arrived) < ($1.element.priority, $1.element.arrived) }) {
                pending.remove(at: drop.offset)
            }
        }
    }
}
