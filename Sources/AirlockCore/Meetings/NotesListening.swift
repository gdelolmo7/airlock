import Foundation

/// How long notes have listened, for a plan that caps it (Free's
/// `PlanLimits.notesListenFor`: the first 30 minutes of each call).
///
/// **Counted in the Mac's running time, never the clock** (`RunningTime`).
/// Setting the clock back during a call would otherwise stretch the notes,
/// and setting it forward would make the "same call" window below pass at
/// once.
///
/// **Stopping and starting again carries on the same count**: notes started
/// while the call they were of is still on, or within `carriesOnFor` of the
/// last stop, add to it rather than starting a new one. So a stop and a
/// restart, a dropped call that comes back, or "Take notes" in the room
/// right after, never buy a second 30 minutes. A call in another app is
/// another meeting and starts its own count.
///
/// **The cap is the plan the count started on** (`startedOn`), never lowered
/// on the way (`PlanSnapshot.kept`): a call started on Plus keeps full notes
/// if the subscription ends halfway, and one started on Free is let go of
/// its cap the moment a bigger plan is bought.
public struct NotesListening: Codable, Equatable, Sendable {
    /// How soon notes must start again after the last stop, or after the end
    /// of the call they were of, to carry on the same count.
    public static let carriesOnFor: TimeInterval = 10 * 60

    /// The plan when the count started.
    public let startedOn: PlanSnapshot
    /// Seconds listened in stretches that have ended.
    public private(set) var banked: TimeInterval
    /// The running time the stretch now listening began; nil while nothing
    /// is (paused or stopped).
    public private(set) var openedAt: TimeInterval?
    /// The running time the notes last stopped, or the call they were of
    /// was last known to be on, whichever is later.
    public private(set) var lastSeen: TimeInterval
    /// The call app the counted notes were of; nil for notes in the room.
    public private(set) var bundleID: String?
    /// Whether that call is still on: notes started during it carry on the
    /// count however long ago they stopped.
    public private(set) var callOn: Bool

    /// A new count, listening from `running`.
    public init(startedOn: PlanSnapshot, call: OngoingCall, at running: TimeInterval) {
        self.startedOn = startedOn
        banked = 0
        openedAt = running
        lastSeen = running
        bundleID = call.isInPerson ? nil : call.bundleID
        callOn = !call.isInPerson
    }

    /// Seconds listened up to `running`.
    public func listened(at running: TimeInterval) -> TimeInterval {
        banked + (openedAt.map { max(0, running - $0) } ?? 0)
    }

    /// How long these notes may listen on `plan` now; nil for as long as the
    /// call lasts.
    public func limit(now plan: PlanSnapshot) -> TimeInterval? {
        PlanSnapshot.kept(startedOn: startedOn, now: plan).limits.notesListenFor
    }

    /// Whether the notes have listened as long as they may.
    public func isSpent(at running: TimeInterval, plan: PlanSnapshot) -> Bool {
        limit(now: plan).map { listened(at: running) >= $0 } ?? false
    }

    /// Seconds still to listen, if there is a limit.
    public func left(at running: TimeInterval, plan: PlanSnapshot) -> TimeInterval? {
        limit(now: plan).map { max(0, $0 - listened(at: running)) }
    }

    /// Whether notes on `call` starting at `running` carry on this count. A
    /// running time behind the last one seen means the Mac has restarted
    /// since: the count is over.
    public func carriesOn(into call: OngoingCall, at running: TimeInterval) -> Bool {
        guard running >= lastSeen else { return false }
        let sameApp = call.isInPerson || bundleID == nil || call.bundleID == bundleID
        if callOn, sameApp { return true }
        return sameApp && running - lastSeen <= Self.carriesOnFor
    }

    /// Notes on `call` carry on the count from `running`.
    public mutating func carryOn(into call: OngoingCall, at running: TimeInterval) {
        if !call.isInPerson {
            bundleID = call.bundleID
            callOn = true
        }
        open(at: running)
    }

    /// Listening (again) from `running`. Does nothing if already listening.
    public mutating func open(at running: TimeInterval) {
        if openedAt == nil { openedAt = running }
    }

    /// Stopped listening at `running`: paused, stopped, or the call is over.
    public mutating func close(at running: TimeInterval) {
        if let openedAt {
            banked += max(0, running - openedAt)
            self.openedAt = nil
        }
        lastSeen = max(lastSeen, running)
    }

    /// The call the notes were of has ended, at `running`.
    public mutating func callIsOver(at running: TimeInterval) {
        guard callOn else { return }
        callOn = false
        lastSeen = max(lastSeen, running)
    }

    /// This count as it stands at `running`, closed there: what is kept
    /// across a quit. A copy that quit while listening comes back having
    /// listened up to the moment it was kept, not up to the moment it
    /// starts again.
    public func kept(at running: TimeInterval) -> NotesListening {
        var copy = self
        copy.close(at: running)
        return copy
    }
}

/// The Mac's running time in seconds, from an arbitrary start: it counts
/// while the Mac sleeps and never moves when the clock is set, so a count
/// kept in it cannot be stretched or skipped by changing the date. It starts
/// again at a restart (`NotesListening.carriesOn` reads that as the end).
public enum RunningTime {
    public static func now() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}
