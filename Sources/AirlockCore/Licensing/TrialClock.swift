import Foundation

/// The free trial, as arithmetic on two dates.
///
/// **No card, everything unlocked, fourteen days.** Asking for a card first
/// roughly triples the share of trials that convert and costs far more than that
/// in trials ever started — and for an app whose pitch is that it holds your
/// keys to the agent, demanding payment details from a stranger before it has
/// done anything is the wrong first impression.
///
/// This is the one piece of licensing the vendor cannot see. A trial has no
/// signed token, because there is nobody to sign it for — so it is local, and
/// therefore resettable by anyone who cares to look. That is accepted rather
/// than fought: the defences would land on honest people (a restored backup, a
/// new Mac, a preferences reset) far more often than on the handful of people
/// determined to avoid €3.99.
public enum TrialClock {
    public static let length = 14

    /// Whole days left, counted from midnight so that "1 day left" means
    /// tomorrow whatever time of day the trial happened to start.
    ///
    /// Clamped to the full length at the top: a clock moved backwards reads as a
    /// trial that has not started yet, and handing that person the fourteen days
    /// they already had is a better failure than a negative countdown.
    public static func daysRemaining(started: Date,
                                     now: Date,
                                     calendar: Calendar = .current) -> Int {
        let elapsed = calendar.dateComponents([.day],
                                              from: calendar.startOfDay(for: started),
                                              to: calendar.startOfDay(for: now)).day ?? 0
        return min(length, max(0, length - elapsed))
    }

    public static func hasExpired(started: Date,
                                  now: Date,
                                  calendar: Calendar = .current) -> Bool {
        daysRemaining(started: started, now: now, calendar: calendar) == 0
    }
}
