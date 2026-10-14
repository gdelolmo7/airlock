import Foundation

/// The notes for one call, after every line the model wrote has been checked
/// against the transcript (`MeetingLedger`).
///
/// Plain parts rather than free prose, so every call's notes read the same
/// way and an empty part is simply left out. Each line carries the transcript
/// turns it came from, so the page can say when it was said and the person
/// can check it: the model is small and can be wrong, and a line nobody can
/// trace back is a line nobody should trust.
public struct MeetingNotes: Equatable, Sendable {
    /// One line of the notes and where in the call it comes from.
    public struct Item: Equatable, Sendable {
        public var text: String
        /// Who will do it, for a to-do: "You", or a name the calendar knows.
        /// Nil when nobody was named, never a guess.
        public var owner: String?
        /// The numbered transcript turns it comes from (`NumberedTranscript`).
        public var sources: [Int]
        /// When the first of those turns started, in seconds from the start.
        public var at: TimeInterval?

        public init(text: String, owner: String? = nil, sources: [Int] = [], at: TimeInterval? = nil) {
            self.text = text
            self.owner = owner
            self.sources = sources
            self.at = at
        }
    }

    /// A stretch of the call the model wrote nothing for, in seconds from
    /// the start. Notes that quietly stop at minute 32 of a 44-minute call
    /// read as if nothing happened after; the page says so instead.
    public struct Stretch: Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval

        public init(start: TimeInterval, end: TimeInterval) {
            self.start = min(start, end)
            self.end = max(start, end)
        }

        /// What the page, the notes window and the notch say about it.
        public var sentence: String {
            Self.lead + MeetingFiles.clock(start) + "–" + MeetingFiles.clock(end) + Self.tail
        }

        /// Around the times, so `MeetingPage` can read the line back.
        static let lead = "Couldn't write notes for "
        static let tail = ". The transcript has it all."

        /// In order, with stretches that overlap or meet joined. Meeting
        /// within a second counts, since the page shows whole seconds and
        /// "10:00–12:00" next to "12:00–14:00" reads as one stretch said twice.
        public static func merged(_ stretches: [Stretch]) -> [Stretch] {
            var merged: [Stretch] = []
            for stretch in stretches.sorted(by: { $0.start < $1.start }) {
                if let last = merged.last, stretch.start <= last.end + 1 {
                    merged[merged.count - 1].end = max(last.end, stretch.end)
                } else {
                    merged.append(stretch)
                }
            }
            return merged
        }
    }

    /// Two or three sentences: what the call was about and where it ended up.
    public var summary: String
    public var todos: [Item]
    public var decisions: [Item]
    public var questions: [Item]
    public var keyPoints: [Item]
    /// Where the model wrote nothing, so the notes are not read as the
    /// whole call. Not part of `isEmpty`: it says what is missing, not what
    /// was said.
    public var unwritten: [Stretch]

    public init(summary: String = "", todos: [Item] = [], decisions: [Item] = [],
                questions: [Item] = [], keyPoints: [Item] = [], unwritten: [Stretch] = []) {
        self.summary = MeetingText.clean(summary)
        self.unwritten = Stretch.merged(unwritten)
        self.todos = Self.tidy(todos)
        // The model often files the same thing as a task and as a decision;
        // it reads better once, as something to do.
        let tasks = Set(self.todos.map { MeetingText.key($0.text) })
        self.decisions = Self.tidy(decisions).filter { !tasks.contains(MeetingText.key($0.text)) }
        self.questions = Self.tidy(questions)
        // A key point that only repeats a line above it says nothing new.
        let listed = tasks.union(self.decisions.map { MeetingText.key($0.text) })
            .union(self.questions.map { MeetingText.key($0.text) })
        self.keyPoints = Self.tidy(keyPoints).filter { !listed.contains(MeetingText.key($0.text)) }
    }

    public var isEmpty: Bool {
        summary.isEmpty && todos.isEmpty && decisions.isEmpty && questions.isEmpty && keyPoints.isEmpty
    }

    /// Fewer words than this and the model is not asked at all: there is
    /// nothing to take notes of, and a small model handed almost nothing
    /// makes something up to fill the page.
    public static let minimumWords = 20

    /// What the page says instead of notes when `minimumWords` was not reached.
    public static let tooLittle = "Too little was said on this call for notes."

    /// Blank lines dropped, bullets the model added itself stripped, repeats
    /// removed in order (the first keeps its place; a later copy that names
    /// who does it lends the first its owner).
    private static func tidy(_ items: [Item]) -> [Item] {
        var kept: [Item] = []
        var index: [String: Int] = [:]
        for item in items {
            var item = item
            item.text = MeetingText.clean(item.text)
            item.owner = item.owner.map(MeetingText.clean).flatMap { $0.isEmpty ? nil : $0 }
            guard !item.text.isEmpty else { continue }
            let key = MeetingText.key(item.text)
            if let at = index[key] {
                if kept[at].owner == nil { kept[at].owner = item.owner }
                continue
            }
            index[key] = kept.count
            kept.append(item)
        }
        return kept
    }
}

/// The small text rules every line of the notes goes through.
public enum MeetingText {
    /// One line, as it should be printed: no bullet or tick box the model
    /// added itself, no "(S12)" it copied from the transcript into the text,
    /// no line breaks, no runs of spaces.
    public static func clean(_ text: String) -> String {
        var text = text.replacingOccurrences(
            of: #"\s*[\[(]\s*[Ss]\d+(\s*[,;–-]\s*[Ss]?\d+)*\s*[\])]"#, with: "",
            options: .regularExpression)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let first = text.first, "-•*".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) {
            text = String(text.dropFirst(box.count))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A list line: cleaned, without a closing full stop. The model ends
    /// some lines with one and not others, and a list reads as notes.
    /// An ellipsis, a question mark or an exclamation mark stays.
    public static func line(_ text: String) -> String {
        var text = clean(text)
        if text.hasSuffix("."), !text.hasSuffix("..") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a line is written as a question, in any script. The model is
    /// told to write open questions as questions; a statement it lists
    /// there ("Somebody needs to check the analytics") is not an open
    /// question, and on test calls it was a task said again.
    public static func isQuestion(_ text: String) -> Bool {
        text.contains { "?？؟¿⸮\u{037E}".contains($0) }
    }

    /// An open question as the notes show it, or nil when it is not one.
    /// Talk copied on after the question mark is cut off ("¿Qué pasa?
    /// Porque yo así puedo sacar un listado…"), and what is left must be
    /// three words or more: from a meeting in the room the model also
    /// listed "¿En qué?", a word or two of somebody's reply, which nobody
    /// could follow up.
    ///
    /// It must also say what it is about (`saysWhatAbout`). The same
    /// meeting listed "How long do you wait?" and "What happens if it
    /// doesn't all arrive?": real questions in the room, meaningless on a
    /// page read a week later.
    public static func openQuestion(_ text: String) -> String? {
        guard isQuestion(text) else { return nil }
        var question = text
        if let end = text.lastIndex(where: { "?？؟⸮\u{037E}".contains($0) }) {
            question = String(text[...end])
        }
        return NumberedTranscript.words(in: question) >= 3 && saysWhatAbout(question) ? question : nil
    }

    /// Whether a line names something: a word that is not a question word,
    /// a pronoun or an everyday verb ("happen", "wait", "pasar",
    /// "llegar"), a short word in capitals ("PDF"), or a number. Only
    /// English and Spanish words are listed, so a line in another language
    /// always names something: this can only ever drop a question.
    static func saysWhatAbout(_ text: String) -> Bool {
        text.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }.contains { piece in
            let word = String(piece)
            if word.contains(where: \.isNumber) { return true }
            if word.count >= 2, word.allSatisfy({ !$0.isLetter || $0.isUppercase }) { return true }
            let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let bare = folded.split { $0 == "'" || $0 == "’" }.first.map(String.init) ?? folded
            return bare.count >= 4 && !vagueWords.contains(bare)
        }
    }

    /// Folded words of four letters or more that, on their own, say
    /// nothing about what a question is about. Short words never count,
    /// so they are not listed.
    static let vagueWords: Set<String> = [
        // English
        "what", "when", "where", "which", "whom", "whose", "there", "here", "this", "that", "these",
        "those", "they", "them", "their", "your", "yours", "with", "about", "from", "into", "then",
        "before", "after",
        "does", "doesn", "didn", "aren", "wasn", "would", "could", "should", "will",
        "have", "having", "been", "being", "were", "going", "doing", "done", "make", "made", "makes",
        "happen", "happens", "happened", "happening", "come", "comes", "came", "coming", "arrive",
        "arrives", "arrived", "wait", "waits", "waiting", "take", "takes", "took", "taking", "think",
        "know", "mean", "means", "want", "like", "feel", "said", "says", "tell", "look", "seem",
        "seems", "work", "works", "thing", "things", "something", "anything", "everything",
        "nothing", "time", "long", "much", "many", "some", "more", "most", "else", "just", "really",
        "even", "still", "also", "again", "right", "okay", "well", "though", "other", "same",
        "first", "last", "next", "both", "each", "every", "anyone", "someone", "everyone",
        "anybody", "somebody", "everybody", "guys", "another", "others",
        // Spanish
        "como", "cuanto", "cuanta", "cuantos", "cuantas", "cuando", "donde", "adonde", "quien",
        "quienes", "cual", "cuales", "porque", "para", "pero", "esto", "esta", "este", "estos",
        "estas", "esos", "esas", "aquello", "aqui", "alli", "todo", "toda", "todos", "todas",
        "algo", "nada", "cosa", "cosas", "tiempo", "rato", "mucho", "mucha", "muchos", "muchas",
        "poco", "poca", "pocos", "pocas", "otro", "otra", "otros", "otras", "mismo", "misma",
        "entonces", "luego", "ahora", "antes", "despues", "siempre", "nunca", "tambien", "verdad",
        "bien", "vale", "pues", "tipo", "veces", "alguien", "nadie", "vosotros", "ustedes",
        "pasa", "pasar", "pasas", "pasan", "paso", "pasado", "pasaria", "llega", "llegar", "llegas",
        "llegan", "llego", "llegue", "espera", "esperas", "esperar", "esperan", "esperamos",
        "hace", "hacer", "haces", "hacen", "hacemos", "hago", "hecho", "tiene", "tienes", "tener",
        "tienen", "tenemos", "tengo", "puede", "puedes", "poder", "pueden", "podemos", "sabes",
        "saber", "sabe", "crees", "creo", "parece", "quieres", "quiere", "querer", "estan",
        "estamos", "estoy", "sera", "seria", "eres", "somos", "vamos", "dice", "dices", "decir",
        "dijo", "funciona", "queda", "quedan", "sale", "salen",
    ]

    /// Whether two lines say the same thing in other words: most of the
    /// words that carry meaning in the shorter one are in the other.
    /// Loose on its own, so it is only used for two lines from the same
    /// moment of the call (`MeetingLedger`), where it catches "I'll take
    /// care of booking the room" filed as a decision next to the to-do
    /// "Book the room before Friday".
    public static func sameThing(_ one: String, _ other: String) -> Bool {
        let a = meaningfulWords(one), b = meaningfulWords(other)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        return Double(shorter.intersection(longer).count) / Double(shorter.count) >= 0.6
    }

    /// Words of four letters or more, or with a digit, case and accents
    /// aside: short words are mostly "the", "and", "de", "la".
    static func meaningfulWords(_ text: String) -> Set<String> {
        Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 || $0.contains(where: \.isNumber) })
    }

    /// The first six letters of each word that carries meaning
    /// (`meaningfulWords`), without the `leaving` ones: "preparar" and
    /// "preparación" are one word here, "contrato" and "contacto" two.
    /// Crude, and that is the point: it needs no dictionary, so it works
    /// the same in every language that writes words with letters.
    static func stems(_ text: String, leaving: Set<String> = []) -> Set<String> {
        Set(meaningfulWords(text).subtracting(leaving).map { String($0.prefix(6)) })
    }

    /// Short words written with a capital where no sentence starts: "Ana",
    /// "CRM". `meaningfulWords` leaves them out for being short, and a
    /// name is the whole difference between "Send it to Ana" and "… to Luis".
    static func shortNames(_ text: String) -> Set<String> {
        Set(text.split { !$0.isLetter && !$0.isNumber }.dropFirst()
            .filter { (2..<4).contains($0.count) && $0.first?.isUppercase == true }
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) })
    }

    /// The person's own words on one line, and otherwise exactly as typed.
    public static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What makes two lines the same: case, punctuation and a closing full
    /// stop aside.
    public static func key(_ text: String) -> String {
        let letters = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.punctuationCharacters.union(.symbols).contains(scalar) ? " " : Character(scalar)
        }
        return String(letters).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension MeetingFiles {
    /// `Notes.md`: the summary on top, then the person's own notes, then
    /// what to do, what was decided, what is still open and what was
    /// discussed. Every line ends with when it was said, so it can be found
    /// in the transcript.
    ///
    /// `notes` nil means no notes could be written (the model is off or
    /// failed), and the page says so rather than being absent: the folder
    /// still has the transcript, and a missing file reads as a bug.
    ///
    /// `writtenFrom` is `MeetingNotesSource.line`, said under the date when
    /// the notes were written from another listening than the transcript's.
    ///
    /// `writer` is who wrote them, while notes online are switched on
    /// (`MeetingNotesWriter`): notes written online say so at the foot, and
    /// notes the Mac wrote while offline say under the date that they will
    /// be written online (`offlineLine`).
    public static func notesPage(for record: MeetingRecord, notes: MeetingNotes?,
                                 unavailableReason: String? = nil,
                                 writtenFrom: String? = nil,
                                 writer: MeetingNotesWriter? = nil,
                                 timeZone: TimeZone = .current) -> String {
        let title = title(of: record)
        // The calendar's title is a name and keeps its capitals, as does a
        // recording's; "Call in Zoom" is a description and reads as one
        // after "Notes:".
        let heading = titleIsAName(record) ? title : title.lowercasedFirst
        var lines = ["# Notes: \(heading)", "", header(of: record, timeZone: timeZone), ""]
        if writer?.waitsForOnline == true { lines += ["_\(offlineLine)_", ""] }
        if let writtenFrom { lines += ["_\(writtenFrom)_", ""] }
        let words = NumberedTranscript(record).wordCount
        let notes = notes.flatMap { $0.isEmpty ? nil : $0 }

        if let notes, !notes.summary.isEmpty {
            lines += ["## \(summaryHeading)", "", notes.summary, ""]
        } else if notes == nil {
            if words == 0 {
                lines += ["Nothing was heard on this call, so there is nothing to summarise.", ""]
            } else if words < MeetingNotes.minimumWords {
                lines += [MeetingNotes.tooLittle, ""]
            } else {
                lines += ["No summary this time\(unavailableReason.map { ": \($0)" } ?? ".")",
                          "The full transcript is in \(transcriptName).", ""]
            }
        }
        // Right under the summary, which was written without those minutes
        // and cannot say so itself. In italics, like the transcript's pauses.
        if let notes {
            lines += notes.unwritten.flatMap { ["_\($0.sentence)_", ""] }
        }
        if !record.jots.isEmpty {
            lines += ["## \(yourNotesHeading)", ""]
                + record.jots.map { "- \(MeetingText.oneLine($0.text)) · \(clock($0.at))" } + [""]
        }
        if let notes {
            lines += section(todosHeading, notes.todos, box: true)
            lines += section(decisionsHeading, notes.decisions)
            lines += section(questionsHeading, notes.questions)
            lines += section(keyPointsHeading, notes.keyPoints)
        }
        let by = writer?.place == .online
            ? "Written online by Airlock, with Google's Gemini, from \(transcriptName). "
            : "Written on this Mac by Airlock from \(transcriptName). "
        lines += ["---", "",
                  "_" + by
                  + "No audio was kept. The summary is made by a model and can be wrong; "
                  + "check the transcript before relying on it._"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Under the date, on notes the Mac wrote while offline that will be
    /// written online once it is back (`CloudNotesRedo`).
    public static let offlineLine =
        "Written on this Mac while offline. They'll be improved once you're back online."

    /// `page` without `offlineLine`: for notes that will not be written
    /// online after all, which must stop promising it.
    public static func withoutOfflineLine(_ page: String) -> String {
        page.replacingOccurrences(of: "_\(offlineLine)_\n\n", with: "")
    }

    /// The name an earlier notes page is kept under when the notes are
    /// written again: "Notes (earlier version).md", then "… 2.md" and on,
    /// so no earlier page is ever written over.
    public static func earlierNotesName(existing: Set<String>) -> String {
        WorkspaceLayout.uniqueName(for: earlierNotesFirstName, existing: existing)
    }

    public static let earlierNotesFirstName = "Notes (earlier version).md"

    /// "- [ ] Send the budget by Friday — Ana · 2:15". The owner and the time
    /// are what `MeetingPage` reads back, so a dash in the text itself is
    /// softened to an en dash and cannot be mistaken for the owner's.
    private static func section(_ name: String, _ items: [MeetingNotes.Item], box: Bool = false) -> [String] {
        guard !items.isEmpty else { return [] }
        let list = items.map { item -> String in
            var line = "- " + (box ? "[ ] " : "")
                + MeetingText.clean(item.text).replacingOccurrences(of: " — ", with: " – ")
            if let owner = item.owner { line += " — \(owner)" }
            if let at = item.at { line += " · \(clock(at))" }
            return line
        }
        return ["## \(name)", ""] + list + [""]
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
