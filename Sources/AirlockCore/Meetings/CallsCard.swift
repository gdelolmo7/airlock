import Foundation

/// What the notch's Calls tab shows: the last few calls whose notes are on
/// disk, by day, each as its name, when it was, how long it lasted and how
/// many to-dos it left. A way back to a call's notes from the notch itself.
///
/// Facts about the call and nothing it says. The tab sits in a panel that
/// opens in front of other people, so no line of a transcript or summary is
/// ever kept here, only the title the folder is already known by.
public enum CallsCard {
    /// At most this many rows. The tab has the panel to itself, so six fit
    /// at the default width and text size with room for their day headings;
    /// every call is one click further in the notes window ("All calls").
    public static let limit = 6

    public static let title = String(localized: "Calls")
    public static let allCalls = String(localized: "All calls")
    /// What the tab says while call notes are on and nothing is saved yet.
    /// Said rather than hidden, so the tab is where somebody who just
    /// switched notes on expects their first call to land.
    public static let emptyTitle = String(localized: "No calls yet")
    public static let emptyLine = String(localized: "Notes from your calls will show here.")
    /// The empty tab's second line: a meeting with no call needs the button.
    public static let emptyRoomLine = String(localized: "For a meeting in the room, press Take notes.")

    /// The tab's button for notes by hand (`MeetingNotesFlow.handButton`):
    /// notes of a meeting in the room, of the call that is on, or "Stop
    /// notes". Nil while the last notes are still being written, when there
    /// is nothing to press.
    public static func handLabel(_ button: MeetingNotesFlow.HandButton) -> String? {
        switch button {
        case .takeNotes, .takeNotesOfCall: String(localized: "Take notes")
        case .stop: String(localized: "Stop notes")
        case .busy: nil
        }
    }

    /// What the same button does, said on hover.
    public static func handHelp(_ button: MeetingNotesFlow.HandButton) -> String {
        switch button {
        case .takeNotes: String(localized: "Takes notes of a meeting in the room, through this Mac's microphone")
        case .takeNotesOfCall: String(localized: "Takes notes of the call you're on")
        case .stop: String(localized: "Stops the notes and writes them up")
        case .busy: ""
        }
    }

    /// One call on the tab.
    public struct Row: Equatable, Sendable, Identifiable {
        /// The call's folder name under the meetings folder: what the notes
        /// window is opened on.
        public let folder: String
        public let title: String
        public let startedAt: Date
        public let endedAt: Date
        /// Unticked to-dos on the notes page.
        public let todos: Int
        /// The app the call was in and, for one in a browser, the site: what
        /// the row's logo is drawn from, as the call pill draws it live.
        public let bundleID: String
        public let site: MeetingLink.Provider?
        /// How many people were on it (`CallPeople.count`); nil when not known.
        public let people: Int?
        /// The notes came from a recording added afterwards
        /// (`MeetingRecord.recording`), drawn with a waveform, not the room.
        public let fromRecording: Bool

        public var id: String { folder }

        public init(folder: String, title: String, startedAt: Date, endedAt: Date, todos: Int,
                    bundleID: String, site: MeetingLink.Provider? = nil, people: Int? = nil,
                    fromRecording: Bool = false) {
            self.folder = folder
            self.title = title
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.todos = todos
            self.bundleID = bundleID
            self.site = site
            self.people = people
            self.fromRecording = fromRecording
        }

        /// The people count worth saying on the row: three or more. Two is
        /// every call that has no reason to say otherwise.
        public var crowd: Int? {
            guard let people, people >= 3 else { return nil }
            return people
        }
    }

    /// The calls of one day, under its heading.
    public struct Day: Equatable, Sendable, Identifiable {
        /// The day's first moment, in the calendar the rows were grouped in.
        public let start: Date
        /// "Today", "Yesterday", "Tue 6 Oct".
        public let heading: String
        public let rows: [Row]

        public var id: Date { start }
    }

    // MARK: - Which calls

    /// The tab's rows, newest first, from every call on disk.
    ///
    /// Only finished calls. One still going is already in the panel, as the
    /// notes banner above the tabs, and has no notes to open yet; one the app
    /// quit during is finished at the next launch and joins then. `page`
    /// reads a call's notes page and is asked only for the calls that make
    /// the tab, so a long history costs six small reads, not one per call.
    public static func rows(from calls: [(folder: URL, record: MeetingRecord)],
                            page: (URL) -> String?) -> [Row] {
        let finished = calls.compactMap { call -> (folder: URL, record: MeetingRecord, end: Date)? in
            guard let end = call.record.endedAt else { return nil }
            return (call.folder, call.record, end)
        }
        // Newest first by when the call began, as the notes window lists them.
        // Two calls begun in the same second keep a fixed order (the later
        // folder name, "… 2", first) rather than swapping between reads.
        let newest = finished.sorted {
            $0.record.startedAt != $1.record.startedAt
                ? $0.record.startedAt > $1.record.startedAt
                : $0.folder.lastPathComponent > $1.folder.lastPathComponent
        }
        return newest.prefix(limit).map { call in
            Row(folder: call.folder.lastPathComponent,
                title: MeetingFiles.title(of: call.record),
                startedAt: call.record.startedAt,
                endedAt: call.end,
                todos: openTodos(in: page(call.folder)),
                bundleID: call.record.bundleID,
                site: call.record.site,
                people: CallPeople.count(of: call.record),
                fromRecording: call.record.recording != nil)
        }
    }

    /// Finished calls begun this week, by the calendar's own week: what the
    /// tab's header counts, from every call on disk rather than its rows.
    public static func thisWeek(_ calls: [(folder: URL, record: MeetingRecord)], now: Date = Date(),
                                calendar: Calendar = .current) -> Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return 0 }
        return calls.filter { $0.record.endedAt != nil && week.contains($0.record.startedAt) }.count
    }

    /// The rows by the day each call began, newest day first, each day's
    /// rows in the order given. A day with no call has no heading.
    public static func days(_ rows: [Row], now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        var order: [Date] = []
        var byDay: [Date: [Row]] = [:]
        for row in rows {
            let start = calendar.startOfDay(for: row.startedAt)
            if byDay[start] == nil { order.append(start) }
            byDay[start, default: []].append(row)
        }
        return order.sorted(by: >).map { start in
            Day(start: start, heading: dayHeading(start, now: now, calendar: calendar),
                rows: byDay[start] ?? [])
        }
    }

    /// To-dos still open on a notes page: its "- [ ]" lines. A box ticked in
    /// a text editor is done and no longer counts; no page yet is none.
    public static func openTodos(in page: String?) -> Int {
        guard let page else { return 0 }
        return MeetingPage.blocks(of: page).reduce(0) { count, block in
            if case .item(_, checked: false?, _, _) = block { return count + 1 }
            return count
        }
    }

    // MARK: - Search

    /// Whether a call's words hold every word of `query`, whatever the case
    /// and accents: "budget ana" finds the budget review Ana was on, "reunion"
    /// finds "reunión". An empty query finds every call. `texts` is what the
    /// call is searched by: its name, its notes page and what was said.
    public static func matches(_ query: String, in texts: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { word in
            texts.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    // MARK: - Wording

    /// "1 to-do", "3 to-dos", and nothing at all for none: a call that left
    /// none says so by not mentioning any.
    public static func todos(_ count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return String(localized: "1 to-do")
        default: return String(localized: "\(count) to-dos")
        }
    }

    /// "5 calls this week" beside the tab's name; nil for none, when the
    /// days below say enough.
    public static func weekLine(_ count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return String(localized: "1 call this week")
        default: return String(localized: "\(count) calls this week")
        }
    }

    /// "12 min": whole minutes, never under one, as the notes page header
    /// counts them (`MeetingFiles.header`).
    public static func length(from start: Date, to end: Date) -> String {
        String(localized: "\(max(1, Int((end.timeIntervalSince(start) / 60).rounded()))) min")
    }

    /// "Today 14:30 · 12 min", "Yesterday 09:05 · 40 min", "Mon 6 Oct 14:30 ·
    /// 5 min", with the year once it is not this one; "· now" for a call
    /// still going. The notes window's list says it this way.
    public static func when(startedAt start: Date, endedAt end: Date?, now: Date = Date(),
                            calendar: Calendar = .current) -> String {
        let day = dayName(of: start, now: now, calendar: calendar, weekday: .abbreviated)
        let time = start.formatted(timeStyle(calendar))
        guard let end else { return String(localized: "\(day) \(time) · now") }
        return "\(day) \(time) · \(length(from: start, to: end))"
    }

    /// The notes window's line under a call's title: "Today 10:02–10:16 ·
    /// 14 min", the list's day (`when`) with both ends of the clock (`span`),
    /// so the call reads the same in the list and above its notes. "· now"
    /// for a call still going, as the list has it.
    public static func header(startedAt start: Date, endedAt end: Date?, now: Date = Date(),
                              calendar: Calendar = .current) -> String {
        guard let end else { return when(startedAt: start, endedAt: nil, now: now, calendar: calendar) }
        let day = dayName(of: start, now: now, calendar: calendar, weekday: .abbreviated)
        return "\(day) \(span(from: start, to: end, calendar: calendar))"
    }

    /// A day's heading on the tab: "Today", "Yesterday", "Tue 6 Oct", with
    /// the year once it is not this one. The same words as the rows and the
    /// header (`day`), so a day is never written two ways.
    public static func dayHeading(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        self.day(day, now: now, calendar: calendar)
    }

    /// "Today", "Yesterday", "Tue 6 Oct", or "30 Dec 2025": the one way the
    /// call notes say a day, in the list, above a call's notes and under an
    /// answer from the calls.
    public static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        dayName(of: date, now: now, calendar: calendar, weekday: .abbreviated)
    }

    /// A row's second line on the tab: "12:55–13:39 · 44 min". The day is
    /// the heading above it, so only the clock is said here.
    public static func span(from start: Date, to end: Date, calendar: Calendar = .current) -> String {
        "\(clock(from: start, to: end, calendar: calendar)) · \(length(from: start, to: end))"
    }

    /// Both ends of the clock: "12:55–13:39".
    public static func clock(from start: Date, to end: Date, calendar: Calendar = .current) -> String {
        let style = timeStyle(calendar)
        return "\(start.formatted(style))–\(end.formatted(style))"
    }

    /// The notes window's day and clock, with the length said beside it:
    /// "Today 10:02–10:16"; "Today 10:02" for a call still going.
    public static func dayAndClock(startedAt start: Date, endedAt end: Date?, now: Date = Date(),
                                   calendar: Calendar = .current) -> String {
        let day = dayName(of: start, now: now, calendar: calendar, weekday: .abbreviated)
        guard let end else { return "\(day) \(start.formatted(timeStyle(calendar)))" }
        return "\(day) \(clock(from: start, to: end, calendar: calendar))"
    }

    /// A start time alone, "10:02", as the notes window's list says it under
    /// a day's heading.
    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(timeStyle(calendar))
    }

    /// The clock `seconds` into a call that began at `start`: "20:58", where
    /// the files write "6:12". What the windows show beside a line, so a
    /// moment in a call reads as the time it was, never as minutes that look
    /// like an hour.
    public static func time(_ seconds: TimeInterval, into start: Date, calendar: Calendar = .current) -> String {
        time(start.addingTimeInterval(max(0, seconds)), calendar: calendar)
    }

    /// The clock in the calendar's own words: "14:30" in Spain, "2:30 PM"
    /// in the US.
    private static func timeStyle(_ calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current,
                         calendar: calendar, timeZone: calendar.timeZone)
    }

    /// "Today", "Yesterday", the day of this year, or the date in another.
    private static func dayName(of date: Date, now: Date, calendar: Calendar,
                                weekday: Date.FormatStyle.Symbol.Weekday) -> String {
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar,
                                     timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(style.weekday(weekday).day().month(.abbreviated))
        }
        return date.formatted(style.day().month(.abbreviated).year())
    }
}
