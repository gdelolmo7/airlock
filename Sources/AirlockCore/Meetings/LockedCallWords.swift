import Foundation

/// What is said about a Free call's locked part (`LockedPart`): on the
/// ready card, on the notes window's notice, at the end of the transcript,
/// and on the welcome card once a paid plan opens it.
public enum LockedCallWords {
    /// How many days the part is kept, as said.
    public static var keptDays: Int { Int(CallLock.keptFor / 86_400) }

    static var limitMinutes: Int { Int(PlanLimits.freeNotesListen / 60) }

    /// "Tuesday 27 October".
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        format("EEEE d MMMM", template: "EEEEdMMMM", date, timeZone)
    }

    /// "9:30".
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        format("H:mm", template: "Hmm", date, timeZone)
    }

    /// In English, the British pattern these sentences were written around;
    /// in any other language, the Mac's own way of writing it.
    private static func format(_ pattern: String, template: String, _ date: Date, _ timeZone: TimeZone) -> String {
        let format = DateFormatter()
        format.timeZone = timeZone
        if Locale.current.language.languageCode == .english {
            format.locale = Locale(identifier: "en_GB")
            format.dateFormat = pattern
        } else {
            format.locale = .current
            format.setLocalizedDateFormatFromTemplate(template)
        }
        return format.string(from: date)
    }

    /// The ready card's line: "Notes cover the first 30 minutes. The last
    /// 12 are kept until Tuesday 27 October, for Plus."
    public static func ready(minutes: Int, until: Date, timeZone: TimeZone = .current) -> String {
        let untilDay = day(until, timeZone: timeZone)
        return minutes == 1
            ? String(localized: "Notes cover the first \(limitMinutes) minutes. The last minute is kept until \(untilDay), for Plus.")
            : String(localized: "Notes cover the first \(limitMinutes) minutes. The last \(minutes) are kept until \(untilDay), for Plus.")
    }

    /// Said after the window's "These notes cover the first 30 minutes…"
    /// while the part is kept.
    public static func kept(minutes: Int, until: Date, timeZone: TimeZone = .current) -> String {
        let untilDay = day(until, timeZone: timeZone)
        return minutes == 1
            ? String(localized: "The last minute is kept on this Mac until \(untilDay). Plus opens them and writes notes of the whole call.")
            : String(localized: "The last \(minutes) minutes are kept on this Mac until \(untilDay). Plus opens them and writes notes of the whole call.")
    }

    /// The same once its week is over.
    public static func removed(minutes: Int, on date: Date, timeZone: TimeZone = .current) -> String {
        let removedDay = day(date, timeZone: timeZone)
        return minutes == 1
            ? String(localized: "The other minute was kept for \(keptDays) days and removed on \(removedDay).")
            : String(localized: "The other \(minutes) minutes were kept for \(keptDays) days and removed on \(removedDay).")
    }

    /// At the end of the transcript, where the locked part would be.
    public static func waitingTitle(minutes: Int) -> String {
        minutes == 1 ? String(localized: "1 more minute is waiting") : String(localized: "\(minutes) more minutes are waiting")
    }

    /// Under `waitingTitle`: "9:30 to 9:42, kept on this Mac until Tuesday
    /// 27 October. Plus opens them and writes notes of the whole call."
    public static func waitingDetail(from: Date, to: Date, until: Date, timeZone: TimeZone = .current) -> String {
        String(localized: "\(clock(from, timeZone: timeZone)) to \(clock(to, timeZone: timeZone)), kept on this Mac until \(day(until, timeZone: timeZone)). Plus opens them and writes notes of the whole call.")
    }

    /// The welcome card's redo question, for a call a paid plan just opened.
    public static func redoQuestion(title: String, when: String, minutes: Int) -> String {
        String(localized: "Write the notes of “\(title)” (\(when), \(minutes) min) again, for the whole call?")
    }

    /// Under it.
    public static func redoReason(opened minutes: Int) -> String {
        minutes == 1
            ? String(localized: "Free's notes covered the first \(limitMinutes) minutes. The other minute was kept on this Mac, and is open now.")
            : String(localized: "Free's notes covered the first \(limitMinutes) minutes. The other \(minutes) were kept on this Mac, and are open now.")
    }
}
