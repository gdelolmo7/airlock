import Foundation

/// Whether the app in front is playing a video, read from the locks apps take
/// to keep the screen on.
///
/// **Why this and not "full screen" alone.** The island hid over every
/// full-screen window from 2026-10-04. The owner, 2026-10-26: over a film on
/// YouTube or Netflix, yes; over TextEdit, no. What tells the two apart from
/// outside the app is the screen lock: a browser or a player asks macOS to keep
/// the display on while a video plays (Chrome names it "Video Wake Lock",
/// measured the same day) and lets go when it is paused or ends. An editor never
/// asks.
///
/// Read with `IOPMCopyAssertionsByProcess` in the app; this only decides.
public enum VideoInFront {
    /// One lock as macOS lists it, cut down to what the decision reads.
    public struct ScreenLock: Equatable, Sendable {
        /// The process holding it.
        public var pid: Int32
        /// The app it was taken for, when another process holds it on that
        /// app's behalf (WebKit's helpers do this for Safari).
        public var onBehalfOf: Int32?
        /// It keeps the display on, not only the Mac awake. Playing music
        /// keeps the Mac awake and the screen free to sleep.
        public var keepsDisplayOn: Bool

        public init(pid: Int32, onBehalfOf: Int32? = nil, keepsDisplayOn: Bool) {
            self.pid = pid
            self.onBehalfOf = onBehalfOf
            self.keepsDisplayOn = keepsDisplayOn
        }
    }

    /// The lock types that keep the display on. macOS's own internal ones
    /// (`InternalPreventDisplaySleep`, held by powerd) are left out: nobody
    /// in front takes them.
    static let displayTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// One entry of `IOPMCopyAssertionsByProcess`'s arrays. Nil when it names
    /// no process.
    public static func lock(from entry: [String: Any]) -> ScreenLock? {
        guard let pid = (entry["AssertPID"] as? NSNumber)?.int32Value else { return nil }
        let type = entry["AssertionTrueType"] as? String ?? entry["AssertType"] as? String ?? ""
        return ScreenLock(pid: pid,
                          onBehalfOf: (entry["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value,
                          keepsDisplayOn: displayTypes.contains(type))
    }

    /// Whether the app with process id `front` holds, or has held for it, a
    /// lock that keeps the display on.
    public static func isPlaying(front: Int32, locks: [ScreenLock]) -> Bool {
        locks.contains { $0.keepsDisplayOn && ($0.pid == front || $0.onBehalfOf == front) }
    }
}
