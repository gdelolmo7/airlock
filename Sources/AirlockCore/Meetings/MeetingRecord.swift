import Foundation

/// Who said a line in a call transcript.
///
/// Known from WHERE the words came from, never guessed from a voice: the
/// microphone is you, and the call app's own sound is everyone else. The two
/// are recorded as separate tracks and never mixed, which is what makes this
/// certain rather than a model's opinion. "Them" can be several people. When
/// the voice model is on they are told apart as Person 1, Person 2…, by voice
/// within one call and never by name (`MeetingSegment.person`, `CallVoices`):
/// a wrong name is worse than none. A call the calendar says was with one
/// person is the exception: the other side can only be them
/// (`MeetingRecord.label(for:)`). Notes of a meeting in person have no
/// "you" side: the one microphone hears the whole room, so every line is
/// "them" and is told apart by voice like a call's (`isInPerson`).
public enum MeetingSpeaker: String, Codable, Sendable {
    case me
    case them

    public var label: String { self == .me ? "You" : "Them" }
}

/// One finished stretch of speech, as the recogniser delivered it.
public struct MeetingSegment: Codable, Equatable, Sendable {
    public var speaker: MeetingSpeaker
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// Which voice on the other side said it, numbered from 1 in the order
    /// they first spoke, in this call only. Nil for "You", for a call heard
    /// as one voice, and for every call before the voice model (an older
    /// `meeting.json` has no key, and decodes as nil).
    public var person: Int?

    public init(speaker: MeetingSpeaker, start: TimeInterval, end: TimeInterval, text: String,
                person: Int? = nil) {
        self.speaker = speaker
        self.start = start
        self.end = max(start, end)
        self.text = text
        self.person = person
    }
}

/// A line the person typed during the call. Theirs, word for word: it is
/// shown as they wrote it, and it tells the notes what mattered to them.
public struct MeetingJot: Codable, Equatable, Sendable {
    /// Seconds from the start of the meeting.
    public var at: TimeInterval
    public var text: String

    public init(at: TimeInterval, text: String) {
        self.at = at
        self.text = text
    }
}

/// A stretch of the call the notes were paused for. Nothing said in it is
/// written down, and the transcript says where the gap is so it does not
/// read as silence.
public struct MeetingPause: Codable, Equatable, Sendable {
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    /// Nil while still paused.
    public var end: TimeInterval?

    public init(start: TimeInterval, end: TimeInterval? = nil) {
        self.start = start
        self.end = end.map { max(start, $0) }
    }
}

/// Which language one side of a call was listened in, from when.
///
/// One when a side settles its language, and one more each time it follows
/// the call into another (`CallLanguageFollow`). What the transcript's
/// "Catalan from 10:12" divider is drawn from, and what tells the notes which
/// stretches are in a language their writer cannot read.
public struct MeetingListening: Codable, Equatable, Sendable {
    public var speaker: MeetingSpeaker
    /// Seconds from the start of the meeting.
    public var from: TimeInterval
    /// A locale identifier, "ca_ES".
    public var language: String

    public init(speaker: MeetingSpeaker, from: TimeInterval, language: String) {
        self.speaker = speaker
        self.from = from
        self.language = language
    }
}

/// A line heard by the take a side switched away from, kept while the one
/// shown is in a language Apple's notes writer cannot read, so the notes
/// can be written from it instead. Never shown in the transcript.
public struct MeetingShadowLine: Codable, Equatable, Sendable {
    public var segment: MeetingSegment
    /// The locale the shadow listened in, "es_ES".
    public var language: String

    public init(segment: MeetingSegment, language: String) {
        self.segment = segment
        self.language = language
    }
}

/// A name the person gave one voice once the meeting was over: "Person 2"
/// is Ana, or, in the room, "Person 2" is me. Given by hand, never guessed:
/// a wrong name is worse than none, so the app only ever suggests one.
public struct MeetingVoiceName: Codable, Equatable, Sendable {
    /// The voice: its person number, or `MeetingRecord.otherSide` for the
    /// other side of a call heard as one voice.
    public var voice: Int
    /// What they are called, "Ana". Empty when `isYou`.
    public var name: String
    /// "That's me": in the room, the voice of the person the notes are for.
    public var isYou: Bool

    public init(voice: Int, name: String, isYou: Bool = false) {
        self.voice = voice
        self.name = isYou ? "" : name
        self.isYou = isYou
    }
}

/// The calendar event a call belongs to, as far as the notes need it: the
/// name people know the meeting by, and who else was invited.
public struct MeetingEvent: Codable, Equatable, Sendable {
    public var title: String
    public var start: Date
    /// The OTHER people on the invite, by display name. Never you: a call
    /// with one name here is a call with that one person.
    public var attendees: [String]

    public init(title: String, start: Date, attendees: [String] = []) {
        self.title = title
        self.start = start
        self.attendees = attendees
    }

    /// The other person's name on a one-to-one call, else nil.
    public var oneToOne: String? {
        guard attendees.count == 1 else { return nil }
        let name = attendees[0].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The title, when it says anything.
    public var name: String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}

/// The recording a meeting's notes were written from, when they were not
/// heard live: a voice memo or a voice note added afterwards
/// (`RecordingImport`). The sound itself is never copied or kept; this is
/// what is known of it.
public struct MeetingRecording: Codable, Equatable, Sendable {
    /// The file's name as it was, "Kitchen planning.m4a".
    public var fileName: String
    /// How long the recording is, in seconds.
    public var seconds: TimeInterval

    public init(fileName: String, seconds: TimeInterval) {
        self.fileName = fileName
        self.seconds = max(0, seconds)
    }

    /// The meeting's name, from the file's (`RecordingImport.title`).
    public var title: String { RecordingImport.title(forFile: fileName) }
}

/// Who wrote a meeting's notes: the Mac's own model, or a larger one online
/// (`CloudNotes`), and whether notes the Mac wrote while offline still wait
/// to be written online (`CloudNotesRedo`).
///
/// Kept only while notes online are switched on at all; every other
/// meeting has none, and its `meeting.json` is what it always was.
public struct MeetingNotesWriter: Codable, Equatable, Sendable {
    public enum Place: String, Codable, Sendable {
        case mac
        case online
    }

    /// The name kept for the Mac's own model.
    public static let macModel = "apple-on-device"

    public var place: Place
    /// The model that wrote them: the server's name for it when online.
    public var model: String?
    public var writtenAt: Date
    /// Written on the Mac while it was offline: to be written online once it
    /// is back. The page says so (`MeetingFiles.offlineLine`).
    public var waitsForOnline: Bool
    /// How many times writing them online again was tried.
    public var onlineTries: Int

    public init(place: Place, model: String?, writtenAt: Date, waitsForOnline: Bool = false,
                onlineTries: Int = 0) {
        self.place = place
        self.model = model
        self.writtenAt = writtenAt
        self.waitsForOnline = waitsForOnline
        self.onlineTries = max(0, onlineTries)
    }

    public static func mac(at date: Date, waitsForOnline: Bool = false) -> MeetingNotesWriter {
        MeetingNotesWriter(place: .mac, model: macModel, writtenAt: date, waitsForOnline: waitsForOnline)
    }

    public static func online(model: String?, at date: Date) -> MeetingNotesWriter {
        MeetingNotesWriter(place: .online, model: model, writtenAt: date)
    }

    /// Fields missing from an older file read as nothing waiting.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(place: try container.decode(Place.self, forKey: .place),
                  model: try container.decodeIfPresent(String.self, forKey: .model),
                  writtenAt: try container.decode(Date.self, forKey: .writtenAt),
                  waitsForOnline: try container.decodeIfPresent(Bool.self, forKey: .waitsForOnline) ?? false,
                  onlineTries: try container.decodeIfPresent(Int.self, forKey: .onlineTries) ?? 0)
    }
}

/// Everything known about one call's notes: which app, when, and what was said.
///
/// Text only, on purpose (the owner, 2026-10-08): no audio is ever written to
/// disk. That makes this record the whole of what is kept, and the reason it is
/// rewritten after every segment — a crash or a quit mid-call loses at most
/// the sentence in flight, not the meeting.
public struct MeetingRecord: Codable, Equatable, Sendable {
    public var bundleID: String
    public var appName: String
    public var site: MeetingLink.Provider?
    public var startedAt: Date
    /// Nil while notes are still being taken.
    public var endedAt: Date?
    /// When the call ended too short to keep (`MeetingNotesFlow.shortestKept`).
    /// The folder is removed once the call has had its chance to come back
    /// (`sameMeetingWindow`), and until then nothing lists it. Nil for every
    /// call that is kept, and cleared if this one carries on.
    public var droppedAt: Date?
    /// The recogniser languages that produced the text, for the record.
    public var languages: [String]
    /// In order of when they were said, whichever track they came from.
    public private(set) var segments: [MeetingSegment]
    /// The calendar event the call was found to belong to, if any. Copied in
    /// when the notes start and kept with them, so the notes stay named after
    /// the meeting whatever the calendar says later.
    public var event: MeetingEvent?
    /// Lines typed during the call, in time order.
    public private(set) var jots: [MeetingJot]
    /// Moments the person flagged as important, in time order. Each one
    /// covers the half-minute before it (`markReach`): by the time somebody
    /// reaches for the button, the thing worth keeping has just been said.
    public private(set) var marks: [TimeInterval]
    /// When the notes were paused, in time order. Only the last can be open.
    public private(set) var pauses: [MeetingPause]
    /// Which language each side was listened in, from when, in time order.
    public private(set) var listenings: [MeetingListening]
    /// What the other listening heard while a side was in a language the
    /// notes writer cannot read, in time order (`MeetingShadowLine`).
    public private(set) var shadow: [MeetingShadowLine]
    /// The names given to voices after the meeting, one per voice, in the
    /// order they were given (`name(_:as:)`).
    public private(set) var names: [MeetingVoiceName]
    /// The recording the notes were written from, for a meeting added from
    /// one rather than heard live; nil for every other. A recording is read
    /// as a meeting in the room (`isInPerson`), and `endedAt` stays nil
    /// until every second of it has been heard.
    public var recording: MeetingRecording?
    /// Who wrote the notes, while notes online are switched on
    /// (`MeetingNotesWriter`); nil otherwise, and on every older meeting.
    public var notesWriter: MeetingNotesWriter?

    public init(bundleID: String, appName: String, site: MeetingLink.Provider? = nil,
                startedAt: Date, endedAt: Date? = nil, languages: [String] = [],
                segments: [MeetingSegment] = [], event: MeetingEvent? = nil,
                jots: [MeetingJot] = [], marks: [TimeInterval] = [], pauses: [MeetingPause] = [],
                listenings: [MeetingListening] = [], shadow: [MeetingShadowLine] = [],
                droppedAt: Date? = nil, names: [MeetingVoiceName] = [],
                recording: MeetingRecording? = nil, notesWriter: MeetingNotesWriter? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.site = site
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.droppedAt = droppedAt
        self.languages = languages
        self.segments = segments.sorted { $0.start < $1.start }
        self.event = event
        self.jots = jots.sorted { $0.at < $1.at }
        self.marks = marks.sorted()
        self.pauses = pauses.sorted { $0.start < $1.start }
        self.listenings = listenings.sorted { $0.from < $1.from }
        self.shadow = shadow.sorted { $0.segment.start < $1.segment.start }
        self.recording = recording
        self.notesWriter = notesWriter
        self.names = []
        for name in names { self.name(name.voice, as: name.isYou ? nil : name.name, isYou: name.isYou) }
    }

    /// A `meeting.json` written before events, jots, marks, pauses,
    /// listenings, the shadow, names and recordings existed has none of
    /// their keys. It still opens, with all of them empty: those files are
    /// calls somebody had, and an update must not lose them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bundleID: try container.decode(String.self, forKey: .bundleID),
            appName: try container.decode(String.self, forKey: .appName),
            site: try container.decodeIfPresent(MeetingLink.Provider.self, forKey: .site),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            endedAt: try container.decodeIfPresent(Date.self, forKey: .endedAt),
            languages: try container.decodeIfPresent([String].self, forKey: .languages) ?? [],
            segments: try container.decodeIfPresent([MeetingSegment].self, forKey: .segments) ?? [],
            event: try container.decodeIfPresent(MeetingEvent.self, forKey: .event),
            jots: try container.decodeIfPresent([MeetingJot].self, forKey: .jots) ?? [],
            marks: try container.decodeIfPresent([TimeInterval].self, forKey: .marks) ?? [],
            pauses: try container.decodeIfPresent([MeetingPause].self, forKey: .pauses) ?? [],
            listenings: try container.decodeIfPresent([MeetingListening].self, forKey: .listenings) ?? [],
            shadow: try container.decodeIfPresent([MeetingShadowLine].self, forKey: .shadow) ?? [],
            droppedAt: try container.decodeIfPresent(Date.self, forKey: .droppedAt),
            names: try container.decodeIfPresent([MeetingVoiceName].self, forKey: .names) ?? [],
            recording: try container.decodeIfPresent(MeetingRecording.self, forKey: .recording),
            notesWriter: try container.decodeIfPresent(MeetingNotesWriter.self, forKey: .notesWriter))
    }

    /// The name people know the call by: the meeting service when the call is
    /// in a browser tab, the app otherwise.
    public var callName: String { site?.displayName ?? appName }

    /// Inserted in time order. The two tracks finish their sentences at
    /// different moments, so arrival order is not speaking order.
    public mutating func add(_ segment: MeetingSegment) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var clean = segment
        clean.text = text
        let index = segments.lastIndex { $0.start <= clean.start }.map { $0 + 1 } ?? 0
        segments.insert(clean, at: index)
    }

    public var isEmpty: Bool { segments.isEmpty }

    /// The same call with other lines, for what is written from it rather
    /// than shown (`MeetingNotesSource`).
    mutating func replaceSegments(with segments: [MeetingSegment]) {
        self.segments = segments.sorted { $0.start < $1.start }
    }

    /// The shadow with other lines (`CallVoices`, which numbers its voices).
    mutating func replaceShadow(with shadow: [MeetingShadowLine]) {
        self.shadow = shadow.sorted { $0.segment.start < $1.segment.start }
    }

    /// What the transcript and the summary read: every segment the microphone
    /// heard only because the speakers were playing it is gone.
    public var spokenSegments: [MeetingSegment] { MeetingEcho.removingEchoes(from: segments) }

    /// Seconds from start to end, or to `now` while still running.
    public func duration(at now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    // MARK: - Who the other side is

    /// Notes started by hand with no call (`OngoingCall.inPerson`): the
    /// microphone heard everyone in the room, you among them. Every line is
    /// on the "them" side, so the voices are told apart like a call's other
    /// side, and nothing is ever "You": which voice is yours is not known.
    public var isInPerson: Bool { bundleID == OngoingCall.inPersonBundleID }

    /// The other person's name when the calendar says the call was with one
    /// person, else nil. Only then is "Them" certainly one person; with two
    /// or more on the invite, any one name could be the wrong one. Never in
    /// person: the room's one microphone heard you as well as them.
    public var otherName: String? { isInPerson ? nil : event?.oneToOne }

    /// What a speaker is called in the transcript: "You", or the other
    /// person's name on a one-to-one call, or the name given to the other
    /// side (`names`). In person, a line no voice was given to is "Someone",
    /// or the name given to the room when it was one voice (`isOneVoiceRoom`).
    public func label(for speaker: MeetingSpeaker) -> String {
        if speaker == .them, let named = givenLabel(of: Self.otherSide), !isInPerson || isOneVoiceRoom {
            return named
        }
        return unnamedLabel(for: speaker)
    }

    /// What the speaker of `segment` is called: as `label(for:)`, except
    /// that on a call with several voices told apart each is "Person 2",
    /// or the name given to that voice. The calendar's one name wins over
    /// the voices: a one-to-one call is never split.
    public func label(for segment: MeetingSegment) -> String {
        if !names.isEmpty, let voice = voice(of: segment), let named = givenLabel(of: voice) { return named }
        return voiceLabel(for: segment)
    }

    /// `label(for:)` without the names given after the meeting: "Person 2".
    /// What the notes writer reads, so the notes are written the same way
    /// whatever anyone was called, and the names are put in afterwards
    /// (`MeetingNaming`), where they can be changed again.
    public func voiceLabel(for segment: MeetingSegment) -> String {
        guard segment.speaker == .them, otherName == nil, let person = segment.person else {
            return unnamedLabel(for: segment.speaker)
        }
        return Self.personLabel(person)
    }

    private func unnamedLabel(for speaker: MeetingSpeaker) -> String {
        if isInPerson { return Self.someone }
        return speaker == .me ? speaker.label : (otherName ?? speaker.label)
    }

    public static func personLabel(_ person: Int) -> String { "Person \(person)" }

    /// Whoever said a line in a meeting in person, when the voices were not
    /// told apart: never "You", which may be wrong.
    public static let someone = "Someone"

    /// The highest person number given so far, 0 when none: a call that
    /// drops and carries on numbers its new voices after these, since
    /// nothing says the voices are the same ones.
    public var lastPerson: Int { segments.compactMap(\.person).max() ?? 0 }

    // MARK: - Names given after the meeting

    /// The voice a name for the other side of a call heard as one voice is
    /// given to. Person numbers start at 1, so it is never one of theirs.
    public static let otherSide = 0

    /// Which voice said `segment`, as far as one can be named: its person
    /// number, or `otherSide` on a call whose other side is one voice (a
    /// one-to-one call always is), and in a room that was one voice. Nil for
    /// your own lines, and in person for a line no voice was given to when
    /// others were: that "Someone" is anyone in the room.
    public func voice(of segment: MeetingSegment) -> Int? {
        voice(of: segment, oneVoiceRoom: isOneVoiceRoom)
    }

    private func voice(of segment: MeetingSegment, oneVoiceRoom: @autoclosure () -> Bool) -> Int? {
        guard segment.speaker == .them else { return nil }
        if otherName == nil, let person = segment.person { return person }
        guard isInPerson else { return Self.otherSide }
        return oneVoiceRoom() ? Self.otherSide : nil
    }

    /// A meeting in the room where no voices were told apart: Airlock heard
    /// one voice, as when somebody takes notes alone, or could not tell them
    /// apart. Every line is then the one voice `otherSide`, which can be
    /// named, or be "That's me", as the other side of a call heard as one
    /// voice can. Until then each line is still "Someone".
    public var isOneVoiceRoom: Bool { isInPerson && !segments.contains { $0.person != nil } }

    /// Every voice that can be named, in the order first heard.
    public var voices: [Int] {
        let room = isOneVoiceRoom
        var heard: [Int] = []
        for segment in spokenSegments {
            if let voice = voice(of: segment, oneVoiceRoom: room), !heard.contains(voice) { heard.append(voice) }
        }
        return heard
    }

    /// The name given to `voice`, if any.
    public func givenName(of voice: Int) -> MeetingVoiceName? {
        names.first { $0.voice == voice }
    }

    /// What a named voice is called: its name, or "You" for "That's me".
    /// Nil while it has no name.
    public func givenLabel(of voice: Int) -> String? {
        givenName(of: voice).map { $0.isYou ? MeetingSpeaker.me.label : $0.name }
    }

    /// Names `voice`, or with `isYou` says it is the person the notes are
    /// for (only ever in the room: on a call your side is your microphone).
    /// A blank name with no `isYou` takes the name away, back to "Person 2".
    public mutating func name(_ voice: Int, as name: String?, isYou: Bool = false) {
        let name = MeetingText.oneLine(name ?? "")
        let you = isYou && isInPerson
        names.removeAll { $0.voice == voice }
        guard you || !name.isEmpty else { return }
        names.append(MeetingVoiceName(voice: voice, name: name, isYou: you))
    }

    /// Every voice named as `names` says, and any voice they leave out
    /// back to its number.
    public mutating func replaceNames(with names: [MeetingVoiceName]) {
        self.names = []
        for given in names { name(given.voice, as: given.name, isYou: given.isYou) }
    }

    // MARK: - Jots, marks and pauses

    /// A line typed during the call, kept in time order. Blank is ignored.
    public mutating func jot(_ text: String, at: TimeInterval) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let index = jots.lastIndex { $0.at <= at }.map { $0 + 1 } ?? 0
        jots.insert(MeetingJot(at: at, text: text), at: index)
    }

    /// "That was important": the half-minute up to `at` is marked.
    public mutating func mark(at: TimeInterval) {
        let index = marks.lastIndex { $0 <= at }.map { $0 + 1 } ?? 0
        marks.insert(at, at: index)
    }

    /// How far back a mark reaches.
    public static let markReach: TimeInterval = 30

    /// Whether a stretch of speech falls within any mark's reach.
    public func isMarked(_ segment: MeetingSegment) -> Bool {
        marks.contains { mark in segment.start <= mark && segment.end >= mark - Self.markReach }
    }

    /// Opens a pause. A second pause while one is open changes nothing.
    public mutating func pause(at: TimeInterval) {
        guard !isPaused else { return }
        pauses.append(MeetingPause(start: max(at, pauses.last?.end ?? at)))
    }

    /// Closes the open pause, if there is one.
    public mutating func resume(at: TimeInterval) {
        guard isPaused, let last = pauses.indices.last else { return }
        pauses[last].end = max(pauses[last].start, at)
    }

    public var isPaused: Bool { pauses.last.map { $0.end == nil } ?? false }

    /// Brings the saved pauses in line with the notes: `pausedSince` is when
    /// the notes were paused, nil while they are written down (or once they
    /// have ended). A pause the record has not got yet opens where the notes'
    /// pause began; a pause the notes no longer have closes at `now`, which
    /// is also how notes that end while paused close their last pause.
    /// Returns whether anything changed, so the caller knows to save.
    @discardableResult
    public mutating func followPause(since pausedSince: Date?, now: Date) -> Bool {
        switch (pausedSince, isPaused) {
        case let (since?, false):
            pause(at: max(0, since.timeIntervalSince(startedAt)))
            return true
        case (nil, true):
            resume(at: max(0, now.timeIntervalSince(startedAt)))
            return true
        default:
            return false
        }
    }

    // MARK: - Languages

    /// One side is listened in `language` from `from` on. The same language
    /// again is no change; a listening already recorded at or after `from`
    /// is replaced, since what was heard there is being replaced too.
    public mutating func listen(_ speaker: MeetingSpeaker, from: TimeInterval, in language: String) {
        listenings.removeAll { $0.speaker == speaker && $0.from >= from }
        if listenings.last(where: { $0.speaker == speaker })?.language == language { return }
        let index = listenings.lastIndex { $0.from <= from }.map { $0 + 1 } ?? 0
        listenings.insert(MeetingListening(speaker: speaker, from: from, language: language), at: index)
    }

    /// A line from the other listening, in time order. Blank is ignored.
    public mutating func addShadow(_ line: MeetingShadowLine) {
        var line = line
        line.segment.text = line.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.segment.text.isEmpty else { return }
        let index = shadow.lastIndex { $0.segment.start <= line.segment.start }.map { $0 + 1 } ?? 0
        shadow.insert(line, at: index)
    }

    /// One side followed the call into `language` from `seam` on: what it
    /// said from there is replaced by `lines`, heard in that language.
    ///
    /// `keptAs` names the language the replaced lines were heard in when
    /// they are to be kept as the shadow, which is when `language` is one the
    /// notes writer cannot read. Shadow lines from the seam on go either way:
    /// they were the other listening of a stretch that now has a new one.
    public mutating func switchLanguage(of speaker: MeetingSpeaker, at seam: TimeInterval,
                                        to language: String, lines: [MeetingSegment],
                                        keptAs replaced: String? = nil) {
        let removed = segments.filter { $0.speaker == speaker && $0.start >= seam }
        segments.removeAll { $0.speaker == speaker && $0.start >= seam }
        shadow.removeAll { $0.segment.speaker == speaker && $0.segment.start >= seam }
        if let replaced {
            for segment in removed { addShadow(MeetingShadowLine(segment: segment, language: replaced)) }
        }
        for line in lines where line.speaker == speaker && line.start >= seam { add(line) }
        listen(speaker, from: seam, in: language)
    }
}
