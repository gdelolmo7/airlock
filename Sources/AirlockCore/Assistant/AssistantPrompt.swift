import Foundation

/// What the notch is told to be when it answers a spoken question.
///
/// Sits beside `TranscriptCleanup.defaultInstructions` for the same reason that
/// one does: it is part of what the feature *means*, not how it is presented, and
/// it is editable in Settings so the shipped text has to live somewhere a user
/// edit can be compared against.
///
/// The instructions lean hard on brevity and on admitting ignorance. Apple's
/// on-device model is roughly 3B-class — capable at rewriting, summarising and
/// short factual recall, weak on world knowledge, arithmetic and code. A model
/// that answers everything confidently at that size is worse than one that says
/// it does not know, because the escalation to Claude Code is one button away
/// and only gets pressed if the user is told it is needed.
public enum AssistantPrompt {
    /// Measured against three alternatives over 14 spoken questions chosen to hit
    /// every failure mode seen live. Deterministic (`.greedy`), so the numbers are
    /// differences rather than dice rolls:
    ///
    /// | prompt              | shape | wrong | recited | words |
    /// |---------------------|-------|-------|---------|-------|
    /// | the previous one    | 11/14 |   1   |    0    |  84   |
    /// | brief + scripted    |  9/14 |   0   |    5    |  46   |
    /// | verbose + own words | 11/14 |   0   |    1    |  72   |
    /// | **this one**        | 13/14 |   0   |    0    |  39   |
    ///
    /// Three things it does deliberately, each because the alternative was tried
    /// and measured:
    ///
    /// - **Says the input is a raw transcript.** Ask mode skips `TranscriptCleanup`
    ///   on purpose, so filler, stutters and mis-heard words arrive untouched. The
    ///   previous prompt never mentioned it.
    /// - **Names absent capabilities rather than stating a policy.** "You have no
    ///   clock" stops the fabrication that "decline questions needing current
    ///   information" did not — that one still produced "It is currently 10:41 pm
    ///   in Tokyo".
    /// - **Never dictates a sentence.** An earlier version said *"say that you
    ///   cannot, and that Claude Code can"*, and a 3B model converts indirect
    ///   speech to direct: five of fourteen answers came back as the literal
    ///   string "I cannot, and that Claude Code can." Goals survive; scripts get
    ///   recited. The capability list is short for the same reason — when the
    ///   model has nothing to say it reaches for the nearest text, and a long
    ///   enumeration is the easiest thing to quote.
    ///
    /// Two failures survive, both inherent to the model's size, and both are why
    /// the escalation button is never hidden: it will state stale training
    /// knowledge as current ("who won the last election"), and given a question
    /// whose subject it cannot see ("what does this do") it invents a subject
    /// rather than asking.
    ///
    /// The can't-act paragraph and the language line were added after two live
    /// screenshots: a do-request the grammar missed was answered with invented
    /// chrome:// steps, and a Spanish question got an English answer. The first
    /// wording of that paragraph enumerated capabilities ("open apps or
    /// websites, change settings, or control the music") and the probe caught
    /// the model quoting the list verbatim when asked "how does this work?" —
    /// the enumeration lesson above, relearned. Verb-led and short, it probes
    /// 15/16 with no hard failures, Spanish declines included.
    public static let defaultInstructions = """
    You answer questions someone speaks aloud at their Mac. Your reply appears in \
    a small panel under the notch, read at a glance.

    What reaches you is a raw speech transcript: expect filler like "um", false \
    starts, repeated words, and words the recogniser misheard. Work out what was \
    meant and answer that. When the speaker corrects themselves, answer only the \
    corrected question. Never repeat the question back.

    Being right matters more than being short. Aim for one to three sentences, \
    and take another if accuracy needs it. Prefer a plain sentence to a list.

    You have no clock, no internet, and cannot see this person's screen, files or \
    code. Asked for something that needs one of those, say you don't have it and \
    suggest Claude Code — in your own words, briefly. Never guess instead.

    You cannot do anything on this Mac either — only answer. Asked to open, \
    change or control something, say briefly that you couldn't. Never invent \
    steps, menu paths or web addresses; describe only what you are certain \
    exists.

    Reply in the language the question was spoken in.

    If you cannot tell what the question refers to, ask which thing they mean.

    Plain sentences, **bold** for emphasis, a fenced code block when the answer \
    is code. No headings, no tables.
    """

    /// Ceiling on the answer, in tokens.
    ///
    /// The panel is a strip under a notch, not a document view. This is a hard
    /// stop on a runaway generation rather than a style guide — the instructions
    /// above are what actually keep answers short.
    public static let maximumResponseTokens = 512

    /// Below this, there is no question to ask.
    ///
    /// One word, not two. "Monads?" and "Why?" are real questions, and a
    /// two-word floor silently swallowed them: the log showed
    /// `asking the notch <6 chars, 1 words>` followed by nothing at all, which
    /// from the outside is indistinguishable from the app losing your sentence.
    /// Anything that reaches here has already survived `HoldGesture.minimumHold`
    /// and `DictationText.prepared`, so it is speech, not a stray keypress.
    public static let minimumWordCount = 1

    public static func isWorthAsking(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= minimumWordCount
    }

    /// Whether the model handed the question back instead of answering it.
    ///
    /// Measured: asked "Okay, how does this work?" the model replied "How does
    /// this work?" — which looks like an answer, occupies the answer's place on
    /// screen, and says nothing. Sampling is not fixed here (unlike cleanup,
    /// where determinism matters more than variety), so the same question can
    /// answer well once and echo the next time.
    ///
    /// Deliberately the same shape as `TranscriptCleanup.vetted`'s novel-word
    /// test, inverted: there, words the speaker never said meant the model had
    /// invented something; here, an answer built from nothing *but* the
    /// question's own words means it invented nothing at all.
    ///
    /// Caught rather than hidden — an echo becomes an honest "no answer" with
    /// the escalation attached, which is more use than a sentence that pretends.
    public static func isEcho(question: String, answer: String) -> Bool {
        let asked = words(question)
        let replied = words(answer)
        guard !replied.isEmpty else { return true }
        // A genuine answer is usually longer; anything that expands on the
        // question has said something, whatever words it reused.
        guard replied.count <= asked.count + 2 else { return false }
        let askedSet = Set(asked)
        guard replied.filter({ !askedSet.contains($0) }).count <= 1 else { return false }

        // The word test alone is not enough, and the case that proved it is
        // "is Swift statically typed" → "Yes, Swift is statically typed." —
        // every word reused, one added, and a perfectly good answer. What
        // separates that from an echo is that an echo is still *asking*. A
        // declarative sentence made of the question's own words has answered it;
        // an interrogative one has handed it back.
        if answer.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return true }

        // …unless what was said was not a question at all. "Decrease the music
        // by 10%." in reply to "decrease the music by 10%" is a restatement
        // with no question mark to give it away, and it reads as the app
        // acknowledging an instruction it has not carried out — worse than an
        // echo of a question, because it looks like something happened.
        //
        // So the "?" test applies to things that were ASKED. An instruction
        // repeated back has said nothing, whatever it ends with.
        return !looksLikeAQuestion(question)
    }

    /// Whether the speaker was asking rather than instructing.
    ///
    /// The same interrogative set `VoiceGrammar` uses to decide the opposite
    /// question — one list, so a word cannot be a question opener to one half of
    /// this app and an instruction opener to the other.
    static func looksLikeAQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        guard let first = words(trimmed).first(where: { !VoiceGrammar.fillers.contains($0) })
        else { return false }
        return VoiceGrammar.interrogatives.contains(first)
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
