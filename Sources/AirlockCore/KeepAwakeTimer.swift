import Foundation

/// Keep awake for a set time: the lengths the menu offers, when a hold that
/// was given an end lets go, and how the time left is said.
///
/// Pure, beside `KeepAwakePolicy`: the clock and the calendar arrive as
/// parameters, so "until 02:30 on the night the clocks change" is a test
/// rather than a wait for October. Nothing here holds an assertion or starts a
/// timer; the model does both, and asks here what they should be.
///
/// **The end is a wall-clock `Date`, on purpose.** A Mac asleep with its lid
/// shut is not counting down on any clock that stops in sleep, so a one-hour
/// hold that wakes three hours later has to let go at once rather than hold on
/// for the hour a stopped clock thinks is still left.
public enum KeepAwakeTimer {
    /// What a hold is asked to last.
    public enum Choice: Equatable, Sendable {
        /// A length in minutes, counted from the moment it starts.
        case lasting(minutes: Int)
        /// Until the next time the clock reads this, today or tomorrow.
        case until(TimeOfDay)
        /// No end: what the switch did before it had lengths.
        case untilTurnedOff
    }

    /// A time on the clock with no day attached: what "Until…" is set to.
    public struct TimeOfDay: Equatable, Sendable {
        public let hour: Int
        public let minute: Int

        /// Folded into one day, so any pair of numbers is a real time: 24:30
        /// is 00:30, and a step back from 00:00 is 23:45.
        public init(hour: Int, minute: Int) {
            let day = Self.minutesInADay
            let total = ((hour * 60 + minute) % day + day) % day
            self.hour = total / 60
            self.minute = total % 60
        }

        /// Moved `steps` of `untilStep` round the clock, landing on the step
        /// grid. A time that is off the grid (one remembered from before the
        /// step changed) lands on the nearest mark in the direction pressed,
        /// so the first press never skips one.
        public func stepped(_ steps: Int) -> TimeOfDay {
            let total = hour * 60 + minute
            let step = KeepAwakeTimer.untilStep
            let marks: Int
            if steps > 0 {
                marks = Int((Double(total) / Double(step)).rounded(.down)) + steps
            } else if steps < 0 {
                marks = Int((Double(total) / Double(step)).rounded(.up)) + steps
            } else {
                return self
            }
            return TimeOfDay(hour: 0, minute: marks * step)
        }

        private static let minutesInADay = 24 * 60
    }

    // MARK: - What the menu offers

    /// The lengths the menu offers, in minutes.
    public static let lengths = [30, 60, 120, 240]

    /// What one click on the switch starts, and the keyboard shortcut with it,
    /// since the shortcut presses the same switch.
    ///
    /// Until it is turned off, which is what the switch always did, so nobody
    /// who never opens the menu finds it behaving differently. This is the one
    /// place to change that.
    public static let singleClick: Choice = .untilTurnedOff

    /// What "+30 min" adds.
    public static let addedTime: TimeInterval = 30 * 60

    /// How far one press of the "Until…" stepper moves the time. A quarter of
    /// an hour reaches the times people say ("until half past five") without
    /// making the evening-to-morning trip a long walk.
    public static let untilStep = 15

    public static let untilTitle = "Until…"
    public static let untilTurnedOffTitle = "Until I turn it off"
    /// The button beside the countdown. Spelled out by `spokenAddedTime`.
    public static let addedTimeTitle = "+30 min"

    /// A length as the menu says it: "30 minutes", "1 hour", "2 hours".
    public static func title(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) minutes" }
        let hours = minutes / 60
        let rest = minutes % 60
        let lead = hours == 1 ? "1 hour" : "\(hours) hours"
        return rest == 0 ? lead : "\(lead) \(rest) minutes"
    }

    /// What VoiceOver says for each item. The visible words lean on the menu
    /// around them; spoken one at a time they need the verb back.
    public static func spokenTitle(minutes: Int) -> String {
        "Keep awake for \(title(minutes: minutes))"
    }

    public static let spokenUntilTitle = "Keep awake until a time you pick"
    public static let spokenUntilTurnedOffTitle = "Keep awake until you turn it off"
    public static let spokenAddedTime = "Add 30 minutes"

    /// Where the "Until…" picker starts when nothing was picked before: on the
    /// hour, at least an hour away. Every length up to four hours is already
    /// one press, so the picker is mostly for later than that.
    public static func suggestedUntil(now: Date, calendar: Calendar) -> TimeOfDay {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: now)
        let hour = parts.hour ?? 0
        let onTheHour = (parts.minute ?? 0) == 0 && (parts.second ?? 0) == 0
        return TimeOfDay(hour: hour + (onTheHour ? 1 : 2), minute: 0)
    }

    // MARK: - When it ends

    /// When a hold started now with `choice` lets go, or nil for one with no
    /// end.
    public static func deadline(for choice: Choice, now: Date, calendar: Calendar) -> Date? {
        switch choice {
        case .lasting(let minutes):
            return now.addingTimeInterval(TimeInterval(minutes) * 60)
        case .until(let time):
            return nextOccurrence(of: time, after: now, calendar: calendar)
        case .untilTurnedOff:
            return nil
        }
    }

    /// The next time the clock reads `time`, strictly after `now`: 08:00 picked
    /// at 23:00 is tomorrow morning, and 08:00 picked at 08:00 is tomorrow too,
    /// since "until now" would end before it began.
    ///
    /// The two nights a year the clocks change:
    /// - A time the clocks skip (02:30 when 02:00 jumps to 03:00) is the moment
    ///   the clock passes it, 03:00. The hold ends when the clock first reads
    ///   later than the time asked for, which is the promise.
    /// - A time the clocks repeat (02:30 twice when 03:00 falls back to 02:00)
    ///   is the first of the two still ahead. Never the later one: a hold that
    ///   ends an hour early is a nuisance, one that holds an hour past its end
    ///   is the thing this must not do.
    public static func nextOccurrence(of time: TimeOfDay, after now: Date, calendar: Calendar) -> Date {
        let wanted = DateComponents(hour: time.hour, minute: time.minute, second: 0)
        // Foundation answers this for every real calendar. The fallback is
        // the most the asked-for time can ever be away, so even an
        // unanswerable calendar cannot stretch a hold past a day.
        return calendar.nextDate(after: now, matching: wanted, matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first, direction: .forward)
            ?? now.addingTimeInterval(24 * 60 * 60)
    }

    /// The end after "+30 min". Counted from now when the old end has already
    /// passed, so a press in the last instant buys the full half hour rather
    /// than whatever was left of it.
    public static func extended(deadline: Date, now: Date) -> Date {
        max(deadline, now).addingTimeInterval(addedTime)
    }

    /// Whether a hold that started at `startedAt` and ends at `deadline` is
    /// over at `now`.
    ///
    /// A clock that went back to before the hold started ends it, the same
    /// side `KeepAwakePolicy.agentsBusy` takes: a wall clock that cannot be
    /// trusted any more must never be the reason a Mac stays up past its end.
    public static func hasEnded(deadline: Date, startedAt: Date, now: Date) -> Bool {
        now >= deadline || now < startedAt
    }

    // MARK: - What the panel says

    /// The time left, in the panel's words: "42 min left", "1 h 20 min left",
    /// "less than a minute left".
    ///
    /// Minutes are rounded to the nearest, so a fresh half hour reads "30 min"
    /// rather than "29 min" a moment after it was picked. A minute or less
    /// reads "less than a minute": every change of wording happens exactly AT
    /// its boundary (`nextWordingChange`), so a redraw scheduled for that
    /// instant already finds the new words.
    public static func timeLeft(until deadline: Date, now: Date) -> String {
        guard let minutes = minutesLeft(until: deadline, now: now) else { return "less than a minute left" }
        guard minutes >= 60 else { return "\(minutes) min left" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h left" : "\(minutes / 60) h \(rest) min left"
    }

    /// The line under the switch while a hold with an end runs.
    public static func countdownLine(until deadline: Date, now: Date) -> String {
        "Awake · \(timeLeft(until: deadline, now: now))"
    }

    /// The same line for VoiceOver, with the abbreviations spelled out:
    /// "min" is read as "minimum" and "h" as a letter.
    public static func spokenCountdown(until deadline: Date, now: Date) -> String {
        "Keeping this Mac awake, \(spokenTimeLeft(until: deadline, now: now))"
    }

    static func spokenTimeLeft(until deadline: Date, now: Date) -> String {
        guard let minutes = minutesLeft(until: deadline, now: now) else { return "less than a minute left" }
        func count(_ n: Int, _ unit: String) -> String { n == 1 ? "1 \(unit)" : "\(n) \(unit)s" }
        guard minutes >= 60 else { return "\(count(minutes, "minute")) left" }
        let rest = minutes % 60
        let hours = count(minutes / 60, "hour")
        return rest == 0 ? "\(hours) left" : "\(hours) \(count(rest, "minute")) left"
    }

    /// When the countdown's words next change, for a redraw then and at no
    /// other time; nil once the hold is over.
    ///
    /// Each whole-minute wording covers the half minute either side of its
    /// minute, and "less than a minute" runs to the end with nothing to
    /// redraw for, so the panel redraws about once a minute and not at all in
    /// the last one.
    public static func nextWordingChange(until deadline: Date, after now: Date) -> Date? {
        let left = deadline.timeIntervalSince(now)
        guard left > 0 else { return nil }
        guard let minutes = minutesLeft(until: deadline, now: now) else { return deadline }
        let boundary = max(TimeInterval(minutes) * 60 - 30, 60)
        return deadline.addingTimeInterval(-boundary)
    }

    /// Whole minutes left, rounded to the nearest, with each boundary going to
    /// the smaller wording; nil for a minute or less.
    private static func minutesLeft(until deadline: Date, now: Date) -> Int? {
        let left = deadline.timeIntervalSince(now)
        guard left > 60 else { return nil }
        return Int(((left - 30) / 60).rounded(.up))
    }

    /// The "Until…" picker's reading of where the time it shows lands: "Until
    /// 08:00" today, "Until 08:00 tomorrow" once the clock has passed it.
    /// The time is written the way the Mac writes times, so a twelve-hour Mac
    /// reads "8:00 AM".
    public static func untilLine(_ time: TimeOfDay, now: Date, calendar: Calendar, locale: Locale) -> String {
        let end = nextOccurrence(of: time, after: now, calendar: calendar)
        let clock = end.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                   calendar: calendar, timeZone: calendar.timeZone))
        return calendar.isDate(end, inSameDayAs: now) ? "Until \(clock)" : "Until \(clock) tomorrow"
    }

    /// Said in the open island when a hold reaches its end. The same quiet
    /// news as the battery cutoff's line, kept until seen by the same rule
    /// (`KeepAwakePolicy.keepsStoppedNotice`).
    public static let endedMessage = "Keep awake ended. Your Mac can sleep again."
}
