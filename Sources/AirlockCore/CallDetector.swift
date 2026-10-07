import Foundation

/// An app holding the microphone, as one sample of CoreAudio's process list
/// sees it. Owned by the app, not the helper: a browser tab's call arrives as
/// a helper process and is reported as the browser.
public struct MicUser: Equatable, Sendable {
    public var bundleID: String
    public var name: String
    /// The same app is also playing sound. A call does both, all the time —
    /// you are hearing the other side — while dictation, a voice memo or a
    /// recorder only listens. That difference is the whole test for "call".
    public var playing: Bool

    public init(bundleID: String, name: String, playing: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.playing = playing
    }
}

/// A call the island is showing.
public struct OngoingCall: Codable, Equatable, Sendable {
    public var bundleID: String
    public var appName: String
    /// When the app first took the microphone, not when the call was
    /// believed: the settle wait is ours, the timer is the user's.
    public var startedAt: Date
    /// The service the call is on, when the app is a browser and its window
    /// says so (a Meet tab). Set by the app, which can read window titles;
    /// the detector only ever sees which app holds the microphone.
    public var site: MeetingLink.Provider?

    public init(bundleID: String, appName: String, startedAt: Date,
                site: MeetingLink.Provider? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.startedAt = startedAt
        self.site = site
    }

    /// The running timer beside the icon: "0:42", "12:05", then "1h02" past an
    /// hour, because "1:02:14" is three characters wider than the compact
    /// island's one-glyph-plus-a-few budget and the seconds stop mattering.
    public func elapsedLabel(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        if hours > 0 { return String(format: "%dh%02d", hours, minutes) }
        return String(format: "%d:%02d", minutes, seconds % 60)
    }
}

/// A call as this copy of Airlock last saw it, kept so a restart mid-call
/// (an update, a reinstall) carries the timer on instead of starting at zero.
public struct CallSnapshot: Codable, Equatable, Sendable {
    public var call: OngoingCall
    public var seenAt: Date

    public init(call: OngoingCall, seenAt: Date) {
        self.call = call
        self.seenAt = seenAt
    }
}

/// Decides from microphone samples whether the user is on a call.
///
/// **What it can see, and what it cannot.** macOS tells any app which other
/// apps are using the microphone and the speakers, with no permission. It does
/// not tell anyone a call is RINGING — WhatsApp and FaceTime keep that to
/// themselves — so this reacts when the call is picked up, never before.
///
/// Fed once a second; owns no clock, so every rule is a test with no sleeping.
public struct CallDetector: Equatable, Sendable {
    /// The microphone held this long before it counts. Short enough that the
    /// pill is up before the first sentence is over, long enough that an app
    /// briefly opening the mic (a level check, a sound test) never shows a call.
    public static let settle: TimeInterval = 2
    /// The microphone gone this long before the call ends. Calls drop the mic
    /// for a beat when the route changes (AirPods in, AirPods out); ending on
    /// the first missing sample would restart the timer at zero mid-call.
    public static let grace: TimeInterval = 3
    /// How long Airlock may be gone and still pick a call back up. An update
    /// relaunches in seconds; past a minute it is more likely a new call in
    /// the same app than the old one, and a timer that starts at zero is the
    /// smaller mistake than one that claims an hour that never happened.
    public static let resumeWindow: TimeInterval = 60

    /// The FaceTime app, which is where an iPhone call relayed to this Mac
    /// and a FaceTime call both live on screen.
    public static let faceTime = "com.apple.FaceTime"

    /// The app a call daemon's microphone belongs to, or nil for anything
    /// else. FaceTime audio — and an iPhone call answered on the Mac — is held
    /// by system daemons rather than by the FaceTime app, so without this the
    /// one calling app every Mac has would never show.
    public static func callApp(forDaemon bundleID: String) -> String? {
        let daemons = ["com.apple.avconferenced", "com.apple.TelephonyUtilities",
                       "com.apple.telephonyutilities", "com.apple.callservicesd"]
        return daemons.contains { bundleID.hasPrefix($0) } ? faceTime : nil
    }

    public enum Change: Equatable, Sendable {
        case started(OngoingCall)
        case ended(OngoingCall, at: Date)
        /// The call a previous run was showing, picked up after a restart
        /// with its original start time.
        case resumed(OngoingCall)
    }

    public private(set) var call: OngoingCall?
    private var candidate: OngoingCall?
    private var lostAt: Date?
    private var resumable: CallSnapshot?

    public init() {}

    /// Starts with the call a previous run saved, if it was seen recently
    /// enough. It still has to be found again: the same app holding the mic
    /// for the settle — playing or not, see `observe` — and only the start
    /// time is carried over.
    public init(resuming snapshot: CallSnapshot?, now: Date) {
        if let snapshot, now.timeIntervalSince(snapshot.seenAt) <= Self.resumeWindow {
            resumable = snapshot
        }
    }

    /// What to save so the next run can resume this call; nil when there is none.
    public func snapshot(at now: Date) -> CallSnapshot? {
        call.map { CallSnapshot(call: $0, seenAt: now) }
    }

    /// Whether a saved call is still waiting to be picked up.
    public var isResumePending: Bool { resumable != nil }

    /// **Playing is needed to START a call, not to keep one.** A browser stops
    /// its sound output whenever nobody is talking — a quiet Meet's output
    /// switched on and off every few seconds in the owner's log — so once a
    /// call is known, the same app still holding the mic is enough. The same
    /// goes for the call a previous run saved: it was already proven a call,
    /// and relaunching into a quiet moment left it unfound (build 741).
    @discardableResult
    public mutating func observe(_ users: [MicUser], at now: Date) -> Change? {
        // Sorted so two apps on the mic at once always resolve the same way.
        let onMic = users.sorted { $0.bundleID < $1.bundleID }
        let calling = onMic.filter(\.playing)

        if let current = call {
            if onMic.contains(where: { $0.bundleID == current.bundleID }) {
                lostAt = nil
                return nil
            }
            let since = lostAt ?? now
            lostAt = since
            guard now.timeIntervalSince(since) >= Self.grace else { return nil }
            call = nil
            lostAt = nil
            candidate = nil
            return .ended(current, at: since)
        }

        if let snapshot = resumable, now.timeIntervalSince(snapshot.seenAt) > Self.resumeWindow {
            resumable = nil
        }
        let saved = resumable?.call.bundleID
        let eligible = onMic.filter { $0.playing || $0.bundleID == saved }

        if let waiting = candidate, eligible.contains(where: { $0.bundleID == waiting.bundleID }) {
            guard now.timeIntervalSince(waiting.startedAt) >= Self.settle else { return nil }
            candidate = nil
            if let snapshot = resumable, snapshot.call.bundleID == waiting.bundleID {
                resumable = nil
                call = snapshot.call
                return .resumed(snapshot.call)
            }
            // Only the saved call may skip the playing test; if it expired
            // during the settle, this is a mic with nobody on the other end.
            guard calling.contains(where: { $0.bundleID == waiting.bundleID }) else { return nil }
            resumable = nil
            call = waiting
            return .started(waiting)
        }
        // The saved call's app first, so another app joining the mic at the
        // same moment cannot take its place.
        let next = eligible.first { $0.bundleID == saved } ?? calling.first
        candidate = next.map {
            OngoingCall(bundleID: $0.bundleID, appName: $0.name, startedAt: now)
        }
        return nil
    }
}
