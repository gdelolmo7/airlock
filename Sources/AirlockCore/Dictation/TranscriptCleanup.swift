import Foundation

/// Decides when transcript cleanup is worth running, and whether what the model
/// returned is safe to type.
///
/// The stakes are specific: whatever this accepts gets typed into the user's
/// document as if they said it. A language model asked to "clean up" text can
/// instead answer it, translate it, wrap it in quotes, prepend "Here's the
/// cleaned version:", or refuse — and every one of those, typed at the cursor,
/// is worse than the raw transcript. So the contract is asymmetric on purpose:
/// rejection costs one missed polish, acceptance of garbage costs the user's
/// words. When in doubt, the raw transcript wins.
///
/// Pure, like the rest of the dictation core — the model call is I/O and lives
/// in the app target, but every decision about its output is testable here.
public enum TranscriptCleanup {
    /// What the session hands the model as instructions. Editable in Settings;
    /// this is the shipped default, and it lives here rather than in the UI
    /// because it is part of what "cleanup" means, not how it is presented.
    ///
    /// Instructions alone do NOT stop the model answering the transcript, which
    /// is why `prompt(for:)` exists — see the measurement there. This text says
    /// what cleaning means; the wrapper says the text is cargo.
    public static let defaultInstructions = """
    You clean up dictated speech. The user's message is a raw transcript from \
    speech recognition. Reply with only the cleaned transcript — no preamble, \
    no quotation marks around it, no commentary.

    Remove filler words (um, uh, like, you know). When the speaker corrects \
    themselves, keep only the corrected version. Fix punctuation, \
    capitalization, and obvious transcription mistakes.

    Never add content the speaker did not say. Never answer questions in the \
    transcript. Never translate — keep the speaker's language exactly. If \
    nothing needs fixing, return the transcript unchanged.
    """

    /// The transcript, wrapped so the model treats it as cargo rather than as
    /// speech addressed to it.
    ///
    /// This is the single highest-value line in cleanup, and it is here rather
    /// than in `defaultInstructions` for two reasons. Measured over 12 dictations
    /// weighted toward imperatives and questions — what you actually say to a
    /// coding agent:
    ///
    /// | framing                          | cleaned |
    /// |----------------------------------|---------|
    /// | bare transcript as the prompt     |  5 / 12 |
    /// | same instructions, wrapped prompt | 11 / 12 |
    ///
    /// Unwrapped, "Run the tests and tell me which ones are failing" came back
    /// as "Sure, I can help with that. Please provide me with the tests", and
    /// "go ahead and refactor the audio capture class" came back as a Swift
    /// file. The instructions already said "Never answer questions in the
    /// transcript"; a small model hands a bare user turn to its assistant reflex
    /// regardless. Vetting caught every one of those — so the symptom was never
    /// wrong text, it was cleanup silently not happening on most of what this
    /// app is for.
    ///
    /// It belongs in the prompt and not in the instructions because the
    /// instructions are user-editable: a wrapper applies to everyone, while an
    /// instructions rewrite reaches only users who never customised theirs.
    /// Rewriting the instructions to match measured no better AND leaked the tag
    /// into two accepted outputs — hence `strippingTags`.
    public static func prompt(for transcript: String) -> String {
        "\(openTag)\n\(transcript)\n\(closeTag)"
    }

    static let openTag = "<transcript>"
    static let closeTag = "</transcript>"

    /// Below this, skip the model entirely.
    ///
    /// Short utterances have nothing to clean — the speech engine already
    /// punctuates "Yep." — and cleanup's cost is latency between releasing the
    /// key and the text landing. Filler and self-correction live in longer
    /// speech, so the threshold buys speed where cleanup buys nothing.
    public static let minimumWordCount = 5

    public static func isWorthCleaning(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= minimumWordCount
    }

    /// The model's output, vetted. Returns the text to type, or nil meaning
    /// "use the raw transcript".
    ///
    /// Two checks, complementary:
    ///
    /// - **Growth cap.** Cleanup only removes and repunctuates, so output
    ///   meaningfully longer than input means the model added something —
    ///   preamble, commentary, an answer. Shrinkage is NOT capped: stripping
    ///   filler from "um, uh, so, like, go home" legitimately drops most of the
    ///   words.
    /// - **Novel-word cap.** The cleaned text must be made from words the
    ///   speaker said. Punctuation, casing and deletions introduce no new
    ///   words; a translation, an answer, or "Here's the cleaned text:" all do.
    ///   A small allowance covers legitimate joins ("can not" → "cannot") and
    ///   number normalisation.
    ///
    /// Known limit, accepted deliberately: if the transcript itself instructs
    /// the model ("reply with just the word done") and the model obeys with
    /// words the speaker used, both checks pass. That requires the user to
    /// dictate an instruction at their own dictation tool, and the fallback for
    /// tightening it — a filler lexicon per language — is worse than the hole.
    public static func vetted(raw: String, cleaned: String) -> String? {
        let candidate = sanitized(cleaned, rawBeganQuoted: beginsQuoted(raw))
        guard !candidate.isEmpty else { return nil }

        // Punctuation and casing add a few characters; anything past the slack
        // is content, and content is the one thing cleanup must never add.
        guard candidate.count <= raw.count + max(12, raw.count / 5) else { return nil }

        let rawWords = Set(words(raw))
        let cleanedWords = words(candidate)
        guard !cleanedWords.isEmpty else { return nil }
        // Proportional, with NO floor. A floor of one was the hole: an answer
        // to a question reuses the question's vocabulary, so
        // "what is the capital of France I forget" → "The capital of France is
        // Paris." introduces exactly one novel word and would have sailed
        // through. Below eight words nothing novel is allowed at all, which is
        // strict — number normalisation on a short phrase falls back to raw —
        // and strict is the correct bias when the cost of a wrong yes is the
        // user's own sentence.
        let novel = cleanedWords.filter { !rawWords.contains($0) }
        guard novel.count <= cleanedWords.count / 8 else { return nil }

        return candidate
    }

    // MARK: - Sanitising

    /// Collapse whitespace (a model that returns "text:\n\n…" folds to one
    /// line) and strip one layer of wrapping quotes the model added — but only
    /// when the raw transcript did not itself begin quoted, so a speaker who
    /// dictates a quotation keeps it.
    static func sanitized(_ cleaned: String, rawBeganQuoted: Bool) -> String {
        var text = strippingTags(cleaned)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if !rawBeganQuoted, text.count > 2,
           let first = text.first, let last = text.last,
           quotePairs.contains(where: { $0.open == first && $0.close == last }) {
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Remove the wrapper `prompt(for:)` added, if the model echoed it back.
    ///
    /// Stripping rather than rejecting, because a leaked tag is a mechanical
    /// artifact around otherwise-good text, not a sign the model misbehaved.
    /// It cannot be left to the novel-word cap either: `<transcript>` folds to
    /// the single word "transcript", which is inside the allowance for anything
    /// over eight words — measured leaking into two *accepted* outputs, i.e.
    /// typed at the user's cursor.
    private static func strippingTags(_ text: String) -> String {
        text.replacingOccurrences(of: closeTag, with: " ")
            .replacingOccurrences(of: openTag, with: " ")
    }

    private static let quotePairs: [(open: Character, close: Character)] = [
        ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"),
        ("«", "»"),
    ]

    private static func beginsQuoted(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return quotePairs.contains { $0.open == first }
    }

    /// Case- and diacritic-folded, split on anything that is not a letter or
    /// digit — so "café" and "cafe" compare equal and "it's" contributes
    /// "it"/"s" on both sides of the comparison.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
