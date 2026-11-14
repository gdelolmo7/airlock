import Foundation

/// What the person answered under "Check these words", kept for every call
/// after it.
///
/// A call's notes ask "Claude, heard as “Cloud”"; the answer is the same in
/// the next call, so it should not be asked again. Two things carry an
/// answer forward:
/// - **"Always write X as Y"** (`DictationWords`) for the ways it was heard
///   that are safe to change everywhere (`alwaysWritten`): several words
///   ("cloud code"), or one that is no ordinary word ("Claudio"). The
///   transcript is then spelled right before the notes are written, so the
///   question never comes up.
/// - **This list**, for the rest. "Cloud" is a real word and is never
///   changed in every call; but when a later call's notes ask the same
///   question again, the answer given before is applied (`answer(for:heard:)`)
///   and the line is not shown. "Leave it" is kept the same way.
///
/// A question is answered from here only when every way it was heard was
/// answered before, for the same word: one new way of hearing it is still
/// asked. Pure; the App keeps the list in Settings.
public struct MeetingWordMemory: Codable, Equatable, Sendable {
    /// The most answers kept; the oldest go first.
    public static let most = 300

    public struct Answer: Codable, Equatable, Sendable {
        /// The word the notes listed ("Claude").
        public var listed: String
        /// How the transcript had it ("Cloud", "Claudio").
        public var heard: [String]
        /// What it should read: the listed word for "Use", the person's own
        /// for "Type it". Nil for "Leave it".
        public var written: String?

        public init(listed: String, heard: [String], written: String?) {
            self.listed = listed
            self.heard = heard
            self.written = written
        }
    }

    public private(set) var answers: [Answer]

    public init(answers: [Answer] = []) {
        self.answers = answers
    }

    /// The list with one more answer. `best` is what was put in, `listed`
    /// the notes' guess when the person typed another word. A later answer
    /// for the same word and way of hearing it replaces the earlier one.
    public func remembering(_ best: String, heard: [String], use: Bool, listed: String? = nil) -> Self {
        let listed = listed ?? best
        let forms = Self.tidied(heard)
        guard !MeetingKnownWords.key(listed).isEmpty, !forms.isEmpty else { return self }
        let wordKey = MeetingKnownWords.key(listed)
        let formKeys = Set(forms.map(MeetingKnownWords.key))
        // What the new answer covers is taken out of the older ones.
        var kept: [Answer] = answers.compactMap { old in
            guard MeetingKnownWords.key(old.listed) == wordKey else { return old }
            var old = old
            old.heard = old.heard.filter { !formKeys.contains(MeetingKnownWords.key($0)) }
            return old.heard.isEmpty ? nil : old
        }
        kept.append(Answer(listed: listed, heard: forms, written: use ? best : nil))
        return Self(answers: Array(kept.suffix(Self.most)))
    }

    /// What was answered before to a question.
    public enum Remembered: Equatable, Sendable {
        /// "Use" or "Type it": write this.
        case use(String)
        /// "Leave it".
        case leave
    }

    /// The answer given before to "`best`, heard as `heard`", or nil when
    /// any way it was heard is new, or the earlier answers for it don't
    /// agree.
    public func answer(for best: String, heard: [String]) -> Remembered? {
        let wordKey = MeetingKnownWords.key(best)
        let forms = Self.tidied(heard)
        guard !wordKey.isEmpty, !forms.isEmpty else { return nil }
        var found: [String?] = []
        for form in forms {
            let key = MeetingKnownWords.key(form)
            // The latest answer that covers it.
            guard let answer = answers.last(where: { answer in
                MeetingKnownWords.key(answer.listed) == wordKey
                    && answer.heard.contains { MeetingKnownWords.key($0) == key }
            }) else { return nil }
            found.append(answer.written)
        }
        let first = found[0]
        guard found.allSatisfy({ $0 == first }) else { return nil }
        return first.map(Remembered.use) ?? .leave
    }

    /// The ways `best` was heard that "Use" should also put under "Always
    /// write X as Y", for every call and dictation: those with more than one
    /// word, or one word that `isDictionaryWord` (asked in lowercase) says is
    /// no ordinary word. Never a figure, never one that only differs from
    /// `best` in its capitals or accents, never more than
    /// `MeetingKnownWords.longestSplit` words.
    public static func alwaysWritten(_ heard: [String], as best: String,
                                     isDictionaryWord: (String) -> Bool) -> [String] {
        guard MeetingWordCheck.belongsInKnownWords(best) else { return [] }
        let bestKey = MeetingKnownWords.key(best)
        return tidied(heard).filter { form in
            let key = MeetingKnownWords.key(form)
            let words = form.split(separator: " ").count
            guard !key.isEmpty, key != bestKey, !form.contains(where: \.isNumber),
                  words <= MeetingKnownWords.longestSplit else { return false }
            return MeetingKnownWords.pieces(form) > 1 || !isDictionaryWord(form.lowercased())
        }
    }

    /// Trimmed, single spaces, empties and repeats dropped.
    static func tidied(_ forms: [String]) -> [String] {
        MeetingKnownWords.tidied(forms)
    }
}
