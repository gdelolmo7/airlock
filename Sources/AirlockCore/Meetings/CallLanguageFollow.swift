import Foundation
import NaturalLanguage

/// Following a call that moves into another language partway through, one
/// side of it at a time.
///
/// **Why it exists (a real call, numbers only).** A 44-minute call was in
/// Spanish for ten minutes and in Catalan after that. The race
/// (`TranscriptRace`) is called once, on the first paragraph, so it picked
/// es_ES and kept it, and the Spanish recogniser wrote the Catalan half as
/// Spanish-looking words. Read line by line, the transcript said so: the share
/// of lines that read as Catalan, per five minutes, went 7%, 0%, then 40, 36,
/// 36, 78, 27, 48 and 50%. Read as one text it still came out es 0.999, which
/// is why the check before the notes (`CallLanguage.check`) could not see it.
///
/// So each side keeps a rolling read of its own lines (`Watch`). When enough
/// of the last dozen read as another language this Mac can listen in, a
/// second take starts in that language over the last stretch of audio, and
/// it takes over only if it heard that stretch clearly better (`confirms`).
/// The take it replaced keeps running beside it, so going back costs nothing.
public enum CallLanguageFollow {
    /// The two recognisers. `SpeechTranscriber` is the better one and knows
    /// 30 locales on this Mac; `DictationTranscriber` is the older engine and
    /// knows 54, Catalan among them, which the first does not.
    public enum Module: String, Codable, Sendable {
        case speech
        case dictation
    }

    /// A language to listen in and the recogniser that listens.
    public struct Listener: Hashable, Sendable {
        /// A locale identifier, "ca_ES".
        public var identifier: String
        public var module: Module

        public init(identifier: String, module: Module) {
            self.identifier = identifier
            self.module = module
        }

        /// "ca" for "ca_ES".
        public var code: String? { CallLanguage.code(of: identifier) }
    }

    /// "Catalan" for "ca_ES" or "ca". Nil when the language has no English
    /// name.
    public static func name(of identifier: String) -> String? {
        guard let code = CallLanguage.code(of: identifier),
              let name = Locale(identifier: "en").localizedString(forLanguageCode: code),
              name != code else { return nil }
        return name
    }

    // MARK: - Reading each line

    /// Words a line needs before its language counts. "Sí, vale." reads as
    /// anything, and the real call's shares above were read from lines of
    /// four words and up.
    public static let wordsToRead = 4

    /// The language one line reads as, among `codes`, or nil for a line too
    /// short to say.
    ///
    /// Only the languages this Mac can listen in are candidates: nothing else
    /// could be acted on, and an open read sends a Spanish line to Galician
    /// now and then, which no recogniser here knows.
    public static func language(of line: String, among codes: Set<String>) -> String? {
        guard words(in: line) >= wordsToRead else { return nil }
        let recognizer = NLLanguageRecognizer()
        if !codes.isEmpty {
            recognizer.languageConstraints = codes.sorted().flatMap { code -> [NLLanguage] in
                code == "zh" ? [.simplifiedChinese, .traditionalChinese] : [NLLanguage(rawValue: code)]
            }
        }
        recognizer.processString(line)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return CallLanguage.code(of: language.rawValue)
    }

    /// Words in any script, so a line in Japanese counts its words too.
    public static func words(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// Words of each take the read below looks at: the newest, so it follows
    /// the speech rather than how it began.
    public static let wordsShownRead = 20

    /// Which take the words on screen follow while the takes race: the one
    /// showing, while its newest words read as its own language; otherwise
    /// the first whose words do; otherwise still the one showing.
    ///
    /// By what the words read as, not by confidence, as dictation's preview
    /// is (`TranscriptRace.liveChoice`). The quick recognisers that write the
    /// words give their guesses no confidence (measured), only their
    /// finished sentences, and a Spanish one finished none for twenty
    /// seconds, so the English attempt stayed on screen all that time. A
    /// read tells the language spoken rather than which recogniser heard it
    /// better, and the language spoken is all the screen needs: the take in
    /// it writes it, and the other writes its own words for those sounds,
    /// which read as the spoken language too ("Holaal com del Valencia de la
    /// se quene" reads es, from four words).
    ///
    /// - `takes`: each take's locale identifier, its language code and its
    ///   words as they would show, in race order, the primary first.
    public static func shown(_ takes: [(identifier: String, code: String, words: String)],
                             showing: String) -> String {
        let codes = Set(takes.map(\.code))
        func readsAsItsOwn(_ take: (identifier: String, code: String, words: String)) -> Bool {
            let newest = take.words.split(whereSeparator: \.isWhitespace).suffix(wordsShownRead)
            return language(of: newest.joined(separator: " "), among: codes) == take.code
        }
        if let current = takes.first(where: { $0.identifier == showing }), readsAsItsOwn(current) { return showing }
        return takes.first(where: readsAsItsOwn)?.identifier ?? showing
    }

    // MARK: - The watch

    /// The rolling read of one take's lines.
    public struct Watch: Equatable, Sendable {
        /// Lines that count (`wordsToRead`), kept newest last: two to three
        /// minutes of one side talking.
        public static let window = 12
        /// Lines of one other language in the window that start a second
        /// take: a quarter. The real call's Spanish stretch read 1 line in 13
        /// and 0 in 49 as Catalan; its Catalan stretch, 27% to 78%.
        public static let enough = 3

        public struct Line: Equatable, Sendable {
            /// The language the line read as, by code.
            public var language: String
            /// When it was said, in seconds from the start of the call.
            public var start: TimeInterval

            public init(language: String, start: TimeInterval) {
                self.language = language
                self.start = start
            }
        }

        /// The language the take listens in, by code.
        public let own: String
        public private(set) var lines: [Line] = []

        public init(own: String) {
            self.own = own
        }

        /// One more line, by the language it read as; nil (too short) does
        /// not count.
        public mutating func add(_ language: String?, at start: TimeInterval) {
            guard let language else { return }
            lines.append(Line(language: language, start: start))
            if lines.count > Self.window { lines.removeFirst(lines.count - Self.window) }
        }

        public func count(of language: String) -> Int {
            lines.count { $0.language == language }
        }

        /// Drops what was said before `time`. Called on every take at a
        /// switch: lines from before it read the old language, and left in,
        /// the new winner's watch asked for the old language back at once
        /// (probed: 7 lines in 12 from before the seam, and Spanish audio
        /// handed back to Catalan).
        public mutating func forget(before time: TimeInterval) {
            lines.removeAll { $0.start < time }
        }

        /// The other language the window leans to, once it has `enough` of
        /// it. Two at once: the one with more lines, then the one heard last.
        public var other: String? {
            var counts: [String: Int] = [:]
            var latest: [String: Int] = [:]
            for (index, line) in lines.enumerated() where line.language != own {
                counts[line.language, default: 0] += 1
                latest[line.language] = index
            }
            return counts.filter { $0.value >= Self.enough }
                .max { ($0.value, latest[$0.key] ?? 0) < ($1.value, latest[$1.key] ?? 0) }?.key
        }
    }

    /// Lines a shadow must have counted before its read is trusted.
    public static let shadowCounted = 8

    /// Whether a shadow's own lines say the call went back to the shadow's
    /// language: of its last dozen, at least `shadowCounted` counted and at
    /// most one read as the winner's language.
    ///
    /// Evidence only, never a switch on its own. On synthetic Catalan an
    /// es_ES take read 9 lines in 9 as Catalan, but on the real call only
    /// 27–78%, so a dozen Spanish-reading lines can turn up by chance in a
    /// Catalan stretch; `confirms` still has to pass.
    public static func shadowSaysBack(_ shadow: Watch, winner: String) -> Bool {
        shadow.lines.count >= shadowCounted && shadow.count(of: winner) <= 1
    }

    // MARK: - Which locale

    /// The locale to listen in for a language code and which recogniser:
    /// `SpeechTranscriber` when it knows the language, `DictationTranscriber`
    /// otherwise, nil when neither does.
    ///
    /// Of the language's locales, the one nearest `near` (the take's locale,
    /// then the Mac's): the same country, then the same part of the world,
    /// then the same continent, then where the language is likeliest spoken.
    /// Portuguese on a Spanish call is pt_PT, not pt_BR; English on a Mac set
    /// to en_US is en_US.
    ///
    /// A Mac set to English (US) with Spain as its region is
    /// `en_US@rg=eszzzz`, and `Locale.region` reads that as Spain: where the
    /// person is, which is what Portuguese should be near (pt_PT). For
    /// English itself the identifier names its own region outright, so a
    /// near locale in the very language asked for counts by that first:
    /// en_US, not the en_GB the rest of Europe would give.
    public static func listener(for code: String, speech: [String], dictation: [String],
                                near: [String]) -> Listener? {
        if let identifier = nearest(code, in: speech, near: near) {
            return Listener(identifier: identifier, module: .speech)
        }
        if let identifier = nearest(code, in: dictation, near: near) {
            return Listener(identifier: identifier, module: .dictation)
        }
        return nil
    }

    static func nearest(_ code: String, in identifiers: [String], near: [String]) -> String? {
        let candidates = identifiers.filter { CallLanguage.code(of: $0) == code }.sorted()
        guard !candidates.isEmpty else { return nil }
        let regions = candidates.map { Locale(identifier: $0).region }
        let own = near.filter { CallLanguage.code(of: $0) == code }
            .compactMap { Locale.Language.Components(identifier: $0).region }
        let wanted = own + near.compactMap { Locale(identifier: $0).region }
        let likeliest = Locale.Language(identifier: Locale.Language(identifier: code).maximalIdentifier).region
        // Several equally near (German in Europe: Austria, Switzerland,
        // Germany): the one where the language is likeliest spoken.
        func pick(_ indices: [Int]) -> String? {
            (indices.first { likeliest != nil && regions[$0] == likeliest } ?? indices.first).map { candidates[$0] }
        }
        let steps: [(Locale.Region) -> Locale.Region?] = [{ $0 }, { $0.containingRegion }, { $0.continent }]
        for step in steps {
            for region in wanted {
                guard let target = step(region) else { continue }
                if let found = pick(candidates.indices.filter({ regions[$0].flatMap(step) == target })) {
                    return found
                }
            }
        }
        return pick(Array(candidates.indices))
    }

    // MARK: - The second take

    /// Seconds of each side's audio kept for a second take to start from:
    /// enough to reach back over the dozen lines the watch read.
    public static let replay: TimeInterval = 90

    /// Where a second take starts: the first line in the window that read as
    /// `language` and is still in the replay; failing that, the first of the
    /// take's lines that is. Always a line's start, so the lines replaced are
    /// whole ones. Nil when nothing said is still in the replay.
    public static func seam(watch: Watch, language: String, lineStarts: [TimeInterval],
                            replayFrom: TimeInterval) -> TimeInterval? {
        if let first = watch.lines.first(where: { $0.language == language && $0.start >= replayFrom }) {
            return first.start
        }
        return lineStarts.filter { $0 >= replayFrom }.min()
    }

    /// Where a call moved into a second take's language, read from that
    /// take's own lines: the first line of its last run that did not read
    /// as the winner's language, no earlier than `after`. Lines too short
    /// to read neither end the run nor start it. Nil when the take's newest
    /// readable line reads as the winner's.
    ///
    /// For a shadow going back, and for a speech take against a dictation
    /// winner (`challengerPlacesTheSeam`). Catalan dictation writes Spanish
    /// audio as something that still reads Catalan (7 lines in 9 on one
    /// voice), so the winner's first Spanish-reading line came 31 s after
    /// Spanish did, and those 31 s stayed in Catalan. Spanish speech reads
    /// its own Spanish as Spanish (12 in 12) and Catalan as Catalan (9 in 9
    /// synthetic; 27–78% on the real call), so its run of non-Catalan lines
    /// starts within a line or two of the change.
    public static func seamFromOwnLines(_ lines: [(start: TimeInterval, language: String?)], winner: String,
                                        after: TimeInterval) -> TimeInterval? {
        var seam: TimeInterval?
        for line in lines.reversed() {
            guard line.start >= after, line.language != winner else { break }
            if line.language != nil { seam = line.start }
        }
        return seam
    }

    /// A seam placed from a second take's lines, moved back to the start of
    /// the winner's line it falls in the first half of. Two recognisers
    /// time the same sentence a little apart (0.1 s, probed), and the
    /// winner's line starting just before the seam stayed in the transcript
    /// beside the second take's version of it. Later in a line, the seam
    /// stays: moving it would hand the second take's lines back.
    public static func snap(_ seam: TimeInterval, to winnerLines: [(start: TimeInterval, end: TimeInterval)])
        -> TimeInterval {
        guard let line = winnerLines.last(where: { $0.start <= seam && seam < $0.end }) else { return seam }
        return seam - line.start <= (line.end - line.start) / 2 ? line.start : seam
    }

    /// Whether a second take's own lines place the seam rather than the
    /// winner's: when it is speech and the winner dictation. Speech writes
    /// each language as itself (es_ES speech read Spanish 12 in 12, Italian
    /// 8 in 9, Catalan 9 in 9 as what they were); dictation writes the
    /// language it was given (ca_ES dictation, 7 in 9 Spanish lines as
    /// Catalan; it_IT, every Spanish line as Italian). Such a take starts
    /// from the oldest audio kept, not the winner's late guess.
    public static func challengerPlacesTheSeam(challenger: Module, winner: Module) -> Bool {
        challenger == .speech && winner == .dictation
    }

    /// Finished characters past the seam before the two takes are compared:
    /// about a paragraph and a half. The race decides on 200
    /// (`MeetingTrack.decideAfter`), but dictation delivers in long pieces
    /// and one of them can carry most of 200 on its own.
    public static let compareAfter = 300
    /// Seconds after the seam by which a second take that has not heard
    /// `compareAfter` is refused: the other language was not really there.
    public static let giveUpAfter: TimeInterval = 180
    /// How long a refused language waits before it is tried again, so a
    /// call that keeps leaning one way does not start a take every minute.
    public static let retryAfter: TimeInterval = 300

    /// When each language was last refused, by code.
    public struct Refusals: Equatable, Sendable {
        private var refused: [String: TimeInterval] = [:]

        public init() {}

        public mutating func refuse(_ code: String, at time: TimeInterval) {
            refused[code] = time
        }

        public func allows(_ code: String, at time: TimeInterval) -> Bool {
            guard let last = refused[code] else { return true }
            return time - last >= CallLanguageFollow.retryAfter
        }
    }

    // MARK: - Confirming

    /// What one take heard over the stretch the two are compared on.
    public struct Hearing: Equatable, Sendable {
        public var module: Module
        public var words: Int
        /// Character-weighted mean of the per-run confidence. Nil when the
        /// model gives none: ca_ES dictation reports none at all, on any audio.
        public var confidence: Double?

        public init(module: Module, words: Int, confidence: Double?) {
            self.module = module
            self.words = words
            self.confidence = confidence
        }
    }

    /// Added to a dictation take's confidence before it is compared with a
    /// speech take's. Measured with `say` (16 kHz, sentences 0.9 s apart),
    /// mean confidence over the whole file, words in brackets:
    ///
    /// | audio           | speech es_ES | dict es_ES | speech it_IT | dict it_IT | dict ca_ES |
    /// |-----------------|--------------|------------|--------------|------------|------------|
    /// | Spanish, Mónica | 0.983 (402)  | 0.880 (404)| 0.861 (394)  | 0.413 (272)| none (346) |
    /// | Spanish, Eddy   | 0.940 (403)  | 0.696 (382)| 0.752 (390)  | 0.318 (190)| none (100) |
    /// | Spanish, Reed   | 0.945 (404)  | 0.694 (382)| 0.744 (389)  | 0.298 (186)| none (96)  |
    /// | Italian, Alice  | 0.801 (256)  | 0.468 (222)| 0.960 (267)  | 0.901 (269)| none (101) |
    /// | Catalan, Montse | 0.817 (310)  | 0.457 (244)| 0.598 (228)  | 0.317 (191)| none (304) |
    ///
    /// Dictation scores the right language 0.06–0.25 lower than speech does
    /// (0.880 against 0.983, 0.901 against 0.960), so the two scales are not
    /// one scale. Lifted by 0.20, the right take still wins every row by the
    /// race's own margin and the wrong one never does: Italian heard by
    /// es_ES speech against it_IT dictation is 0.801 against 1.101, Spanish
    /// heard by es_ES speech against it_IT dictation 0.983 against 0.613.
    public static let dictationLift = 0.20

    /// With confidence on one side only, how much of the confident take's
    /// words the other must have to count as hearing the same speech. A
    /// recogniser in the wrong language drops words rather than scoring them
    /// low: ca_ES dictation kept 24–86% of the words on Spanish and 39% on
    /// Italian, and 98% on Catalan, where it is right.
    public static let coverageRight = 0.90

    /// With no confidence on either side, how many more words the second
    /// take needs.
    public static let moreWords = 1.10

    /// A take this confident (lifted, for dictation) is hearing its own
    /// language. Right-language speech scored 0.940–0.983 in the table
    /// above and wrong-language speech at most 0.861; right-language
    /// dictation 0.894–1.101 lifted, wrong at most 0.668.
    ///
    /// It settles what words alone cannot: ca_ES dictation keeps 86% of
    /// one Spanish voice's words, so over a stretch it came out at 0.90 of
    /// Spanish speech's either side of the line, and Spanish audio was
    /// handed to Catalan. Spanish speech at 0.98 on it is the tell. On
    /// Catalan audio it scored 0.817, under the line, so it is only ever
    /// a reason to stay in, or go back to, the confident take's language.
    public static let sure = 0.90

    /// Whether `challenger` heard the compared stretch clearly better than
    /// `incumbent`. Confidence decides when both have it, by the race's
    /// margin (`TranscriptRace.takeoverMargin`) once dictation is lifted;
    /// words decide when either has none, unless the one with confidence is
    /// `sure` of what it heard.
    public static func confirms(challenger: Hearing, incumbent: Hearing) -> Bool {
        guard challenger.words > 0 else { return false }
        guard incumbent.words > 0 else { return true }
        switch (challenger.confidence, incumbent.confidence) {
        case let (mine?, theirs?):
            return lifted(mine, challenger.module) - lifted(theirs, incumbent.module)
                >= TranscriptRace.takeoverMargin
        case (nil, let theirs?):
            return lifted(theirs, incumbent.module) < sure && coverage(challenger, of: incumbent) >= coverageRight
        case (let mine?, nil):
            return lifted(mine, challenger.module) >= sure || coverage(incumbent, of: challenger) < coverageRight
        case (nil, nil):
            return coverage(challenger, of: incumbent) >= moreWords
        }
    }

    /// One line as a take heard it, for comparing two takes over a stretch.
    public struct Said: Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var words: Int
        /// Σ confidence × characters, and the characters scored: zero when
        /// the recogniser gives no confidence.
        public var weighted: Double
        public var scored: Int

        public init(start: TimeInterval, end: TimeInterval, words: Int, weighted: Double = 0, scored: Int = 0) {
            self.start = start
            self.end = end
            self.words = words
            self.weighted = weighted
            self.scored = scored
        }
    }

    /// What a take heard of `from..<until`. A line across either end counts
    /// for the share of its time inside, words and confidence alike.
    ///
    /// Counted by where lines start, the two takes were compared on
    /// different stretches: speech's sentences end inside the stretch by
    /// construction (it is cut at one), while a dictation piece starting a
    /// moment before its end counted whole, and so did one starting in the
    /// slack before the seam. Probed with Spanish back after Catalan, the
    /// Catalan take came out with 87 words to Spanish speech's 71 over the
    /// "same" stretch, more than the 86% of the words it hears of Spanish
    /// over a whole file, and the call stayed in Catalan.
    public static func hearing(_ lines: [Said], module: Module, from: TimeInterval,
                               until: TimeInterval) -> Hearing {
        var words = 0.0
        var weighted = 0.0
        var scored = 0.0
        for line in lines {
            let share: Double
            if line.end > line.start {
                let inside = min(line.end, until) - max(line.start, from)
                share = max(0, min(1, inside / (line.end - line.start)))
            } else {
                share = line.start >= from && line.start < until ? 1 : 0
            }
            guard share > 0 else { continue }
            words += Double(line.words) * share
            weighted += line.weighted * share
            scored += Double(line.scored) * share
        }
        return Hearing(module: module, words: Int(words.rounded()),
                       confidence: scored > 0 ? weighted / scored : nil)
    }

    static func lifted(_ confidence: Double, _ module: Module) -> Double {
        module == .dictation ? confidence + dictationLift : confidence
    }

    static func coverage(_ take: Hearing, of other: Hearing) -> Double {
        Double(take.words) / Double(max(1, other.words))
    }

    // MARK: - Dictation's long results

    /// A stretch of a dictation result as the recogniser timed it, in
    /// seconds of the audio. Nil times: the recogniser did not say.
    public struct Timed: Equatable, Sendable {
        public var text: String
        public var start: TimeInterval?
        public var end: TimeInterval?

        public init(text: String, start: TimeInterval?, end: TimeInterval?) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// A silence this long between two words ends a line.
    /// `DictationTranscriber` delivers one result per 5–23 s of speech even
    /// asked to finish often, unpunctuated in Catalan, where speech gives a
    /// result every two or three sentences. Cut where the speaker paused,
    /// the lines read like speech's and land at their own times.
    public static let pieceGap: TimeInterval = 0.5

    /// A piece of fewer words than this joins the neighbour it is nearer in
    /// time. Cut at every half-second pause, the Catalan probe came out with
    /// lines of a single word ("Setmana", "De"): a speaker who stops to
    /// think, not a sentence. Two words still stand ("Bon dia.").
    public static let shortestPiece = 2

    /// One result cut at its pauses. Runs with no time join the line they
    /// follow. Blank lines are dropped, and a piece shorter than
    /// `shortestPiece` words joins the nearer of its neighbours.
    public static func pieces(of runs: [Timed], gap: TimeInterval = pieceGap) -> [Timed] {
        var pieces: [Timed] = []
        var current = Timed(text: "", start: nil, end: nil)

        func close() {
            let text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pieces.append(Timed(text: text, start: current.start, end: current.end)) }
            current = Timed(text: "", start: nil, end: nil)
        }

        for run in runs {
            if let start = run.start, let end = current.end, start - end >= gap { close() }
            current.text += run.text
            if let start = run.start, current.start == nil { current.start = start }
            if let end = run.end { current.end = max(current.end ?? end, end) }
        }
        close()
        return joiningShort(pieces)
    }

    private static func joiningShort(_ pieces: [Timed]) -> [Timed] {
        var pieces = pieces
        while pieces.count > 1,
              let index = pieces.firstIndex(where: { words(in: $0.text) < shortestPiece }) {
            func gap(_ a: Int, _ b: Int) -> TimeInterval {
                guard let end = pieces[a].end, let start = pieces[b].start else { return .infinity }
                return start - end
            }
            let before = index > 0 ? gap(index - 1, index) : .infinity
            let after = index + 1 < pieces.count ? gap(index, index + 1) : .infinity
            let first = index > 0 && (before <= after || index + 1 == pieces.count) ? index - 1 : index
            let a = pieces[first]
            let b = pieces[first + 1]
            pieces[first] = Timed(text: a.text + " " + b.text, start: a.start ?? b.start, end: b.end ?? a.end)
            pieces.remove(at: first + 1)
        }
        return pieces
    }
}
