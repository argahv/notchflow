import Foundation

public struct Countdown: Codable, Equatable, Sendable {
    public private(set) var deadline: Date?
    public private(set) var pausedRemaining: TimeInterval?
    public init() {}
    public var running: Bool { deadline != nil }
    public var exists: Bool { deadline != nil || pausedRemaining != nil }
    public func remaining(at now: Date = Date()) -> TimeInterval {
        max(0, deadline?.timeIntervalSince(now) ?? pausedRemaining ?? 0)
    }
    public mutating func start(seconds: TimeInterval, now: Date = Date()) {
        deadline = now.addingTimeInterval(max(1, seconds)); pausedRemaining = nil
    }
    public mutating func pause(now: Date = Date()) {
        guard deadline != nil else { return }
        pausedRemaining = remaining(at: now); deadline = nil
    }
    public mutating func resume(now: Date = Date()) {
        guard let remaining = pausedRemaining else { return }
        deadline = now.addingTimeInterval(remaining); pausedRemaining = nil
    }
    public mutating func cancel() { deadline = nil; pausedRemaining = nil }
    public mutating func consumeCompletion(now: Date = Date()) -> Bool {
        guard let deadline, deadline <= now else { return false }
        cancel(); return true
    }
}
