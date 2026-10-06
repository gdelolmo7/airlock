import Foundation

/// Why a hold delivered no audio — the microphone, or the app closing the
/// window before the microphone had started.
///
/// **The bug this exists for.** `deliver` decided this on the peak level alone:
/// flat meant "the microphone produced nothing, which is locatable and fixable",
/// and the card said so — *"the hold registered and the transcriber ran, so this
/// is the microphone rather than the app"*. It had no idea how long the window
/// had been open, so it said that about captures that were never open long
/// enough for any input to deliver a sample.
///
/// That is the worst reading available, because it sends somebody to Settings to
/// replace a microphone that works. Found in a real log: sixteen captures, two
/// of them over two seconds and both transcribed fine, and seven of the fourteen
/// sub-second ones at `peak` exactly 0.0 — not a quiet room, which reads around
/// 0.001–0.02 in the same log, but no samples at all. The input was a pair of
/// Bluetooth headphones being used for playback at the time.
///
/// Pure and time-parameterised like `HoldGesture`, and for the same reason: the
/// view layer of dictation cannot be unit-tested, so the decision worth
/// protecting is the one that gets extracted to where `swift test` can see it.
public enum SilentCapture: Equatable, Sendable {
    /// The level never moved, and the window was too short to conclude anything
    /// from that. Says nothing about the microphone.
    case tooShort
    /// The window was open long enough that a working input would have
    /// delivered something, and it stayed flat. Now it is the microphone.
    case inputProducedNothing

    /// Below this, nothing reached the microphone at all.
    public static let silenceFloor: Float = 0.001

    /// How long an input may take to start delivering before its silence is
    /// evidence of anything.
    ///
    /// Sized for Bluetooth, which is the case that gets this wrong: a headset
    /// being used for playback has to switch profiles before it can record, and
    /// it is silent for roughly a second while it does. A wired input is
    /// delivering well inside this, so the only cost of the allowance is that a
    /// genuinely dead wired microphone is described as "too short" for the first
    /// second — a vaguer message, not a wrong one.
    public static let inputSettle: TimeInterval = 1.0

    /// - Parameter listenedFor: the window the analyzer was actually up for,
    ///   NOT how long the key was down. The engine start sits between the two
    ///   and is precisely the part that eats a short hold.
    ///
    /// Returns nil when the level moved — there is no silence to explain.
    public static func diagnose(peak: Float, listenedFor: TimeInterval) -> SilentCapture? {
        guard peak < silenceFloor else { return nil }
        return listenedFor < inputSettle ? .tooShort : .inputProducedNothing
    }
}
