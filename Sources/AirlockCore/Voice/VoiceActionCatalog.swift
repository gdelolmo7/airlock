import Foundation

/// Every action the notch will consider performing from speech.
///
/// One line per action, and this is the only list. `AgentRegistry` and the
/// app's `WidgetRegistry` work the same way for the same reason: a feature that
/// needs edits in four files gets added in three of them by someone in a hurry.
public enum VoiceActionCatalog {
    /// The namespace every action name carries. See `VoiceAction.toolName`.
    public static let prefix = "Voice."

    /// Every conformer that exists.
    ///
    /// Not the same as `registered`, and the gap is deliberate — see there.
    /// Tests and `PromptProbe --all` work from this one.
    public static let all: [any VoiceAction.Type] = [
        VoiceClipboardAction.self,
        VoiceAudioOutputAction.self,
        VoiceAgentAction.self,
        // LAST, and it matters. `VoiceGrammar.match` takes the first trigger
        // that captures, in registry order, so appending can never change how an
        // existing phrase resolves — it can only claim phrases nothing else
        // wanted. Inserting it higher would be a silent re-ranking of three
        // actions that already have a scored case set.
        VoiceShortcutAction.self,
        VoiceOpenAction.self,
        VoiceVolumeAction.self,
        VoiceMediaAction.self,
    ]

    /// What the app offers with nothing extra switched on.
    ///
    /// **Derived from `offered`, so precedence has exactly one definition.** It
    /// was a literal, and a literal here plus an append in `offered` meant two
    /// places decided order — which `VoiceGrammar.match` resolves by
    /// first-capture-wins, so any disagreement between them would silently
    /// re-rank actions rather than fail.
    ///
    /// That all three of the originals are here is a reversal `VoiceGrammar`
    /// earned. While a language model did this job two had to be held back:
    /// Clipboard fired on 0 of 2 cases under two catalogue wordings, and Agent
    /// invented its target every time — `test_session`, `test-session-123` —
    /// under three prompts, one of which said in plain words not to. A grammar
    /// has neither problem: no prompt, so an extra action costs no tokens and
    /// cannot destabilise the others, and it extracts no `session` at all.
    ///
    /// What is NOT relaxed is the floor. `Voice.Agent` and `Voice.Shortcut`
    /// still carry a `riskFloorReason`, so they always show a card and no allow
    /// rule can approve them in advance.
    public static var registered: [any VoiceAction.Type] { offered(shortcuts: false) }

    /// What to offer this user, right now.
    ///
    /// `registered` is what the app ships switched on; `Voice.Shortcut` is
    /// switched on per user and so cannot live in a `let`. It is separated
    /// rather than folded in because the two answer different questions — "what
    /// does this build support" and "what has this person agreed to" — and a
    /// single list would have to lie about one of them.
    ///
    /// Its own switch, not a sub-setting of spoken actions, for two reasons a
    /// risk floor does not cover. Enumerating the library runs a subprocess, so
    /// somebody who owns no Shortcuts should not pay for one on every phrase.
    /// And the verbs here are the user's own, which is a different thing to
    /// agree to than a fixed list Airlock wrote.
    /// **Order is precedence.** `VoiceGrammar.match` returns the first trigger
    /// that captures and never reconsiders — it does not fall through when
    /// `propose` then declines — so a greedy trigger placed early silently
    /// swallows phrases meant for everything after it.
    ///
    /// `VoiceOpenAction` is therefore always LAST: its trigger has no object
    /// noun to anchor on (`.afterVerb`), so it captures whatever follows "open"
    /// or "launch". Put it before `VoiceShortcutAction` and "launch my morning
    /// focus shortcut" is captured as an app called "morning focus shortcut",
    /// resolves to nothing, and is answered — with the Shortcut never tried.
    public static func offered(shortcuts: Bool) -> [any VoiceAction.Type] {
        var list: [any VoiceAction.Type] = [
            VoiceClipboardAction.self,
            VoiceAudioOutputAction.self,
            VoiceAgentAction.self,
            // Before the audio action, which shares "change", "volume" and
            // "to". Resolution falls through now, so this is a preference
            // rather than a requirement — but it saves a failed `propose` on
            // every volume phrase.
            VoiceVolumeAction.self,
            VoiceMediaAction.self,
        ]
        if shortcuts { list.append(VoiceShortcutAction.self) }
        list.append(VoiceOpenAction.self)
        return list
    }

    /// A spoken phrase all the way to something doable, or nil.
    ///
    /// The whole path in one place, and the ONLY one the app should use: every
    /// trigger that captures is offered to its own `propose`, and the first
    /// that yields a proposal wins. A trigger that matches and then declines no
    /// longer swallows the phrase — see `VoiceGrammar.candidates` for the three
    /// bugs that shape paid for.
    public static func resolve(spoken: String,
                               in context: VoiceContext,
                               offering actions: [any VoiceAction.Type] = registered)
        -> ActionProposal? {
        for candidate in VoiceGrammar.candidates(spoken, offering: actions) {
            if let proposal = propose(actionNamed: candidate.name,
                                      arguments: candidate.arguments,
                                      in: context, offering: actions) {
                return proposal
            }
        }
        return nil
    }

    /// Ceiling on a catalogue line, in characters.
    ///
    /// Every line is in the prompt for every spoken word, and `AssistantPrompt`
    /// measured what a long enumeration does to a 3B model: *"when the model has
    /// nothing to say it reaches for the nearest text, and a long enumeration is
    /// the easiest thing to quote."* A ceiling that a test enforces is the only
    /// version of that lesson which survives the next contributor.
    public static let maximumSummaryLength = 96

    public static func isVoiceTool(_ toolName: String) -> Bool {
        toolName.hasPrefix(prefix)
    }

    /// Looks through EVERY conformer, registered or not.
    ///
    /// Deliberately not `registered`: this answers "what does this tool name
    /// mean", which `RiskAssessor` and `RuleGeneralizer` need for any rule ever
    /// written — including one left in `policy.yaml` from a build where the
    /// action was on. A rule whose tool is unregistered must still read as
    /// itself, not silently become a `Bash`-shaped stranger.
    public static func action(named toolName: String) -> (any VoiceAction.Type)? {
        all.first { $0.toolName == toolName }
    }

    /// Resolve a model-produced action name and argument bag into something
    /// doable, or nil.
    ///
    /// Tolerant about the name on purpose: the model is asked for
    /// `Voice.AudioOutput` and will sometimes say `AudioOutput`, or change the
    /// case. Accepting both costs one comparison and turns a whole class of
    /// near-misses into working commands. Anything still unrecognised is nil —
    /// never a guess at the closest action, because the closest action to
    /// "clipboard" is one that sends a prompt to an agent.
    public static func propose(actionNamed name: String,
                               arguments: [String: String],
                               in context: VoiceContext,
                               offering actions: [any VoiceAction.Type] = registered) -> ActionProposal? {
        resolve(name: name, offering: actions)?.propose(arguments, in: context)
    }

    /// The action a model-produced name refers to, or nil. See `propose` for why
    /// this is lenient about spelling and strict about existence.
    ///
    /// Defaults to `registered`, so a model that names an action the app does
    /// not offer resolves to nothing and the phrase falls through to being
    /// answered — the same fate as any other unrecognised name.
    public static func resolve(name: String,
                               offering actions: [any VoiceAction.Type] = registered)
        -> (any VoiceAction.Type)? {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return nil }
        return actions.first { normalized($0.toolName) == wanted }
    }

    /// Nil when this tool may be granted standing permission. Consulted by
    /// `RiskAssessor`, which stays the single definition of "risky".
    public static func riskFloorReason(toolName: String) -> String? {
        action(named: toolName)?.riskFloorReason
    }

    public static func exactRuleSummary(toolName: String) -> String? {
        action(named: toolName)?.exactRuleSummary
    }

    /// The catalogue as the model sees it. Stable order, so a prompt diff is a
    /// diff and not a reshuffle.
    public static func promptCatalogue(_ actions: [any VoiceAction.Type] = registered) -> String {
        actions.map { action in
            let parameters = action.parameters.joined(separator: ", ")
            return "- \(action.toolName)(\(parameters)) — \(action.summary)"
        }.joined(separator: "\n")
    }

    /// Case-folded, prefix-optional. `Voice.AudioOutput`, `audiooutput` and
    /// `AUDIO_OUTPUT` all land on the same action.
    static func normalized(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix(prefix.lowercased()) {
            value = String(value.dropFirst(prefix.count))
        }
        return value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
