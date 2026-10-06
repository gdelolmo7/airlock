import Foundation

/// One spoken shape that names an action, without a model.
///
/// Declared by the action itself, so adding an action stays one conformer plus
/// one registry line.
public struct VoiceTrigger: Sendable {
    /// Where the argument sits relative to the words that identify the action.
    public enum Placement: Sendable, Equatable {
        /// "put the sound **on** the airpods" — the tail after a preposition.
        case afterPreposition
        /// "copy that **terminal** command" — the words between verb and object.
        case betweenVerbAndObject
        /// "open **spotify**" — everything after the verb, with NO object noun
        /// required, because there isn't one to require.
        ///
        /// **The greedy one, and the only placement with no anchor.** The other
        /// two are held in place by a word from a fixed list; this is held in
        /// place by nothing but the verb, so it captures whatever follows and
        /// leans entirely on `propose` refusing what does not exist. That makes
        /// it safe but it also makes it FIRST-MATCH HUNGRY: `VoiceGrammar.match`
        /// returns the first trigger that captures and never reconsiders, so an
        /// action using this must be registered LAST or it will shadow every
        /// action after it that shares a verb. See `VoiceActionCatalog.offered`.
        case afterVerb
        /// "go **to** youtube" — a preposition straight after the verb, then
        /// everything else. No object noun, same as `.afterVerb`, but the
        /// preposition narrows it: "go to youtube" captures, "go ahead and fix
        /// it" does not, because `ahead` is not in the list.
        ///
        /// Also greedy, and subject to the same last-in-the-registry rule.
        case afterVerbPreposition
        /// "**pause** the music" — the VERB is the argument.
        ///
        /// For actions where the instruction is the verb and the object only
        /// says what it applies to. An object is still required, so a bare
        /// "play" matches nothing: with no anchor at all, every "play" and
        /// "stop" in ordinary speech would become a command.
        case theVerb
        /// "set the volume **50**" — everything after the object, with no
        /// preposition required.
        ///
        /// Subsumes the prepositional form for free: "set the volume **to** 50"
        /// captures "to 50", and `to` is already in `leadingNoise`. One trigger
        /// where two would otherwise be needed, and no way for them to disagree.
        case afterObject
    }

    /// What is being done. Matched anywhere, so politeness and filler in front
    /// cost nothing: "um can you **switch** the audio…" is the same instruction.
    public let verbs: [String]
    /// What it is being done to. This is what stops every "put" and "send" in
    /// the language reaching an action.
    public let objects: [String]
    /// Only for `.afterPreposition`.
    public let prepositions: [String]
    public let placement: Placement
    /// Which `VoiceAction.parameters` entry the captured words fill.
    public let argument: String

    public init(verbs: [String], objects: [String], prepositions: [String] = [],
                placement: Placement = .afterPreposition, argument: String) {
        self.verbs = verbs
        self.objects = objects
        self.prepositions = prepositions
        self.placement = placement
        self.argument = argument
    }
}

/// Deciding whether a spoken phrase is an instruction, with no model at all.
///
/// **Written after measuring the alternative.** Apple's on-device model was
/// asked to do this and could not do it stably: three actions listed and it
/// fired on 2/2 audio cases; remove an unrelated third action it never fires and
/// the same phrases go to 0/2. Add example phrases to fix that and two questions
/// become commands. `swift run PromptProbe actions` has the table.
///
/// For one to three actions over a fixed vocabulary, generalisation is not what
/// is needed — predictability is. This costs no milliseconds, no megabytes and
/// no network, and every case in `ActionEvaluation` can be scored by
/// `swift test` rather than by a probe that needs Apple Intelligence switched on.
///
/// **It is allowed to be loose, because resolution is strict.** "put it on the
/// desk" happily matches the audio trigger and then finds no device called
/// "desk", so it proposes nothing and the phrase is answered instead. Every
/// captured argument still has to name something that exists on this Mac — see
/// `VoiceAction.propose`. That is what lets the patterns here be generous with
/// phrasing without being generous with consequences.
public enum VoiceGrammar {
    /// Words that cannot begin an instruction, whatever follows them.
    ///
    /// This is the whole safety half, and it is why "how do I change the audio
    /// output on a mac" — the phrase that beat every model configuration tried —
    /// costs one array lookup here.
    ///
    /// `can`, `could` and `would` are deliberately ABSENT: "can you switch the
    /// audio to the TV" is a polite instruction, not a question, and rejecting
    /// it would throw away how people actually speak. They are safe to admit
    /// because "can you tell me…" contains no action verb and matches nothing.
    /// Where the matched verb is carried in the argument bag.
    ///
    /// Underscored so it cannot collide with a `VoiceAction.parameters` entry,
    /// and ignored by every action that does not want it. It exists because
    /// "increase the volume by 10" and "decrease the volume by 10" capture the
    /// same words and mean opposite things — the verb is the only thing that
    /// says which, and without it a delta cannot be resolved at all.
    public static let matchedVerbKey = "_verb"

    /// The Spanish rows follow the English rule exactly: the you-forms that
    /// make polite requests ("puedes abrir…") are ADMITTED, like "can" and
    /// "could"; the I-forms and question words that make questions ("puedo…",
    /// "como subo…") are refused. Diacritics never arrive — `VoiceMatch.fold`
    /// has already stripped them — so "cómo" is matched as "como".
    static let interrogatives: Set<String> = [
        "how", "what", "whats", "why", "when", "where", "who", "whos", "whose",
        "which", "is", "are", "was", "were", "does", "did", "should", "must",
        "como", "que", "cual", "cuales", "cuando", "donde", "quien", "quienes",
        "puedo", "debo", "deberia", "es", "son", "esta", "estan",
    ]

    /// Skipped when looking for the first real word. A raw transcript starts
    /// with these constantly — `TranscriptCleanup` is deliberately not run on
    /// this path, so they arrive untouched.
    static let fillers: Set<String> = [
        "um", "uh", "er", "erm", "so", "well", "okay", "ok", "hey", "just",
        "like", "please", "and", "yeah",
        "pues", "bueno", "vale", "oye", "entonces", "mira", "eh",
    ]

    /// Allowed between a verb and its preposition, and nothing else is.
    ///
    /// "go BACK to Claude Code" is the same instruction as "go to Claude Code"
    /// — the adverb says the app was already open once, which is a fact about
    /// the user's day rather than a different intent. It fell through the whole
    /// catalog to the Q&A model, which answered "I don't have the ability to go
    /// back to Cloud Code" while holding both the action and, through
    /// `VoiceMishearings`, the spelling. The third time this exact shape of
    /// failure has been written down here.
    ///
    /// **A closed set, deliberately, rather than "skip one word".** The
    /// immediacy rule in `afterVerbPreposition` is what stops "go AND FIND the
    /// link to youtube" reading as a navigation, and a general one-word skip
    /// would start eating into that guard for no gain — these two words are the
    /// whole observed population.
    static let verbAdverbs: Set<String> = ["back", "again"]

    /// Dropped from the front of a captured argument. The Spanish articles
    /// matter more than the English ones did: Spanish rarely names a thing
    /// bare, so nearly every capture arrives wearing "el" or "la".
    static let leadingNoise: Set<String> = [
        "the", "my", "a", "an", "this", "that", "of", "to",
        // "show ME the calendar" — the pronoun is part of the asking, never
        // part of the name.
        "me",
        "el", "la", "los", "las", "un", "una", "mi", "mis",
        "este", "esta", "ese", "esa", "al", "de",
    ]
    /// Dropped from the end of one. "kitchen tv please" is a device called
    /// "kitchen tv". "por favor" is two tokens and the loop strips one at a
    /// time, so both words are listed.
    static let trailingNoise: Set<String> = [
        "please", "thanks", "thank", "you", "now", "instead", "again", "ok", "okay",
        "por", "favor", "gracias", "ahora", "porfa", "ya", "vale",
    ]

    /// The first action a phrase names, or nil. Registry order.
    ///
    /// Kept because it says something worth asserting on its own — which
    /// trigger a phrase looks like — but the app does NOT use it. See
    /// `candidates`, and `VoiceActionCatalog.resolve`.
    public static func match(
        _ spoken: String,
        offering actions: [any VoiceAction.Type] = VoiceActionCatalog.registered
    ) -> (name: String, arguments: [String: String])? {
        candidates(spoken, offering: actions).first
    }

    /// EVERY action the phrase could be, in registry order.
    ///
    /// **Capturing is a guess, and one guess is not enough.** This used to
    /// return only the first, and resolution stopped there — so an action whose
    /// trigger matched but whose `propose` then declined would swallow the
    /// phrase, and nothing behind it was ever tried. It bit three times in one
    /// week and each time the fix was a hand-maintained ordering rule:
    ///
    /// - "launch my morning focus shortcut" captured as an app called "morning
    ///   focus shortcut", so the Shortcut was never reached.
    /// - "go to youtube" captured as an app, so a site could never resolve —
    ///   which is why `Voice.Open` had to become one action instead of two.
    /// - "change the volume to 10 percent" captures as an audio DEVICE named
    ///   "10 percent", so a volume action behind it could not work at all.
    ///
    /// The ordering rules were all correct and all fragile: each held only
    /// until the next action arrived. Returning every candidate and letting
    /// `propose` decide is the same answer without a rule to remember, and it
    /// costs nothing — `propose` is pure, and there are single-digit actions.
    ///
    /// Order still matters for genuine TIES, where two actions could both
    /// resolve the same phrase. It is no longer load-bearing for the common
    /// case, which is one of them declining.
    public static func candidates(
        _ spoken: String,
        offering actions: [any VoiceAction.Type] = VoiceActionCatalog.registered
    ) -> [(name: String, arguments: [String: String])] {
        let tokens = VoiceMatch.fold(spoken).split(separator: " ").map(String.init)
        guard let first = tokens.first(where: { !fillers.contains($0) }),
              !interrogatives.contains(first) else { return [] }

        var found: [(name: String, arguments: [String: String])] = []
        for action in actions {
            for trigger in action.triggers {
                if let value = capture(trigger, in: tokens),
                   let verb = tokens.firstIndex(where: { trigger.verbs.contains($0) }) {
                    // The verb travels with the capture under a reserved key.
                    // "decrease the volume by 10" and "increase the volume by
                    // 10" capture the same words and mean opposite things, so
                    // an action that reads a delta cannot work without it.
                    found.append((action.toolName,
                                  [trigger.argument: value, Self.matchedVerbKey: tokens[verb]]))
                }
            }
        }
        return found
    }

    /// The words one trigger captures, or nil when the phrase is not its shape.
    static func capture(_ trigger: VoiceTrigger, in tokens: [String]) -> String? {
        guard let verb = tokens.firstIndex(where: { trigger.verbs.contains($0) }) else { return nil }
        let afterVerb = tokens.index(after: verb)
        guard afterVerb < tokens.endIndex else { return nil }

        // Before the object guard: neither of these has an object to find.
        if trigger.placement == .afterVerb {
            return trimmed(Array(tokens[afterVerb...]))
        }
        if trigger.placement == .afterVerbPreposition {
            // Required IMMEDIATELY after the verb, unlike `.afterPreposition`
            // which scans. "go to youtube" is the shape; scanning would let
            // "go and find the link to youtube" match, which is a sentence
            // about a link rather than an instruction to navigate.
            // One or more adverbs may sit in the gap — see `verbAdverbs`. The
            // preposition is still REQUIRED, and still required to be the next
            // real word, so the guard the comment above describes is intact.
            var cursor = afterVerb
            while cursor < tokens.endIndex, Self.verbAdverbs.contains(tokens[cursor]) {
                cursor = tokens.index(after: cursor)
            }
            guard cursor < tokens.endIndex,
                  trigger.prepositions.contains(tokens[cursor]) else { return nil }
            let afterPreposition = tokens.index(after: cursor)
            guard afterPreposition < tokens.endIndex else { return nil }
            return trimmed(Array(tokens[afterPreposition...]))
        }

        guard let object = tokens[afterVerb...].firstIndex(where: { trigger.objects.contains($0) })
        else { return nil }

        switch trigger.placement {
        case .theVerb:
            return tokens[verb]
        case .afterObject:
            let afterObject = tokens.index(after: object)
            guard afterObject < tokens.endIndex else { return nil }
            return trimmed(Array(tokens[afterObject...]))
        case .afterVerb, .afterVerbPreposition:
            return nil  // handled above; unreachable, and the compiler wants it
        case .betweenVerbAndObject:
            return trimmed(Array(tokens[afterVerb..<object]))
        case .afterPreposition:
            let afterObject = tokens.index(after: object)
            guard afterObject < tokens.endIndex,
                  // Scanned for rather than required next, so "over to" and
                  // "right through" cost nothing.
                  let preposition = tokens[afterObject...].firstIndex(where: {
                      trigger.prepositions.contains($0)
                  })
            else { return nil }
            return trimmed(Array(tokens[tokens.index(after: preposition)...]))
        }
    }

    /// Strip the words around a name that are not part of it. Nil when nothing
    /// is left, which is a phrase that named the action and then named nothing.
    static func trimmed(_ words: [String]) -> String? {
        var slice = words[...]
        while let first = slice.first, leadingNoise.contains(first) { slice = slice.dropFirst() }
        while let last = slice.last, trailingNoise.contains(last) { slice = slice.dropLast() }
        return slice.isEmpty ? nil : slice.joined(separator: " ")
    }
}
