import Foundation

/// The rules behind keep-awake's three options: the battery cutoff, letting
/// the screen sleep, and what is said when the cutoff ends it.
///
/// Pure, so the one decision with a number in it is tested rather than read
/// off a view. IOKit's readings arrive as parameters; nothing here holds an
/// assertion or reads a battery.
public enum KeepAwakePolicy {
    /// The levels Settings offers, in percent. Zero is "never stop", the
    /// default, which is what keep-awake did before the option existed.
    public static let cutoffChoices = [0, 10, 20, 30, 50]

    /// Whether a held keep-awake has to let go now.
    ///
    /// Only on battery: a Mac on power is not going flat, whatever its level
    /// says, and a laptop charging at 15% overnight is the most ordinary reason
    /// to keep one awake. `percentage` is nil on a Mac with no battery, which
    /// never stops.
    public static func shouldStop(cutoff: Int, percentage: Int?, onBattery: Bool) -> Bool {
        guard cutoff > 0, onBattery, let percentage else { return false }
        return percentage < cutoff
    }

    /// Why a press that would start keep-awake did nothing, or nil to go ahead.
    ///
    /// The same rule as `shouldStop`, checked before anything is held: starting
    /// it only to drop it on the next battery reading would light the button
    /// for a second and say nothing about why it went out.
    public static func refusal(cutoff: Int, percentage: Int?, onBattery: Bool) -> String? {
        guard shouldStop(cutoff: cutoff, percentage: percentage, onBattery: onBattery) else { return nil }
        return "The battery is below \(cutoff)%, where keep awake stops. Plug in, or lower the cutoff in Settings."
    }

    // MARK: - While an agent works (card Awake 1)

    /// How long the Mac stays held after the last agent stopped working.
    ///
    /// Two minutes: a session goes quiet between a reply and the next tool
    /// call, and a hold that drops in every gap would let a Mac already past
    /// its idle time fall asleep mid-task. Short enough that a finished task
    /// does not keep a laptop up for long.
    public static let agentLinger: TimeInterval = 120

    /// Whether an agent is working now, or stopped recently enough to count.
    ///
    /// Working means running. A session waiting on an answer is not: nothing
    /// happens while it waits, so there is nothing to keep the Mac up for. The
    /// backwards-clock guard is the island's, for the same reason.
    public static func agentsBusy(working: Bool, lastWorkedAt: Date?, now: Date) -> Bool {
        if working { return true }
        guard let lastWorkedAt else { return false }
        let elapsed = now.timeIntervalSince(lastWorkedAt)
        return elapsed >= 0 && elapsed < agentLinger
    }

    /// Whether to hold the Mac awake for agents.
    ///
    /// Plugged in, the switch decides. On battery it takes the second switch
    /// as well, and the battery cutoff still applies: a hold nobody pressed for
    /// must never be the thing that runs a laptop flat.
    public static func holdsForAgents(enabled: Bool, onBatteryToo: Bool, busy: Bool,
                                      cutoff: Int, percentage: Int?, onBattery: Bool) -> Bool {
        guard enabled, busy else { return false }
        guard onBattery else { return true }
        return onBatteryToo && !shouldStop(cutoff: cutoff, percentage: percentage, onBattery: true)
    }

    /// The panel's line after the cutoff ended it. It stays until somebody
    /// has seen it (`keepsStoppedNotice`), because the person it is for is
    /// often away when it happens.
    public static func stoppedMessage(cutoff: Int) -> String {
        "Keep awake stopped: the battery went below \(cutoff)%."
    }

    /// How long the line stays once the panel has first shown it. Five
    /// minutes: long enough to read it, close the panel and come back, short
    /// enough that it is not still there tomorrow.
    public static let stoppedNoticeAfterSeen: TimeInterval = 5 * 60

    /// Whether the panel should still say the cutoff ended keep awake.
    ///
    /// It used to stay until the next press, and a press may never come — the
    /// line sat under the rail for days, news long after it was news. Counting
    /// from when it was first SHOWN rather than from when it happened is the
    /// point: somebody away for an afternoon still finds it when they open the
    /// panel. `firstSeenAt` nil means nobody has looked yet. A clock that went
    /// backwards keeps it rather than dropping news nobody read.
    public static func keepsStoppedNotice(firstSeenAt: Date?, now: Date) -> Bool {
        guard let firstSeenAt else { return true }
        return now.timeIntervalSince(firstSeenAt) < stoppedNoticeAfterSeen
    }
}
