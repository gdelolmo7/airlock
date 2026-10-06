import Foundation
import FoundationModels
import AirlockCore

/// The shape the model is made to produce when it may answer *or* act.
///
/// **Guided generation, not the `Tool` protocol.** `Tool.call` executes; this
/// path has to propose and wait for a human, which would mean suspending inside
/// a tool call across a click and then explaining a denial to a model that
/// narrates it. A struct comes back, the app decides, and nothing in the model's
/// world knows whether the answer was yes.
///
/// **Back in a shared target, and the old comment explains why.** It said this
/// "briefly lived in a shared target so the app and the probe could not drift
/// apart on the schema — then the app stopped needing a model at all
/// (`VoiceGrammar`), and a target existing to synchronise one consumer is a
/// target with no reason."
///
/// There are two consumers again. `AssistantService.classify` uses this to
/// decide what a phrase the grammar did not recognise was asking for, and
/// `PromptProbe` scores that same path — so the probe's central claim, that it
/// measures what ships, is true by construction rather than by inspection. The
/// two ARE the same type; there is nothing left to drift.
///
/// It still cannot go in `AirlockCore`: `NotchHook` depends on Core, and
/// importing `FoundationModels` there would link the framework into a fail-open
/// CLI that runs on every agent tool call. Hence a target of its own.
///
/// Three fields, and the count is the design: it does not grow when an action is
/// added, so the catalogue can change without the schema changing under it. All
/// strings, because a small model asked for a typed union produces prose about
/// the union.
@Generable
public struct SpokenReply {
    @Guide(description: "The exact action name from the list, or empty when answering a question instead.")
    public var action: String

    @Guide(description: "The chosen action's own fields. Empty when answering a question.")
    public var arguments: [SpokenArgument]

    @Guide(description: "The spoken reply, when answering rather than acting. Empty when acting.")
    public var answer: String
}

@Generable
public struct SpokenArgument {
    @Guide(description: "The field name, exactly as the action lists it.")
    public var name: String
    @Guide(description: "What the speaker said this field should be.")
    public var value: String
}

extension SpokenReply {
    /// Hand off to Core, which owns every rule about what this means.
    public var reply: VoiceReply {
        VoiceReply.resolve(action: action,
                           arguments: arguments.map { (name: $0.name, value: $0.value) },
                           answer: answer)
    }
}
