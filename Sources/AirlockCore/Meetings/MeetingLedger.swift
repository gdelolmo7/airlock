import Foundation

/// What the model wrote for one part of a call, before any of it is believed.
///
/// A plain copy of the model's answer, so the checks that decide what is
/// kept (`MeetingLedger`) live in Core and are tested without a model.
public struct MeetingDraft: Equatable, Sendable {
    public struct Fact: Equatable, Sendable {
        public var text: String
        /// Transcript line IDs as the model wrote them, e.g. "S12".
        public var sources: [String]

        public init(text: String, sources: [String]) {
            self.text = text
            self.sources = sources
        }
    }

    public struct Todo: Equatable, Sendable {
        public var task: String
        /// As the model wrote it; may be empty, "unassigned", or a guess.
        public var owner: String
        /// When it is due, in the call's words, or empty.
        public var due: String
        public var sources: [String]

        public init(task: String, owner: String = "", due: String = "", sources: [String]) {
            self.task = task
            self.owner = owner
            self.due = due
            self.sources = sources
        }
    }

    public var decisions: [Fact]
    public var todos: [Todo]
    public var questions: [Fact]
    public var topics: [Fact]

    public init(decisions: [Fact] = [], todos: [Todo] = [], questions: [Fact] = [], topics: [Fact] = []) {
        self.decisions = decisions
        self.todos = todos
        self.questions = questions
        self.topics = topics
    }
}

/// Who on a call a to-do can belong to.
///
/// "You", the other people the calendar invite names, and "Person 2" when
/// the voices on the other side were told apart. Nobody else: a name the
/// model offers that is not one of these was made up or misheard, and a
/// to-do with nobody's name on it is honest where a wrong name is not.
public struct MeetingPeople: Equatable, Sendable {
    /// The other people's display names, as the calendar has them.
    public let others: [String]
    /// How many voices the other side was told apart into (`CallVoices`):
    /// 0 when it was not, which is also every one-to-one call.
    public let voices: Int
    /// A meeting in the room (`MeetingRecord.isInPerson`): one microphone
    /// heard everybody, so no line is the notes' owner's for certain and
    /// nobody is "You".
    public let inPerson: Bool

    public init(others: [String], voices: Int = 0, inPerson: Bool = false) {
        var seen = Set<String>()
        self.others = others.compactMap(CallEventMatch.displayName).filter { seen.insert(Self.fold($0)).inserted }
        self.voices = voices
        self.inPerson = inPerson
    }

    public init(record: MeetingRecord) {
        let voices = record.otherName == nil
            ? Set(record.spokenSegments.compactMap { $0.speaker == .them ? $0.person : nil }).count
            : 0
        self.init(others: record.event?.attendees ?? [], voices: voices > 1 ? voices : 0,
                  inPerson: record.isInPerson)
    }

    /// The other person on a one-to-one call.
    public var oneToOne: String? { others.count == 1 ? others[0] : nil }

    /// Whether the model is told everyone else on the call is "Them": not
    /// in the room ("Someone"), no one name from the calendar, no voices
    /// told apart ("Person 2").
    public var callsThem: Bool { !inPerson && oneToOne == nil && voices < 2 }

    /// "Person 1 and Person 2", "Person 1 to Person 4".
    var voiceRange: String {
        voices == 2
            ? "\(MeetingRecord.personLabel(1)) and \(MeetingRecord.personLabel(2))"
            : "\(MeetingRecord.personLabel(1)) to \(MeetingRecord.personLabel(voices))"
    }

    /// "Person 1" … one for each voice told apart, none when they were not.
    public var voiceLabels: [String] {
        voices > 1 ? (1...voices).map(MeetingRecord.personLabel) : []
    }

    /// The word before a voice's number, as the model may write it.
    static let person: Set<String> = ["person", "persona"]

    /// The names a to-do's owner may be: "You" (never in the room), the
    /// invited, then the voices. `invited` caps the invited, for a prompt.
    public func names(invited: Int = .max) -> [String] {
        (inPerson ? [] : [MeetingSpeaker.me.label]) + others.prefix(invited) + voiceLabels
    }

    /// Who the model is told was on the call.
    public var promptLine: String {
        if inPerson {
            let line = voices > 1
                ? "This was a meeting in the room, heard through one microphone. People heard: "
                    + "\(voiceRange) (voices told apart by sound only: which one is the person the "
                    + "notes are for, or which invited person each one is, is not known). Nobody here is \"You\"."
                : "This was a meeting in the room, heard through one microphone. Every line is "
                    + "\(MeetingRecord.someone): who said what is not known, and nobody here is \"You\"."
            guard !others.isEmpty else { return line }
            return line + " Invited: " + others.prefix(12).joined(separator: ", ") + "."
        }
        if let name = oneToOne { return "People on the call: You, and \(name) (the other side)." }
        let line = voices > 1
            ? "People on the call: You, and \(voiceRange) (other voices, told apart by sound only: "
                + "which invited person each one is, is not known)."
            : "People on the call: You, and Them (everyone else on the call)."
        guard !others.isEmpty else { return line }
        return line + " Invited: " + others.prefix(12).joined(separator: ", ") + "."
    }

    /// The owner the model named, as a known person, or nil.
    ///
    /// "You" (in English or Spanish), or one of the invited, matched on any
    /// of their names: "Ana" is Ana García. Two people sharing the name that
    /// was said keep it as said, since either is somebody on the call.
    /// In the room there is no "You" to be: nobody is known to be the owner.
    public func owner(_ said: String) -> String? {
        let name = said.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        let folded = Self.fold(name)
        guard !folded.isEmpty, !Self.nobody.contains(folded) else { return nil }
        if Self.you.contains(folded) { return inPerson ? nil : MeetingSpeaker.me.label }
        let words = Self.words(folded)
        guard !words.isEmpty else { return nil }
        if words.count == 2, Self.person.contains(words[0]), let number = Int(words[1]) {
            return (1...max(1, voices)).contains(number) && voices > 1 ? MeetingRecord.personLabel(number) : nil
        }
        let matches = others.filter { Set(Self.words(Self.fold($0))).isSuperset(of: words) }
        if matches.count == 1 { return matches[0] }
        return matches.isEmpty ? nil : name
    }

    /// Whether a named person can be heard in these turns: their name is
    /// said, or they are the one speaking (only knowable on a one-to-one
    /// call, where the other side is labelled with their name).
    func isHeard(_ owner: String, in turns: [NumberedTranscript.Turn]) -> Bool {
        if owner == MeetingSpeaker.me.label { return turns.contains { $0.speaker == .me } }
        let names = Set(Self.words(Self.fold(owner)))
        return turns.contains { turn in
            turn.label == owner || !names.isDisjoint(with: Self.words(Self.fold(turn.text)))
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" }.map(String.init)
    }

    /// Answers that mean nobody was named.
    private static let nobody: Set<String> = [
        "unassigned", "nobody", "none", "no one", "noone", "n/a", "na", "unknown", "tbd",
        "them", "they", "someone", "somebody", "everyone", "everybody", "all", "the team", "team",
        "sin asignar", "no asignado", "nadie", "ninguno", "ninguna", "alguien", "todos", "ellos",
        "ellas", "equipo", "el equipo", "desconocido",
    ]

    /// Answers that mean the person the notes are for.
    private static let you: Set<String> = ["you", "tu", "usted", "vos"]
}

/// Every line of notes the model offered, checked against the transcript,
/// and kept only if it holds up.
///
/// The rules, in the order they run:
/// - A line must cite at least one transcript turn the model was actually
///   shown. Citations to turns that do not exist, or that were in another
///   part, are removed; a line left citing nothing is dropped.
/// - A to-do's owner must be somebody on the call (`MeetingPeople`) who can
///   be heard in or right next to the cited turns. Otherwise the to-do is
///   kept with no owner rather than an invented one.
/// - A due date is kept only when its words were said in those turns, and
///   is folded into the task: "Send the budget" + "by Friday".
/// - A to-do that only tells who explained what in the meeting ("Person 3
///   explica el proceso") is dropped, unless a date for it was said.
/// - The same line twice, from this part or an earlier one, is kept once,
///   and so is a line from an earlier part in other words. A question
///   asked again from the same turn, one wording inside the other, too.
///   A decision that only repeats a to-do is dropped.
/// - After the last part, a second look (`CallNotesChecks`): an owner stays
///   only if the model, shown just the lines the to-do came from, confirms
///   that person said they will do it; an open question goes if the lines
///   right after it answer it.
public struct MeetingLedger: Sendable {
    public let transcript: NumberedTranscript
    public let people: MeetingPeople
    public private(set) var todos: [MeetingNotes.Item] = []
    public private(set) var decisions: [MeetingNotes.Item] = []
    public private(set) var questions: [MeetingNotes.Item] = []
    public private(set) var topics: [MeetingNotes.Item] = []

    /// What one part contributed, for the log.
    public struct Tally: Equatable, Sendable {
        public var kept = 0
        public var dropped = 0

        public init(kept: Int = 0, dropped: Int = 0) {
            self.kept = kept
            self.dropped = dropped
        }
    }

    public init(transcript: NumberedTranscript, people: MeetingPeople) {
        self.transcript = transcript
        self.people = people
    }

    public init(record: MeetingRecord) {
        self.init(transcript: NumberedTranscript(record), people: MeetingPeople(record: record))
    }

    // MARK: - Checking one part

    /// One part's draft, checked. `shown` is the turns that part showed the
    /// model, the only ones its lines may cite.
    ///
    /// A line already kept is not kept again. From an earlier part, mostly
    /// the same words is enough (`MeetingText.sameThing`): each part is read
    /// without being told what the others found, so a to-do settled at
    /// minute 5 and repeated at minute 30 comes back in other words. Within
    /// one part only the same line counts, since two to-dos written side by
    /// side that share words ("Send the budget to Ana", "… to Luis") are two,
    /// unless one is the other with more said (`sameTask`): then they are one
    /// to-do, in the words that say more.
    @discardableResult
    public mutating func add(_ draft: MeetingDraft, shown: Set<Int>) -> Tally {
        var tally = Tally()
        let transcript = transcript
        var todos = todos, decisions = decisions, questions = questions, topics = topics
        let earlier = (todos: todos.count, decisions: decisions.count, questions: questions.count,
                       topics: topics.count)
        defer {
            self.todos = todos
            self.decisions = decisions
            self.questions = questions
            self.topics = topics
        }
        func keep(_ item: MeetingNotes.Item?, into list: inout [MeetingNotes.Item], earlier: Int,
                  unlessIn others: [MeetingNotes.Item] = [], asked: Bool = false, merged: Bool = false) {
            guard var item, !item.text.isEmpty else {
                tally.dropped += 1
                return
            }
            let key = MeetingText.key(item.text)
            if others.contains(where: { MeetingText.key($0.text) == key || Self.restates(item, $0) }) {
                tally.dropped += 1
                return
            }
            if let index = list.indices.first(where: {
                MeetingText.key(list[$0].text) == key
                    || ($0 < earlier && MeetingText.sameThing(list[$0].text, item.text))
                    || (asked && Self.asksAgain(item, list[$0]))
            }) {
                if list[index].owner == nil, let owner = item.owner { list[index].owner = owner }
                tally.dropped += 1
                return
            }
            if merged, let index = list.indices.first(where: { Self.sameTask(item, list[$0]) }) {
                if Self.saysMore(item.text, than: list[index].text) { list[index].text = item.text }
                list[index].sources = Array(Set(list[index].sources + item.sources)).sorted()
                list[index].at = transcript.turn(list[index].sources[0])?.start
                if list[index].owner == nil, let owner = item.owner { list[index].owner = owner }
                tally.dropped += 1
                return
            }
            item.at = transcript.turn(item.sources[0])?.start
            list.append(item)
            tally.kept += 1
        }
        for todo in draft.todos {
            keep(checked(todo, shown: shown), into: &todos, earlier: earlier.todos, merged: true)
        }
        for fact in draft.decisions {
            keep(checked(fact, shown: shown), into: &decisions, earlier: earlier.decisions, unlessIn: todos)
        }
        for fact in draft.questions {
            keep(checked(fact, shown: shown).flatMap { item in
                MeetingText.openQuestion(item.text).map { MeetingNotes.Item(text: $0, sources: item.sources) }
            }, into: &questions, earlier: earlier.questions, asked: true)
        }
        for fact in draft.topics { keep(checked(fact, shown: shown), into: &topics, earlier: earlier.topics) }
        return tally
    }

    /// The same question from the same line, one wording inside the other:
    /// "¿Cuántos proveedores…?" and "¿Con cuántos proveedores…?", both
    /// from one part. Like to-dos from one part are kept apart ("Send the
    /// deck to Ana", "…to Luis"); a question asked once is one question.
    static func asksAgain(_ question: MeetingNotes.Item, _ other: MeetingNotes.Item) -> Bool {
        guard !Set(question.sources).isDisjoint(with: other.sources) else { return false }
        let one = " \(MeetingText.key(question.text)) ", two = " \(MeetingText.key(other.text)) "
        return one.count > 2 && two.count > 2 && (one.contains(two) || two.contains(one))
    }

    /// Whether two to-dos are one task: the same moment of the call (a turn
    /// in common), and every word that carries meaning in one is in the
    /// other, word endings aside (`MeetingText.stems`): "Pintar una pared"
    /// and "Pintar otra pared", cited from the same two lines. "Send the report to finance" and "…
    /// to legal" are two: each has a word the other hasn't.
    static func sameTask(_ todo: MeetingNotes.Item, _ other: MeetingNotes.Item) -> Bool {
        guard !Set(todo.sources).isDisjoint(with: other.sources) else { return false }
        let one = taskWords(todo.text), two = taskWords(other.text)
        return !one.isEmpty && !two.isEmpty && (one.isSubset(of: two) || two.isSubset(of: one))
    }

    /// Whether `text` says something `other` doesn't: a word that carries
    /// meaning and names something ("the big room upstairs"), not only
    /// "otra" or "another" (`MeetingText.vagueWords`).
    static func saysMore(_ text: String, than other: String) -> Bool {
        !taskWords(text, leaving: MeetingText.vagueWords).isSubset(of: taskWords(other))
    }

    /// What a to-do is made of, for `sameTask`: its word stems and its
    /// short names.
    private static func taskWords(_ text: String, leaving: Set<String> = []) -> Set<String> {
        MeetingText.stems(text, leaving: leaving).union(MeetingText.shortNames(text))
    }

    /// Whether a decision only says a to-do again: the same moment of the
    /// call (a turn in common) and mostly the same words.
    static func restates(_ decision: MeetingNotes.Item, _ todo: MeetingNotes.Item) -> Bool {
        !Set(decision.sources).isDisjoint(with: todo.sources) && MeetingText.sameThing(decision.text, todo.text)
    }

    /// The cited turns that exist and were shown, in order, without repeats.
    func sources(_ cited: [String], shown: Set<Int>) -> [Int] {
        Array(Set(cited.compactMap(NumberedTranscript.id(from:)))
            .filter { shown.contains($0) && transcript.turn($0) != nil }).sorted()
    }

    func checked(_ fact: MeetingDraft.Fact, shown: Set<Int>) -> MeetingNotes.Item? {
        let sources = sources(fact.sources, shown: shown)
        let text = MeetingText.line(fact.text)
        guard !sources.isEmpty, !text.isEmpty else { return nil }
        return MeetingNotes.Item(text: text, sources: sources)
    }

    func checked(_ todo: MeetingDraft.Todo, shown: Set<Int>) -> MeetingNotes.Item? {
        let sources = sources(todo.sources, shown: shown)
        var task = MeetingText.line(todo.task)
        guard !sources.isEmpty, !task.isEmpty else { return nil }
        let context = nearby(sources)
        let due = MeetingText.line(todo.due)
        let dueSaid = Self.isSaid(due, in: context)
        guard dueSaid || !tellsTheMeeting(task, in: context) else { return nil }
        if dueSaid, !MeetingText.key(task).contains(MeetingText.key(due)) {
            while task.last == "." { task.removeLast() }
            task += " " + due
        }
        let owner = people.owner(todo.owner).flatMap { people.isHeard($0, in: context) ? $0 : nil }
        return MeetingNotes.Item(text: task, owner: owner, sources: sources)
    }

    /// Whether a to-do only tells what somebody did in the meeting itself:
    /// "Lucía explica cómo trabaja", "Person 3 explica el proceso". From
    /// a meeting in the room the model listed the introductions as to-dos,
    /// and the check after it (`CallNotesChecks`) kept them, since being
    /// asked to explain reads as being asked to do something.
    ///
    /// It is somebody, then a word for telling in the present ("explains",
    /// "explica", "présente"), then what they told. Somebody is a voice
    /// ("Person 3"), one of the invited, or a name said in these lines
    /// where a sentence does not start. A task the way to-dos are written
    /// ("Explicar el proceso a Lucía", "Enviar muestra al cliente") starts
    /// with what to do, so it is never one; a to-do the model wrote with a
    /// date that was said is kept by the caller, since "Ana presenta el
    /// presupuesto el viernes" is work for later.
    func tellsTheMeeting(_ task: String, in lines: [NumberedTranscript.Turn]) -> Bool {
        let words = task.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard words.count >= 2 else { return false }
        for verb in 1...min(3, words.count - 1) {
            guard words[verb].first?.isLowercase == true,
                  Self.tellingWords.contains(MeetingPeople.fold(words[verb])) else { continue }
            let subject = Array(words[..<verb])
            return people.owner(subject.joined(separator: " ")) != nil
                || subject.allSatisfy { Self.isNameSaid($0, in: lines) }
        }
        return false
    }

    /// Whether `word` is said in these lines as a name is: with a capital,
    /// where a sentence does not start. "Lucía" in "que Lucía empiece"; not
    /// "Enviar", which a sentence may start with.
    static func isNameSaid(_ word: String, in lines: [NumberedTranscript.Turn]) -> Bool {
        guard word.first?.isUppercase == true else { return false }
        return lines.contains { line in
            let said = line.text.split(whereSeparator: \.isWhitespace)
            return said.indices.dropFirst().contains { index in
                guard said[index].trimmingCharacters(in: .punctuationCharacters) == word else { return false }
                return !(said[index - 1].last.map { ".!?…:".contains($0) } ?? true)
            }
        }
    }

    /// Words for explaining, in the present, folded: what somebody does in
    /// a meeting while the others listen. Third person only, so the
    /// imperative a to-do starts with is not among them in English, and in
    /// Spanish it has a subject before it. Words that are also work are
    /// left out: "Ana cuenta el stock" counts it, "Ana habla con el
    /// proveedor" and "Ana introduce los datos" may be what she will do.
    static let tellingWords: Set<String> = [
        // English
        "explains", "describes", "introduces", "presents", "outlines", "demonstrates", "summarizes",
        "summarises", "walks",
        // Spanish and Catalan
        "explica", "describe", "presenta", "expone", "descriu", "exposa",
        // French
        "explique", "decrit", "presente", "expose",
        // German
        "erklart", "beschreibt", "prasentiert",
        // Italian and Portuguese
        "spiega", "descrive", "illustra", "descreve", "apresenta",
    ]

    /// The cited turns and the turn either side of each: who a task is for
    /// is often said in the question just before the "yes, I'll do it".
    private func nearby(_ sources: [Int]) -> [NumberedTranscript.Turn] {
        Set(sources.flatMap { [$0 - 1, $0, $0 + 1] }).sorted().compactMap(transcript.turn)
    }

    /// Whether every word of a due date that carries meaning ("Friday",
    /// "week", "15th") was said in these turns. A date the model worked out
    /// for itself ("October 10" for "Friday") is not kept.
    ///
    /// It must name a time, too: a number, or a word like "Friday",
    /// "tomorrow" or "week". From a meeting in the room the model filled
    /// the field with whatever stood near the task ("Normalmente",
    /// "Intentar", "De ahí sí que tienes tiempo"), all of it said, none of
    /// it a date, and the page showed "Controlar los gastos Normalmente".
    static func isSaid(_ due: String, in turns: [NumberedTranscript.Turn]) -> Bool {
        let words = MeetingPeople.words(MeetingPeople.fold(due)).filter { word in
            (word.count >= 3 || word.contains(where: \.isNumber)) && !dueFillers.contains(word)
        }
        guard !words.isEmpty, !nobodyDue.contains(MeetingPeople.fold(due)), !due.contains("?"),
              words.contains(where: { $0.contains(where: \.isNumber) || timeWords.contains($0) })
        else { return false }
        let heard = Set(turns.flatMap { MeetingPeople.words(MeetingPeople.fold($0.text)) })
        return words.allSatisfy(heard.contains)
    }

    /// Words that name a time, folded, in the languages meetings here are
    /// held in. A due date in another language is not kept, which loses
    /// "by Friday" there and never adds a word that is not a date.
    static let timeWords: Set<String> = [
        // English
        "today", "tonight", "tomorrow", "morning", "afternoon", "evening", "night", "noon", "midday",
        "day", "days", "week", "weeks", "weekend", "month", "months", "year", "quarter", "hour", "hours",
        "minutes", "asap", "soon", "later", "eod", "eow",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december",
        // Spanish
        "hoy", "manana", "tarde", "noche", "mediodia", "dia", "dias", "semana", "semanas", "finde",
        "mes", "meses", "ano", "trimestre", "hora", "horas", "minutos", "pronto", "luego",
        "lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo",
        "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre",
        "setiembre", "octubre", "noviembre", "diciembre",
        // Catalan
        "avui", "dema", "tarda", "nit", "setmana", "setmanes", "any",
        "dilluns", "dimarts", "dimecres", "dijous", "divendres", "dissabte", "diumenge",
        "gener", "febrer", "marc", "maig", "juny", "juliol", "agost", "setembre", "novembre", "desembre",
        // French
        "aujourd'hui", "demain", "soir", "matin", "semaine", "mois", "annee", "jour", "jours", "heure",
        "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche",
        "janvier", "fevrier", "mars", "avril", "mai", "juin", "juillet", "aout", "septembre", "octobre",
        "decembre",
        // German
        "heute", "morgen", "abend", "woche", "wochen", "monat", "jahr", "tag", "tage", "stunde",
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag",
        "januar", "februar", "marz", "juni", "juli", "oktober", "dezember",
        // Italian and Portuguese
        "oggi", "domani", "sera", "settimana", "mese", "anno", "giorno",
        "lunedi", "martedi", "mercoledi", "giovedi", "venerdi", "sabato", "domenica",
        "gennaio", "febbraio", "aprile", "maggio", "giugno", "luglio", "settembre", "ottobre", "dicembre",
        "hoje", "amanha", "semana", "segunda", "terca", "quarta", "quinta", "sexta",
        "janeiro", "fevereiro", "marco", "maio", "junho", "julho", "setembro", "outubro", "dezembro",
    ]

    private static let dueFillers: Set<String> = [
        "the", "end", "before", "until", "next", "this", "and", "for",
        "para", "antes", "del", "los", "las", "que", "hasta", "proximo", "proxima", "este", "esta",
    ]
    private static let nobodyDue: Set<String> = [
        "none", "not said", "not stated", "unspecified", "unknown", "n/a", "no date",
        "sin fecha", "ninguna", "no dicho",
    ]

    // MARK: - The second look

    /// The owned to-dos to ask about again (`CallNotesChecks`), in the order
    /// they were said, at most `limit` of them. The rest are not asked
    /// about, and `settleOwners` takes their owner off.
    public func ownerChecks(limit: Int = CallNotesChecks.ownerLimit) -> [CallNotesChecks.Owner] {
        Array(Self.timeOrder(todos).compactMap { index -> CallNotesChecks.Owner? in
            let todo = todos[index]
            guard let owner = todo.owner else { return nil }
            return CallNotesChecks.Owner(index: index, task: todo.text, owner: owner, lines: nearby(todo.sources))
        }.prefix(limit))
    }

    /// The to-dos to ask about again, in the order they were said, at most
    /// `limit` of them. The rest are not asked about, and stay.
    public func todoChecks(limit: Int = CallNotesChecks.todoLimit) -> [CallNotesChecks.Todo] {
        Array(Self.timeOrder(todos).map { index in
            CallNotesChecks.Todo(index: index, task: todos[index].text, lines: nearby(todos[index].sources))
        }.prefix(limit))
    }

    /// The decisions to ask about again, in the order they were said, at
    /// most `limit` of them. The rest are not asked about, and stay.
    public func decisionChecks(limit: Int = CallNotesChecks.decisionLimit) -> [CallNotesChecks.Decision] {
        Array(Self.timeOrder(decisions).map { index in
            CallNotesChecks.Decision(index: index, decision: decisions[index].text,
                                     lines: nearby(decisions[index].sources))
        }.prefix(limit))
    }

    /// The open questions to ask about again, in the order they were asked,
    /// at most `limit` of them. One with nothing said after it is not asked
    /// about: nothing there could have answered it.
    public func questionChecks(limit: Int = CallNotesChecks.limit) -> [CallNotesChecks.Question] {
        Array(Self.timeOrder(questions).compactMap { index -> CallNotesChecks.Question? in
            let question = questions[index]
            guard let last = question.sources.max() else { return nil }
            let after = (last + 1 ... last + CallNotesChecks.reach).compactMap(transcript.turn)
            guard !after.isEmpty else { return nil }
            return CallNotesChecks.Question(index: index, question: question.text,
                                            lines: question.sources.compactMap(transcript.turn) + after)
        }.prefix(limit))
    }

    /// What the second look did, for the log.
    public struct Settled: Equatable, Sendable {
        /// Owners confirmed, or questions found answered.
        public var yes = 0
        /// Answered no, or unclear.
        public var no = 0
        /// Beyond the limit, nothing to show, or the check failed.
        public var unasked = 0

        public init(yes: Int = 0, no: Int = 0, unasked: Int = 0) {
            self.yes = yes
            self.no = no
            self.unasked = unasked
        }
    }

    /// The owners after the second look, keyed by `CallNotesChecks.Owner.index`.
    /// An owner stays only where the answer was yes; every other one is
    /// taken off, the to-do kept: a to-do with nobody's name on it is
    /// honest, and one with the wrong name sends somebody else's work to
    /// the wrong person. Run once, after the last part.
    @discardableResult
    public mutating func settleOwners(_ answers: [Int: CallNotesChecks.Answer]) -> Settled {
        var settled = Settled()
        for index in todos.indices where todos[index].owner != nil {
            switch answers[index] {
            case .yes:
                settled.yes += 1
                continue
            case .no, .unclear:
                settled.no += 1
            case nil:
                settled.unasked += 1
            }
            todos[index].owner = nil
        }
        return settled
    }

    /// The to-dos after the second look, keyed by `CallNotesChecks.Todo.index`.
    /// One goes only where the answer was a clear no: a step of a process
    /// left in is a nuisance, a real to-do lost is work nobody does. Run
    /// once, after the last part, and before `ownerChecks`, whose indices
    /// it changes.
    @discardableResult
    public mutating func settleTodos(_ answers: [Int: CallNotesChecks.Answer]) -> Settled {
        var settled = Settled()
        var kept: [MeetingNotes.Item] = []
        for (index, todo) in todos.enumerated() {
            switch answers[index] {
            case .no:
                settled.no += 1
                continue
            case .yes, .unclear:
                settled.yes += 1
            case nil:
                settled.unasked += 1
            }
            kept.append(todo)
        }
        todos = kept
        return settled
    }

    /// The decisions after the second look, keyed by
    /// `CallNotesChecks.Decision.index`. One goes only where the answer was
    /// a clear no (an opinion, how things are, an idea still talked over):
    /// an opinion left in is a nuisance, a real decision lost is one
    /// nobody remembers making. Run once, after the last part.
    @discardableResult
    public mutating func settleDecisions(_ answers: [Int: CallNotesChecks.Answer]) -> Settled {
        var settled = Settled()
        var kept: [MeetingNotes.Item] = []
        for (index, decision) in decisions.enumerated() {
            switch answers[index] {
            case .no:
                settled.no += 1
                continue
            case .yes, .unclear:
                settled.yes += 1
            case nil:
                settled.unasked += 1
            }
            kept.append(decision)
        }
        decisions = kept
        return settled
    }

    /// The open questions after the second look, keyed by
    /// `CallNotesChecks.Question.index`. One goes only where the answer was
    /// yes: an answered question left in is a nuisance, an open one lost is
    /// a follow-up nobody makes. Run once, after the last part.
    @discardableResult
    public mutating func settleQuestions(_ answers: [Int: CallNotesChecks.Answer]) -> Settled {
        var settled = Settled()
        var open: [MeetingNotes.Item] = []
        for (index, question) in questions.enumerated() {
            switch answers[index] {
            case .yes:
                settled.yes += 1
                continue
            case .no, .unclear:
                settled.no += 1
            case nil:
                settled.unasked += 1
            }
            open.append(question)
        }
        questions = open
        return settled
    }

    // MARK: - What the next steps read

    /// The checked lines the final step writes the summary from, numbered
    /// F1, F2… so its key points can cite them. Decisions and to-dos first:
    /// when the list must be cut, topics go before anything agreed.
    public struct FactList: Equatable, Sendable {
        public let items: [MeetingNotes.Item]
        public let text: String
        /// The numbers of the facts that are topics: what a key point must
        /// come from (`keyPoints`).
        public let topics: Set<Int>

        /// The number a key point cites: 3 for "F3", "f3" or "3".
        public func number(_ cited: String) -> Int? {
            var text = cited.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            if let first = text.first, first == "F" || first == "f" { text.removeFirst() }
            guard let number = Int(text), items.indices.contains(number - 1) else { return nil }
            return number
        }

        /// The fact a key point cites: "F3", "f3" or "3".
        public func item(_ cited: String) -> MeetingNotes.Item? {
            number(cited).map { items[$0 - 1] }
        }
    }

    public func factList(limit: Int = 5_000) -> FactList {
        let notes = checkedNotes()
        let all = notes.decisions.map { ("decision", $0) } + notes.todos.map { ("to-do", $0) }
            + notes.questions.map { ("open question", $0) } + topics.map { ("topic", $0) }
        var items: [MeetingNotes.Item] = []
        var lines: [String] = []
        var topicNumbers: Set<Int> = []
        var size = 0
        for (kind, item) in all {
            let owner = item.owner.map { ", \($0)" } ?? ""
            let line = "F\(items.count + 1) [\(kind)\(owner)] \(item.text)"
            guard size + line.count + 1 <= limit else { break }
            items.append(item)
            lines.append(line)
            if kind == "topic" { topicNumbers.insert(items.count) }
            size += line.count + 1
        }
        return FactList(items: items, text: lines.joined(separator: "\n"), topics: topicNumbers)
    }

    /// The final step's key points, checked: each must cite facts from the
    /// list, at least one of them a topic, and takes its transcript turns
    /// (and time) from them. One that cites only decisions, to-dos or
    /// questions says again what their own sections already say: the model
    /// did that on test calls ("Decided to launch without the blog"). So
    /// does one that cites a topic as well but is one of those lines again
    /// in its own words (`saysAgain`): on a 40-minute meeting all four key
    /// points were a to-do or a decision with "Se decidió" put in front.
    public func keyPoints(_ drafts: [MeetingDraft.Fact], from list: FactList) -> [MeetingNotes.Item] {
        let listed = list.items.indices.filter { !list.topics.contains($0 + 1) }.map { list.items[$0].text }
        return drafts.compactMap { draft in
            let text = MeetingText.line(draft.text)
            let cited = Set(draft.sources.compactMap(list.number))
            guard !text.isEmpty, !cited.isDisjoint(with: list.topics),
                  !listed.contains(where: { Self.saysAgain(text, $0) }) else { return nil }
            let sources = Array(Set(cited.flatMap { list.items[$0 - 1].sources })).sorted()
            guard let first = sources.first else { return nil }
            return MeetingNotes.Item(text: text, sources: sources, at: transcript.turn(first)?.start)
        }
    }

    /// Whether a key point is `line` again: of the words that carry meaning
    /// (`MeetingText.stems`, so "preparación" is "preparar" again), it has
    /// nothing the line hasn't, or one word more ("decidió", "decided") and
    /// nearly all of the line's. "Se integra la caja con el almacén para no
    /// perder ventas" adds the reason, and stays.
    static func saysAgain(_ point: String, _ line: String) -> Bool {
        let point = MeetingText.stems(point), line = MeetingText.stems(line)
        guard !point.isEmpty, !line.isEmpty else { return false }
        let added = point.subtracting(line)
        if added.isEmpty { return true }
        return added.count == 1 && Double(point.intersection(line).count) / Double(line.count) >= 0.8
    }

    // MARK: - The notes

    /// The notes from everything kept. Without key points (the final step
    /// failed, or none of its key points held up), the topics stand in:
    /// plain, but still sourced (`standIns`).
    public func notes(summary: String? = nil, keyPoints: [MeetingNotes.Item]? = nil) -> MeetingNotes {
        let checked = checkedNotes()
        let listed = checked.todos + checked.decisions + checked.questions
        return MeetingNotes(summary: Self.sentences(summary ?? "", limit: 3),
                            todos: checked.todos, decisions: checked.decisions,
                            questions: checked.questions,
                            keyPoints: keyPoints ?? Self.standIns(topics, besides: listed))
    }

    /// The topics that stand in for key points: at most `limit`, and when
    /// there are more, one from each stretch of the meeting, so they say
    /// what was talked about from start to end rather than every subject
    /// a part touched (a 40-minute meeting had 36).
    /// In each stretch the topic with the most words that carry meaning
    /// wins, the earlier on a tie: "Tiles from the old supplier, delivered
    /// late" over "Tiles". Topics put as a question, and topics that
    /// are a line above again (`saysAgain`), are left out while others are
    /// left.
    static func standIns(_ topics: [MeetingNotes.Item], besides listed: [MeetingNotes.Item],
                         limit: Int = 5) -> [MeetingNotes.Item] {
        let plain = topics.filter { topic in
            !topic.text.hasSuffix("?") && !listed.contains { saysAgain(topic.text, $0.text) }
        }
        let candidates = byTime(plain.isEmpty ? topics : plain)
        guard candidates.count > limit, let first = candidates.first?.at, let last = candidates.last?.at,
              last > first else { return Array(candidates.prefix(limit)) }
        let width = (last - first) / Double(limit)
        return (0..<limit).compactMap { stretch -> MeetingNotes.Item? in
            let inside = candidates.filter { item in
                let place = min(limit - 1, Int(((item.at ?? first) - first) / width))
                return place == stretch
            }
            var best: (item: MeetingNotes.Item, words: Int)?
            for item in inside {
                let words = MeetingText.meaningfulWords(item.text).count
                if words > best?.words ?? -1 { best = (item, words) }
            }
            return best?.item
        }
    }

    /// A decision kept in an earlier part can turn out to be a to-do found
    /// in a later one; it goes then.
    private func checkedNotes() -> MeetingNotes {
        let decisions = decisions.filter { decision in !todos.contains { Self.restates(decision, $0) } }
        return MeetingNotes(todos: Self.byTime(todos), decisions: Self.byTime(decisions),
                            questions: Self.byTime(questions))
    }

    private static func byTime(_ items: [MeetingNotes.Item]) -> [MeetingNotes.Item] {
        timeOrder(items).map { items[$0] }
    }

    /// The items' places in the list, in the order they were said: the
    /// order the page shows them in.
    private static func timeOrder(_ items: [MeetingNotes.Item]) -> [Int] {
        items.indices.sorted { (items[$0].at ?? 0, $0) < (items[$1].at ?? 0, $1) }
    }

    /// At most `limit` sentences: the summary is meant to be read at a glance.
    static func sentences(_ text: String, limit: Int) -> String {
        let text = MeetingText.clean(text)
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, stop in
            if let sentence { sentences.append(sentence.trimmingCharacters(in: .whitespaces)) }
            if sentences.count == limit { stop = true }
        }
        return sentences.isEmpty ? text : sentences.joined(separator: " ")
    }
}
