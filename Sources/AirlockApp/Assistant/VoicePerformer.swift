import AppKit
import AirlockCore

/// Does what a `VoiceEffect` says, and the only place that knows how.
///
/// **Split out of `AppDelegate` because a closure buried in the middle of a
/// launch routine is not reachable by a test, and the failure this type exists
/// to prevent is exactly the one a test catches.** `VoiceActionCatalog.registered`
/// grew from one action to three; the switch that performs them did not. For as
/// long as that lasted, "copy the last thing I copied from Figma" resolved to
/// nothing and fell through to being answered, and "tell claude to run the
/// tests" put a card on screen and then reported that the session had gone
/// away — a card that promised and then failed. Neither made a sound, because
/// nothing crashes when a registry and a switch disagree.
///
/// Every arm is a closure rather than a model reference, so `VoicePerformerTests`
/// can drive the whole thing with no audio device, no pasteboard and no
/// terminal. `AppDelegate` supplies the real ones.
///
/// Each arm **re-resolves its subject at the moment of use** rather than trusting
/// what the proposal captured. AirPods disconnect, clipboard rows age out of
/// history, and the gap between speaking and clicking Do it is as long as the
/// user wants it to be. Returning false there is what makes
/// `AssistantModel.carryOut` say "couldn't" instead of claiming success.
@MainActor
struct VoicePerformer {
    /// Put an earlier clipboard row back on the pasteboard.
    var copyClipboardItem: (UUID) -> Bool

    /// Move system sound output to a device, by UID.
    var selectAudioOutput: (String) -> Bool

    /// Start a fresh agent session carrying the prompt.
    var startSession: (String) -> Bool

    /// Run one of the user's Shortcuts, by exact name.
    ///
    /// True means it was STARTED, not that it succeeded — a Shortcut can run for
    /// minutes and fail at the end, and the card is long gone by then. That is
    /// the same bargain `startSession` makes when it opens a terminal, and it is
    /// stated here so nobody reads a `true` as more than it is.
    var runShortcut: (String) -> Bool

    /// Set system output volume, 0...1. False when the current device has no
    /// software volume — HDMI and many USB interfaces do not.
    var setVolume: (Double) -> Bool

    /// Play, pause or skip whatever is playing.
    var media: (VoiceMediaCommand) -> Bool

    /// Open an app bundle or an http(s) URL. False when an app has moved or
    /// been deleted since the card was shown.
    var open: (VoiceOpenTarget) -> Bool

    /// Send a prompt to a session the user is already running.
    ///
    /// **Nil, and not an oversight.** There is no mechanism for it and the tree
    /// twice says there deliberately is not:
    /// `TerminalJumpService.openTerminalRunningClaude` opens "a new window on
    /// purpose: never inject into a session the user already owns", and
    /// `openTerminal(running:)` repeats that "injecting into a session someone
    /// already owns would interleave with whatever is running in it".
    ///
    /// So this stays nil, and `AppDelegate` leaves `VoiceContext.agentSessions`
    /// empty to match — with no session named, `VoiceAgentAction` proposes a
    /// fresh one, which is a card that says what will actually happen. Filling
    /// in one half without the other is how the card started lying in the first
    /// place. Wiring this up is a product decision about interleaving, not a
    /// missing line.
    var sendToExistingSession: ((String, String) -> Bool)?

    /// One exhaustive switch, so a new `VoiceEffect` is a compile error here
    /// rather than a silent `false` at runtime.
    func perform(_ effect: VoiceEffect) -> Bool {
        switch effect {
        case .copyClipboardItem(let id):
            return copyClipboardItem(id)

        case .selectAudioOutput(let uid):
            return selectAudioOutput(uid)

        case .sendPrompt(let sessionID, let text):
            // A nil session is not a failure to resolve one — it is
            // `VoiceAgentAction` saying nothing was named, which is what the
            // card showed as "Start a new session".
            guard let sessionID else { return startSession(text) }
            return sendToExistingSession?(sessionID, text) ?? false

        case .runShortcut(let name):
            return runShortcut(name)

        case .setVolume(let level):
            return setVolume(level)

        case .media(let command):
            return media(command)

        case .open(let target):
            return open(target)
        }
    }
}
