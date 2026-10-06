import Foundation

/// The instructions for a model that may answer *or* act.
///
/// **Composed, never replacing.** The answering half is whatever the user has in
/// Settings — edited or shipped — and the action half is generated from
/// `VoiceActionCatalog`, so the catalogue can never drift from what the model
/// was told it can do. A hand-written second copy of the action list is a bug
/// with a delay fuse on it.
///
/// Every line here was written against the lessons `AssistantPrompt` paid for:
/// state goals rather than sentences to say, name what is absent rather than
/// declaring a policy, and keep the list short because a small model with
/// nothing to say quotes the nearest text.
public enum VoicePrompt {
    /// Ceiling on a classifier reply, in tokens.
    ///
    /// Lives here, beside the prompt, because `PromptProbe` and the app must
    /// pass the SAME number. They did not for one build, and the probe's whole
    /// claim — that it measured what ships — was false for as long as that
    /// lasted: a generation truncated by a smaller cap comes back as a struct
    /// with nothing in it, which is indistinguishable from a model that decided
    /// the phrase was a question.
    ///
    /// Generous rather than tight. A reply is a name and two short fields, so
    /// this is a stop on a runaway generation and not a budget; the latency that
    /// matters is time-to-first-token, which a ceiling does not change.
    public static let maximumClassifierTokens = 512

    public static func instructions(
        answering base: String = AssistantPrompt.defaultInstructions,
        catalogue: String = VoiceActionCatalog.promptCatalogue()
    ) -> String {
        """
        \(base)

        \(actionSection(catalogue: catalogue))
        """
    }

    /// Instructions for a pass that ONLY classifies — it never answers.
    ///
    /// The alternative to `instructions(answering:catalogue:)`, and the reason
    /// both exist is that the composed one was measured and lost: teaching one
    /// prompt to answer *and* act took answering from 13/14 to 8/14, turned
    /// "how do I reverse a string in Swift" into `dlrow olleh`, and answered
    /// "what does this do" by describing its own output schema.
    ///
    /// A separate pass cannot do that, because the answering path it feeds is
    /// untouched: no action, and today's code runs with today's prompt. The cost
    /// moves from accuracy to latency, which is the trade this product can
    /// actually afford.
    ///
    /// The "never invent" line is not general advice. It is aimed at a measured
    /// failure: asked to tell an agent to run the tests, the model filled in
    /// `session=test_session`, a plausible-looking name for a session that has
    /// never existed.
    public static func classifierInstructions(
        _ actions: [any VoiceAction.Type] = VoiceActionCatalog.registered
    ) -> String {
        """
        Someone just spoke at their Mac. Decide whether they were telling it to \
        do one of these:

        \(VoiceActionCatalog.promptCatalogue(actions))

        What reaches you is a raw speech transcript: expect filler, false starts \
        and misheard words. When they were giving one of these instructions, put \
        the name in `action` and what they said in `arguments`.

        When they were asking something — how something works, what something \
        is, why something happened — leave `action` empty. Something else \
        answers those, and it answers them well.

        Fields carry what was SAID and nothing else. You cannot see which \
        devices, clips or sessions exist, so a name you did not hear is one you \
        invented: leave the field out instead. An omitted field is filled in \
        correctly by the Mac; an invented one is wrong.

        `answer` is always empty.
        """
    }


    /// The part under measurement. `PromptProbe` scores the whole composed
    /// prompt against BOTH case sets, so a change here that buys action accuracy
    /// by damaging answers shows up as a number rather than a surprise.
    public static func actionSection(catalogue: String) -> String {
        """
        Sometimes the speaker is not asking anything — they are telling you to do \
        one of these, and nothing else:

        \(catalogue)

        When that is plainly what was meant, put the name in `action`, put only \
        that action's own fields in `arguments`, and leave `answer` empty. \
        Otherwise leave `action` empty and answer in `answer` as above.

        Prefer answering. You cannot see which devices, clips or sessions exist, \
        so pass on what was actually said and let the Mac work out whether it is \
        real — but when you cannot tell WHICH thing was meant, or whether it was \
        an instruction at all, answering is the right outcome and not a failure.
        """
    }
}
