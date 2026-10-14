import Foundation

/// When crash reports may be sent, and when to ask. Pure, so the rules are
/// tested without a crash library or a bundle.
///
/// Two things have to be true before anything starts: the build carries
/// somewhere to send to (a DSN, added at packaging), and the person said yes.
/// The answer is off until they do. `swift run`, the tests, a development
/// package and anybody building the public source have no DSN, so they never
/// start it, whatever the setting says.
public enum CrashReportPolicy {
    /// The DSN a build carries, if it is one to start with.
    ///
    /// Only from a real `.app` (a bare executable has no Info.plist of its
    /// own), and only https with a key and a project: a DSN is the address
    /// and the key in one, and a malformed one would start a handler that
    /// can never deliver anything.
    public static func usableDSN(_ value: Any?, isBundled: Bool) -> String? {
        guard isBundled,
              let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              let key = url.user, !key.isEmpty,
              !url.lastPathComponent.isEmpty, url.lastPathComponent != "/"
        else { return nil }
        return text
    }

    /// Whether the crash handler should be running now.
    public static func shouldRun(dsn: String?, consent: Bool) -> Bool {
        dsn != nil && consent
    }

    /// Whether to ask, once, after a run that ended unexpectedly.
    ///
    /// Only in a build that could send, only while the answer is still off,
    /// and only once ever: somebody who said "not now" is not asked again
    /// after every crash. The switch in Settings is where they change it.
    public static func asksAfterUnexpectedQuit(available: Bool, consent: Bool,
                                               alreadyAsked: Bool,
                                               lastRunEndedUnexpectedly: Bool) -> Bool {
        available && !consent && !alreadyAsked && lastRunEndedUnexpectedly
    }
}
