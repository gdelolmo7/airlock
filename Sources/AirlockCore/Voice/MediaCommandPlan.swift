import Foundation

/// What to do to the player, given what was asked and what dictation already did.
///
/// **Pure and separate because this decision has three inputs and the player
/// only offers a toggle.** Every wrong answer here looks identical from outside
/// — the card says it worked and the music does the opposite — and two of the
/// three inputs are invisible to the person speaking: the poll's idea of what is
/// playing, and the fact that dictation paused the track for the duration of the
/// hold before the command was even transcribed.
///
/// That third input is the one that made this worth extracting. Holding the ask
/// key pauses playback (`DictationModel.pauseMusicIfWanted`), so by the time
/// "pause the music" is understood, the player is ALREADY paused — and an arm
/// that reasons from the observed state alone is reasoning about a player
/// something else moved underneath it.
public enum MediaCommandPlan {

    public enum Action: Equatable, Sendable {
        /// Send the toggle. The player offers nothing else.
        case toggle
        /// It is already doing what was asked. Report success and touch nothing —
        /// sending a toggle here would do the OPPOSITE of the card.
        case alreadyThere
        /// Nothing is playing and nothing can be told to start. `MediaWidgetModel.send`
        /// needs `state.player` to know which controller to talk to, so there is
        /// no toggle to send.
        case noPlayer
    }

    /// - Parameters:
    ///   - command: what was asked for.
    ///   - isPlaying: what the player is doing RIGHT NOW, nil when there is no
    ///     player at all.
    ///   - dictationPaused: whether dictation paused this track for the hold and
    ///     has not put it back. When true, `isPlaying` is false because of us —
    ///     not because of the user — and the state the SPEAKER was describing is
    ///     playing.
    public static func decide(command: VoiceMediaCommand,
                              isPlaying: Bool?,
                              dictationPaused: Bool) -> Action {
        guard let isPlaying else { return .noPlayer }

        switch command {
        case .next, .previous:
            // Skipping works whether or not it is playing, and dictation's pause
            // does not change which track is next.
            return .toggle

        case .play:
            // Dictation's pause is exactly the thing to undo. `isPlaying` is
            // false, and toggling is right — the difference from the ordinary
            // paused case is only that the user never saw it stop.
            return isPlaying ? .alreadyThere : .toggle

        case .pause:
            // **The case that reads as the command being ignored.** Dictation
            // already paused it, so the observed state matches the request and
            // the honest answer is that nothing needs sending. What makes that
            // correct rather than a silent failure is the CALLER cancelling
            // dictation's resume — otherwise the track comes back a moment
            // later and the command appears to have done nothing at all.
            //
            // `dictationPaused` is not consulted for the decision, only recorded
            // in this comment: the end state is identical either way. It is a
            // parameter because reading it is how the caller remembers there is
            // a resume to cancel.
            return isPlaying ? .toggle : .alreadyThere
        }
    }
}
