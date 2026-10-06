import Foundation

/// A question that can no longer be answered from the notch, and why.
///
/// Both ways a question can end without an answer used to end the same way on
/// screen: the card vanished. That is right for the card — nothing is waiting,
/// so nothing should look like it is — and wrong for the user, who saw a
/// question, looked away, and came back to a panel that had quietly forgotten
/// it. "Did I imagine that?" is the state this exists to prevent.
///
/// It is a **receipt**, not a gate: it carries no options and no buttons except
/// a dismiss, because the decision has already gone elsewhere. `.ignored` sends
/// the ask back to the agent's own prompt — the same place `ask_timeout` sends
/// it — and `.agentExited` has nowhere to send it at all.
public struct QuestionReceipt: Codable, Sendable, Hashable {
    public enum Reason: String, Codable, Sendable, Hashable {
        /// Handed back on purpose (the card's Escape) or by `ask_timeout`. The
        /// agent is alive and asking in its own terminal.
        case ignored
        /// The agent died with the question still on screen. Nothing is
        /// listening, which is why the options are gone rather than dimmed — a
        /// disabled row still looks like something you could click if you tried
        /// harder.
        case agentExited
    }

    public var question: String
    public var header: String?
    public var reason: Reason
    public var at: Date

    public init(question: String, header: String? = nil, reason: Reason, at: Date) {
        self.question = question
        self.header = header
        self.reason = reason
        self.at = at
    }

    public var title: String {
        switch reason {
        case .ignored: return "Asked in its terminal instead"
        case .agentExited: return "Exited before you answered"
        }
    }
}
