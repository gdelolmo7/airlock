import Foundation

/// What one press of Escape means while the assistant surface is up.
///
/// **Pure, and in Core, because the alternative is two event monitors.** The
/// panel is non-activating, so SwiftUI never sees these keys and every consumer
/// installs an `NSEvent.addLocalMonitorForEvents` — see the note on
/// `AssistantModel.beginKeyboardSession` and the identical one on
/// `ClipboardWidgetModel`. Adding a second monitor for a command bar would put
/// two closures in the same global list, both claiming the same keyCode, with
/// the winner decided by installation order. That is not a thing anyone can
/// reason about, and it is not a thing a test can pin.
///
/// So there stays exactly one monitor, and this decides what it does. The
/// ordering is the whole content of the type, and it is here rather than in a
/// `switch` inside a view so it can be read in one screen and asserted in one
/// test.
public enum AssistantEscape: Sendable {

    /// One rung. Named for the effect, not the widget, so the app's mapping
    /// stays a `switch` the compiler checks.
    public enum Step: Sendable, Equatable {
        /// Drop an unanswered proposal. Never performs it — see
        /// `AssistantModel.dismiss`, where the same rule is recorded as
        /// `.deferred` in the gate log.
        case dismissCard
        /// Empty the command bar but leave it open and focused.
        case clearTypedText
        /// Close the command bar.
        case closeBar
        /// Take down an answer, the question, and the whole surface.
        case dismissAnswer
        /// Not ours. Hand the event on rather than swallowing it — a monitor
        /// that eats every Escape breaks Escape everywhere else in macOS.
        case pass
    }

    /// Narrowest thing first, and each rung undoes strictly less than the one
    /// below it.
    ///
    /// The order is not arbitrary and each step earns its place:
    ///
    /// - **A pending card outranks everything.** It is the only state where
    ///   something is waiting on the user, and the island contract reserves
    ///   expansion for exactly that. Escape has to be able to say no to it
    ///   before it can be used to tidy anything else away.
    /// - **Then the text, and only if there is any.** A half-typed command is
    ///   work; losing the panel and the words in one keystroke is the mistake
    ///   people make once and then stop trusting the bar. An EMPTY bar skips
    ///   this rung entirely, so Escape-Escape closes and Escape on an empty bar
    ///   closes immediately — pressing it twice to shut an empty field reads as
    ///   the key not working.
    /// - **Then the bar**, then whatever answer is behind it.
    /// - **Then pass.** Silence is not ours to keep.
    public static func step(hasPending: Bool,
                            barHasText: Bool,
                            barOpen: Bool,
                            isPresenting: Bool) -> Step {
        if hasPending { return .dismissCard }
        if barOpen { return barHasText ? .clearTypedText : .closeBar }
        if isPresenting { return .dismissAnswer }
        return .pass
    }
}
