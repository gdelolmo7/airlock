import Foundation

/// One event tap, as the system reports it — not as the process that asked for
/// it believes it to be.
///
/// Two fields out of the ten in `CGEventTapInformation`, because these are the
/// two that answer "will this deliver anything?". The latency figures describe a
/// tap that is already working.
public struct EventTapFacts: Equatable, Sendable {
    /// WindowServer's own flag. A tap it has decided not to feed reads `false`
    /// here while the process still holds a perfectly valid `CFMachPort`.
    public let isEnabled: Bool
    /// The mask WindowServer **kept**, which is not always the mask that was
    /// asked for — see `EventTapCheck`.
    public let eventsOfInterest: UInt64

    public init(isEnabled: Bool, eventsOfInterest: UInt64) {
        self.isEnabled = isEnabled
        self.eventsOfInterest = eventsOfInterest
    }
}

/// Whether a created event tap is actually going to see events.
public enum EventTapHealth: Equatable, Sendable {
    /// Enabled, and watching everything that was asked for.
    case live
    /// The process owns no tap that overlaps what was asked for. Creation
    /// failed, or something tore it down.
    case absent
    /// The tap exists and is useless: switched off, silently narrowed, or both.
    ///
    /// `missingEvents` is the part of the requested mask that WindowServer did
    /// not keep — worth carrying because it is the tell. A tap that kept
    /// `flagsChanged` and lost `keyDown` was not misconfigured by us.
    case inert(isEnabled: Bool, missingEvents: UInt64)

    public var isLive: Bool { self == .live }
}

/// Does the process's hotkey tap actually work?
///
/// **This exists because `CGEvent.tapCreate` returning a port proves nothing.**
/// `HoldKeyMonitor` shipped for months treating a non-nil return as success, and
/// its own comment claimed that was "the only signal there is". It is not, and
/// it is not even a signal: an unsigned test binary with `AXIsProcessTrusted()`
/// false gets a port back, and then receives zero events forever. The app could
/// not tell a working hotkey from a dead one, which is why a user holding ⌃ and
/// getting silence had nothing to read anywhere — not in the log, not in
/// Settings, which cheerfully reported every permission granted.
///
/// **What actually happens when the permission is missing** (measured, not
/// guessed): the tap is created, appears in `CGGetEventTapList`, and comes back
/// with `enabled = 0` and a mask with the `keyDown` bit *stripped* —
/// `0x240140a` requested, `0x240100a` kept. WindowServer quietly removes the
/// event types it will not let an untrusted process see and disables the rest.
/// So the list is ground truth, and asking it is the whole check.
///
/// **The permission is Input Monitoring — `kTCCServiceListenEvent` — and not
/// Accessibility.** They are separate TCC services, and the app confused them:
/// Accessibility read `Allowed`, validated fine, and gated nothing here. Every
/// fix aimed at it therefore changed nothing, which is its own kind of expensive.
public enum EventTapCheck {
    /// - Parameters:
    ///   - taps: every tap owned by this process. The caller filters by pid;
    ///     this decides what the collection means.
    ///   - requested: the mask that was passed to `tapCreate`.
    ///
    /// **One healthy tap is enough, and that is deliberate.** Event-listening
    /// access is granted per *process*, so a single live tap proves the
    /// permission is there and any other inert one is a different, transient
    /// problem — `tapDisabledByTimeout` between the disable and the callback
    /// re-enabling it, most likely. Requiring every tap to be live would report
    /// a permission failure for a hiccup that fixes itself in microseconds.
    ///
    /// Taps that do not overlap `requested` are ignored rather than counted as
    /// broken: they are somebody else's, and being wrong about a tap this app
    /// did not create is how a permission warning turns into folklore.
    public static func health(of taps: [EventTapFacts], requested: UInt64) -> EventTapHealth {
        let ours = taps.filter { $0.eventsOfInterest & requested != 0 }
        guard !ours.isEmpty else { return .absent }
        if ours.contains(where: { $0.isEnabled && $0.eventsOfInterest & requested == requested }) {
            return .live
        }
        // Report the closest thing to a working tap. With several inert ones the
        // message should describe the best case, or it overstates the damage.
        let best = ours.max { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return rhs.isEnabled }
            return (lhs.eventsOfInterest & requested).nonzeroBitCount
                < (rhs.eventsOfInterest & requested).nonzeroBitCount
        }
        // `ours` is non-empty, so `max` cannot be nil; the fallback keeps the
        // failure honest rather than crashing on an impossible branch.
        guard let best else { return .inert(isEnabled: false, missingEvents: requested) }
        return .inert(isEnabled: best.isEnabled,
                      missingEvents: requested & ~best.eventsOfInterest)
    }

    /// Why the hold key is dead, when the two answers need opposite advice.
    ///
    /// Same shape and same reason as `CalendarAccessDiagnosis`: a permission
    /// failure is only actionable once you know which of two states it is, and
    /// telling the user the wrong one sends them somewhere that cannot help.
    ///
    /// - Parameter isListenEventGranted: `CGPreflightListenEventAccess()` — what
    ///   TCC has on file, which is a different question from whether events
    ///   arrive.
    public static func fault(health: EventTapHealth,
                             isListenEventGranted: Bool) -> HoldKeyFault? {
        guard !health.isLive else { return nil }
        return isListenEventGranted ? .grantIsNotWorking : .notGranted
    }
}

/// The two ways a hold key ends up dead.
public enum HoldKeyFault: Equatable, Sendable {
    /// TCC has no grant. Asking for it is the fix, and the app can do that.
    case notGranted
    /// **TCC says yes and the events still do not come.**
    ///
    /// The state that cost a day of debugging, and the one nobody thinks to
    /// look for: the tap stayed disabled with `keyDown` stripped while every
    /// permission surface reported healthy. The record existed and was pinned to
    /// a **certificate the app no longer carries** — a self-signed development
    /// cert, left behind when the build moved to Developer ID — so no signature
    /// Airlock can produce satisfies it (`-67050 errSecCSReqFailed`).
    ///
    /// Requesting it again does nothing, which is why this is a separate case.
    ///
    /// **And the remedy cannot assume a row to click.** This said "remove it
    /// from the list and add it back" until the machine it was found on turned
    /// out to have an *empty* Input Monitoring list — no Airlock row at all,
    /// while `CGPreflightListenEventAccess()` returned true and the taps ran.
    /// An app with no ListenEvent record of its own falls back to its
    /// Accessibility grant, so the normal state is to be absent from that pane
    /// entirely; a broken record overrides the fallback and still shows nothing
    /// to remove. Clearing the record is the fix that works either way —
    /// `InputMonitoring.staleRecordFix`.
    case grantIsNotWorking
}
