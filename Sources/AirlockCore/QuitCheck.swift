import Foundation

/// Whether quitting Airlock asks first.
///
/// Since a full window puts Airlock in the Dock (`DockPresence`), ⌘Q while
/// call notes are in front quits the whole app, not the window. Pressed out of
/// habit to "close the notes app" in the middle of a call, it would stop that
/// call's notes. So while notes are being taken, paused included, a quit asks
/// once; at any other time it goes straight through, as it always has.
///
/// Two kinds of quit never ask. A log out, restart or shut down: a question
/// there holds up the whole Mac, and the notes survive it anyway (see
/// `question`). And Airlock quitting itself on purpose, such as an update
/// relaunching it: whoever started that has already decided.
public enum QuitCheck {
    public enum Reason: Equatable, Sendable {
        /// ⌘Q, Quit from a menu or the Dock, a script.
        case asked
        /// The Mac is logging out, restarting or shutting down.
        case macEnding
        /// Airlock is quitting itself, and meant to.
        case onPurpose
    }

    /// Reads the reason off what macOS sent.
    ///
    /// `quitReasonCode` is the four-letter code in the quit event's reason
    /// attribute, nil when there is no event (⌘Q is a menu action, not an
    /// event) or no reason in it (the Dock's Quit, a script). macOS sets it
    /// only when the session is ending.
    public static func reason(quitReasonCode: UInt32?, onPurpose: Bool) -> Reason {
        if onPurpose { return .onPurpose }
        if let quitReasonCode, macEndingCodes.contains(quitReasonCode) { return .macEnding }
        return .asked
    }

    public static func asks(takingNotes: Bool, reason: Reason) -> Bool {
        takingNotes && reason == .asked
    }

    /// The codes the system puts in a quit event while the session ends:
    /// log out (with and without its dialog), restart and shut down (with and
    /// without theirs).
    public static let macEndingCodes: Set<UInt32> = Set(
        ["logo", "rlgo", "rrst", "rsdn", "rest", "shut"].map(fourCharCode)
    )

    static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// What the question says.
    public struct Question: Equatable, Sendable {
        public let title: String
        public let message: String
        /// The default, for Return and Escape alike: nobody loses notes by
        /// pressing the wrong key.
        public let keep: String
        public let quit: String
    }

    /// Worded for the person, and true to what a quit actually does: the
    /// transcript is written to disk after every sentence, and the next
    /// launch writes the notes of any call that was cut off. So what is lost
    /// is the rest of the call, not what was already said.
    public static func question(inPerson: Bool) -> Question {
        let what = inPerson ? "this meeting" : "this call"
        return Question(
            title: "Airlock is taking notes",
            message: "Quitting now stops the notes for \(what). What's been said so far is kept, "
                + "and the notes are written from it when Airlock opens again.",
            keep: "Keep taking notes",
            quit: "Quit anyway"
        )
    }
}
