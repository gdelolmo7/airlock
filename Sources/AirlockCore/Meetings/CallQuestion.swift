import Foundation

/// Whether something asked of the assistant is about the person's own past
/// calls: "what did Marta say about the budget?", "¿qué quedamos ayer en la
/// llamada con Pablo?".
///
/// **It is asked before `PromptRouting`, and only while call notes are on.**
/// The routing ladder offers a typed phrase to an agent unless it reads as a
/// question, and it reads English only: "qué quedamos con Pablo" has no
/// question mark and no English opener, so it would have been offered to
/// Claude Code as a task. A phrase this says yes to never reaches the ladder
/// or the agent; it is answered from the calls, or with "nothing in your
/// calls".
///
/// The two mistakes do not cost the same, and the rules lean on that. Saying
/// no to a call question costs what the assistant did before call notes
/// existed: a general answer that cannot know the call. Saying yes to a
/// general question replaces an answer the model could have given with
/// "nothing in your calls". So one call word is never enough: "how do I join
/// the call", "when is my next meeting" and "what does the meeting store do"
/// all name a call and are not about what was said on one. It takes a
/// question about something said or agreed, with a call, a person who was on
/// one, or a day to put it on; or a call put in the past ("on the call",
/// "yesterday's meeting", "how long was the call").
///
/// Pure, like `PromptRouting`, so each of those rules is a test rather than a
/// sentence typed into a notch.
public enum CallQuestion {
    /// The answer before the names are known.
    public enum Verdict: Equatable, Sendable {
        case no
        case yes
        /// Yes when one of its words is the name of someone a call was
        /// with: "what did Marta say about the budget". Knowing who that is
        /// means reading the calls, which only this case has to wait for.
        case ifNamed
    }

    /// Whether the phrase asks about what was said on a past call.
    ///
    /// `names` are the people the calls were with, as the calendar or the
    /// call itself named them. A name is what makes "what did Marta say"
    /// about a call rather than about anybody called Marta; a name nobody
    /// was on a call with does not count, so "what did Messi say yesterday"
    /// is left to the general answer, while "what did they say yesterday"
    /// is not.
    public static func isAboutPastCalls(_ phrase: String, names: [String] = []) -> Bool {
        switch verdict(phrase) {
        case .yes: true
        case .no: false
        case .ifNamed: mentionsName(CallText.tokens(phrase).map(\.text), names: names)
        }
    }

    public static func verdict(_ phrase: String) -> Verdict {
        let words = CallText.tokens(phrase)
        guard !words.isEmpty, asks(phrase, words.map(\.text)) else { return .no }
        let texts = words.map(\.text)

        let future = mentionsFuture(texts)
        let past = mentionsPast(texts)
        let speech = speech(in: texts, future: future)
        let calls = callIndices(texts)
        let callInPast = calls.contains { pointsBack(at: $0, in: words) }

        // Joining, muting, sharing a screen, a link or a time: a question
        // about a call that has not happened, or about using one. Something
        // said settles it the other way: "what did Ana share on the call".
        if speech == .none, !past, future || texts.contains(where: Self.handling.contains) {
            return .no
        }
        switch speech {
        case .strong:
            return .yes
        case .personal:
            return !calls.isEmpty || past ? .yes : .ifNamed
        case .weak:
            return calls.isEmpty ? .ifNamed : .yes
        case .none:
            return callInPast ? .yes : .no
        }
    }

    // MARK: - Asking

    /// Whether the phrase asks rather than tells.
    ///
    /// Wider than `PromptRouting.readsAsQuestion`: Spanish openers, an
    /// opener after a preposition ("en qué quedamos", "about what"), and the
    /// few requests that are questions in disguise ("remind me what…",
    /// "resúmeme la llamada"). An instruction about calls ("fix the meeting
    /// store") stays an instruction.
    static func asks(_ raw: String, _ words: [String]) -> Bool {
        if raw.contains("?") || raw.contains("¿") { return true }
        let real = Array(words.drop(while: Self.fillers.contains))
        guard let first = real.first else { return false }
        if Self.openers.contains(first) || Self.requests.contains(first) { return true }
        if Self.prepositions.contains(first), real.count > 1, Self.openers.contains(real[1]) {
            return true
        }
        // Spanish asks with the verb first and no other sign: "dijo Marta
        // algo del presupuesto".
        return Self.spanishPast.contains(first)
    }

    private static let fillers: Set<String> = VoiceGrammar.fillers.union([
        "por", "favor", "porfa", "hi", "airlock",
    ])

    private static let openers: Set<String> = VoiceGrammar.interrogatives.union([
        "what", "how", "who", "whom", "didn't", "do", "has", "have", "had",
        "can", "could", "would", "cuanto", "cuanta", "cuantos", "cuantas",
        "porque", "acaso",
    ])

    private static let requests: Set<String> = [
        "remind", "tell", "recap", "summarize", "summarise",
        "recuerdame", "recordame", "dime", "decime", "cuentame", "contame",
        "resumeme", "resume",
    ]

    private static let prepositions: Set<String> = [
        "about", "on", "in", "with", "from", "and",
        "en", "de", "del", "con", "sobre", "a", "para", "y",
    ]

    // MARK: - Something said

    enum Speech: Comparable { case none, weak, personal, strong }

    /// How firmly the phrase asks about something said.
    ///
    /// Strong is "we" agreeing or deciding, and the impersonal "what was
    /// decided" / "qué se dijo": nobody asks a general assistant what they
    /// themselves agreed, so these need nothing else. Personal is "I", "they"
    /// or "she" saying something, which a day is enough to put on a call:
    /// "what did they say yesterday". Weak is anyone else ("what did Marta
    /// say"), as often about the news, and needs a call or a known name.
    ///
    /// The Spanish "quedamos", "hablamos", "acordamos" are also the present
    /// tense: "¿quedamos mañana?" proposes a meeting rather than asking about
    /// one. With a future word in the phrase they do not count.
    static func speech(in words: [String], future: Bool) -> Speech {
        var best = Speech.none
        let did = words.firstIndex { $0 == "did" || $0 == "didn't" }
        for (i, word) in words.enumerated() {
            let before = words[max(0, i - 2)..<i]
            let around = words[max(0, i - 2)..<min(words.count, i + 3)]
            let someone: Speech = around.contains(where: Self.pronouns.contains) ? .personal : .weak
            if Self.englishPast.contains(word) {
                let ours = before.contains("we") || before.last.map(Self.passive.contains) == true
                best = max(best, ours ? .strong : someone)
            } else if Self.englishBase.contains(word), let did, did < i {
                let subject = words[did..<i]
                best = max(best, subject.contains("we") ? .strong
                    : subject.contains(where: Self.pronouns.contains) ? .personal : .weak)
            } else if Self.spanishOurs.contains(word) {
                best = .strong
            } else if Self.spanishOursOrNow.contains(word) {
                if !future { best = .strong }
            } else if Self.spanishPast.contains(word) {
                best = max(best, before.last == "se" ? .strong : someone)
            } else if Self.spanishDone.contains(word), let aux = before.last {
                if aux == "hemos" || aux == "habiamos" { best = .strong }
                else if Self.spanishHave.contains(aux) { best = max(best, someone) }
            }
        }
        return best
    }

    /// People who can only be someone the person knows. "you" is left out:
    /// "what did you say" asks the assistant to repeat itself. So is the
    /// Spanish "el", which folded is both "he" and "the".
    private static let pronouns: Set<String> = [
        "i", "he", "she", "they", "him", "her", "them", "me",
        "yo", "ella", "ellos", "ellas", "le", "les", "nos",
    ]

    private static let englishPast: Set<String> = [
        "said", "told", "mentioned", "agreed", "decided", "discussed", "talked",
        "promised", "asked", "suggested", "proposed", "explained", "committed",
        "settled", "concluded", "covered", "raised", "replied", "confirmed",
        "shared", "presented", "spoke", "planned",
    ]

    private static let englishBase: Set<String> = [
        "say", "tell", "mention", "agree", "decide", "discuss", "talk",
        "promise", "ask", "suggest", "propose", "explain", "commit", "settle",
        "conclude", "cover", "raise", "reply", "confirm", "share", "present",
        "speak", "plan",
    ]

    /// "what was agreed", "what were the points raised" reads the same way.
    private static let passive: Set<String> = ["was", "were", "got", "been"]

    /// First person plural, and only past: "dijimos" is never "we say".
    private static let spanishOurs: Set<String> = [
        "dijimos", "prometimos", "propusimos", "comprometimos",
    ]

    /// First person plural, past or present by context alone.
    private static let spanishOursOrNow: Set<String> = [
        "quedamos", "acordamos", "hablamos", "decidimos", "comentamos",
        "mencionamos", "tratamos", "cerramos", "pactamos", "discutimos",
        "dejamos", "concluimos", "planeamos",
    ]

    /// Someone else, or the speaker alone, in the past.
    static let spanishPast: Set<String> = [
        "dijo", "dijeron", "dije", "comento", "comentaron", "comente",
        "menciono", "mencionaron", "mencione", "prometio", "prometieron", "prometi",
        "pidio", "pidieron", "pedi", "pregunto", "preguntaron", "pregunte",
        "propuso", "propusieron", "propuse", "explico", "explicaron", "explique",
        "conto", "contaron", "conte", "sugirio", "sugirieron", "sugeri",
        "confirmo", "confirmaron", "confirme", "decidio", "decidieron", "decidi",
        "acordo", "acordaron", "acorde", "quedo", "quedaron", "quede",
        "hablo", "hablaron", "hable", "trato", "trataron", "comprometio",
        "comprometieron", "compartio", "compartieron", "comparti",
    ]

    /// Past participles, after a form of "haber".
    private static let spanishDone: Set<String> = [
        "dicho", "comentado", "mencionado", "prometido", "pedido", "preguntado",
        "propuesto", "explicado", "contado", "sugerido", "confirmado", "decidido",
        "acordado", "quedado", "hablado", "tratado", "compartido",
    ]

    private static let spanishHave: Set<String> = ["ha", "han", "he", "habia", "habian"]

    // MARK: - Time

    /// A word that puts the question ahead of now: "tomorrow", "next",
    /// "mañana" (but not "esta mañana", this morning).
    static func mentionsFuture(_ words: [String]) -> Bool {
        words.indices.contains { i in
            let word = words[i]
            if word == "manana" {
                return i == 0 || !["esta", "la", "de", "por", "en"].contains(words[i - 1])
            }
            if word == "viene" { return i > 0 && words[i - 1] == "que" }
            return Self.ahead.contains(word)
        }
    }

    private static let ahead: Set<String> = [
        "tomorrow", "tonight", "next", "upcoming",
        "proxima", "proximo", "proximas", "proximos", "siguiente",
    ]

    /// A word that puts it behind now, today and a weekday included: "on
    /// Monday" is usually the last one when it comes with something said.
    static func mentionsPast(_ words: [String]) -> Bool {
        words.indices.contains { i in
            pastWord(at: i, in: words) || Self.weekdays.contains(words[i])
                || words[i] == "today" || words[i] == "hoy"
        }
    }

    /// A past word that can sit right next to a call: "yesterday's call",
    /// "la reunión de ayer". Today and the weekdays are not: "the meeting
    /// today" and "the meeting on Tuesday" are as often still to come.
    private static func pastWord(at i: Int, in words: [String]) -> Bool {
        let word = words[i]
        if word == "morning" { return i > 0 && words[i - 1] == "this" }
        if word == "manana" { return i > 0 && words[i - 1] == "esta" }
        return Self.behind.contains(word)
    }

    private static let behind: Set<String> = [
        "yesterday", "earlier", "ago", "last", "previous",
        "ayer", "anteayer", "antes", "pasada", "pasado", "pasadas", "pasados",
        "ultima", "ultimo", "anterior",
    ]

    static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo",
    ]

    /// Using a call rather than asking what was said on one.
    private static let handling: Set<String> = [
        "join", "joining", "mute", "unmute", "share", "record", "invite",
        "schedule", "reschedule", "cancel", "link", "url", "password", "passcode",
        "agenda", "unirme", "unirse", "uno", "entrar", "entro", "silenciar", "silenciarme",
        "compartir", "comparto", "grabar", "grabo", "invitar", "programar",
        "agendar", "cancelar", "enlace", "contrasena",
    ]

    // MARK: - Calls

    /// Where the phrase names a call, leaving out the code that happens to
    /// carry the word: "the meeting store", "la llamada a la API".
    static func callIndices(_ words: [String]) -> [Int] {
        words.indices.filter { i in
            guard Self.callNouns.contains(words[i]) else { return false }
            let next = words.dropFirst(i + 1).prefix(3)
            if let first = next.first, Self.code.contains(first) { return false }
            if let first = next.first, ["a", "al", "to"].contains(first),
               next.dropFirst().contains(where: Self.code.contains) { return false }
            return true
        }
    }

    static let callNouns: Set<String> = [
        "call", "calls", "meeting", "meetings", "sync", "syncs", "standup",
        "standups", "oneonone", "oneonones", "huddle", "catchup", "checkin",
        "interview", "videocall",
        "llamada", "llamadas", "reunion", "reuniones", "videollamada",
        "videollamadas", "junta", "juntas",
    ]

    private static let code: Set<String> = [
        "store", "service", "services", "module", "class", "struct", "function",
        "func", "method", "api", "endpoint", "test", "tests", "view", "views",
        "controller", "model", "models", "code", "bug", "branch", "file", "files",
        "stack", "site", "sites", "graph", "chain", "log", "logs", "handler",
        "hook", "hooks", "protocol", "type", "window", "button", "tab", "panel",
        "widget", "pill", "card", "json", "funcion", "metodo",
    ]

    /// Whether the call at `i` is put in the past: a preposition in front
    /// ("on the call", "en la llamada", "from Tuesday's meeting"), "was" in
    /// front ("how long was the call"), or a past word beside it
    /// ("yesterday's call", "la reunión de ayer").
    static func pointsBack(at i: Int, in words: [CallText.Token]) -> Bool {
        let texts = words.map(\.text)
        let lead = max(0, i - 4)
        let before = texts[lead..<i]
        if before.contains(where: Self.into.contains) { return true }
        if before.suffix(3).contains(where: Self.was.contains) { return true }
        for j in max(0, i - 2)..<i where pastWord(at: j, in: texts) || words[j].possessive && Self.weekdays.contains(texts[j]) {
            return true
        }
        for j in (i + 1)..<min(texts.count, i + 4) where pastWord(at: j, in: texts) {
            return true
        }
        return false
    }

    /// Prepositions that place something on a call rather than around it.
    /// "for", "before" and "after" are left out: "what should I prepare for
    /// the call", "what do I do after the call".
    private static let into: Set<String> = [
        "on", "in", "at", "during", "from", "of",
        "en", "de", "del", "durante",
    ]

    private static let was: Set<String> = ["was", "were", "fue", "estuvo", "estuviste", "duro", "fueron"]

    // MARK: - People

    /// Whether a word in the phrase is one of the names, or part of one:
    /// "Marta" for Marta García.
    static func mentionsName(_ words: [String], names: [String]) -> Bool {
        let known = Set(names.compactMap(CallEventMatch.displayName).flatMap {
            CallText.tokens($0).map(\.text)
        }.filter {
            $0.count >= 2 && !Self.notNames.contains($0)
        })
        return words.contains(where: known.contains)
    }

    private static let notNames: Set<String> = [
        "you", "them", "me", "yo", "the", "and", "de", "la", "del", "y", "el", "los", "las",
    ]
}

/// The words of a question or a transcript, folded the way every match here
/// needs them: case and accents gone, so "reunión", "Reunion" and "REUNIÓN"
/// are one word.
public enum CallText {
    public struct Token: Equatable, Sendable {
        public let text: String
        /// It ended in "'s": "Tuesday's meeting".
        public let possessive: Bool
    }

    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Folded words, with "'s" taken off and remembered.
    ///
    /// "stand-up", "one-on-one" and "1:1" are joined first: split on the
    /// hyphen they become "stand" and "up", and neither is a call.
    public static func tokens(_ text: String) -> [Token] {
        var folded = fold(text).replacingOccurrences(of: "’", with: "'")
        for (from, to) in Self.joined { folded = folded.replacingOccurrences(of: from, with: to) }
        return folded
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .compactMap { piece -> Token? in
                var word = String(piece).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                guard !word.isEmpty else { return nil }
                var possessive = false
                if word.hasSuffix("'s") {
                    word.removeLast(2)
                    possessive = true
                }
                return word.isEmpty ? nil : Token(text: word, possessive: possessive)
            }
    }

    private static let joined: [(String, String)] = [
        ("stand-up", "standup"), ("one-on-one", "oneonone"),
        ("1-on-1", "oneonone"), ("1:1", "oneonone"), ("catch-up", "catchup"),
        ("check-in", "checkin"), ("video call", "videocall"), ("video-call", "videocall"),
    ]
}
