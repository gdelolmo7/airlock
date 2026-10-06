import Foundation

/// What the calendar card says while it can't show the agenda, and the one
/// thing to do about it.
///
/// Decided here, from the status and the last request's outcome together,
/// because the card used to decide from one or the other and got three states
/// wrong: a company-managed Mac was sent to a switch it cannot change, add-only
/// access looked exactly like "never asked" and offered a Grant button that
/// macOS may not answer, and a plain refusal never said it was one.
public struct CalendarAccessCard: Equatable, Sendable {
    public enum Remedy: Equatable, Sendable {
        /// Ask macOS: the first time, while nothing is on file.
        case ask
        /// The Calendars page of Privacy & Security.
        case openSystemSettings
        /// Ask again: the last attempt never reached a decision.
        case tryAgain
        /// Nothing the person can do from here.
        case nothing

        public var button: String? {
            switch self {
            case .ask: "Grant Calendar Access"
            case .openSystemSettings: "Open System Settings"
            case .tryAgain: "Try again"
            case .nothing: nil
            }
        }
    }

    public let sentence: String
    public let remedy: Remedy
    /// False only for the first-run invitation, which is an offer rather than
    /// a problem and keeps its own quieter look.
    public let isProblem: Bool

    public static let invitation =
        "See your next meetings here, with one-click join for Zoom, Meet and Teams links."
    /// The button says where to go, so the sentence only says what happened.
    public static let refused = "Calendar access was refused, so your meetings can't show here."
    public static let managed =
        "Whoever manages this Mac has turned calendar access off, so your meetings can't show here."
    public static let addOnly = "Airlock can only add events, so your meetings can't show here."
    public static let suppressed =
        "macOS didn't show its question. Quit Airlock, open it again from Finder, then try again."
    public static let couldNotAsk = "Calendar access couldn't be asked for. Try again in a moment."

    /// nil when the agenda can show.
    public static func card(status: CalendarAuthorization,
                            outcome: CalendarAccessOutcome?) -> CalendarAccessCard? {
        switch status {
        case .fullAccess:
            return nil
        case .restricted:
            // An administrator's decision: the switch in System Settings is
            // greyed out, so a button to it is a dead end.
            return .init(sentence: managed, remedy: .nothing, isProblem: true)
        case .writeOnly:
            // A second request from add-only can go unanswered (the Grant
            // button was seen doing nothing); the page in System Settings is
            // where full access is always on offer.
            return .init(sentence: addOnly, remedy: .openSystemSettings, isProblem: true)
        case .denied, .notDetermined, .other:
            break
        }
        switch outcome {
        case .promptSuppressed:
            // Checked before the status, which reads denied: nothing is on file
            // to turn on, so System Settings would be a page with no Airlock row.
            // No button either: asking again from this same launch is refused
            // the same way, and the sentence says what does work.
            return .init(sentence: suppressed, remedy: .nothing, isProblem: true)
        case .inconclusive:
            return .init(sentence: couldNotAsk, remedy: .tryAgain, isProblem: true)
        case .declined, .standingDenial, .granted, nil:
            break
        }
        if status == .denied {
            return .init(sentence: refused, remedy: .openSystemSettings, isProblem: true)
        }
        return .init(sentence: invitation, remedy: .ask, isProblem: false)
    }
}

/// How wide one day of the week strip is, so the strip shows only whole days.
///
/// A fixed 30pt cell in a column whose width is the person's own setting left
/// a sliver of a tenth day at the right edge, which reads as a rendering
/// mistake. Instead the cells share the width out: as many whole days as fit at
/// the minimum, each widened a little to fill the rest.
public enum DayStripFit {
    public static func cellWidth(for width: Double, minimum: Double, spacing: Double) -> Double {
        guard width.isFinite, width > minimum, minimum > 0 else { return minimum }
        let count = max(1, ((width + spacing) / (minimum + spacing)).rounded(.down))
        return (width - (count - 1) * spacing) / count
    }
}
