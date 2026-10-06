import Foundation

/// Whether an agenda row has to say which day it is on, and what to call it.
///
/// The rolling agenda covers the next 24 HOURS, not the rest of today, so it
/// routinely crosses midnight. A row for tomorrow at 09:00 rendered as bare
/// "09:00" — identical to a row for today at 09:00 — underneath a week strip
/// highlighting today. On a quiet Sunday the card showed nothing but Monday's
/// meetings and looked, correctly, like it was displaying the wrong day.
///
/// Pure and calendar-injected because every mistake here is a boundary: the
/// difference between "same day" and "24 hours apart" is not the same question,
/// and the answer changes with time zone, locale and the user's first weekday.
public enum EventDayLabel {
    /// nil when the event is on the reference day — the common case, and one
    /// that must stay unqualified or every row grows noise.
    public static func label(for start: Date,
                             relativeTo now: Date,
                             calendar: Calendar = .current) -> String? {
        let eventDay = calendar.startOfDay(for: start)
        let today = calendar.startOfDay(for: now)
        guard eventDay != today else { return nil }

        // Days apart, not hours: an event 20 hours away can be tomorrow, and an
        // event 3 hours away can be too. Only the calendar knows.
        let days = calendar.dateComponents([.day], from: today, to: eventDay).day ?? 0
        switch days {
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            // A weekday name is unambiguous inside a week and is all the
            // rolling agenda can ever reach. Anything further out only appears
            // when a day is picked deliberately, where the strip already says
            // which one.
            return start.formatted(.dateTime.weekday(.abbreviated))
        }
    }
}
