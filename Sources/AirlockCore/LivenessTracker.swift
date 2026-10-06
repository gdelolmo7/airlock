import Foundation

/// Debounced death detection: a session is only declared dead after it misses
/// two consecutive liveness checks, so one transient `ps` failure or racy
/// snapshot never kills a live session.
public struct LivenessTracker: Sendable, Equatable {
    public var strikesToDeath: Int
    private var misses: [String: Int] = [:]

    public init(strikesToDeath: Int = 2) {
        self.strikesToDeath = strikesToDeath
    }

    /// Feed one round of observations (sessionID → alive?). Sessions absent
    /// from `observations` are forgotten (no longer tracked). Returns the IDs
    /// that just crossed the death threshold.
    public mutating func update(observations: [String: Bool]) -> [String] {
        var dead: [String] = []
        var next: [String: Int] = [:]
        for (id, alive) in observations {
            if alive { continue } // reset any strikes by omission from `next`
            let count = (misses[id] ?? 0) + 1
            if count >= strikesToDeath {
                dead.append(id) // declared dead; drop tracking
            } else {
                next[id] = count
            }
        }
        misses = next
        return dead.sorted()
    }
}
