import Foundation

/// Whether both sides of a call are reaching the notes, decided while the
/// call is on, so the panel can say so then rather than after the call,
/// when the missing half is already lost.
///
/// "Not reaching" means no sound is arriving at all, which is different from
/// someone being quiet. A quiet side is normal (people take turns), so a
/// side only counts as missing while the OTHER side is talking: then the
/// call is clearly live, and the missing half is clearly being lost.
///
/// The two "missing" lines hold once shown until sound arrives again, so a
/// pause in the other side's talking does not make them blink. Pure and fed
/// on each look by the model, which measures the two streams.
public struct CallChannelHealth: Equatable, Sendable {
    /// What the model measured of one side.
    public struct Side: Equatable, Sendable {
        /// When this side's sound was first asked for; nil while it has not
        /// started at all (the call app makes no sound yet, so there is
        /// nothing to listen to).
        public var since: Date?
        /// The last moment sound arrived. For the microphone that is
        /// `microphoneInput`: any buffer at all once the stream now running
        /// has carried a sample above zero, and only such a sample before
        /// then. For the call it is any sound at all, silence included,
        /// because a call app hands over silence whenever nobody talks.
        public var lastInput: Date?
        /// The last moment this side held speech (`isSpeech`).
        public var lastSpeech: Date?
        /// Whether a single sample above zero has ever arrived.
        public var heardAnything: Bool

        public init(since: Date? = nil, lastInput: Date? = nil, lastSpeech: Date? = nil,
                    heardAnything: Bool = false) {
            self.since = since
            self.lastInput = lastInput
            self.lastSpeech = lastSpeech
            self.heardAnything = heardAnything
        }
    }

    /// No sound from one side for this long, while the other talks, and it
    /// is said. About the length of a sentence: long enough that a device
    /// switch (`MicRestart`) is over before anything shows.
    public static let quietLimit: TimeInterval = 3
    /// The call app's sound has been arriving this long and every sample of
    /// it was zero: macOS is handing over silence, which is what a refused
    /// "System Audio Recording" permission looks like. Long, because a call
    /// can open with a minute of nobody saying anything.
    public static let permissionLimit: TimeInterval = 45
    /// Loud enough to be someone talking: about -40 dB below full scale, as
    /// a root-mean-square over one buffer. A room's hum and a fan sit below
    /// it; a voice at a laptop's microphone, or out of a call, sits well
    /// above it.
    public static let speechLevel: Float = 0.01

    /// Your microphone's sound isn't arriving.
    public private(set) var yoursMissing = false
    /// The call's sound isn't arriving.
    public private(set) var theirsMissing = false
    /// The call's sound arrives but is all zeros: the permission is off.
    public private(set) var theirsNotAllowed = false

    public init() {}

    /// One look. `youAreMuted` is the call app's own mute button: muted, your
    /// side is not expected on the call, so it is never "missing".
    public mutating func update(yours: Side, theirs: Side, youAreMuted: Bool, now: Date) {
        let yoursQuiet = Self.isMissing(yours, now: now)
        let theirsQuiet = Self.isMissing(theirs, now: now)
        if youAreMuted || !yoursQuiet {
            yoursMissing = false
        } else if Self.isTalking(theirs, now: now) {
            yoursMissing = true
        }
        if !theirsQuiet {
            theirsMissing = false
        } else if Self.isTalking(yours, now: now) {
            theirsMissing = true
        }
        if let since = theirs.since, !theirs.heardAnything {
            theirsNotAllowed = now.timeIntervalSince(since) >= Self.permissionLimit
        } else {
            theirsNotAllowed = false
        }
    }

    /// No sound from the microphone for this long, at a meeting in the
    /// room, and it is said. Longer than `quietLimit`: with no other side
    /// to show the meeting is live, only the stream itself can be judged,
    /// and a device switch must be over first.
    public static let roomLimit: TimeInterval = 10

    /// One look at a meeting in the room, where the microphone is the only
    /// side: missing once nothing has arrived for `roomLimit`. Nobody
    /// talking is not enough to say it, so it is never "only while the
    /// other side talks"; there is no call sound to be missing or refused.
    public mutating func update(room microphone: Side, now: Date) {
        if let since = microphone.since {
            let last = max(microphone.lastInput ?? since, since)
            yoursMissing = now.timeIntervalSince(last) >= Self.roomLimit
        } else {
            yoursMissing = false
        }
        theirsMissing = false
        theirsNotAllowed = false
    }

    /// Your side's `Side.lastInput`, from what the microphone stream measured.
    ///
    /// Some microphones (USB ones with a noise gate, some headsets) send
    /// exact zeros whenever you are quiet, so "a sample above zero" alone
    /// would call your side missing every time you listen while they talk.
    /// Once the stream now running has carried real sound, it is a working
    /// microphone, and buffers arriving are enough: zeros after that are the
    /// gate, or you being quiet. Before then, a stream of nothing but zeros is
    /// a refused permission or a dead device, and only real sound counts.
    /// - `lastBuffer`: the last buffer of any kind, zeros included.
    /// - `lastSound`: the last buffer with a sample above zero.
    /// - `streamStartedAt`: when the microphone stream now running started;
    ///   nil when the last start failed. Sound from a stream before it does
    ///   not vouch for this one, which may be on another device.
    public static func microphoneInput(lastBuffer: Date?, lastSound: Date?,
                                       streamStartedAt: Date?) -> Date? {
        guard let streamStartedAt, let lastSound, lastSound >= streamStartedAt else {
            return lastSound
        }
        return max(lastBuffer ?? lastSound, lastSound)
    }

    /// Started, and nothing has arrived for `quietLimit`.
    static func isMissing(_ side: Side, now: Date) -> Bool {
        guard let since = side.since else { return false }
        let last = max(side.lastInput ?? since, since)
        return now.timeIntervalSince(last) >= quietLimit
    }

    static func isTalking(_ side: Side, now: Date) -> Bool {
        guard let spoke = side.lastSpeech else { return false }
        return now.timeIntervalSince(spoke) < quietLimit
    }

    /// Whether a buffer's level is someone talking.
    public static func isSpeech(level: Float) -> Bool { level >= speechLevel }

    /// Root-mean-square level of samples in -1...1.
    public static func level<Samples: Collection>(_ samples: Samples) -> Float
    where Samples.Element == Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Root-mean-square level of 16-bit samples, on the same -1...1 scale.
    public static func level<Samples: Collection>(_ samples: Samples) -> Float
    where Samples.Element == Int16 {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            let scaled = Float(sample) / Float(Int16.max)
            sum += scaled * scaled
        }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// When the notes' microphone is started again.
///
/// Switching headsets, or AirPods going in or out, changes the Mac's
/// microphone mid-call. The audio engine stops itself when that happens and
/// its stream goes quiet without ending, so your side of the notes would stop
/// being written for the rest of the call while the call itself carries on
/// with the new microphone. The model starts the microphone again, on the new
/// device, into the same notes.
public struct MicRestart: Equatable, Sendable {
    /// No sound from a running microphone for this long and it has stalled.
    /// A working one hands over a buffer about ten times a second.
    public static let stallLimit: TimeInterval = 2
    /// After a start that did not bring sound back, wait this long before the
    /// next, doubling each time up to `longestWait`, so a microphone that
    /// cannot start is not hammered all call long.
    public static let firstWait: TimeInterval = 2
    public static let longestWait: TimeInterval = 30

    private var lastTry: Date?
    private var wait: TimeInterval = firstWait

    public init() {}

    /// Whether to start the microphone again now.
    /// - `startedAt`: when the current stream started; nil when the last
    ///   start failed.
    /// - `lastInput`: the last buffer from any stream so far.
    /// - `deviceChanged`: the Mac's microphone is no longer the one the
    ///   stream started on.
    public mutating func shouldRestart(now: Date, startedAt: Date?, lastInput: Date?,
                                       deviceChanged: Bool) -> Bool {
        if deviceChanged {
            // A new device is a new chance: no waiting carried over.
            wait = Self.firstWait
            lastTry = now
            return true
        }
        if let startedAt {
            // Only this stream's sound counts, not the stalled one's before it.
            let fresh = lastInput.flatMap { $0 >= startedAt ? $0 : nil }
            if now.timeIntervalSince(fresh ?? startedAt) < Self.stallLimit {
                if fresh != nil {
                    // Flowing: the next stall starts over.
                    wait = Self.firstWait
                    lastTry = nil
                }
                return false
            }
        }
        if let lastTry {
            guard now.timeIntervalSince(lastTry) >= wait else { return false }
            wait = min(wait * 2, Self.longestWait)
        }
        lastTry = now
        return true
    }
}
