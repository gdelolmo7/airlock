import Foundation

/// Whether the pointer leaving the panel should take an answer with it.
///
/// Pure and in Core because the interesting part is a three-way condition, and
/// the alternative is discovering it by hovering at a notch — which is how the
/// bug it fixes survived: an answer stayed up until Escape or the 45-second
/// timer, so the panel sat over the top of the screen long after it had been
/// read, and moving the pointer away did nothing.
public enum AnswerDismissal {

    /// - Parameters:
    ///   - answerShowing: the assistant is holding the panel open.
    ///   - hoveredSinceAnswer: the pointer has been ON the panel since this
    ///     answer appeared. Edge-triggered for a recorded reason — an out event
    ///     can arrive with no matching in, and acting on that alone dismissed
    ///     the answer the instant it was shown.
    ///   - hasPendingCard: something is waiting on the user.
    public static func onPointerExit(answerShowing: Bool,
                                     hoveredSinceAnswer: Bool,
                                     hasPendingCard: Bool) -> Bool {
        // A card is exempt, and this is the whole reason the rule is not simply
        // "dismiss on exit". A card is a question waiting on an answer; the
        // island contract reserves expansion for exactly that, and dropping one
        // because the pointer wandered would be answering it by walking away —
        // logged `.deferred`, with the agent left waiting for its own timeout.
        guard !hasPendingCard else { return false }
        return answerShowing && hoveredSinceAnswer
    }
}
