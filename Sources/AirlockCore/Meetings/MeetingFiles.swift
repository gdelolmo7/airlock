import Foundation

/// The files one call's notes are kept in, and what goes in them.
///
/// `~/Airlock/Meetings/<date time – call>/`, beside the tray, so they are
/// plain files the owner can open, search, back up or delete in Finder, and
/// that an agent pointed at the folder can read to answer "what did we agree
/// on Tuesday?". No database: the folder is the store, like the tray.
///
/// Three files: `Notes.md` (the summary), `Transcript.md` (who said what, when)
/// and `meeting.json` (the same transcript for the app itself to read back).
public enum MeetingFiles {
    public static let notesName = "Notes.md"
    public static let transcriptName = "Transcript.md"
    public static let recordName = "meeting.json"
    /// The notes page's section for the lines the person typed during the
    /// call. The window reads it back to tell their words from Airlock's.
    public static let yourNotesHeading = "Your notes"
    /// The page's other sections, as the window looks them up to give each
    /// its card.
    public static let summaryHeading = "Summary"
    public static let todosHeading = "To-dos"
    public static let decisionsHeading = "Decisions"
    public static let questionsHeading = "Open questions"
    public static let keyPointsHeading = "Key points"
    /// Notes written by topic: one "### 1. Title · 4:05" under it for each.
    public static let topicsHeading = "Topics"
    /// Names and figures the transcript may have heard wrong (`MeetingNotes.Word`).
    public static let wordsHeading = "Check these words"

    /// The folder for a call, e.g. "2026-10-08 14.30 – Zoom", or
    /// "2026-10-08 14.30 – Budget review" when the calendar named the meeting.
    ///
    /// Dots, not colons, in the time: Finder shows a colon in a file name as a
    /// slash and the shell sees it as something else again. The date leads so
    /// the folder sorts by when the call was. The meeting's own name beats the
    /// app's, because that is what somebody looks for a week later.
    public static func folderName(for record: MeetingRecord,
                                  timeZone: TimeZone = .current) -> String {
        let stamp = Self.stamp(record.startedAt, format: "yyyy-MM-dd HH.mm", timeZone: timeZone)
        var name = safe(record.event?.name ?? record.recording?.title ?? "")
        if name.isEmpty { name = safe(record.callName) }
        return name.isEmpty ? stamp : "\(stamp) – \(name)"
    }

    /// A name a folder can carry: no path separators, no leading dot that
    /// would hide it, no control characters, nothing absurdly long.
    static func safe(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmed = cleaned
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        return String(trimmed.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Transcript

    /// The transcript a person reads: one paragraph per turn, the speaker and
    /// the time it started, with the person's own typed notes and any pauses
    /// in their place in time.
    ///
    /// Consecutive lines by the same speaker are one turn unless there was a
    /// real pause between them, because the recogniser cuts sentences far more
    /// often than people hand over. A pause is written out so a gap in the
    /// words reads as "notes were off", not as silence.
    public static func transcript(of record: MeetingRecord,
                                  timeZone: TimeZone = .current) -> String {
        var lines = ["# \(title(of: record))", "", header(of: record, timeZone: timeZone), ""]
        let entries = MeetingTimeline.entries(of: record)
        if !entries.contains(where: \.isSpeech) {
            lines.append("_Nothing was heard yet._")
            lines.append("")
        }
        for entry in entries {
            switch entry {
            case .speech(let turn, _):
                lines += ["**\(record.label(for: turn))** · \(clock(turn.start))  ", turn.text, ""]
            case .jot(let jot):
                lines += ["**Your note** · \(clock(jot.at))  ", jot.text, ""]
            case .pause(let pause):
                // The window's words, in italics: one wording for a pause.
                lines += ["_\(MeetingTimeline.pauseLabel(pause))_", ""]
            case .language(let listening):
                lines += ["_\(MeetingTimeline.languageLabel(listening))_", ""]
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    /// A pause longer than this between two lines by the same speaker starts
    /// a new paragraph.
    static let turnPause: TimeInterval = 8

    /// A line at or after one of `breaks` never joins a turn that started
    /// before it, so a change of language (`MeetingTimeline.dividers`) sits
    /// between two turns rather than after one that runs across it.
    ///
    /// `longest`, in characters: no turn grows past it. A line that would
    /// take a turn over it starts the next one, and a line longer than it on
    /// its own is cut at spaces (`pieces`). Only the windows ask for it
    /// (`MeetingTimeline.shown`); the file keeps whole turns.
    public static func turns(_ segments: [MeetingSegment],
                             breakingAt breaks: [TimeInterval] = [],
                             longest: Int? = nil) -> [MeetingSegment] {
        var turns: [MeetingSegment] = []
        var length = 0
        let lines = longest.map { longest in segments.flatMap { pieces(of: $0, longest: longest) } } ?? segments
        for segment in lines {
            let size = longest == nil ? 0 : segment.text.count
            if var last = turns.last, last.speaker == segment.speaker, last.person == segment.person,
               segment.start - last.end <= turnPause,
               !breaks.contains(where: { last.start < $0 && $0 <= segment.start }),
               longest.map({ length + 1 + size <= $0 }) ?? true {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                turns[turns.count - 1] = last
                length += 1 + size
            } else {
                turns.append(segment)
                length = size
            }
        }
        return turns
    }

    /// `segment` in pieces of at most `longest` characters, each cut at the
    /// last space that fits (anywhere, in a word longer than that) and timed
    /// by its share of the line. A line no longer than that is itself.
    static func pieces(of segment: MeetingSegment, longest: Int) -> [MeetingSegment] {
        let text = segment.text
        guard longest > 0, text.count > longest else { return [segment] }
        let total = Double(text.count)
        let span = segment.end - segment.start
        var pieces: [MeetingSegment] = []
        var from = text.startIndex
        var before = 0
        while from < text.endIndex {
            var to = text.index(from, offsetBy: longest, limitedBy: text.endIndex) ?? text.endIndex
            if to < text.endIndex, text[to] != " ", let space = text[from..<to].lastIndex(of: " "), space > from {
                to = space
            }
            let count = text[from..<to].count
            pieces.append(MeetingSegment(speaker: segment.speaker,
                                         start: segment.start + span * Double(before) / total,
                                         end: segment.start + span * Double(before + count) / total,
                                         text: String(text[from..<to]), person: segment.person))
            before += count
            from = to
            while from < text.endIndex, text[from] == " " {
                from = text.index(after: from)
                before += 1
            }
        }
        return pieces
    }

    /// The calendar's name for the meeting when there is one, as written,
    /// or the recording's it was added from, or the one its notes gave it
    /// (`MeetingRecord.topic`). Otherwise "Call with Ana" when the invite
    /// says it was one person, and "Call in Zoom" when nothing better is
    /// known.
    public static func title(of record: MeetingRecord) -> String {
        if record.event?.name == nil, let recording = record.recording { return recording.title }
        return title(event: record.event, callName: record.callName, inPerson: record.isInPerson,
                     topic: record.topic)
    }

    /// Whether `title(of:)` is a name, kept as written ("Budget review",
    /// "Kitchen planning"), rather than a description ("Call in Zoom").
    public static func titleIsAName(_ record: MeetingRecord) -> Bool {
        record.event?.name != nil || record.recording != nil || record.topic != nil
    }

    /// `title(of:)` for a call whose record is not to hand: its calendar
    /// event, if any, the name its notes gave it once they are written
    /// (`topic`), and the app's or the service's name (`callName`). The
    /// panel names a call by this once its notes are taken, so the line
    /// about them and the list they are found in say the same.
    /// A meeting in person is a "Meeting", not a "Call in In person".
    public static func title(event: MeetingEvent?, callName: String, inPerson: Bool = false,
                             topic: String? = nil) -> String {
        if let name = event?.name { return name }
        if let topic { return topic }
        if let other = event?.oneToOne { return "\(inPerson ? "Meeting" : "Call") with \(other)" }
        return inPerson ? "Meeting in person" : "Call in \(callName)"
    }

    /// "2026-10-08 14:30–15:12 · 42 min", or "… 14:30 · in progress".
    public static func header(of record: MeetingRecord, timeZone: TimeZone = .current) -> String {
        let start = stamp(record.startedAt, format: "yyyy-MM-dd HH:mm", timeZone: timeZone)
        guard let end = record.endedAt else { return "\(start) · in progress" }
        let finish = stamp(end, format: "HH:mm", timeZone: timeZone)
        let minutes = max(1, Int((end.timeIntervalSince(record.startedAt) / 60).rounded()))
        return "\(start)–\(finish) · \(minutes) min"
    }

    /// "4:05", or "1:02:09" past the hour.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
        return String(format: "%d:%02d", minutes, rest)
    }

    private static func stamp(_ date: Date, format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
