import Foundation

/// Every `VoiceAction` conformer, together — the same arrangement as the app's
/// `BuiltinWidgets.swift`, and for the same reason: three small conformers in
/// one file read better than three files with one struct each.
///
/// The three were chosen so the first slice is boring. None needs a capability
/// the app does not already have, the first two are reversible, and only the
/// third can reach outside the notch.

// MARK: - Clipboard

/// "Copy the last thing I copied from Figma."
public struct VoiceClipboardAction: VoiceAction {
    public static let toolName = "Voice.Clipboard"
    /// Measured wording. "Put an earlier clipboard entry back on the clipboard"
    /// read correctly to a human and fired on 0 of 2 clipboard cases: nothing in
    /// it looks like "copy the last thing I copied from Figma". Naming the words
    /// people actually use — copy, again, and what they'd name it by — is the
    /// change, and the probe is how it stops being an opinion.
    public static let summary = "Copy something earlier again, by its text, its source app, or its position."
    public static let parameters = ["query", "index"]
    public static let exactRuleSummary = "Anything copied from this app"

    /// Two shapes, because people name a clip two ways: by where it came from
    /// ("copy the last thing I copied FROM Figma") and by what it is ("copy that
    /// TERMINAL command"). Both land in `query`, which searches content and
    /// source app alike.
    public static let triggers = [
        VoiceTrigger(verbs: ["copy", "paste", "grab",
                             "copia", "copiar", "pega", "pegar"],
                     objects: ["thing", "one", "item", "text", "link", "url",
                               "command", "code", "clip", "snippet", "line",
                               "cosa", "texto", "enlace", "comando", "codigo",
                               "linea", "elemento"],
                     prepositions: ["from", "de", "desde"],
                     argument: "query"),
        VoiceTrigger(verbs: ["copy", "paste", "grab",
                             "copia", "copiar", "pega", "pegar"],
                     objects: ["thing", "one", "item", "text", "link", "url",
                               "command", "code", "clip", "snippet", "line",
                               "cosa", "texto", "enlace", "comando", "codigo",
                               "linea", "elemento"],
                     placement: .betweenVerbAndObject,
                     argument: "query"),
    ]

    public static func propose(_ arguments: [String: String],
                               in context: VoiceContext) -> ActionProposal? {
        guard !context.clipboard.isEmpty else { return nil }
        guard let item = resolve(arguments, in: context.clipboard) else { return nil }

        // The SOURCE APP, not the clipped text — see `ActionProposal.subject`.
        // A rule naming the text could only ever match that one string again.
        let subject = item.sourceAppName ?? (item.isImage ? "Image" : "Text")
        // The summary carries the content ONLY when the detail will not. Saying
        // it twice — once truncated, once in full — is what the first rendered
        // sheet showed, and it reads as a bug rather than as thoroughness.
        let detail = item.preview.count > VoiceText.previewLimit ? item.preview : nil
        let what = detail == nil ? VoiceText.quoted(item.preview) : "this"
        return ActionProposal(
            toolName: toolName,
            subject: subject,
            summary: item.sourceAppName.map { "Copy \(what) from \($0)" } ?? "Copy \(what)",
            detail: detail,
            effect: .copyClipboardItem(id: item.id))
    }

    /// **An argument that was given must resolve.** Falling through to "the
    /// newest entry" when a stated index or query does not is how asking for a
    /// Figma frame silently copies a password — and `index: "0"` reaching this
    /// is not hypothetical, it is what a model does with "the last one".
    /// Defaulting to the newest happens only when NOTHING was specified.
    ///
    /// **Recency breaks ties here, and that is not the rule elsewhere.**
    /// `VoiceMatch.unique` refuses to choose between two audio devices because
    /// nothing distinguishes them; a clipboard is ordered newest-first, so "the
    /// last thing I copied from Figma" names the newest Figma entry by
    /// construction.
    private static func resolve(_ arguments: [String: String],
                                in clipboard: [ClipboardItem]) -> ClipboardItem? {
        if let raw = arguments["index"], !VoiceMatch.fold(raw).isEmpty {
            guard let position = VoiceMatch.ordinal(raw), position <= clipboard.count else {
                return nil
            }
            return clipboard[position - 1]
        }
        guard let query = arguments["query"].map(VoiceMatch.fold), !query.isEmpty else {
            return clipboard.first
        }
        if let hit = clipboard.first(where: { VoiceMatch.fold($0.searchableText).contains(query) }) {
            return hit
        }
        // Only once the text search has failed: an ordinal can arrive in `query`
        // when the model puts everything in one field. Searching first is what
        // keeps "second draft" a search for those words rather than a jump to
        // row two.
        guard let position = VoiceMatch.ordinal(query), position <= clipboard.count else {
            return nil
        }
        return clipboard[position - 1]
    }
}

// MARK: - Audio output

/// "Put the sound on the AirPods."
public struct VoiceAudioOutputAction: VoiceAction {
    public static let toolName = "Voice.AudioOutput"
    public static let summary = "Move system sound output to a named device."
    public static let parameters = ["device"]
    public static let exactRuleSummary = "Only sound moving to this device"

    /// `it` and `this` earn their place: "put IT on the AirPods" is how people
    /// say this once the music is already playing. They are safe because the
    /// captured name still has to match a device that exists — "put it on the
    /// desk" matches here and proposes nothing.
    public static let triggers = [
        VoiceTrigger(verbs: ["put", "switch", "move", "send", "play", "route",
                             "output", "swap", "change",
                             "pon", "cambia", "manda", "mueve", "pasa", "saca"],
                     objects: ["sound", "audio", "output", "music", "volume",
                               "it", "this", "everything",
                               "sonido", "salida", "musica", "volumen",
                               "esto", "todo"],
                     prepositions: ["on", "to", "through", "onto", "via", "over",
                                    "en", "a", "al", "por"],
                     argument: "device"),
    ]

    public static func propose(_ arguments: [String: String],
                               in context: VoiceContext) -> ActionProposal? {
        guard let query = arguments["device"], !query.isEmpty else { return nil }
        // Ambiguity is nil: two devices matching "pro" is a reason to say
        // nothing was understood, not a reason to pick one.
        guard let device = VoiceMatch.unique(query, in: context.audioOutputs,
                                             name: \.name) else { return nil }
        return ActionProposal(
            toolName: toolName,
            subject: device.name,
            summary: "Send sound to \(device.name)",
            effect: .selectAudioOutput(uid: device.uid))
    }
}

// MARK: - Agent

/// "Tell Claude to run the tests."
public struct VoiceAgentAction: VoiceAction {
    public static let toolName = "Voice.Agent"
    public static let summary = "Send a spoken instruction to a coding agent."
    public static let parameters = ["prompt", "session"]

    /// Declared but unreachable: this action is not registered, so
    /// `VoiceGrammar` is never offered it. Kept so the case set can score it the
    /// day it is.
    public static let triggers = [
        // "dile a claude QUE corra los tests" — Spanish subordinates with
        // `que` where English infinitives with `to`, so it is a preposition
        // here in the trigger's sense: the word the prompt starts after.
        VoiceTrigger(verbs: ["tell", "ask", "get",
                             "dile", "pide", "pidele", "manda"],
                     objects: ["claude", "agent", "codex", "airlock"],
                     prepositions: ["to", "que"],
                     argument: "prompt"),
    ]

    /// The one action here that reaches outside the notch, so no allow rule may
    /// ever auto-approve it. A microphone is a channel anyone within earshot can
    /// use, and standing permission to instruct a coding agent is not something
    /// this app will hand out on a single click.
    public static let riskFloorReason: String? = "sends a spoken instruction to a coding agent"

    public static func propose(_ arguments: [String: String],
                               in context: VoiceContext) -> ActionProposal? {
        let prompt = (arguments["prompt"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }

        let target: VoiceAgentTarget?
        if let named = arguments["session"], !VoiceMatch.fold(named).isEmpty {
            // Named a session: it either exists or the command does not.
            guard let match = VoiceMatch.unique(named, in: context.agentSessions,
                                                name: \.label) else { return nil }
            target = match
        } else {
            switch context.agentSessions.count {
            case 0: target = nil                       // start a fresh one
            case 1: target = context.agentSessions[0]  // no ambiguity to resolve
            // Several running and none named. Guessing would send an instruction
            // to the wrong checkout, which is the one outcome here that is
            // genuinely hard to undo.
            default: return nil
            }
        }

        let subject = target?.label ?? "new session"
        // See the note in `VoiceClipboardAction`: a long instruction belongs in
        // the detail once, not truncated in the summary and in full underneath.
        let detail = prompt.count > VoiceText.previewLimit ? prompt : nil
        let tail = detail == nil ? ": \(prompt)" : ""
        return ActionProposal(
            toolName: toolName,
            subject: subject,
            summary: target.map { "Ask \($0.label)\(tail)" } ?? "Start a new session\(tail)",
            detail: detail,
            effect: .sendPrompt(sessionID: target?.sessionID, text: prompt))
    }
}

// MARK: - Shortcuts

/// "Run my morning focus shortcut."
///
/// **The only action whose vocabulary the user writes.** Every other conformer
/// here names things Airlock already understands — devices, clips, sessions —
/// and its triggers can be tuned against a fixed set of phrasings. A Shortcut is
/// called whatever its author called it, so the useful verbs ("run", "start",
/// "do") are the most generic in the language and would, on their own, turn a
/// large share of ordinary speech into commands.
///
/// So the word **"shortcut" is required, literally**, and that is the whole
/// safety design. It costs a little naturalness — "run my backup" does not
/// work, "run my backup shortcut" does — and it buys a trigger that cannot fire
/// on a sentence which was not about Shortcuts at all. `VoiceGrammarTests`
/// scores the same 18 questions against it as against everything else.
public struct VoiceShortcutAction: VoiceAction {
    public static let toolName = "Voice.Shortcut"
    public static let summary = "Run one of your Shortcuts by name."
    public static let parameters = ["name"]

    /// **No allow rule may ever pre-approve this, and the reason is not that a
    /// Shortcut is powerful — it is that a Shortcut is EDITABLE.**
    ///
    /// Every other floor in this app is about what an action does. This one is
    /// about what an action might become: a rule reading
    /// `Voice.Shortcut(Morning Focus)` authorises a name, and the steps behind
    /// that name can be rewritten in the Shortcuts app a minute later, by
    /// anyone at this Mac, without the rule changing a character. There is no
    /// version of standing permission that survives that, so none is offered.
    public static let riskFloorReason: String? =
        "runs a Shortcut, and a Shortcut's steps can be changed after you allow it"

    /// Unreachable while the floor holds — no Always button is ever shown — but
    /// `RuleGeneralizer` and `RiskAssessor` read it for any rule already sitting
    /// in a `policy.yaml`, so it has to describe the truth rather than nothing.
    public static let exactRuleSummary = "Only this exact Shortcut, whatever it is changed to"

    /// Two shapes, both anchored on the literal word.
    ///
    /// "run my morning focus **shortcut**" puts the name before the anchor;
    /// "run the **shortcut** called morning focus" puts it after one. Anything
    /// that does not contain the word matches nothing at all, which is the
    /// point.
    public static let triggers = [
        VoiceTrigger(verbs: ["run", "launch", "start", "trigger", "execute", "do", "play",
                             "ejecuta", "corre", "lanza", "inicia"],
                     objects: ["shortcut", "shortcuts", "atajo", "atajos"],
                     placement: .betweenVerbAndObject,
                     argument: "name"),
        // Spanish names its Shortcut AFTER the noun — "ejecuta el atajo
        // llamado enfoque" — which is exactly the called/named shape.
        VoiceTrigger(verbs: ["run", "launch", "start", "trigger", "execute", "do", "play",
                             "ejecuta", "corre", "lanza", "inicia"],
                     objects: ["shortcut", "shortcuts", "atajo", "atajos"],
                     prepositions: ["called", "named", "llamado", "llamada"],
                     argument: "name"),
    ]

    public static func propose(_ arguments: [String: String],
                               in context: VoiceContext) -> ActionProposal? {
        guard !context.shortcuts.isEmpty else { return nil }
        guard let query = arguments["name"], !VoiceMatch.fold(query).isEmpty else { return nil }
        // Ambiguity resolves to nothing, and a big library makes that the common
        // case rather than the edge: "focus" against "Morning Focus" and
        // "Evening Focus" is two hits, so nothing is proposed and the phrase is
        // answered instead. Picking one would be running the wrong automation.
        guard let name = VoiceMatch.unique(query, in: context.shortcuts, name: { $0 })
        else { return nil }

        return ActionProposal(
            toolName: toolName,
            // The Shortcut's own name is the subject, so the card names exactly
            // what will run and a gate-log entry reads back as itself.
            subject: name,
            summary: "Run the \(name) shortcut",
            effect: .runShortcut(name: name))
    }
}

// MARK: - Opening

/// "Open Spotify." "Go to YouTube." "Open my Gmail settings."
///
/// One action for all three, and that is a design decision rather than tidiness.
/// `VoiceGrammar.match` returns the first trigger that CAPTURES and never
/// reconsiders — it does not retry when `propose` declines — so a separate
/// site action could never get a turn behind this one: "go to youtube" would be
/// captured as an app, find none, and be answered with the site action never
/// tried. Two greedy triggers competing for "open" cannot both work, so there
/// is one, and it resolves in order.
///
/// **The order is app → alias → bare host**, and it is the order of confidence.
/// An installed app named Spotify is a certainty; an alias is something someone
/// wrote down; a bare host is a guess from punctuation. Ambiguity at any step
/// stops the whole thing rather than falling to the next — two apps tying must
/// not quietly become a website.
///
/// **No risk floor.** Opening an app or a page starts nothing the user did not
/// name and is undone by ⌘W. So Always is offered, and one click per
/// destination is the answer to "if I am already asking for it, just do it".
public struct VoiceOpenAction: VoiceAction {
    public static let toolName = "Voice.Open"
    public static let summary = "Open an app or a website by name."
    public static let parameters = ["name"]
    public static let exactRuleSummary = "Opening this, any time"

    /// `go` earns its place here and nowhere else: "go to youtube" is how
    /// people say this, and the preposition trigger keeps it from capturing
    /// "go ahead and…".
    ///
    /// `start` and `play` are still absent. With no object to anchor on, "play
    /// the music" would capture "music", find `Music.app`, and propose
    /// launching it over the top of `VoiceAudioOutputAction` — the action the
    /// speaker actually meant.
    ///
    /// The Spanish verbs ride the same triggers rather than a parallel set:
    /// a trigger is only word lists, so "abre spotify" and "ve a claude" cost
    /// two array entries each, and the capture, trimming and resolution behind
    /// them are exactly the tested English path. `VoiceMatch.fold` is
    /// diacritic-insensitive, so "vé" and "lánzame" arrive as their plain
    /// spellings. This is the shape further languages take: words on the
    /// trigger, never a second grammar.
    public static let triggers = [
        // `show` and its Spanish family are OPEN verbs here: "show me the
        // calendar" / "enséñame el calendario" is a request to put the thing
        // on screen, and opening it is the one way this action has. The live
        // failure that added them fell through to the Q&A model, which
        // invented a chrome:// URL rather than opening anything.
        VoiceTrigger(verbs: ["open", "launch", "show",
                             "abre", "abrir", "abreme", "lanza", "inicia",
                             "ensename", "ensena", "muestrame", "muestra"],
                     objects: [],
                     placement: .afterVerb,
                     argument: "name"),
        // Spanish says "go back" with a verb rather than an adverb, so
        // `verbAdverbs` cannot reach it — "vuelve a claude" needs the verb
        // itself. Both take the preposition already in the list.
        VoiceTrigger(verbs: ["go", "navigate", "browse",
                             "ve", "vete", "entra", "navega",
                             "vuelve", "vuelvete", "volver", "regresa", "regresar"],
                     objects: [],
                     prepositions: ["to", "a", "al"],
                     placement: .afterVerbPreposition,
                     argument: "name"),
    ]

    public static func propose(_ arguments: [String: String],
                               in context: VoiceContext) -> ActionProposal? {
        guard let raw = arguments["name"], !VoiceMatch.fold(raw).isEmpty else { return nil }

        // A trailing "in/en <browser>" is WHERE, not WHAT — "el calendario en
        // chrome" is asking for a page called calendario, not an app called
        // "calendario en chrome". Under the qualifier the site-shaped readings
        // come FIRST (naming a browser is saying "a page, please"), apps last
        // as the nearest thing when no page is known. Resolving to nothing
        // falls through to the plain path with the full phrase, so a
        // browser-shaped tail can never make a phrase resolve worse than it
        // did before this existed.
        //
        // The browser itself is not chosen: the URL opens in the DEFAULT
        // browser, and naming Chrome on a Safari-default Mac is a gap accepted
        // over teaching the open effect which app to hand a URL to.
        if let base = strippingBrowserQualifier(raw) {
            switch resolve(base, in: context.sites, names: { [$0.phrase] }) {
            case .ambiguous: return nil
            case .one(let site): return siteProposal(site)
            case .none: break
            }
            if let url = VoiceSiteAliases.bareURL(base) {
                return proposal(subject: base, summary: "Open \(base)", target: .url(url))
            }
            switch resolve(base, in: context.apps, names: { $0.spokenNames }) {
            case .ambiguous: return nil
            case .one(let app): return appProposal(app)
            case .none: break
            }
        }

        // 1. An installed app, by any name it answers to — the on-disk one or
        //    a localized alias ("abre la música" finds Music.app through
        //    "Música"). `matches` rather than `unique` so an AMBIGUITY stops
        //    here instead of falling through to a website.
        switch resolve(raw, in: context.apps, names: { $0.spokenNames }) {
        case .ambiguous: return nil
        case .one(let app): return appProposal(app)
        case .none: break
        }

        // 2. A phrase somebody wrote down.
        switch resolve(raw, in: context.sites, names: { [$0.phrase] }) {
        case .ambiguous: return nil
        case .one(let site): return siteProposal(site)
        case .none: break
        }

        // 3. Something that already looks like a host.
        if let url = VoiceSiteAliases.bareURL(raw) {
            return proposal(subject: raw, summary: "Open \(raw)", target: .url(url))
        }
        return nil
    }

    /// Browser names a trailing "in/en" qualifier may carry. Folded, and
    /// including the generic words — "in the browser" and "en el navegador"
    /// qualify exactly like a name. Deliberately NOT checked against installed
    /// apps: saying "en chrome" without Chrome installed still means "a page,
    /// please", and the default browser is where pages go anyway.
    private static let browsers: Set<String> = [
        "chrome", "google chrome", "safari", "firefox", "arc", "edge",
        "microsoft edge", "brave", "opera", "vivaldi", "browser", "navegador",
    ]

    /// The words before a trailing browser qualifier, or nil when there is
    /// none. "calendario en chrome" → "calendario"; "notion in dark mode" →
    /// nil, because "dark mode" is not a browser and the phrase is not about
    /// where.
    static func strippingBrowserQualifier(_ raw: String) -> String? {
        let tokens = VoiceMatch.fold(raw).split(separator: " ").map(String.init)
        guard let marker = tokens.lastIndex(where: { $0 == "in" || $0 == "en" }),
              marker > 0, marker < tokens.count - 1 else { return nil }
        // Articles inside the tail are the same noise they are anywhere:
        // "in THE browser", "en EL navegador".
        let tail = tokens[(marker + 1)...]
            .filter { !VoiceGrammar.leadingNoise.contains($0) }
            .joined(separator: " ")
        guard browsers.contains(tail) else { return nil }
        let base = tokens[..<marker].joined(separator: " ")
        return base.isEmpty ? nil : base
    }

    private static func appProposal(_ app: VoiceAppTarget) -> ActionProposal {
        proposal(subject: app.name, summary: "Open \(app.name)",
                 target: .app(path: app.path))
    }

    private static func siteProposal(_ site: VoiceSiteAlias) -> ActionProposal {
        proposal(subject: site.phrase, summary: "Open \(site.phrase)",
                 detail: site.url, target: .url(site.url))
    }

    private enum Resolution<T> {
        case none, ambiguous
        case one(T)
    }

    /// The one candidate `spoken` names — directly, or through a plausible
    /// mishearing when the direct query names nothing at all.
    ///
    /// The asymmetry between the two tie rules is deliberate. A DIRECT tie is
    /// evidence: the user's words genuinely fit two things, and picking one
    /// would be wrong confidently, so `.ambiguous` stops the whole action. A
    /// VARIANT tie is a bad guess about spelling — "cloud" reimagined as
    /// "claude" happening to graze two apps says nothing about what was said —
    /// so the guess is discarded and the next lens tried, and a query whose
    /// every guess misses falls through to the next step exactly as if the
    /// mishearing table did not exist.
    private static func resolve<T>(_ spoken: String, in candidates: [T],
                                   names: (T) -> [String]) -> Resolution<T> {
        let direct = VoiceMatch.matches(spoken, in: candidates, names: names)
        if direct.count > 1 { return .ambiguous }
        if let hit = direct.first { return .one(hit) }
        for variant in VoiceMishearings.variants(of: spoken) {
            let hits = VoiceMatch.matches(variant, in: candidates, names: names)
            if hits.count == 1, let hit = hits.first { return .one(hit) }
        }
        return .none
    }

    private static func proposal(subject: String, summary: String,
                                 detail: String? = nil,
                                 target: VoiceOpenTarget) -> ActionProposal {
        ActionProposal(toolName: toolName, subject: subject, summary: summary,
                       detail: detail, effect: .open(target: target))
    }
}

// MARK: - Volume

/// "Set the volume to 30 percent."
///
/// Absolute only. "Turn it up" is a relative move, which needs to know where it
/// is now — and `propose` is pure, so it would have to come through
/// `VoiceContext`, be stale by the time anyone clicks Do it, and land somewhere
/// nobody asked for. A number is unambiguous at every point in that chain.
///
/// Registered BEFORE `VoiceAudioOutputAction`, which shares "change", "volume"
/// and "to" and would otherwise look for a device called "30 percent". Since
/// `VoiceActionCatalog.resolve` now falls through, that is a preference rather
/// than a requirement — but the right one, because it costs a failed `propose`
/// on every volume phrase otherwise.
public struct VoiceVolumeAction: VoiceAction {
    public static let toolName = "Voice.Volume"
    public static let summary = "Set the system volume to a percentage."
    public static let parameters = ["level"]
    public static let exactRuleSummary = "Setting the volume, any level"

    /// **Wide on verbs, narrow on objects.** The object list is what keeps this
    /// away from every other sentence, so the verbs can be as many as people
    /// actually use — and "push the volume to 50" proved the point by being a
    /// verb nobody had thought of.
    ///
    /// `.afterObject` rather than `.afterPreposition` covers both "…volume to
    /// 50" and "…volume 50" with one trigger, because `to` is already dropped
    /// as leading noise.
    public static let triggers = [
        VoiceTrigger(verbs: ["set", "change", "put", "turn", "make", "drop", "raise",
                             "push", "bump", "lower", "bring", "crank", "adjust",
                             "increase", "decrease", "reduce", "boost",
                             "sube", "baja", "pon", "ajusta", "cambia",
                             "aumenta", "disminuye"],
                     objects: ["volume", "sound", "audio", "music",
                               "volumen", "sonido", "musica"],
                     placement: .afterObject,
                     argument: "level"),
        // "sube el volumen" / "raise the volume" — the direction is the verb
        // and there is nothing after the object to capture, so the trigger
        // above cannot fire at all. `theVerb` hands the verb itself to
        // `propose`, where `relative` reads the direction from it. Directional
        // verbs only, and AFTER the absolute trigger: "sube el volumen a 50"
        // captures for both, and the one that names a destination must win.
        VoiceTrigger(verbs: ["raise", "lower", "increase", "decrease", "boost",
                             "sube", "baja", "aumenta", "disminuye"],
                     objects: ["volume", "sound", "audio", "music",
                               "volumen", "sonido", "musica"],
                     placement: .theVerb,
                     argument: "level"),
    ]

    public static func propose(_ arguments: [String: String],
                               in context: VoiceContext) -> ActionProposal? {
        guard let raw = arguments["level"] else { return nil }
        let verb = arguments[VoiceGrammar.matchedVerbKey] ?? ""

        // "by" is TERMINAL, and this is not a style choice. Falling through to
        // the absolute reading when a step cannot be resolved is the one
        // failure worth engineering against: "decrease the volume by 10" would
        // become "set it to 10" — near-silence — which is both wrong and
        // confidently wrong. If a step was asked for, it is a step or it is
        // nothing.
        let percent: Int?
        if VoiceMatch.fold(raw).split(separator: " ").contains("by") {
            percent = delta(raw, verb: verb, from: context.volume)
        } else {
            percent = percentage(in: raw) ?? relative(raw, verb: verb, from: context.volume)
        }
        guard let percent else { return nil }
        return ActionProposal(
            toolName: toolName,
            // The LEVEL is the subject, so a rule reads `Voice.Volume(30%)` and
            // an Always click grants that level rather than every level. A
            // coarser subject would be a rule nobody meant to write.
            subject: "\(percent)%",
            summary: "Set the volume to \(percent)%",
            effect: .setVolume(Double(percent) / 100))
    }

    /// Verbs that say which way a `by N` moves. Without one, "by 10" is not
    /// an instruction anybody could carry out. The Spanish pairs also carry
    /// the plain relative move — "sube el volumen" is "turn it up" with the
    /// direction IN the verb, which English only says with a trailing word.
    static let decreasing: Set<String> = ["decrease", "lower", "drop", "reduce", "quieten",
                                          "baja", "bajar", "disminuye"]
    static let increasing: Set<String> = ["increase", "raise", "boost", "bump", "push", "crank",
                                          "sube", "subir", "aumenta"]

    /// "decrease the music **by 10**" — a step of a stated size.
    ///
    /// **The distinction "by" makes is the whole point, and getting it wrong is
    /// worse than not firing.** "to 10" is a destination and "by 10" is a
    /// step; reading the second as the first turns "turn it down a bit" into
    /// near-silence, which is the kind of wrong that makes somebody stop using
    /// a feature.
    ///
    /// Needs a direction, and takes it from the verb rather than the captured
    /// words, because the capture is identical for "increase … by 10" and
    /// "decrease … by 10". Nil when the verb does not say — "set the volume by
    /// 10" means nothing, so it proposes nothing.
    static func delta(_ text: String, verb: String, from current: Double?) -> Int? {
        let tokens = VoiceMatch.fold(text).split(separator: " ").map(String.init)
        guard let current else { return nil }
        guard let step = tokens.compactMap({ Int($0.prefix { $0.isNumber }) }).first(where: { $0 > 0 })
        else { return nil }

        let folded = VoiceMatch.fold(verb)
        let direction: Int
        if decreasing.contains(folded) { direction = -1 }
        else if increasing.contains(folded) { direction = 1 }
        else if tokens.contains("down") { direction = -1 }
        else if tokens.contains("up") { direction = 1 }
        else { return nil }

        let now = Int((current * 100).rounded())
        return max(0, min(100, now + direction * step))
    }

    /// How far "up" and "down" move. A tenth: small enough to say twice,
    /// large enough to hear once.
    static let relativeStep = 10

    /// "turn the volume down" — a move relative to where it is now.
    ///
    /// Needs the CURRENT level, which is why `VoiceContext` carries it. The
    /// staleness is real and bounded: the context is built at the moment of
    /// asking, so the worst case is somebody pressing a hardware key between
    /// speaking and approving, and the card names the resulting number.
    ///
    /// Nil when the device has no software volume, rather than assuming a
    /// starting point — guessing would move it somewhere nobody asked for.
    static func relative(_ text: String, verb: String = "", from current: Double?) -> Int? {
        guard let current else { return nil }
        let now = Int((current * 100).rounded())
        // The verb first: "sube el volumen" carries its whole direction there,
        // with nothing in the capture to scan. Same sets as `delta`, so a verb
        // that means up for "by 10" cannot mean anything else here.
        let foldedVerb = VoiceMatch.fold(verb)
        if increasing.contains(foldedVerb) { return min(100, now + relativeStep) }
        if decreasing.contains(foldedVerb) { return max(0, now - relativeStep) }
        for token in VoiceMatch.fold(text).split(separator: " ") {
            switch String(token) {
            case "up", "louder", "higher", "mas": return min(100, now + relativeStep)
            case "down", "quieter", "lower", "softer", "menos": return max(0, now - relativeStep)
            default: continue
            }
        }
        return nil
    }

    /// The first plain number in the phrase, 0...100. Nil for anything else —
    /// "to the airpods" has no number, and the audio action is behind us.
    static func percentage(in text: String) -> Int? {
        // Words people actually say for the ends of the range. "half" is here
        // because it is the one fraction anybody uses out loud. The Spanish
        // column is the same three points: silence, the middle, the top.
        let words = ["zero": 0, "off": 0, "mute": 0, "muted": 0, "half": 50,
                     "max": 100, "maximum": 100, "full": 100,
                     "cero": 0, "silencio": 0, "mitad": 50,
                     "maximo": 100, "tope": 100]
        for token in VoiceMatch.fold(text).split(separator: " ") {
            if let named = words[String(token)] { return named }
            let digits = token.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { continue }
            // A trailing unit is fine ("30%", "30percent"); a number glued to
            // letters that are not one is somebody's device name.
            let rest = token.dropFirst(digits.count)
            guard rest.isEmpty || rest == "percent" || rest == "pc" else { continue }
            return value <= 100 ? value : nil
        }
        return nil
    }
}

// MARK: - Media

/// "Play." "Pause the music." "Next track."
///
/// Whatever is already playing — `MediaPlayerController` decides which player
/// that is, exactly as the widget's own buttons do. No player is named here on
/// purpose: "play music" said out loud does not mean "launch Spotify", it means
/// "resume", and launching something is what `Voice.Open` is for.
public struct VoiceMediaAction: VoiceAction {
    public static let toolName = "Voice.Media"
    public static let summary = "Play, pause or skip what is playing."
    public static let parameters = ["command"]
    public static let exactRuleSummary = "Any transport control"

    public static let triggers = [
        // "pon la musica" is play, and "pon la musica en la tele" is routing —
        // the same split English already has with "play". The audio action's
        // trigger needs a preposition after its object and this one does not,
        // so each phrase lands where it should without an ordering rule.
        VoiceTrigger(verbs: ["play", "pause", "resume", "stop", "skip", "next", "previous",
                             "pausa", "para", "deten", "pon", "reanuda", "continua",
                             "salta", "siguiente", "anterior"],
                     objects: ["music", "song", "track", "playback", "it", "this",
                               "audio", "podcast", "video",
                               "musica", "cancion", "tema", "pista", "esto"],
                     placement: .theVerb,
                     argument: "command"),
    ]

    public static func propose(_ arguments: [String: String],
                               in context: VoiceContext) -> ActionProposal? {
        guard let command = command(in: arguments["command"] ?? "") else { return nil }
        return ActionProposal(
            toolName: toolName,
            subject: command.rawValue,
            summary: summaryText(command),
            effect: .media(command))
    }

    static func command(in text: String) -> VoiceMediaCommand? {
        let folded = VoiceMatch.fold(text)
        for token in folded.split(separator: " ") {
            switch String(token) {
            case "pause", "stop", "pausa", "para", "deten": return .pause
            case "play", "resume", "pon", "reanuda", "continua": return .play
            case "next", "skip", "siguiente", "salta": return .next
            case "previous", "back", "anterior": return .previous
            default: continue
            }
        }
        return nil
    }

    private static func summaryText(_ command: VoiceMediaCommand) -> String {
        switch command {
        case .play: return "Resume playback"
        case .pause: return "Pause playback"
        case .next: return "Skip to the next track"
        case .previous: return "Go back a track"
        }
    }
}

// MARK: - Wording

/// Shared trimming, so a card's first line is one line whatever was copied.
enum VoiceText {
    /// Long enough to recognise what you copied, short enough that the summary
    /// stays a sentence. Anything longer moves to `detail`, which the card can
    /// give more room.
    static let previewLimit = 48

    static func truncated(_ text: String) -> String {
        guard text.count > previewLimit else { return text }
        return String(text.prefix(previewLimit - 1)) + "…"
    }

    static func quoted(_ text: String) -> String {
        "“\(truncated(text))”"
    }
}
