import Foundation

/// The next call on the calendar, as the "Next call" desktop widget shows it.
///
/// The app reads the calendar (the widget is sandboxed and asks nothing of
/// EventKit) and writes this where the widget can read it (`DeskShelf`). It
/// carries the next few timed events rather than one, so the widget's own
/// timeline can move from "in 12 min" to "Now" to the call after it on time,
/// with the app asleep or busy.
///
/// No link is carried. A press on Join opens `airlock://join?event=…`, and the
/// app joins that event only if it is one of its own upcoming events: a link
/// typed by anybody can at most join a call already on your calendar.
public struct DeskNextCall: Codable, Equatable, Sendable {
    public struct Event: Codable, Equatable, Sendable, Identifiable {
        /// The calendar's own id for the event.
        public var id: String
        public var title: String
        public var start: Date
        public var end: Date
        /// What the Join button says ("Join Zoom"), or nil when the invite
        /// has no call to join.
        public var join: String?

        public init(id: String, title: String, start: Date, end: Date, join: String?) {
            self.id = id
            self.title = title
            self.start = start
            self.end = end
            self.join = join
        }

        public var joinURL: URL? {
            guard join != nil else { return nil }
            var parts = URLComponents()
            parts.scheme = "airlock"
            parts.host = DeskNextCall.joinHost
            parts.queryItems = [URLQueryItem(name: "event", value: id)]
            return parts.url
        }
    }

    /// A call from today whose notes are written, the newest one.
    public struct Notes: Codable, Equatable, Sendable {
        public var call: String
        /// The call's folder, by name, under the meetings folder.
        public var folder: String
        public var at: Date

        public init(call: String, folder: String, at: Date) {
            self.call = call
            self.folder = folder
            self.at = at
        }

        public var openURL: URL? {
            var parts = URLComponents()
            parts.scheme = "airlock"
            parts.host = DeskNextCall.notesHost
            parts.queryItems = [URLQueryItem(name: "call", value: folder)]
            return parts.url
        }
    }

    /// Timed events still to end, earliest first. All-day ones are left out:
    /// a day-long "Out of office" is not a call.
    public var events: [Event]
    public var notes: Notes?
    /// The notch's ground, as for the to-dos.
    public var surface: DeskSurface?

    public init(events: [Event], notes: Notes? = nil, surface: DeskSurface? = nil) {
        self.events = events
        self.notes = notes
        self.surface = surface
    }

    public static let empty = DeskNextCall(events: [])
    public static let snapshotName = "desk-next-call.json"
    public static let widgetKind = "com.airlock.next-call"
    public static let joinHost = "join"
    public static let notesHost = "call-notes"
    // MARK: - What to show at a moment

    public enum Moment: Equatable, Sendable {
        /// A call is on: `then` is the one after it, if any.
        case now(Event, then: Event?)
        /// The next call, still to start, and the one after it.
        case next(Event, then: Event?)
        /// Nothing more on the calendar.
        case clear
    }

    /// What the widget shows at `now`: a call that has started and not ended
    /// is on; otherwise the next one to start. The app carries the next 24
    /// hours, so "clear" means nothing until this time tomorrow.
    public func moment(at now: Date) -> Moment {
        let left = events.filter { $0.end > now }.sorted { $0.start < $1.start }
        guard let first = left.first else { return .clear }
        let then = left.dropFirst().first
        return first.start <= now ? .now(first, then: then) : .next(first, then: then)
    }

    /// Every time the widget should redraw by itself: each start and end,
    /// and each minute of the hour before every start, so "in 12 min"
    /// counts down without the app, also after a call that was on ends.
    public func changes(after now: Date) -> [Date] {
        var dates = Set(events.flatMap { [$0.start, $0.end] })
        for event in events where event.start > now {
            var tick = event.start.addingTimeInterval(-60)
            while tick > now, event.start.timeIntervalSince(tick) <= 3600 {
                dates.insert(tick)
                tick.addTimeInterval(-60)
            }
        }
        return dates.filter { $0 > now }.sorted()
    }

    // MARK: - Built from the app's own

    /// The next timed events from the calendar, up to `limit`, still to end.
    public static func upcoming(_ events: [Event], now: Date, limit: Int = 3) -> [Event] {
        Array(events.filter { $0.end > now }.sorted { $0.start < $1.start }.prefix(limit))
    }

    /// The newest of today's calls whose notes are written and ready to read.
    /// A call still waiting for its notes (`noNotesYet`) is not ready.
    public static func notesReady(_ calls: [(folder: String, record: MeetingRecord)], now: Date,
                                  calendar: Calendar = .current) -> Notes? {
        calls
            .filter { calendar.isDate($0.record.startedAt, inSameDayAs: now) }
            .filter { $0.record.notesWriter.map { $0.noNotesYet == nil } ?? false }
            .max { $0.record.startedAt < $1.record.startedAt }
            .map { Notes(call: MeetingFiles.title(of: $0.record), folder: $0.folder, at: $0.record.startedAt) }
    }

    /// The event a join link names, or nil when it names none of `events`.
    public static func eventID(from url: URL) -> String? {
        guard url.scheme == "airlock", url.host == joinHost else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "event" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The call folder a notes link names: a plain name only, never a path.
    public static func callFolder(from url: URL) -> String? {
        guard url.scheme == "airlock", url.host == notesHost,
              let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "call" })?.value,
              !name.isEmpty, !name.contains("/"), !name.hasPrefix(".")
        else { return nil }
        return name
    }
}

/// The Next call widget's words.
public enum DeskCallWords {
    public static let name = String(localized: "Next call")
    public static let blurb = String(localized: "Your next call, how long until it starts, and a button to join it.")
    public static let next = String(localized: "Next call")
    public static let now = String(localized: "Now")
    public static let then = String(localized: "Then")
    public static let clearTitle = String(localized: "Nothing else today")
    public static let clearLine = String(localized: "Your calendar is clear.")
    public static let notesReady = String(localized: "Notes ready")
    public static let join = String(localized: "Join")
    public static let tomorrow = String(localized: "Tomorrow")

    public static func ends(_ time: String) -> String { String(localized: "ends \(time)") }

    /// "in 12 min", "in 1 h 5 min": whole minutes, rounded up, so it never
    /// says "in 0 min" before a call has started.
    public static func startsIn(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return String(localized: "in \(minutes) min") }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? String(localized: "in \(hours) h") : String(localized: "in \(hours) h \(rest) min")
    }
}
