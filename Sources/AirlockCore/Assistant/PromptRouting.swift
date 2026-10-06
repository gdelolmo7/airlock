import Foundation

/// Where a typed phrase should go, when the grammar has already declined it.
///
/// The command bar and the quick-prompt bar are kept apart today because one
/// spawns a terminal and one does not — and with a single field, **wording
/// alone** decides which. "fix the failing snapshot tests" and "how much
/// protein is in chicken thigh" arrive through the same keystroke, and the
/// expensive one is the accident.
///
/// So the expensive route stops being inferred and becomes a pick. This decides
/// only whether there is a choice worth offering and what order to offer it in;
/// pressing Return still takes the top rung, which is why a phrase that reads as
/// a question never puts a terminal there.
///
/// Pure and value-typed like `AgentsPresence` and `AssistantEscape`, for the
/// same reason: it is a handful of rules that would otherwise be verified by
/// typing sentences into a notch and watching what opened.
public enum PromptRouting: Equatable, Sendable {
    public enum Route: Equatable, Sendable, Hashable {
        /// A new terminal running the agent, carrying this prompt.
        case claudeCode
        /// The on-device model. Nothing runs, no terminal opens.
        case answer
    }

    /// The rungs to offer, top first. **Empty means offer nothing** — the phrase
    /// reads as a question, and a question has one sensible destination, so a
    /// ladder in front of it is a click charged for nothing.
    ///
    /// Never returns `[.answer]` alone: a one-rung ladder is a confirmation
    /// dialog wearing a list's clothes.
    public static func candidates(for phrase: String) -> [Route] {
        readsAsQuestion(phrase) ? [] : [.claudeCode, .answer]
    }

    /// Whether the phrase is asking rather than instructing.
    ///
    /// Deliberately conservative in ONE direction. A question misread as a task
    /// costs a click on "Just answer me"; a task misread as a question is
    /// answered by a 3B model that was never going to fix the snapshot tests,
    /// and the useful route is not on screen at all. So anything ambiguous
    /// falls through to the ladder, where both routes are visible.
    static func readsAsQuestion(_ phrase: String) -> Bool {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.hasSuffix("?") { return true }

        // First word only. "how do I..." asks; "fix how the parser handles..."
        // instructs, and the interrogative buried mid-sentence is a noun there.
        let lowered = trimmed.lowercased()
        guard let first = lowered.split(whereSeparator: { $0 == " " || $0 == "\n" }).first
        else { return true }
        let word = String(first.trimmingCharacters(in: CharacterSet.alphanumerics.inverted))
        return Self.interrogatives.contains(word)
    }

    /// Words that only ever open a question in English.
    ///
    /// "will" and "should" are here and "make"/"run"/"fix" deliberately are not:
    /// the list holds openers that cannot begin an imperative. `can` is the
    /// awkward one — "can you fix the tests" is a request — but it still wants
    /// the ladder rather than a terminal on Return, and the ladder is what
    /// falling through to `.answer` on top would deny it. It stays out.
    private static let interrogatives: Set<String> = [
        "what", "whats", "what's", "why", "how", "hows", "how's", "when", "where",
        "who", "whos", "who's", "whom", "whose", "which",
        "is", "are", "am", "was", "were", "do", "does", "did",
        "should", "would", "will",
    ]
}
