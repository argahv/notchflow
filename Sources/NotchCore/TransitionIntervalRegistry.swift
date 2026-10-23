enum TransitionIntervalEndReason: Equatable {
    case completed
    case fallback
    case superseded(by: Int)
}

struct TransitionIntervalRegistry<Value> {
    private var intervals: [Int: Value] = [:]

    mutating func insert(_ interval: Value, for transition: Int) {
        precondition(intervals[transition] == nil)
        intervals[transition] = interval
    }

    mutating func end(_ transition: Int, reason: TransitionIntervalEndReason)
        -> (transition: Int, interval: Value, reason: TransitionIntervalEndReason)? {
        intervals.removeValue(forKey: transition).map { (transition, $0, reason) }
    }

    mutating func supersede(before latestTransition: Int)
        -> [(transition: Int, interval: Value, reason: TransitionIntervalEndReason)] {
        intervals.keys.filter { $0 < latestTransition }.sorted().compactMap { transition in
            intervals.removeValue(forKey: transition).map { (transition, $0, .superseded(by: latestTransition)) }
        }
    }
}
