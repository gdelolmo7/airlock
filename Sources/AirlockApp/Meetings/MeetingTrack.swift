import AVFoundation
import AirlockCore
import CoreMedia
import Speech

/// One side of a call, turned into lines: the microphone ("You") or the call
/// app's sound ("Them"), each with analyzers of its own.
///
/// Built from what `SpeechSession` measured, and different from dictation
/// where a meeting is different:
/// - **Finished sentences make the record.** The words being said
///   (`onHearing`) are only ever shown, under the lines, as dictation shows
///   them: the first person to watch a call's transcript waited for whole
///   paragraphs and asked for it word by word. Nothing is written, raced or
///   followed on them. For speech they come from a second, faster
///   recogniser on an analyzer of its own (`Quick`, `CallListening.quick`):
///   the notes' own guess came 2–6 s late, and asked to hurry it writes
///   worse notes. A second analyzer cost nothing measurable on this Mac.
/// - **The language is decided early, then followed.** Dictation races its
///   two languages over every hold; a meeting is one long hold. Both
///   recognisers run until about a paragraph has been heard, the race is
///   called on that (`TranscriptRace.winner`, the same rule), and what the
///   winner heard meanwhile is handed on in order. The race is not the end
///   of it: a call that moves into another language later is followed
///   (`CallLanguageFollow`), see below.
/// - **Times come from the audio, not the clock.** Each result says which
///   stretch of the stream it covers, and the stream started at a known moment
///   of the meeting, so a line lands where it was said even when the
///   recogniser delivers it seconds later.
/// - **Each line is tidied as it arrives** (`MeetingWords`): a capital where
///   a clipped first word left none, and nothing kept that nobody said.
///
/// **Following a change of language.** Every line the winner hears is read
/// for its language (`CallLanguageFollow.Watch`). Once a quarter of the last
/// dozen read as another language this Mac can listen in, a second take
/// starts in it, on an analyzer of its own fed the last 90 seconds of this
/// side's audio and then live (`MeetingTee`), and the two are compared over
/// the same stretch (`CallLanguageFollow.confirms`). If it heard that
/// stretch clearly better, its lines replace the winner's from where the
/// change was heard (`Event.switched`) and it becomes the winner. The take
/// it replaced keeps listening beside it as the **shadow**: its own lines
/// are evidence for going back, going back needs no replay, and while the
/// winner's language is one Apple's notes writer cannot read, the shadow's
/// lines are what the notes are written from (`Event.shadow`,
/// `MeetingNotesSource`). Two takes cost about 1.3× one on a shared
/// analyzer and about 2× on two; three at most, for the minutes a
/// challenger is being compared.
@MainActor
final class MeetingTrack {
    /// What the track tells the notes, in the order it happens.
    enum Event {
        /// A finished line in the language the side is heard in now.
        case line(MeetingSegment)
        /// The race decided: the side is heard in `language` from `from`
        /// (seconds into the call).
        case listening(from: TimeInterval, language: String)
        /// The side moved into `language` at `seam`: its lines from there are
        /// `lines`. `keptAs`, when set, keeps the lines they replace as the
        /// shadow, in that language (`MeetingRecord.switchLanguage`).
        case switched(seam: TimeInterval, language: String, lines: [MeetingSegment], keptAs: String?)
        /// A line from the take kept beside a winner the notes writer
        /// cannot read. Never shown.
        case shadow(MeetingShadowLine)
    }

    let speaker: MeetingSpeaker
    /// Characters of finished text after which the language is decided.
    static let decideAfter = 200
    /// A race between the two recognisers waits for both to reach
    /// `decideAfter`, up to this many characters from either: dictation
    /// delivers one result per 5–23 s, and called on the first speech
    /// result past 200 it would lose with nothing heard yet.
    static let decideAtTheLatest = 600
    /// Seconds of each take's own lines kept, for comparing a challenger and
    /// for handing over from the seam: the 90 s a challenger can reach back,
    /// the three minutes it has to prove itself, and room to spare.
    static let remembered: TimeInterval = 400
    /// A challenger's line starting this little before the seam is the
    /// seam's own line, heard a moment earlier.
    static let seamSlack: TimeInterval = 0.5
    /// How long the incumbent gets to deliver its lines for the compared
    /// stretch before the comparison goes ahead without them: dictation can
    /// be 23 s behind.
    static let incumbentWait: TimeInterval = 30

    private let log: (String) -> Void
    private let onEvent: (Event) -> Void
    /// The words being said on this side, as the recogniser guesses them
    /// before it finishes the sentence: "" once they are a line, or nothing
    /// is being said. Set before `begin`; without it no guess is asked for
    /// and no quick recogniser runs.
    /// During the race the words already finished but held for it come
    /// first, so nothing said vanishes while the language is decided.
    var onHearing: ((String) -> Void)?
    private var lastHeard = ""
    private let listeners: CallListeners
    private let canRead: (String) -> Bool
    /// The words typed in Settings, for the recogniser to expect. Only the
    /// dictation recogniser listens: the meeting one wrote the same text
    /// with them as without, so they are also put right afterwards
    /// (`MeetingKnownWords`).
    private let vocabulary: [String]
    /// The most words the recogniser is given.
    static let longestVocabulary = 100

    private let tee = MeetingTee(keep: CallLanguageFollow.replay)
    private var feeding: Task<Void, Never>?
    private var format: AVAudioFormat?
    /// The most words kept for the screen past a take's finished lines: the
    /// screen shows the newest few, and a recogniser that stopped finishing
    /// must not grow them without end.
    static let unfinishedWords = 300

    /// Seconds into the meeting at which this track's audio started.
    private var offset: TimeInterval = 0
    private var startedAt = Date()

    private var lanes: [Lane] = []
    /// The takes in the first race, until it is decided.
    private var racing: [Take] = []
    /// The take the screen follows until the race is decided, by locale.
    private var showing = ""
    private var winner: Take?
    private var shadow: Take?
    private var challenge: Challenge?
    /// Where the winner took over: the start, or the last switch's seam.
    private var since: TimeInterval = 0
    private var refusals = CallLanguageFollow.Refusals()
    /// Languages whose recogniser is being made ready, by code.
    private var preparing: Set<String> = []
    /// The call is ending: no new take is started, and one on trial is
    /// judged once, at the end, on what it heard.
    private var ended = false
    /// Every language the side was heard in, in order.
    private(set) var languages: [String] = []
    /// The other side's words as the recogniser timed them, in seconds of
    /// the meeting, for the lines handed on: what the voices heard on the
    /// call are laid over at its end (`CallVoices`). Kept only for "Them",
    /// in memory, and gone with the track.
    private(set) var words: [CallLanguageFollow.Timed] = []

    /// One analyzer and the output of `tee` it reads.
    @MainActor
    private final class Lane {
        let analyzer: SpeechAnalyzer
        let output: Int
        var modules: [any SpeechModule]

        init(analyzer: SpeechAnalyzer, output: Int, modules: [any SpeechModule]) {
            self.analyzer = analyzer
            self.output = output
            self.modules = modules
        }
    }

    /// The recogniser that puts a speech take's words on screen as they are
    /// said, and what it heard that the take has not finished yet.
    @MainActor
    private final class Quick {
        let module: SpeechTranscriber
        let lane: Lane
        var pump: Task<Void, Never>?
        /// Its finished words, in seconds of the meeting.
        var said: [CallLanguageFollow.Timed] = []
        /// Its running guess past them, and where that starts.
        var guess = ""
        var guessStart: TimeInterval?

        init(module: SpeechTranscriber, lane: Lane) {
            self.module = module
            self.lane = lane
        }
    }

    /// One recogniser in one language, and what it heard.
    @MainActor
    private final class Take {
        let listener: CallLanguageFollow.Listener
        let locale: Locale
        let module: any SpeechModule
        let lane: Lane
        var pump: Task<Void, Never>?
        var watch: CallLanguageFollow.Watch
        /// Its lines over the last `remembered` seconds.
        var heard: [Line] = []
        // The race, before it is decided.
        var held: [Line] = []
        var characters = 0
        /// The recogniser's running guess past its last finished line:
        /// dictation's, which has no quick recogniser beside it.
        var guess = ""
        /// Its words on screen, while it is speech and someone is watching.
        var quick: Quick?
        /// Where its finished lines end, in seconds of the meeting, and
        /// their last words as timed: what of `quick`'s words is a line now.
        var through: TimeInterval = -.infinity
        var recent: [CallLanguageFollow.Timed] = []

        init(listener: CallLanguageFollow.Listener, module: any SpeechModule, lane: Lane) {
            self.listener = listener
            locale = Locale(identifier: listener.identifier)
            self.module = module
            self.lane = lane
            watch = CallLanguageFollow.Watch(own: listener.code ?? listener.identifier)
        }

        var id: String { listener.identifier }
        var code: String { listener.code ?? listener.identifier }
        var heardThrough: TimeInterval? { heard.last?.segment.end }

        func remember(_ line: Line, reading language: String?) {
            var line = line
            line.language = language
            heard.append(line)
            let cutoff = line.segment.start - MeetingTrack.remembered
            if let stale = heard.firstIndex(where: { $0.segment.start >= cutoff }), stale > 0 {
                heard.removeFirst(stale)
            }
            watch.add(language, at: line.segment.start)
        }

        /// What it heard of `from..<until`, by time (`CallLanguageFollow.hearing`).
        func hearing(from: TimeInterval, until: TimeInterval) -> CallLanguageFollow.Hearing {
            let said = heard.map { line in
                CallLanguageFollow.Said(start: line.segment.start, end: line.segment.end,
                                        words: CallLanguageFollow.words(in: line.segment.text),
                                        weighted: line.weighted, scored: line.scored)
            }
            return CallLanguageFollow.hearing(said, module: listener.module, from: from, until: until)
        }
    }

    private struct Line {
        var segment: MeetingSegment
        var weighted: Double
        var scored: Int
        /// What it read as, by code, once remembered; nil when too short.
        var language: String?
        /// Its words as timed, in seconds of the meeting.
        var words: [CallLanguageFollow.Timed] = []
    }

    /// A second take on trial against the winner.
    private struct Challenge {
        let take: Take
        var seam: TimeInterval
        /// Set while the challenger's own lines are to place the seam
        /// (`CallLanguageFollow.challengerPlacesTheSeam`): where it started
        /// hearing. Placed once it has heard through `seam`, the winner's
        /// guess.
        var placesFrom: TimeInterval?
        /// Where the compared stretch ends, fixed once the challenger has
        /// heard `CallLanguageFollow.compareAfter` past the seam.
        var until: TimeInterval?
    }

    /// - Parameter canRead: whether Apple's notes writer reads a locale
    ///   identifier's language (`CallNotesWriter.canRead`).
    init(speaker: MeetingSpeaker, listeners: CallListeners, canRead: @escaping (String) -> Bool,
         vocabulary: [String] = MeetingNotesModel.typedWords(),
         log: @escaping (String) -> Void, onEvent: @escaping (Event) -> Void) {
        self.speaker = speaker
        self.listeners = listeners
        self.canRead = canRead
        self.vocabulary = Array(vocabulary.prefix(Self.longestVocabulary))
        self.log = log
        self.onEvent = onEvent
    }

    /// The language this track listens in now, once it has decided.
    var language: String? { winner?.id }

    /// This side's audio from the start of the track, for the voice model
    /// (`CallVoiceListener`), and how far into the meeting that start is.
    /// Ends when the track does.
    func voiceInput() -> (stream: AsyncStream<AnalyzerInput>, offset: TimeInterval) {
        (tee.output(from: 0).stream, offset)
    }

    /// Start listening to `input` in `picked`, the first the primary.
    /// `offset` is how far into the meeting the stream's first sample is,
    /// `format` what `CallListening.format` gave for `picked`.
    func begin(_ picked: [CallLanguageFollow.Listener], format: AVAudioFormat, offset: TimeInterval,
               input: AsyncStream<AnalyzerInput>) {
        self.offset = offset
        self.format = format
        startedAt = Date()
        // The race listens from the first buffer: its output exists before
        // anything is passed on.
        let modules = picked.map { CallListening.module(for: $0, partials: partials(for: $0)) }
        let lane = open(from: nil, modules: modules)
        racing = zip(picked, modules).map { Take(listener: $0, module: $1, lane: lane) }
        showing = racing.first?.id ?? ""
        quicken(racing, from: nil)
        let tee = tee
        feeding = Task.detached {
            for await item in input { tee.pass(item) }
            tee.end()
        }
        racing.forEach(pump)
        if racing.count == 1 { decide() }
    }

    // MARK: - Lanes and takes

    /// Whether `listener`'s own recogniser guesses at the words for the
    /// screen: dictation's does, speech's has a quick one beside it.
    private func partials(for listener: CallLanguageFollow.Listener) -> Bool {
        onHearing != nil && listener.module == .dictation
    }

    /// `listed`: whether `finish` waits for it. A quick recogniser's lane is
    /// not: nothing it hears is kept.
    private func open(from time: TimeInterval?, modules: [any SpeechModule], listed: Bool = true) -> Lane {
        let (output, stream) = tee.output(from: time)
        let analyzer: SpeechAnalyzer
        if vocabulary.isEmpty {
            analyzer = SpeechAnalyzer(inputSequence: stream, modules: modules)
        } else {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            analyzer = SpeechAnalyzer(inputSequence: stream, modules: modules, analysisContext: context)
        }
        let lane = Lane(analyzer: analyzer, output: output, modules: modules)
        if listed { lanes.append(lane) }
        return lane
    }

    /// Starts the words on screen for those of `takes` that are speech, on
    /// one analyzer of their own, from `time` in seconds of this side's
    /// audio: nil for live, before anything has passed, so they are timed on
    /// the same clock as the lines. Only while someone is watching, and not
    /// once the call is ending.
    private func quicken(_ takes: [Take], from time: TimeInterval?) {
        guard onHearing != nil, !ended else { return }
        let wanted = takes.compactMap { take in CallListening.quick(for: take.listener).map { (take, $0) } }
        guard !wanted.isEmpty else { return }
        let lane = open(from: time, modules: wanted.map(\.1), listed: false)
        for (take, module) in wanted {
            let quick = Quick(module: module, lane: lane)
            take.quick = quick
            pump(quick, of: take)
        }
        log("\(speaker.rawValue) live words: quick \(wanted.map(\.0.id).joined(separator: ", "))")
    }

    private func pump(_ quick: Quick, of take: Take) {
        let transcriber = quick.module
        let speaker = speaker
        let log = log
        quick.pump = Task { [weak self, weak take, weak quick] in
            do {
                for try await result in transcriber.results {
                    guard let self, let take, let quick, take.quick === quick else { return }
                    if result.isFinal {
                        let offset = self.offset
                        quick.said += CallListening.runs(of: result.text).compactMap { word in
                            guard let start = word.start, let end = word.end else { return nil }
                            return CallLanguageFollow.Timed(text: word.text, start: offset + start, end: offset + end)
                        }
                        quick.guess = ""
                        quick.guessStart = nil
                    } else {
                        let start = result.range.start.seconds
                        quick.guess = String(result.text.characters)
                        quick.guessStart = start.isFinite ? self.offset + start : nil
                    }
                    self.trim(take)
                    self.showHearing()
                }
            } catch {
                log("\(speaker.rawValue) live words \(take?.id ?? "?") ended: \(error.localizedDescription)")
            }
        }
    }

    /// Lets go of the quick recogniser's words that `take`'s lines now say,
    /// and keeps both lists of words within `unfinishedWords`.
    private func trim(_ take: Take) {
        if take.recent.count > Self.unfinishedWords { take.recent.removeFirst(take.recent.count - Self.unfinishedWords) }
        guard let quick = take.quick else { return }
        quick.said.removeAll { CallLive.isFinished($0, by: take.recent, through: take.through) }
        if quick.said.count > Self.unfinishedWords { quick.said.removeFirst(quick.said.count - Self.unfinishedWords) }
    }

    /// Stops `take`'s words on screen.
    private func stopQuick(_ take: Take) {
        guard let quick = take.quick else { return }
        take.quick = nil
        quick.pump?.cancel()
        release(quick.module, from: quick.lane, name: "\(take.id) live words")
    }

    private func pump(_ take: Take) {
        let speaker = speaker
        let log = log
        switch take.module {
        case let transcriber as SpeechTranscriber:
            take.pump = Task { [weak self, weak take] in
                do {
                    for try await result in transcriber.results {
                        guard result.isFinal else {
                            guard let self, let take else { return }
                            self.guessed(String(result.text.characters), in: take)
                            continue
                        }
                        let lines = CallListening.lines(of: result.text, range: result.range, cut: false)
                        guard let self, let take else { return }
                        self.received(lines, in: take)
                    }
                } catch {
                    log("\(speaker.rawValue) track \(take?.id ?? "?") ended: \(error.localizedDescription)")
                }
            }
        case let transcriber as DictationTranscriber:
            take.pump = Task { [weak self, weak take] in
                do {
                    for try await result in transcriber.results {
                        guard result.isFinal else {
                            guard let self, let take else { return }
                            self.guessed(String(result.text.characters), in: take)
                            continue
                        }
                        let lines = CallListening.lines(of: result.text, range: result.range, cut: true)
                        guard let self, let take else { return }
                        self.received(lines, in: take)
                    }
                } catch {
                    log("\(speaker.rawValue) track \(take?.id ?? "?") ended: \(error.localizedDescription)")
                }
            }
        default:
            break
        }
    }

    /// Stops `take` costing anything: its recogniser leaves its analyzer,
    /// and an analyzer left with none stops. If the analyzer refuses, the
    /// results are simply ignored, which is right too, only slower.
    private func drop(_ take: Take) {
        take.pump?.cancel()
        stopQuick(take)
        release(take.module, from: take.lane, name: take.id)
    }

    private func release(_ module: any SpeechModule, from lane: Lane, name: String) {
        lane.modules.removeAll { $0 === module }
        let log = log
        let speaker = speaker
        if lane.modules.isEmpty {
            lanes.removeAll { $0 === lane }
            tee.stop(lane.output)
            Task { await lane.analyzer.cancelAndFinishNow() }
        } else {
            let keep = lane.modules
            Task {
                do {
                    try await lane.analyzer.setModules(keep)
                } catch {
                    log("\(speaker.rawValue) could not drop \(name): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Lines

    private func received(_ lines: [CallListening.Heard], in take: Take) {
        let live = racing.contains { $0 === take } || take === winner || take === shadow
            || take === challenge?.take
        guard live else { return }
        // A finished line covers the guess before it, as in dictation
        // (`DictationTranscript`): the next guess picks up after it. The
        // quick recogniser's words up to its end, too, whether it is kept or
        // not.
        take.guess = ""
        let offset = offset
        for heard in lines {
            if let end = heard.end { take.through = max(take.through, offset + end) }
            take.recent += heard.words.map { CallLanguageFollow.Timed(text: $0.text, start: $0.start.map { offset + $0 },
                                                                      end: $0.end.map { offset + $0 }) }
        }
        trim(take)
        defer { showHearing() }
        for heard in lines {
            guard let text = MeetingWords.kept(heard.text, in: take.locale) else { continue }
            var start = heard.start
            var end = heard.end
            if start == nil || end == nil {
                // No time from the recogniser: the moment it arrived is close enough.
                let now = Date().timeIntervalSince(startedAt)
                start = start ?? end ?? now
                end = end ?? now
            }
            let segment = MeetingSegment(speaker: speaker, start: offset + (start ?? 0),
                                         end: offset + (end ?? 0), text: text)
            let words = speaker == .them
                ? heard.words.map { CallLanguageFollow.Timed(text: $0.text, start: $0.start.map { offset + $0 },
                                                             end: $0.end.map { offset + $0 }) }
                : []
            let line = Line(segment: segment, weighted: heard.weighted, scored: heard.scored, words: words)
            if winner == nil {
                take.held.append(line)
                take.characters += text.count
                continue
            }
            take.remember(line, reading: CallLanguageFollow.language(of: text, among: listeners.codes))
            if take === winner {
                say(line)
            } else if take === shadow {
                shadowLine(segment, from: take)
            }
        }
        if winner == nil {
            let counts = racing.map(\.characters)
            let mixed = Set(racing.map(\.listener.module)).count > 1
            let ready = mixed ? counts.allSatisfy { $0 >= Self.decideAfter } || counts.contains { $0 >= Self.decideAtTheLatest }
                              : counts.contains { $0 >= Self.decideAfter }
            if ready { decide() }
            return
        }
        review()
    }

    /// The winner's line, handed on.
    private func say(_ line: Line) {
        words += line.words
        onEvent(.line(line.segment))
    }

    /// A shadow's line goes into the record while it stands in for a winner
    /// the notes writer cannot read.
    private func shadowLine(_ segment: MeetingSegment, from take: Take) {
        guard let winner, !canRead(winner.id), canRead(take.id) else { return }
        onEvent(.shadow(MeetingShadowLine(segment: segment, language: take.id)))
    }

    // MARK: - Words being heard

    /// A running guess from `take`, replacing its last one.
    private func guessed(_ text: String, in take: Take) {
        guard liveTakes.contains(where: { $0 === take }) else { return }
        take.guess = text
        showHearing()
    }

    /// Tells the screen what is being said: the winner's words past its
    /// lines, or before the race is decided the held lines and words of the
    /// take that is understanding it best (`shownTake`). Only a change is
    /// told.
    private func showHearing() {
        guard let onHearing else { return }
        let text: String
        if let winner {
            text = unfinished(of: winner)
        } else if let shown = shownTake() {
            text = CallLive.inProgress(held: shown.held.map(\.segment.text), guess: unfinished(of: shown))
        } else {
            text = ""
        }
        guard text != lastHeard else { return }
        lastHeard = text
        onHearing(text)
    }

    /// What `take` is heard saying past its finished lines: its quick
    /// recogniser's words, or its own guess where it has none.
    private func unfinished(of take: Take) -> String {
        guard let quick = take.quick else { return take.guess }
        return CallLive.unfinished(said: quick.said, guess: quick.guess, guessStart: quick.guessStart,
                                   finished: take.recent, through: take.through)
    }

    /// The take the screen follows before the race is decided: the
    /// primary, until another one's words read as its language and the
    /// primary's do not (`CallLanguageFollow.shown`). It used to be the
    /// primary throughout, so Spanish spoken with English first showed the
    /// English recogniser's attempt at it until the race was called, which
    /// in a short meeting is the end.
    private func shownTake() -> Take? {
        guard let primary = racing.first else { return nil }
        guard racing.count > 1 else { return primary }
        let choice = CallLanguageFollow.shown(racing.map { take in
            (take.id, take.code, CallLive.inProgress(held: take.held.map(\.segment.text), guess: unfinished(of: take)))
        }, showing: showing)
        if choice != showing {
            log("\(speaker.rawValue) live words → \(choice)")
            showing = choice
        }
        return racing.first { $0.id == showing } ?? primary
    }

    // MARK: - The race

    /// Calls the race on what has been heard so far and hands the winner's
    /// lines on. Called early, or at the end for a call too short to reach it.
    private func decide() {
        guard winner == nil, let primary = racing.first else { return }
        let chosen: Take
        if Set(racing.map(\.listener.module)) == [.speech] {
            let candidates = racing.map {
                TranscriptRace.Candidate(localeIdentifier: $0.id,
                                         text: $0.held.map(\.segment.text).joined(separator: " "),
                                         confidence: Self.confidence(of: $0.held) ?? 0)
            }
            let winnerID = TranscriptRace.winner(among: candidates, primary: primary.id)?.localeIdentifier
            chosen = racing.first { $0.id == winnerID } ?? primary
        } else {
            // Recognisers of two kinds score on two scales: the follow's rule,
            // which knows both.
            chosen = racing.dropFirst().first {
                CallLanguageFollow.confirms(challenger: Self.hearing(of: $0), incumbent: Self.hearing(of: primary))
            } ?? primary
        }
        winner = chosen
        since = offset
        languages = [chosen.id]
        if racing.count > 1 {
            log("\(speaker.rawValue) language → \(chosen.id) " + racing
                .map { "\($0.id) \(Self.describe(Self.hearing(of: $0)))" }
                .joined(separator: " · "))
        }
        onEvent(.listening(from: offset, language: chosen.id))

        // Kept beside a winner the notes writer cannot read: the first
        // runner-up it can.
        if !canRead(chosen.id) {
            shadow = racing.first { $0 !== chosen && canRead($0.id) }
        }
        for take in racing {
            for line in take.held {
                take.remember(line, reading: CallLanguageFollow.language(of: line.segment.text, among: listeners.codes))
                if take === chosen {
                    say(line)
                } else if take === shadow {
                    shadowLine(line.segment, from: take)
                }
            }
            take.held = []
        }
        for take in racing where take !== chosen && take !== shadow { drop(take) }
        if let shadow { stopQuick(shadow) }
        racing = []
        // The held lines are lines now: only the winner's guess is left.
        showHearing()
    }

    private static func confidence(of lines: [Line]) -> Double? {
        let scored = lines.reduce(0) { $0 + $1.scored }
        return scored > 0 ? lines.reduce(0) { $0 + $1.weighted } / Double(scored) : nil
    }

    private static func hearing(of take: Take) -> CallLanguageFollow.Hearing {
        CallLanguageFollow.Hearing(module: take.listener.module,
                                   words: take.held.reduce(0) { $0 + CallLanguageFollow.words(in: $1.segment.text) },
                                   confidence: confidence(of: take.held))
    }

    /// "0.82 310w", or "– 304w" with no confidence: numbers only, for the log.
    private static func describe(_ hearing: CallLanguageFollow.Hearing) -> String {
        (hearing.confidence.map { String(format: "%.2f", $0) } ?? "–") + " \(hearing.words)w"
    }

    // MARK: - Following

    /// Seconds into the meeting of the live audio.
    private var now: TimeInterval { offset + tee.passed }

    /// After every line: judge a challenger on trial, or start one when the
    /// winner's lines lean to another language.
    private func review() {
        guard !ended, let winner else { return }
        if let challenge {
            judge(challenge)
            return
        }
        // Back to the shadow's language: its own lines say so, or the
        // winner's do. It is listening already, so nothing is replayed.
        if let shadow, refusals.allows(shadow.code, at: now),
           winner.watch.other == shadow.code
            || CallLanguageFollow.shadowSaysBack(shadow.watch, winner: winner.code) {
            let seam = CallLanguageFollow.seamFromOwnLines(shadow.heard.map { ($0.segment.start, $0.language) },
                                                           winner: winner.code, after: since)
                .map { CallLanguageFollow.snap($0, to: winner.heard.map { ($0.segment.start, $0.segment.end) }) }
                ?? CallLanguageFollow.seam(watch: winner.watch, language: shadow.code,
                                           lineStarts: shadow.heard.map(\.segment.start),
                                           replayFrom: now - CallLanguageFollow.replay)
            guard let seam else { return }
            log("\(speaker.rawValue) language watch: \(shadow.code) \(winner.watch.count(of: shadow.code))/"
                + "\(winner.watch.lines.count) lines → challenger \(shadow.id) (\(shadow.listener.module.rawValue), "
                + "already listening)")
            self.challenge = Challenge(take: shadow, seam: seam)
            judge(self.challenge!)
            return
        }
        guard let other = winner.watch.other, refusals.allows(other, at: now), !preparing.contains(other)
        else { return }
        guard let listener = CallLanguageFollow.listener(for: other, speech: listeners.speech,
                                                         dictation: listeners.dictation,
                                                         near: [winner.id, Locale.current.identifier])
        else {
            refusals.refuse(other, at: now)
            return
        }
        follow(other, with: listener)
    }

    /// Makes `listener` ready, downloading its model in the background when
    /// it is missing, then starts it as a challenger if the winner still
    /// leans to its language.
    private func follow(_ code: String, with listener: CallLanguageFollow.Listener) {
        preparing.insert(code)
        Task { [weak self] in
            var ready = await CallListening.format(for: [listener])
            if ready == nil {
                self?.log("model download \(listener.identifier) started")
                let started = Date()
                if await CallListening.prepare(listener) {
                    ready = await CallListening.format(for: [listener])
                }
                self?.log(ready == nil
                          ? "model download \(listener.identifier) failed"
                          : String(format: "model download %@ finished in %.0fs", listener.identifier,
                                   Date().timeIntervalSince(started)))
            }
            guard let self else { return }
            self.preparing.remove(code)
            guard !self.ended, self.challenge == nil, let winner = self.winner,
                  winner.watch.count(of: code) >= CallLanguageFollow.Watch.enough else { return }
            guard let ready, let format = self.format, ready == format else {
                if ready != nil {
                    self.log("\(self.speaker.rawValue) challenger \(listener.identifier) needs another audio format → refused")
                }
                self.refusals.refuse(code, at: self.now)
                return
            }
            self.challenge(in: listener, code: code, against: winner)
        }
    }

    private func challenge(in listener: CallLanguageFollow.Listener, code: String, against winner: Take) {
        guard let seam = CallLanguageFollow.seam(watch: winner.watch, language: code,
                                                 lineStarts: winner.heard.map(\.segment.start),
                                                 replayFrom: offset + tee.oldest)
        else {
            refusals.refuse(code, at: now)
            return
        }
        log("\(speaker.rawValue) language watch: \(code) \(winner.watch.count(of: code))/\(winner.watch.lines.count) "
            + "lines → challenger \(listener.identifier) (\(listener.module.rawValue))")
        let module = CallListening.module(for: listener, partials: partials(for: listener))
        let placing = CallLanguageFollow.challengerPlacesTheSeam(challenger: listener.module,
                                                                 winner: winner.listener.module)
        let from = placing ? min(seam, max(since, offset + tee.oldest)) : seam
        let lane = open(from: from - offset, modules: [module])
        let take = Take(listener: listener, module: module, lane: lane)
        pump(take)
        challenge = Challenge(take: take, seam: seam, placesFrom: placing ? from : nil)
    }

    /// Compares a challenger with the winner once it has heard enough past
    /// the seam, over the same stretch; refuses it when it has not heard
    /// enough in time. `final` at the end of the call: what is there is
    /// compared, however little.
    private func judge(_ trial: Challenge, final: Bool = false) {
        guard let winner else { return }
        var trial = trial
        let take = trial.take
        if let from = trial.placesFrom, final || (take.heardThrough ?? 0) >= trial.seam {
            trial.seam = CallLanguageFollow.seamFromOwnLines(take.heard.map { ($0.segment.start, $0.language) },
                                                             winner: winner.code, after: from)
                .map { CallLanguageFollow.snap($0, to: winner.heard.map { ($0.segment.start, $0.segment.end) }) }
                ?? trial.seam
            trial.placesFrom = nil
            challenge = trial
        }
        let past = trial.placesFrom != nil ? []
            : take.heard.filter { $0.segment.start >= trial.seam - Self.seamSlack }
        if trial.until == nil,
           past.reduce(0, { $0 + $1.segment.text.count }) >= CallLanguageFollow.compareAfter || (final && !past.isEmpty) {
            trial.until = past.last.map { $0.segment.end }
            challenge = trial
        }
        guard let until = trial.until else {
            if final || now - trial.seam > CallLanguageFollow.giveUpAfter {
                refuse(trial, mine: take.hearing(from: trial.seam, until: now), theirs: nil)
            }
            return
        }
        // The winner gets its chance at the same stretch: dictation delivers late.
        guard final || (winner.heardThrough ?? 0) >= until || now >= until + Self.incumbentWait else { return }
        let mine = take.hearing(from: trial.seam, until: until)
        let theirs = winner.hearing(from: trial.seam, until: until)
        if CallLanguageFollow.confirms(challenger: mine, incumbent: theirs) {
            switchTo(trial, mine: mine, theirs: theirs)
        } else {
            refuse(trial, mine: mine, theirs: theirs)
        }
    }

    private func refuse(_ trial: Challenge, mine: CallLanguageFollow.Hearing, theirs: CallLanguageFollow.Hearing?) {
        let against = theirs.map { "\(winner?.id ?? "?") \(Self.describe($0))" }
            ?? "too little in \(Int(CallLanguageFollow.giveUpAfter))s"
        log("\(speaker.rawValue) challenger \(trial.take.id) \(Self.describe(mine)) vs \(against) → refused")
        refusals.refuse(trial.take.code, at: now)
        if trial.take !== shadow { drop(trial.take) }
        challenge = nil
    }

    private func switchTo(_ trial: Challenge, mine: CallLanguageFollow.Hearing,
                          theirs: CallLanguageFollow.Hearing) {
        guard let old = winner else { return }
        let new = trial.take
        let seam = trial.seam
        let replacing = new.heard.filter { $0.segment.start >= seam - Self.seamSlack }
        words.removeAll { ($0.start ?? 0) >= seam - Self.seamSlack }
        words += replacing.flatMap(\.words)
        let lines = replacing.map { line in
            var segment = line.segment
            segment.start = max(segment.start, seam)
            segment.end = max(segment.end, segment.start)
            return segment
        }
        let readable = canRead(new.id)
        // Beside the new winner: the one it replaced, unless that one can't
        // be read either and the old shadow can.
        var kept: Take? = old
        if new !== shadow, !readable, !canRead(old.id), let shadow, canRead(shadow.id) { kept = shadow }
        for take in [old, shadow].compactMap({ $0 }) where take !== kept && take !== new { drop(take) }
        stopQuick(old)
        if new.quick == nil { quicken([new], from: tee.passed) }
        winner = new
        shadow = kept
        challenge = nil
        since = seam
        for take in [new, kept].compactMap({ $0 }) { take.watch.forget(before: seam) }
        if !languages.contains(new.id) { languages.append(new.id) }
        log("\(speaker.rawValue) challenger \(new.id) \(Self.describe(mine)) vs \(old.id) \(Self.describe(theirs)) "
            + "→ switched at \(MeetingFiles.clock(seam))")
        onEvent(.switched(seam: seam, language: new.id, lines: lines,
                          keptAs: !readable && canRead(old.id) ? old.id : nil))
        showHearing()
    }

    // MARK: - Ending

    /// Waits for the last sentence, within `limit`. The input stream must have
    /// ended first (see `SpeechSession.finish`: the finalize waits on it).
    func finish(within limit: Duration = .seconds(15)) async {
        // A take started now would be fed the replay and never finalized.
        ended = true
        if !(await settles(within: limit)) {
            log("\(speaker.rawValue) track finish TIMED OUT after \(limit)")
            for take in liveTakes { take.pump?.cancel() }
            let stuck = lanes.map(\.analyzer)
            Task { for analyzer in stuck { await analyzer.cancelAndFinishNow() } }
        }
        // A call too short to decide during still gets its lines, and a
        // challenger still on trial is judged on what it heard.
        decide()
        if let challenge { judge(challenge, final: true) }
        close()
    }

    /// Stop without waiting for anything.
    func abandon() async {
        ended = true
        for take in liveTakes { take.pump?.cancel() }
        let analyzers = lanes.map(\.analyzer)
        close()
        for analyzer in analyzers { await analyzer.cancelAndFinishNow() }
    }

    private func close() {
        // Every quick recogniser at once, not one by one: each would ask a
        // shared analyzer to carry on without it.
        var quickLanes: [Lane] = []
        for take in liveTakes {
            guard let quick = take.quick else { continue }
            take.quick = nil
            quick.pump?.cancel()
            if !quickLanes.contains(where: { $0 === quick.lane }) { quickLanes.append(quick.lane) }
        }
        for lane in quickLanes { Task { await lane.analyzer.cancelAndFinishNow() } }
        feeding?.cancel()
        feeding = nil
        tee.end()
        racing = []
        winner = nil
        shadow = nil
        challenge = nil
        lanes = []
        showHearing()
    }

    private var liveTakes: [Take] {
        racing + [winner, shadow, challenge?.take].compactMap { $0 }
    }

    /// The same one-shot race as `SpeechSession.settles`: a task group would
    /// wait for the hung loser at scope exit.
    private func settles(within limit: Duration) async -> Bool {
        let (signal, done) = AsyncStream<Void>.makeStream()
        Task { @MainActor [weak self] in
            await self?.drain()
            done.yield()
            done.finish()
        }
        Task {
            try? await Task.sleep(for: limit)
            done.finish()
        }
        for await _ in signal { return true }
        return false
    }

    private func drain() async {
        for lane in lanes {
            do {
                try await lane.analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                log("\(speaker.rawValue) finalize: \(error.localizedDescription)")
            }
        }
        // A dropped take's results may never end; only the live ones are
        // waited for.
        for take in liveTakes { await take.pump?.value }
    }
}
