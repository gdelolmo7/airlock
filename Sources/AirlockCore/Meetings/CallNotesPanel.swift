import Foundation

/// The small rules behind what the notch panel says while notes are taken
/// and once they are ready. Pure, so each one can be tested without a call
/// or a screen.
public enum CallNotesPanel {
    // MARK: - While notes are taken

    /// What "Copy" puts on the clipboard for the call's chat. Short, because
    /// it lands in the middle of other people's meeting.
    public static let headsUp = "Heads up: I'm taking notes of this call on my Mac. No recording is kept."

    /// The heads-up at a meeting in the room, where there is no chat to
    /// paste into: a reminder to say it out loud.
    public static let roomHeadsUp = "Let everyone in the room know you're taking notes. No audio is kept."

    /// Said once notes stop because the Mac went to sleep
    /// (`MeetingNotesFlow.endedBySleep`), so they don't seem to have
    /// stopped by themselves.
    public static let stoppedBySleep = "Stopped when the Mac went to sleep."

    /// How long into the notes the panel offers the heads-up. The start of a
    /// call is when people say who is on it and how; after that, the line is
    /// one more thing to look past.
    public static let headsUpWindow: TimeInterval = 60

    /// Whether the heads-up is still offered, for notes on a call that first
    /// started at `since` (`MeetingNotesFlow.firstStarted`). The first start,
    /// not the latest: notes carried on after the call dropped or the Mac
    /// slept are the same call, and its people have already been told.
    public static func showsHeadsUp(notesSince since: Date, now: Date) -> Bool {
        now.timeIntervalSince(since) < headsUpWindow
    }

    /// Whether "Mark" is offered, and whether pressing it marks anything:
    /// only while the notes are written down. Paused, the last half-minute
    /// is nothing the notes kept, so a mark there would mark nothing. A jot
    /// is different: what the person types is theirs, paused or not.
    public static func offersMark(_ flow: MeetingNotesFlow) -> Bool {
        guard case .recording = flow.phase else { return false }
        return flow.pausedSince == nil
    }

    /// What the panel says once "Mark" is pressed: how far back the mark
    /// reaches, in the record's own words (`MeetingRecord.markReach`).
    public static var marked: String {
        "Marked the last \(Int(MeetingRecord.markReach)) seconds"
    }

    /// "2 jotted" beside the jot field; nothing before the first line.
    public static func jotted(_ count: Int) -> String? {
        count > 0 ? "\(count) jotted" : nil
    }

    /// The running clock beside "Taking notes": m:ss, or h:mm:ss past the
    /// hour.
    public static func clock(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(seconds))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }

    // MARK: - The transcript, live

    /// One line of what was said, as the panel shows it, or where the call
    /// moved into another language.
    public struct Line: Equatable, Sendable {
        /// "You", "Them", or the other person's name on a one-to-one call.
        /// Empty on a divider.
        public var speaker: String
        public var text: String
        /// "Catalan from 10:12" (`MeetingTimeline.languageLabel`) rather
        /// than something said.
        public var isDivider: Bool

        public init(speaker: String, text: String, isDivider: Bool = false) {
            self.speaker = speaker
            self.text = text
            self.isDivider = isDivider
        }
    }

    /// How many lines "Show transcript" shows: enough to catch up on the
    /// last thing said, few enough to stay a glance.
    public static let transcriptLines = 4

    /// The last `count` things said, oldest first, named the way the
    /// transcript names them, with the speakers' echo left out the way the
    /// notes leave it out (`MeetingEcho`).
    ///
    /// Only the tail is looked at, so a long call costs the same as a short
    /// one. The tail reaches back one echo window past the lines it keeps,
    /// so an echo is still caught when the line it repeats is just older.
    public static func recentLines(of record: MeetingRecord, count: Int = transcriptLines) -> [Line] {
        guard count > 0, !record.segments.isEmpty else { return [] }
        let segments = record.segments
        let keep = segments.suffix(count * 3)
        let reach = (keep.first?.start ?? 0) - MeetingEcho.window
        let from = segments[..<keep.startIndex].lastIndex { $0.end < reach }.map { $0 + 1 }
            ?? segments.startIndex
        let tail = MeetingEcho.removingEchoes(from: Array(segments[from...]))
        let shown = Array(tail.suffix(count))
        var lines = shown.map {
            Line(speaker: record.label(for: $0), text: MeetingText.oneLine($0.text))
        }
        // Where the call moved into another language, among the lines shown,
        // and the latest one on top of them while it is recent: switched a
        // minute ago, every line shown is already in the new language.
        let dividers = MeetingTimeline.dividers(of: record)
        for divider in dividers.reversed() {
            let at = shown.firstIndex { $0.start >= divider.from } ?? shown.count
            let isLatest = divider == dividers.last
            if at == 0, !(isLatest && (shown.last?.start ?? 0) - divider.from <= dividerReach) { continue }
            if at == shown.count, !isLatest { continue }
            lines.insert(Line(speaker: "", text: MeetingTimeline.languageLabel(divider), isDivider: true), at: at)
        }
        // Still `count` lines: a divider takes the place of the oldest.
        while lines.count > count, let oldest = lines.firstIndex(where: { !$0.isDivider }) {
            lines.remove(at: oldest)
        }
        return lines
    }

    /// How long after a change of language the panel still says so above
    /// lines that are all in the new one.
    public static let dividerReach: TimeInterval = 300

    // MARK: - Once the notes are ready

    /// Whether the notes say anything worth showing in the panel. Nothing
    /// written, or only that too little was said, is not: the panel then
    /// shows only its line (`ready`) and leaves the rest to the notes
    /// themselves.
    public static func hasNotes(_ notes: MeetingNotes?) -> Bool {
        guard let notes, !notes.isEmpty else { return false }
        return notes.summary != MeetingNotes.tooLittle
    }

    /// What the line says once the notes are saved.
    public enum Ready: Equatable, Sendable {
        /// "Notes ready", with its tick.
        case notes
        /// Too little was said for the notes to be written at all: no tick,
        /// because nothing was made.
        case tooLittleSaid
        /// Saved, and its notes are written online later: a Mac that can't
        /// write them waits for the service (`MeetingNotesWriter.noNotesYet`).
        /// No tick either: nothing is made yet.
        case later
    }

    /// The line for `Ready.tooLittleSaid`, in the panel and on the island.
    public static let tooLittleSaid = "Not enough was said for notes"
    /// The line for `Ready.later`, in the panel and on the island.
    public static let notesLater = "Call saved, notes later"

    /// `ready(of:notes:)`, or `later` when the page has no notes yet and
    /// says when they will come.
    public static func ready(of record: MeetingRecord, notes: MeetingNotes?,
                             writer: MeetingNotesWriter?) -> Ready {
        writer?.noNotesYet != nil ? .later : ready(of: record, notes: notes)
    }

    /// Whether a call's notes are ready or too little was said for any.
    /// The same rule the notes page goes by (`MeetingFiles.notesPage`):
    /// nothing written and fewer than `MeetingNotes.minimumWords` words heard,
    /// the count under which the notes writer is never asked. Notes that
    /// say something are ready whatever the count, and so is a call long
    /// enough for notes that none could be written for: its page says why.
    public static func ready(words: Int, notes: MeetingNotes?) -> Ready {
        if hasNotes(notes) { return .notes }
        return words < MeetingNotes.minimumWords ? .tooLittleSaid : .notes
    }

    /// `ready(words:notes:)` for a saved call, its words counted the way the
    /// notes writer counts them.
    public static func ready(of record: MeetingRecord, notes: MeetingNotes?) -> Ready {
        ready(words: NumberedTranscript(record).wordCount, notes: notes)
    }

    /// The Mac notification once a call's notes are saved.
    public struct Notice: Equatable, Sendable {
        public var title: String
        public var body: String
    }

    /// "Call notes ready", "11:30–12:44 · 74 min · 3 to-dos": said by the
    /// Mac as well, because the notch says it for a few seconds only, and
    /// the notes are written a while after the call, when nobody is looking
    /// at it. Nil when too little was said: nothing was made to go and read.
    ///
    /// When it was and how much is left to do, and nothing that was said:
    /// a notification can land on a shared screen, and the call's title is
    /// written from its words.
    public static func readyNotice(of record: MeetingRecord, ready: Ready, todos: Int,
                                   calendar: Calendar = .current) -> Notice? {
        guard ready == .notes else { return nil }
        let when = record.endedAt.map { CallsCard.span(from: record.startedAt, to: $0, calendar: calendar) }
        let body = [when, CallsCard.todos(todos)].compactMap { $0 }.joined(separator: " · ")
        return Notice(title: "Call notes ready", body: body.isEmpty ? "Click to read them." : body)
    }

    /// How many sentences of the summary the panel shows. The rest is one
    /// tap away, in the notes themselves.
    public static let summarySentences = 2

    /// The first `sentences` sentences of a summary, as written.
    public static func summaryLead(_ summary: String, sentences: Int = summarySentences) -> String {
        let text = MeetingText.clean(summary)
        guard sentences > 0, !text.isEmpty else { return "" }
        var end = text.endIndex
        var counted = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) {
            _, range, _, stop in
            counted += 1
            if counted == sentences {
                end = range.upperBound
                stop = true
            }
        }
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How many to-dos the panel lists before "+N more".
    public static let todosShown = 3

    /// The to-dos as the panel lists them: the first few, then how many
    /// more there are.
    public struct Todos: Equatable, Sendable {
        /// "Send the budget — Ana", or just the task when nobody was named.
        public var lines: [String]
        /// How many are left out of `lines`.
        public var more: Int

        public init(lines: [String], more: Int) {
            self.lines = lines
            self.more = more
        }

        /// "+2 more", or nil when every to-do is listed.
        public var moreLine: String? { more > 0 ? "+\(more) more" : nil }
    }

    public static func todos(_ items: [MeetingNotes.Item], shown: Int = todosShown) -> Todos {
        let listed = items.prefix(max(0, shown)).map { item -> String in
            let task = MeetingText.line(item.text)
            guard let owner = item.owner.map(MeetingText.clean), !owner.isEmpty else { return task }
            return "\(task) — \(owner)"
        }
        return Todos(lines: listed, more: max(0, items.count - listed.count))
    }
}
