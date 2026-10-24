import Foundation

/// When a microphone that has just started may be stopped again.
///
/// **The crash this exists for** (2026-10-21). The ask key went down, the
/// engine came up, a shortcut on the same modifier called the hold off about a
/// tenth of a second later, and while `AVAudioEngine.stop()` was tearing the
/// input down on the main thread, Core Audio's own input thread jumped to
/// address zero and took the app with it. Nothing of ours was on that thread.
/// Every shortcut on a hold key does this start-then-stop — one log held 231
/// of them — so a race inside macOS that is rare per stop is not rare per day.
///
/// The start cannot be the one to wait: a grace before the microphone opened
/// was tried and clipped the first syllable (see `DictationModel.beginHold`).
/// So the STOP waits, for the one sign we have that the input thread is
/// running steadily rather than still starting: the first buffer reaching our
/// tap. On a working input that is a buffer's length after the start, around
/// a tenth of a second, and a stop that comes later than that waits for
/// nothing.
///
/// Pure and time-parameterised like `HoldGesture`, so the rule is tested where
/// `swift test` can see it; `AudioCapture.stopWhenSettled` does the waiting.
public enum MicrophoneSettle {
    /// How long a stop waits for that first buffer before going ahead anyway,
    /// so an input that never delivers cannot keep the microphone open.
    ///
    /// The same figure as `SilentCapture.inputSettle`, because it is the same
    /// fact: how long an input may take to start delivering. Bluetooth is the
    /// slow case, at about a second; a wired or built-in microphone delivers
    /// well inside it, so a working input never waits this long.
    public static let ceiling: TimeInterval = SilentCapture.inputSettle

    /// Whether the microphone started at `startedAt` may be stopped at `now`.
    ///
    /// `ceiling` is a parameter so tests of the waiting itself need not spend
    /// a second each; everything else uses the default.
    public static func mayStop(startedAt: Date, heardFirstBuffer: Bool, now: Date,
                               ceiling: TimeInterval = Self.ceiling) -> Bool {
        heardFirstBuffer || now.timeIntervalSince(startedAt) >= ceiling
    }
}
