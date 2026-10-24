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
        /// For an open question: one short line on what it depends on or
        /// why it matters. Nil when the writer gave none.
        public var context: String?

        public init(text: String, owner: String? = nil, sources: [Int] = [], at: TimeInterval? = nil,
                    context: String? = nil) {
            self.text = text
            self.owner = owner
            self.sources = sources
            self.at = at
            self.context = context
        }
    }

    /// One subject of the meeting, as notes written online follow it: a
    /// title, one sentence on what came of it, and what was said.
    public struct Topic: Equatable, Sendable {
        public var title: String
        /// One sentence on what was said or settled about it, or empty.
        public var gist: String
        public var points: [Point]
        /// When it came up: its first point's time.
        public var at: TimeInterval?

        public init(title: String, gist: String = "", points: [Point], at: TimeInterval? = nil) {
            self.title = title
            self.gist = gist
            self.points = points
            self.at = at ?? points.compactMap(\.at).min()
        }
    }

    /// One line of a topic, and whether the people agreed on it.
    public struct Point: Equatable, Sendable {
        public var text: String
        /// Agreed in the meeting, not only said.
        public var decided: Bool
        public var sources: [Int]
        public var at: TimeInterval?

        public init(text: String, decided: Bool = false, sources: [Int] = [], at: TimeInterval? = nil) {
            self.text = text
            self.decided = decided
            self.sources = sources
            self.at = at
        }
    }

    /// A word the transcript may have heard wrong: a name spelled more
    /// than one way, or a figure that reads wrong for what was said. The
    /// page asks the person, and "Use" puts `best` in place of every
    /// `heard` in the notes and the transcript.
    public struct Word: Equatable, Sendable {
        /// What the notes use.
        public var best: String
        /// How the transcript has it, each one different from `best`.
        public var heard: [String]
        public var sources: [Int]
        public var at: TimeInterval?

        public init(best: String, heard: [String], sources: [Int] = [], at: TimeInterval? = nil) {
            self.best = best
            self.heard = heard
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

        /// What the page and the notch say about it.
        public var sentence: String { sentence(clock: MeetingFiles.clock) }

        /// The same with the times as `clock` writes them: the notes window
        /// passes the time of day (`CallsCard.time`).
        public func sentence(clock: (TimeInterval) -> String = MeetingFiles.clock) -> String {
            Self.lead + clock(start) + "–" + clock(end) + Self.tail
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

    /// A short name for the meeting, from what was said ("Kitchen tiles
    /// and the delivery date"), for a meeting nothing else names: no
    /// calendar event and no recording (`MeetingFiles.title(of:)`). Nil
    /// when the writer gave none. Always cleaned (`MeetingNotes.title(_:)`).
    public var title: String? {
        didSet { title = Self.title(title) }
    }
    /// Two or three sentences: what the call was about and where it ended up.
    public var summary: String
    public var todos: [Item]
    public var decisions: [Item]
    public var questions: [Item]
    public var keyPoints: [Item]
    /// The meeting subject by subject, in the order they came up: notes
    /// written online since they are asked for by topic. Empty otherwise.
    public var topics: [Topic]
    /// Words to check (`Word`): only ever from notes written by topic.
    /// Not part of `isEmpty`: they are a question about the transcript.
    public var words: [Word]
    /// Where the model wrote nothing, so the notes are not read as the
    /// whole call. Not part of `isEmpty`: it says what is missing, not what
    /// was said.
    public var unwritten: [Stretch]

    public init(summary: String = "", todos: [Item] = [], decisions: [Item] = [],
                questions: [Item] = [], keyPoints: [Item] = [], unwritten: [Stretch] = [],
                title: String? = nil, topics: [Topic] = [], words: [Word] = []) {
        self.title = Self.title(title)
        self.topics = Self.tidy(topics)
        self.words = words.compactMap { word in
            var word = word
            word.best = MeetingText.clean(word.best)
            word.heard = word.heard.map(MeetingText.clean).filter { !$0.isEmpty }
            return word.best.isEmpty || word.heard.isEmpty ? nil : word
        }
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
            && topics.isEmpty
    }

    /// Characters a title has at most: it is a name, and a folder's
    /// (`MeetingFiles.safe`) is cut at 60.
    public static let titleLimit = 60

    /// A title as the model wrote it, as a name: its first line, without
    /// a "Title:" before it, quotes around it or a full stop after it,
    /// and cut at a word to `titleLimit`. Nil when nothing is left.
    public static func title(_ text: String?) -> String? {
        guard let text else { return nil }
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var title = MeetingText.clean(first)
        if let colon = title.firstIndex(of: ":"),
           titleLabels.contains(title[..<colon].trimmingCharacters(in: .whitespaces).lowercased()) {
            title = String(title[title.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let quotes = "\"'“”‘’«»「」*_"
        while let last = title.last, quotes.contains(last) || ".。".contains(last) { title.removeLast() }
        while let first = title.first, quotes.contains(first) { title.removeFirst() }
        title = title.trimmingCharacters(in: .whitespaces)
        if title.count > titleLimit {
            let cut = title.prefix(titleLimit + 1)
            title = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut.prefix(titleLimit))
            while let last = title.last, ",;:-–—".contains(last) || last.isWhitespace { title.removeLast() }
        }
        return title.isEmpty || titlePlaceholders.contains(title.lowercased()) ? nil : title
    }

    /// What a model writes before a title, lowercased, in the languages
    /// the notes are written in most.
    static let titleLabels: Set<String> = ["title", "título", "titulo", "títol", "titre", "titel", "titolo"]

    /// Titles that name nothing, lowercased: "Meeting in person" says more.
    static let titlePlaceholders: Set<String> = [
        "meeting", "call", "untitled", "no title", "none", "n/a",
        "reunión", "llamada", "sin título", "reunió", "trucada", "sense títol",
    ]

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
            item.context = item.context.map(MeetingText.line).flatMap { $0.isEmpty ? nil : $0 }
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

    /// Topics with their lines cleaned: a point said twice in one topic
    /// kept once, a topic with no point or no title left out. Its time is
    /// its first point's, of the points kept.
    private static func tidy(_ topics: [Topic]) -> [Topic] {
        topics.compactMap { topic in
            var seen = Set<String>()
            let points = topic.points.compactMap { point -> Point? in
                var point = point
                point.text = MeetingText.line(point.text)
                guard !point.text.isEmpty, seen.insert(MeetingText.key(point.text)).inserted else { return nil }
                return point
            }
            let title = MeetingText.line(topic.title)
            guard !title.isEmpty, !points.isEmpty else { return nil }
            return Topic(title: title, gist: MeetingText.clean(topic.gist), points: points,
                         at: points.compactMap(\.at).min() ?? topic.at)
        }
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
    /// (`MeetingNotesWriter`): notes written online say so at the foot, with
    /// whose model wrote them, and notes still to be written online say so
    /// under the date (`waitingLine`). Notes the Mac wrote say so, and why
    /// when they were meant to be written online.
    ///
    /// `noModel` is why the Mac had no model to write them with, for a page
    /// without notes: it says what to do about it (`noModelLines`).
    public static func notesPage(for record: MeetingRecord, notes: MeetingNotes?,
                                 unavailableReason: String? = nil,
                                 writtenFrom: String? = nil,
                                 writer: MeetingNotesWriter? = nil,
                                 noModel: ModelAvailability? = nil,
                                 locale: Locale = .current,
                                 timeZone: TimeZone = .current) -> String {
        // Named by these notes when they name it, before the record is.
        var record = record
        if let named = notes?.title { record.topic = named }
        let title = title(of: record, inFile: true)
        // The calendar's title is a name and keeps its capitals, as do a
        // recording's and the notes'; "Call in Zoom" is a description and
        // reads as one after "Notes:".
        let heading = titleIsAName(record) ? title : title.lowercasedFirst
        var lines = ["# Notes: \(heading)", "", header(of: record, timeZone: timeZone), ""]
        let notes = notes.flatMap { $0.isEmpty ? nil : $0 }
        if let waiting = waitingLine(for: writer, locale: locale, timeZone: timeZone) {
            lines += ["_\(waiting)_", ""]
        } else if notes != nil, let writer, writer.place == .mac, writer.why == .allowanceUsed {
            lines += ["_\(allowanceUsedMacLine(backOn: writer.backOn, plan: writer.plan, locale: locale, timeZone: timeZone))_", ""]
        }
        if let listened = record.stoppedAtLimit {
            lines += ["_\(coverLine(listened, of: record.endedAt?.timeIntervalSince(record.startedAt)))_", ""]
        }
        if let writtenFrom { lines += ["_\(writtenFrom)_", ""] }
        let words = NumberedTranscript(record).wordCount

        let written = notes.flatMap { language(of: $0, record: record) }
        let say = { (english: String) in headingWords(english, in: written) }
        if let notes, !notes.summary.isEmpty {
            lines += ["## \(say(summaryHeading))", "", notes.summary, ""]
        } else if notes == nil {
            if words == 0 {
                lines += ["Nothing was heard on this call, so there is nothing to summarise.", ""]
            } else if words < MeetingNotes.minimumWords {
                lines += [MeetingNotes.tooLittle, ""]
            } else if let said = noModelLines(noModel, writer: writer) {
                lines += [said.headline, said.detail + " " + transcriptLine, ""]
            } else {
                lines += ["No summary this time\(unavailableReason.map { ": \($0)" } ?? ".")",
                          transcriptLine, ""]
            }
        }
        // Right under the summary, which was written without those minutes
        // and cannot say so itself. In italics, like the transcript's pauses.
        if let notes {
            lines += notes.unwritten.flatMap { ["_\($0.sentence)_", ""] }
        }
        if !record.jots.isEmpty {
            lines += ["## \(say(yourNotesHeading))", ""]
                + record.jots.map { "- \(MeetingText.oneLine($0.text)) · \(clock($0.at))" } + [""]
        }
        if let notes {
            lines += wordsSection(notes.words, heading: say(wordsHeading))
            lines += section(say(todosHeading), notes.todos, box: true)
            lines += section(say(decisionsHeading), notes.decisions)
            lines += topicsSection(notes.topics, heading: say(topicsHeading))
            lines += section(say(questionsHeading), notes.questions)
            lines += section(say(keyPointsHeading), notes.keyPoints)
        }
        let by: String
        if writer?.place == .online {
            by = "Written online by Airlock"
                + (CloudNotes.maker(ofModel: writer?.model).map { ", with \($0)" } ?? "") + ". "
        } else if notes != nil {
            by = (writer?.why == .serviceDown ? serviceDownFooter : basicModelFooter) + ". "
        } else {
            by = "Written on this Mac by Airlock. "
        }
        lines += ["---", "",
                  "_" + by
                  + "No audio was kept. The summary is written by AI and can be wrong; "
                  + "check the transcript before relying on it._"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// The page's section titles in Spanish, for notes written in Spanish.
    /// Every other language gets the English ones. `MeetingPage.blocks` reads
    /// either back as the English name, so nothing that looks a section up
    /// needs to know which the file has.
    static let spanishHeadings: [String: String] = [
        summaryHeading: "Resumen", yourNotesHeading: "Tus notas", todosHeading: "Tareas",
        decisionsHeading: "Decisiones", questionsHeading: "Preguntas abiertas",
        keyPointsHeading: "Puntos clave", topicsHeading: "Temas", wordsHeading: "Revisa estas palabras",
    ]

    /// `english`, one of the headings above, as a page in `code` writes it.
    public static func headingWords(_ english: String, in code: String?) -> String {
        code == "es" ? spanishHeadings[english] ?? english : english
    }

    /// A section title read off a page, as the English name above, whichever
    /// language the page was written in. Anything else as it is.
    public static func canonicalHeading(_ text: String) -> String {
        spanishHeadings.first { $0.value == text }?.key ?? text
    }

    /// The language the notes themselves are written in, read from their
    /// words the same way the page's "you" is (`MeetingNaming`).
    static func language(of notes: MeetingNotes, record: MeetingRecord) -> String? {
        let prose = ([notes.summary] + (notes.todos + notes.decisions + notes.questions + notes.keyPoints).map(\.text)
            + notes.topics.flatMap { [$0.title, $0.gist] + $0.points.map(\.text) }).joined(separator: "\n")
        return CallLanguage.decide(engine: record.languages, reading: CallLanguage.reading(of: prose))?.code
    }

    /// Whether a notes page has notes on it: any of the headings the notes
    /// are written under. "Your notes" alone is the person's, not notes.
    public static func hasNotes(_ page: String) -> Bool {
        let headings = [summaryHeading, todosHeading, decisionsHeading, questionsHeading, keyPointsHeading,
                        topicsHeading, wordsHeading]
        return MeetingPage.blocks(of: page).contains { block in
            if case .heading(let text, level: 2) = block { return headings.contains(text) }
            return false
        }
    }

    /// "The full transcript is in the Transcript tab.", on a page without
    /// notes: where the window shows it, never a file name.
    public static let transcriptLine = "The full transcript is in the Transcript tab."

    /// The foot of notes the Mac wrote, and the window offers better ones
    /// beside it (`CallNotesOffers`). Older pages say more after it ("with
    /// the basic model, from …"), so the window looks for how it begins.
    public static let basicModelFooter = "Written on your Mac"

    /// The same, when the online notes service was asked and didn't answer:
    /// said on every plan, so a paid plan's Mac-written notes are explained.
    public static let serviceDownFooter =
        "The online notes service didn't answer, so these were written on your Mac"

    /// Under the date of notes a plan's limit stopped
    /// (`MeetingRecord.stoppedAtLimit`): "These notes cover the first 30
    /// minutes of a 42-minute call." The call's length only when it is known
    /// and a whole minute longer.
    public static func coverLine(_ listened: TimeInterval, of call: TimeInterval? = nil) -> String {
        let minutes = max(1, Int((listened / 60).rounded()))
        let first = minutes == 1 ? "minute" : "\(minutes) minutes"
        guard let call, Int((call / 60).rounded()) > minutes else { return coverLead + first + "." }
        return coverLead + first + " of a \(Int((call / 60).rounded()))-minute call."
    }

    /// How `coverLine` begins, which the window looks for.
    public static let coverLead = "These notes cover the first "

    /// Said after the day online notes come back, on Plus: the bigger plan
    /// has more of them.
    public static let proHasMore = "Pro has twice as many."

    /// Under the date of notes the Mac wrote because this month's online
    /// notes were used up: when they come back, and on Plus, that Pro has
    /// more.
    public static func allowanceUsedMacLine(backOn: Date?, plan: PlanSnapshot?, locale: Locale = .current,
                                            timeZone: TimeZone = .current) -> String {
        allowanceUsedMacLead + ", so these were written on your Mac."
            + (backOn.map { " Online notes are back on \(CloudNotesAllowance.day($0, locale: locale, timeZone: timeZone))." }
               ?? "")
            + (plan?.plan == .plus ? " " + proHasMore : "")
    }

    /// How `allowanceUsedMacLine` begins.
    public static let allowanceUsedMacLead = "This month's online notes are used up"

    /// The first line of a page without notes on a Mac with Apple
    /// Intelligence switched off.
    public static let turnOnAppleIntelligence = "Turn on Apple Intelligence to get notes and to-dos."

    /// The first line of a page without notes on a Mac that can't run
    /// Apple's model, on a plan that doesn't write notes online.
    public static let macCantWriteNotes = "This Mac can't write notes itself. Plus writes them online, on any Mac."

    /// What a page without notes says when the Mac had no model to write
    /// them with, or nil to say it the usual way. Apple Intelligence
    /// switched off: turn it on, unless the notes are on their way online
    /// anyway. A Mac that can't run it: Plus can write them, unless this
    /// plan already does, or online notes are off altogether (no writer).
    public static func noModelLines(_ availability: ModelAvailability?, writer: MeetingNotesWriter?)
        -> (headline: String, detail: String)? {
        switch availability {
        case .needsAppleIntelligence where writer?.waitsForOnline != true:
            return (turnOnAppleIntelligence,
                    "Airlock writes call notes with Apple Intelligence, which is switched off.")
        case .deviceNotEligible:
            guard let plan = writer?.plan, !plan.limits.writesNotesOnline, writer?.waitsForOnline != true else {
                return nil
            }
            return (macCantWriteNotes, "Your transcripts are always kept, on every plan.")
        default:
            return nil
        }
    }

    /// Under the date, on notes the Mac wrote while offline that will be
    /// written online once it is back (`CloudNotesRedo`).
    public static let offlineLine =
        "Written on this Mac while offline. They'll be improved once you're back online."

    /// How every line under the date of a page with no notes yet begins, on
    /// a Mac that can't write them (`MeetingNotesWriter.noNotesYet`).
    public static let noNotesYet = "No notes yet."

    /// Offline when the call ended.
    public static let noNotesOfflineLine = noNotesYet + " They'll be written online once you're back online."

    /// Writing them online didn't work; tried again (`CloudNotesRedo.retryWaits`).
    public static let noNotesFailedLine = noNotesYet
        + " The online notes service didn't answer, so Airlock will try again later."

    /// How `noNotesAllowanceLine` begins: said in the same words as
    /// `allowanceUsedMacLead`, wherever the month's online notes ran out.
    public static let noNotesAllowanceLead = noNotesYet + " " + allowanceUsedMacLead

    /// How the line began on pages written before, which the window still
    /// reads as the same notice.
    public static let earlierNoNotesAllowanceLead = noNotesYet + " You've used this month's online notes"

    /// This month's online notes are used: "… these will be written on 1
    /// November." On Plus, that Pro has more.
    public static func noNotesAllowanceLine(until: Date?, plan: PlanSnapshot? = nil, locale: Locale = .current,
                                            timeZone: TimeZone = .current) -> String {
        noNotesAllowanceLead + ", so these will be written "
            + (until.map { "on \(CloudNotesAllowance.day($0, locale: locale, timeZone: timeZone))." }
               ?? "once they're back.")
            + (plan?.plan == .plus ? " " + proHasMore : "")
    }

    /// The line under the date of a page whose notes are still to be written
    /// online, or nil when nothing waits.
    public static func waitingLine(for writer: MeetingNotesWriter?, locale: Locale = .current,
                                   timeZone: TimeZone = .current) -> String? {
        guard let writer, writer.waitsForOnline else { return nil }
        switch writer.noNotesYet {
        case nil: return offlineLine
        case .offline: return noNotesOfflineLine
        case .failed: return noNotesFailedLine
        case .allowanceUsed:
            return noNotesAllowanceLine(until: writer.notBefore, plan: writer.plan, locale: locale, timeZone: timeZone)
        }
    }

    /// `page` with its waiting line (`waitingLine`) put right for `writer`:
    /// changed when the wait has changed, gone when nothing waits any more.
    /// A page without one is left as it is.
    public static func withWaitingLine(_ page: String, for writer: MeetingNotesWriter?,
                                       locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let range = waitingLineRange(in: page) else { return page }
        var page = page
        page.replaceSubrange(range, with: waitingLine(for: writer, locale: locale, timeZone: timeZone)
                                .map { "_\($0)_\n\n" } ?? "")
        return page
    }

    /// `page` without its waiting line: for notes that will not be written
    /// online after all, which must stop promising it.
    public static func withoutWaitingLine(_ page: String) -> String {
        withWaitingLine(page, for: nil)
    }

    /// Where the waiting line is, with the blank line after it.
    private static func waitingLineRange(in page: String) -> Range<String.Index>? {
        if let range = page.range(of: "_\(offlineLine)_\n\n") { return range }
        guard let start = page.range(of: "_\(noNotesYet) "),
              let end = page.range(of: "_\n\n", range: start.upperBound..<page.endIndex) else { return nil }
        return start.lowerBound..<end.upperBound
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
    /// softened to an en dash and cannot be mistaken for the owner's. An
    /// open question's context follows it the same way, in italics:
    /// "- ¿Qué precio? — _Depends on the supplier_ · 4:05".
    private static func section(_ name: String, _ items: [MeetingNotes.Item], box: Bool = false) -> [String] {
        guard !items.isEmpty else { return [] }
        let list = items.map { item -> String in
            var line = "- " + (box ? "[ ] " : "") + soft(MeetingText.clean(item.text))
            if let owner = item.owner { line += " — \(owner)" }
            if let context = item.context { line += " — _\(soft(context))_" }
            if let at = item.at { line += " · \(clock(at))" }
            return line
        }
        return ["## \(name)", ""] + list + [""]
    }

    /// "- **Mapa** — heard as “napa”, “mapá” · 2:15": what the notes took a
    /// word to be, and how the transcript has it (`MeetingPage.word`).
    private static func wordsSection(_ words: [MeetingNotes.Word], heading: String = wordsHeading) -> [String] {
        guard !words.isEmpty else { return [] }
        let list = words.map { word -> String in
            var line = "- **\(soft(word.best))** — \(MeetingPage.heardAs) "
                + word.heard.map { "“\(soft($0))”" }.joined(separator: ", ")
            if let at = word.at { line += " · \(clock(at))" }
            return line
        }
        return ["## \(heading)", ""] + list + [""]
    }

    /// "## Topics", then for each "### 1. Price and plans · 4:05", its gist
    /// and its points: "- **Price:** 40 € a month · 4:10", with "✓ " before
    /// one that was decided (`MeetingPage.topic`, `MeetingPage.point`).
    private static func topicsSection(_ topics: [MeetingNotes.Topic], heading: String = topicsHeading) -> [String] {
        guard !topics.isEmpty else { return [] }
        var lines = ["## \(heading)", ""]
        for (index, topic) in topics.enumerated() {
            var heading = "### \(index + 1). \(soft(topic.title))"
            if let at = topic.at { heading += " · \(clock(at))" }
            lines += [heading, ""]
            if !topic.gist.isEmpty { lines += [soft(topic.gist), ""] }
            lines += topic.points.map { point in
                var line = "- " + (point.decided ? MeetingPage.decidedMark : "") + MeetingPage.bolded(soft(point.text))
                if let at = point.at { line += " · \(clock(at))" }
                return line
            }
            lines.append("")
        }
        return lines
    }

    /// A dash in the notes' own words, softened so it can't be read as the
    /// one before an owner or a context.
    private static func soft(_ text: String) -> String {
        text.replacingOccurrences(of: " — ", with: " – ")
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
