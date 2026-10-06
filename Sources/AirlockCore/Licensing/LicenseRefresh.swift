import Foundation

/// When to ask the licence server for a newer token — and, mostly, when not to.
///
/// The rule this encodes: **start early, fail quietly, and stay off the network
/// the rest of the time.** Refreshing begins well before the billing date, so a
/// subscription gets many chances to renew itself while nothing is yet wrong. If
/// every one of them fails, the grace window in the token absorbs it and the
/// person using the app sees nothing at all.
///
/// The shape falls out of that: a yearly subscriber's Mac makes no licence
/// request for about 355 days, then a handful over a fortnight, then none again.
/// A monthly one goes quiet for twenty. Nobody is polled weekly for the
/// vendor's benefit, because a check that cannot change the answer is telemetry
/// wearing a different hat.
public enum LicenseRefresh {
    /// How long before `renewsAt` to start trying. Ten days of chances ahead of
    /// the date, and then the whole grace window behind it — so a refresh has to
    /// fail for weeks running before anybody notices.
    public static let leadTime: TimeInterval = 10 * 86_400

    /// Never more often than this. A licence server having a bad day should not
    /// be met with a request every thirty seconds from every install.
    public static let minimumInterval: TimeInterval = 6 * 3_600

    /// - Parameters:
    ///   - license: the currently stored licence, if any.
    ///   - lastAttempt: when a refresh was last *attempted* — not when one last
    ///     succeeded. Backing off on attempts is what stops a dead endpoint
    ///     being hammered; backing off on successes would do nothing at all.
    public static func shouldAttempt(license: License?,
                                     lastAttempt: Date?,
                                     now: Date = Date()) -> Bool {
        // A trial has no token, so there is nothing a server could send back
        // that this app does not already know. This is why an unpaid copy is
        // completely silent on the network.
        guard let license else { return false }

        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minimumInterval,
           lastAttempt <= now {
            return false
        }
        return now >= license.renewsAt.addingTimeInterval(-leadTime)
    }
}
