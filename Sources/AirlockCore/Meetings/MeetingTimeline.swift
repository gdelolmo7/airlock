import Foundation

/// A call's transcript in time order: who said what turn by turn, the lines
/// the person typed, the pauses, and where the call moved into another
/// language, each where it happened.
///
/// One merge for the file (`MeetingFiles.transcript`) and the notes window,
/// so the two can never disagree about what came first.
public enum MeetingTimeline {
    public enum Entry: Equatable, Sendable {
        /// One speaker's turn (`MeetingFiles.turns`). `marked` when it falls
        /// within the reach of a mark the person made (`MeetingRecord.isMarked`).
        case speech(MeetingSegment, marked: Bool)
        /// A line the person typed during the call.
        case jot(MeetingJot)
        /// A stretch the notes were paused for.
        case pause(MeetingPause)
        /// Where a side followed the call into another language
        /// (`dividers`): "Catalan from 10:12".
        case language(MeetingListening)

        /// When it happened, in seconds from the start of the call.
        public var at: TimeInterval {
            switch self {
            case .speech(let turn, _): turn.start
            case .jot(let jot): jot.at
            case .pause(let pause): pause.start
            case .language(let listening): listening.from
            }
        }

        /// Something said, rather than typed or a pause.
        public var isSpeech: Bool {
            if case .speech = self { true } else { false }
        }

        /// Breaks a tie at the same moment: what was said comes before what
        /// was typed about it, and both before a pause that starts there. A
        /// change of language comes first: it is about the line it starts at.
        var rank: Int {
            switch self {
            case .language: -1
            case .speech: 0
            case .jot: 1
            case .pause: 2
            }
        }
    }

    /// Everything in the call, in the order it happened. Speech is what the
    /// transcript reads (`spokenSegments`, echoes gone), grouped into turns,
    /// none longer than `longest` characters when it is set
    /// (`MeetingFiles.turns`).
    public static func entries(of record: MeetingRecord, longest: Int? = nil) -> [Entry] {
        let dividers = dividers(of: record)
        var entries: [Entry] = MeetingFiles.turns(record.spokenSegments, breakingAt: dividers.map(\.from),
                                                  longest: longest)
            .map { .speech($0, marked: record.isMarked($0)) }
        entries += record.jots.map(Entry.jot)
        entries += record.pauses.map(Entry.pause)
        entries += dividers.map(Entry.language)
        // A stable order: each kind keeps its own order on a full tie.
        return entries.enumerated()
            .sorted { ($0.element.at, $0.element.rank, $0.offset) < ($1.element.at, $1.element.rank, $1.offset) }
            .map(\.element)
    }

    /// The longest turn the windows draw as one block, in characters. A
    /// longer one carries on in the rows below it, under the same face.
    ///
    /// A row of a lazy list drawn taller than about 5,000 points comes out
    /// solid black (macOS 26; about 11,000 characters in the live window's
    /// column, measured), and the window blanks once that row fills it. One
    /// person talking for minutes makes a turn that long, and so do voices
    /// told apart again mid-call, when two people's turns become one. 1,500
    /// characters is about 700 points there: a paragraph.
    public static let longestShown = 1_500

    /// `entries(of:)` as the windows draw them: a turn longer than
    /// `longestShown` is several, broken between lines. Indexes into the
    /// window's rows (a lit line, a name being given) are indexes into this.
    /// The file, a copy and the notes keep whole turns.
    public static func shown(of record: MeetingRecord) -> [Entry] {
        entries(of: record, longest: longestShown)
    }

    /// Where a line of notes said at `time` points in `entries`: the turn
    /// said at that time or the nearest one before it, else the first turn
    /// after it. Nil when nothing was said at all.
    ///
    /// The page writes a time to the whole second, dropping the rest
    /// (`MeetingFiles.clock`), so a turn that started at 23.4 s is "0:23" and
    /// must count as said at 23 — not as the turn after it.
    public static func spoken(at time: TimeInterval, in entries: [Entry]) -> Int? {
        var before: Int?
        var after: Int?
        for (index, entry) in entries.enumerated() {
            guard case .speech(let turn, _) = entry else { continue }
            if turn.start.rounded(.down) <= time {
                before = index
            } else if after == nil {
                after = index
            }
        }
        return before ?? after
    }

    /// "Paused 12:03–12:05", or "Paused from 12:03" while it is still on.
    /// The windows pass the time of day as `clock` (`CallsCard.time`).
    public static func pauseLabel(_ pause: MeetingPause,
                                  clock: (TimeInterval) -> String = MeetingFiles.clock) -> String {
        guard let end = pause.end else { return String(localized: "Paused from \(clock(pause.start))") }
        return String(localized: "Paused \(clock(pause.start))–\(clock(end))")
    }

    /// The changes of language the transcript marks: each one after a side's
    /// first listening, and not one that names the language the mark before
    /// it named. Both sides following the call into Catalan is one change
    /// for whoever reads it.
    public static func dividers(of record: MeetingRecord) -> [MeetingListening] {
        var started = Set<MeetingSpeaker>()
        var named: String?
        var shown: [MeetingListening] = []
        for listening in record.listenings {
            guard !started.insert(listening.speaker).inserted else { continue }
            let code = CallLanguage.code(of: listening.language) ?? listening.language
            guard code != named else { continue }
            named = code
            shown.append(listening)
        }
        return shown
    }

    /// "Catalan from 10:12", with the time of day as `clock` in the windows.
    public static func languageLabel(_ listening: MeetingListening,
                                     clock: (TimeInterval) -> String = MeetingFiles.clock) -> String {
        let name = CallLanguageFollow.shownName(of: listening.language) ?? listening.language
        return String(localized: "\(name) from \(clock(listening.from))")
    }
}
