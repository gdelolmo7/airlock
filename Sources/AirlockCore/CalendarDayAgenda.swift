import Foundation

/// Two questions a day's agenda has to answer before it can be drawn: which row
/// should be in view when it opens, and which rows are already history.
///
/// Both are about an instant AND a day, and answering either with the instant
/// alone is wrong in a way that looks fine in a screenshot:
///
/// - Pick today at 15:00 and the card opened on the 09:00 stand-up, three
///   finished rows above the meeting you are actually in.
/// - Dimming compared `end <= now` without asking which day was on screen, so
///   yesterday rendered uniformly half-dead and tomorrow uniformly live. A
///   picked day is a whole unit — nothing on it is "already over" relative to a
///   clock that is not running inside it.
///
/// Pure and calendar-injected for the same reason as `EventDayLabel`: "is this
/// day today" is a question only the calendar and the time zone can answer, and
/// `Date` arithmetic gets it wrong at every boundary. Core is clockless, so
/// `now` is always a parameter.
public enum CalendarDayAgenda {
    /// The only part of an agenda row these decisions need. The app's
    /// `CalendarEvent` carries titles, colours and join links; none of them
    /// change where the list opens or what counts as finished.
    public struct Event: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let isAllDay: Bool

        public init(start: Date, end: Date, isAllDay: Bool) {
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
        }
    }

    /// Whether the agenda on screen is the one `now` is inside of, and therefore
    /// whether relative language ("now", "in 40m") and dimming mean anything.
    ///
    /// `day == nil` is the rolling agenda, which is built from `now` outwards
    /// and so is anchored to it by construction even where it crosses midnight.
    public static func reflectsNow(day: Date?,
                                   now: Date,
                                   calendar: Calendar = .current) -> Bool {
        guard let day else { return true }
        return calendar.isDate(day, inSameDayAs: now)
    }

    /// Finished, and therefore worth fading: still useful context for reading
    /// the day, not something to act on.
    ///
    /// False on any day the clock is not running inside — see the type comment.
    /// False for all-day events at all times: an all-day row has no minute to be
    /// past, and fading half of a day's OOO markers says nothing true.
    public static func isPast(_ event: Event,
                              day: Date?,
                              now: Date,
                              calendar: Calendar = .current) -> Bool {
        guard !event.isAllDay else { return false }
        guard reflectsNow(day: day, now: now, calendar: calendar) else { return false }
        return event.end <= now
    }

    /// Index into `events` — timed rows, ascending by start — of the row the
    /// agenda should open on.
    ///
    /// Today opens on whatever is running, else on the next thing to start;
    /// `end > now` covers both in one test, which is the point: a meeting you
    /// are in the middle of must not be scrolled past just because it started.
    ///
    /// Zero for any other day, because a day you picked deliberately is read
    /// from its beginning, and zero again for a today whose events have all
    /// finished — with nothing running and nothing coming, there is no row to
    /// prefer, and the honest answer is the whole day rather than its last item.
    public static func focusIndex(in events: [Event],
                                  day: Date?,
                                  now: Date,
                                  calendar: Calendar = .current) -> Int {
        guard reflectsNow(day: day, now: now, calendar: calendar) else { return 0 }
        guard let index = events.firstIndex(where: { !$0.isAllDay && $0.end > now }) else { return 0 }
        return index
    }
}
