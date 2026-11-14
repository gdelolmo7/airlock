import Foundation

/// The push-to-talk gesture, as a pure state machine.
///
/// Hold a key, speak, release. Simple until you ask what happens when the
/// release never comes — and it does happen: another app grabs the keyboard, a
/// Space switches, the screen locks mid-hold. Carbon hands us a press and a
/// release as independent events with nothing tying them together, so a lost
/// release means an audio engine running forever and a microphone light that
/// never goes out. That is the failure this type exists to make impossible.
///
/// Time is always a parameter, never `Date()` read from inside. That is what
/// makes every branch here testable in microseconds instead of by holding a key.
public struct HoldGesture: Equatable, Sendable {
    /// Below this, it was a tap, not a hold.
    ///
    /// Capture still starts on the way down rather than after a delay: people
    /// begin speaking immediately, and arming late would clip the first word.
    /// The audio is simply thrown away if the key comes back up too soon, which
    /// costs a few hundred milliseconds of engine time and loses nothing.
    ///
    /// **Raised from 0.25.** The hold keys are bare modifiers, which are also
    /// how every chord on the machine starts, so brushing one is ordinary rather
    /// than exceptional. A chord proper is disqualified by `HoldKeyMonitor` the
    /// moment the second key or a click arrives; this floor is for the bare tap
    /// with nothing after it, which nothing else catches. At 0.25 those reached
    /// the recogniser, found silence, and produced a card apologising for a
    /// microphone that was fine.
    ///
    /// It is deliberately NOT raised to the second or so an input can take to
    /// start delivering — that would discard genuine short speech on a wired
    /// microphone. What happens between here and there is a message that admits
    /// the window was short, rather than one that blames the hardware. See
    /// `SilentCapture`.
    ///
    /// **0.375 rather than the rounder 0.4, and the reason is arithmetic.** This
    /// type documents an INCLUSIVE boundary — exactly at the minimum counts —
    /// and the only way to test that is to build two `Date`s that differ by
    /// exactly this. A `Date` is a double around 7.8e8, where the gap between
    /// representable values is about 1.2e-7, so a fraction that is not a sum of
    /// powers of two does not survive the round trip: 0.4 comes back as
    /// 0.39999997, which is *below* the floor, so the boundary case fails and
    /// the contract silently becomes exclusive. 0.375 is 2⁻² + 2⁻³ and is exact.
    /// The 25ms this gives up is worth an assertion that means what it says.
    public static let minimumHold: TimeInterval = 0.375

    /// The floor to use when the chord guard is known to be blind.
    ///
    /// `HoldKeyMonitor` disqualifies a hold the moment a second key arrives —
    /// that is what stops ⌥⌫ being read as speech. macOS's secure event input
    /// withholds key events from every event tap, so while another app holds it
    /// that guard does not fire, and deleting a word with the modifier down is
    /// indistinguishable from someone about to talk.
    ///
    /// There is no way to see the keystroke in that state, so the only lever
    /// left is time. A second is long enough that word-deleting rarely reaches
    /// it and short enough to stay usable, and it applies ONLY while secure
    /// input is actually held — normal operation keeps the 0.375 floor and its
    /// immediate feedback.
    public static let blindHold: TimeInterval = 1.0

    /// A ceiling, so a genuinely stuck key cannot record until the disk fills.
    /// Reaching it delivers what was said — it is a safety limit, not a penalty.
    ///
    /// Five minutes with the key held. It was two, which cut off anyone
    /// thinking a longer message through aloud.
    public static let maximumHold: TimeInterval = 300

    /// The ceiling for a dictation locked on by a tap. Longer than a hold,
    /// because nobody is pinning a key down for it — and still a ceiling,
    /// because a locked dictation that was forgotten is a microphone left on.
    public static let maximumLocked: TimeInterval = 600

    /// How long a locked dictation may hear nothing at all before it is taken
    /// for a stray tap and ended quietly.
    ///
    /// The hold keys are bare modifiers, and brushing one is ordinary. With
    /// tap-to-lock that brush would otherwise leave the microphone open for
    /// ten minutes behind somebody who never meant to dictate.
    public static let strayLockWindow: TimeInterval = 15

    /// Whether a locked dictation should be given up as a tap nobody meant.
    /// Words or a voice on the microphone at any point keep it.
    public static func lockLooksStray(runningFor: TimeInterval, heardWords: Bool, peak: Float) -> Bool {
        runningFor >= strayLockWindow && !heardWords && peak < HoldInterruption.voiceLevel
    }

    public enum Event: Equatable, Sendable {
        case keyDown(at: Date)
        case keyUp(at: Date)
        /// The watchdog. `isPhysicallyDown` comes from the hardware key state
        /// rather than from our event stream, which is the entire point: it is
        /// the one source that cannot have missed an event.
        case tick(at: Date, isPhysicallyDown: Bool)
        /// Torn down from outside — the feature switched off, the app quitting,
        /// or Escape.
        case cancel
        /// The key is down and something else is going on with it: a scroll,
        /// a drag, or (while locked on) another key or a click. That was a
        /// shortcut, not a tap, so the release that follows neither locks a
        /// new dictation on nor stops a locked one.
        case pressAbandoned
    }

    public enum Effect: Equatable, Sendable {
        case startCapture
        /// A tap: keep recording with the key up, until it is tapped again.
        case lock
        /// Stop, transcribe, deliver.
        case finish(Finish)
        /// Stop, transcribe nothing, deliver nothing.
        case discard(Discard)
    }

    public enum Finish: Equatable, Sendable {
        case released
        /// The key came up without us being told. Still delivers: the words were
        /// spoken, and losing them because an event went missing would be a
        /// worse bug than the one being worked around.
        case releaseLost
        case reachedLimit
    }

    public enum Discard: Equatable, Sendable {
        case tooShort
        case cancelled
    }

    /// When the current hold began; nil when idle.
    public private(set) var startedAt: Date?

    /// This gesture's floor. Per-instance rather than always the static, so the
    /// caller can raise it for a hold it knows it cannot disqualify — see
    /// `blindHold`. Fixed at construction: a floor that moved mid-hold would
    /// change the answer to "was this long enough" while the key was still down.
    public let floor: TimeInterval

    /// Whether a release below the floor locks the dictation on instead of
    /// discarding it. Off unless asked for: the caller turns it on only when
    /// the person has the setting on and the chord guard can see keys — a
    /// blind hold cannot tell a tap from ⌥⌫ (`blindHold`).
    public let locksOnTap: Bool

    /// Recording with the key up, after a tap. Ends on the next press and
    /// release, on `cancel`, or at `maximumLocked`.
    public private(set) var isLocked = false

    /// Locked, and the key is down again: its release stops the dictation.
    private var isStopping = false

    /// This press was shared with a scroll or a drag (`pressAbandoned`), so
    /// its release is not a tap. ⌃-scroll is the screen zoom, and a quick
    /// one used to lock the microphone on behind it.
    private var isShared = false

    public init(startedAt: Date? = nil, floor: TimeInterval = HoldGesture.minimumHold,
                locksOnTap: Bool = false) {
        self.startedAt = startedAt
        self.floor = floor
        self.locksOnTap = locksOnTap
    }

    public var isRecording: Bool { startedAt != nil }

    /// The ceiling this dictation runs to.
    public var limit: TimeInterval { isLocked ? Self.maximumLocked : Self.maximumHold }

    private mutating func reset() {
        startedAt = nil
        isLocked = false
        isStopping = false
        isShared = false
    }

    public func heldFor(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    /// Returns what the caller should do, or nil for "nothing changed".
    ///
    /// Every transition is idempotent. A second `keyDown` while recording is
    /// ignored rather than restarting — key repeat exists, and auto-repeat on a
    /// held key would otherwise tear down and rebuild the audio engine many
    /// times a second.
    @discardableResult
    public mutating func apply(_ event: Event) -> Effect? {
        switch event {
        case .keyDown(let now):
            guard startedAt != nil else {
                startedAt = now
                return .startCapture
            }
            // Locked on: this press is the one that stops it, on the way up.
            // On the way up and not down, so a shortcut that starts with the
            // same key can still be told apart (`pressAbandoned`).
            if isLocked { isStopping = true }
            return nil

        case .keyUp(let now):
            guard let started = startedAt else { return nil } // release with no press
            if isLocked {
                guard isStopping else { return nil }
                reset()
                return .finish(.released)
            }
            if now.timeIntervalSince(started) >= floor {
                reset()
                return .finish(.released)
            }
            if locksOnTap, !isShared {
                isLocked = true
                return .lock
            }
            reset()
            return .discard(.tooShort)

        case .tick(let now, let isPhysicallyDown):
            guard let started = startedAt else { return nil }
            let held = now.timeIntervalSince(started)
            if held >= limit {
                reset()
                return .finish(.reachedLimit)
            }
            // Locked on, the key is meant to be up.
            guard !isLocked, !isPhysicallyDown else { return nil }
            reset()
            // Same short-tap rule as a real release: a key that was never held
            // long enough is a tap whether or not we saw it come up. A lost
            // release never locks — nobody chose that.
            return held >= floor ? .finish(.releaseLost) : .discard(.tooShort)

        case .cancel:
            guard startedAt != nil else { return nil }
            reset()
            return .discard(.cancelled)

        case .pressAbandoned:
            isStopping = false
            if startedAt != nil, !isLocked { isShared = true }
            return nil
        }
    }
}
