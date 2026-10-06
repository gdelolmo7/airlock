import Foundation

/// How a battery reading is put into words.
///
/// Pure, clockless and UI-free: IOKit's numbers arrive as parameters and
/// sentences leave as strings. It lives in Core because a battery gets described
/// in two places — the gutter indicator's tooltip and screen-reader label, and
/// the compact island's critical rung — and two hand-written phrasings of the
/// same reading is exactly how the island ends up saying "18 minutes left" while
/// the gutter says something else about the same battery. `remaining(minutes:)`
/// is the single sentence both of them build on.
///
/// **An absent estimate is a state, not a zero.** macOS publishes no time
/// remaining at all for the first minutes after the cable moves — the
/// "Calculating…" in the system menu — and that is the *common* case right after
/// you unplug, not an edge one. Everything here takes an optional and says the
/// absence in words; nothing rounds it down to "0 minutes left".
public enum BatteryReading {
    /// "18 minutes", "1 hour", "2 hours 5 minutes" — or nil when there is no
    /// estimate to give. Non-positive counts are treated as absent: IOKit reports
    /// -1 while it is still working one out.
    public static func duration(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let hours = minutes / 60
        let rest = minutes % 60
        let hourPart = hours == 1 ? "1 hour" : "\(hours) hours"
        let minutePart = rest == 1 ? "1 minute" : "\(rest) minutes"
        if hours == 0 { return minutePart }
        if rest == 0 { return hourPart }
        return "\(hourPart) \(minutePart)"
    }

    /// "18 minutes left", or nil when macOS has no estimate yet. The caller
    /// decides what to say instead — the island drops the clause and keeps its
    /// glyph, the gutter admits it is still calculating.
    public static func remaining(minutes: Int?) -> String? {
        guard let phrase = duration(minutes: minutes) else { return nil }
        return "\(phrase) left"
    }

    /// Plugged in and not charging. macOS does this on purpose — Optimised
    /// Battery Charging, or the charge limit — and "on power" beside a bolt read
    /// as a charger that had stopped working. Saying why is the whole fix.
    public static let holding = "plugged in, holding the charge to protect the battery"

    /// What the gutter draws: the battery at its real level, plus a small mark
    /// for the cable. A full battery with a bolt at 5% was the old drawing, and
    /// it said the opposite of the number beside it.
    public enum Mark: Equatable, Sendable {
        case none
        /// Charging: a bolt.
        case charging
        /// On power, not charging: a plug, never a bolt.
        case holding
    }

    public static func mark(isCharging: Bool, isPluggedIn: Bool, isCharged: Bool) -> Mark {
        if isCharging { return .charging }
        // Fully charged on the cable is finished, not held back; the level
        // glyph is already full and says it.
        if isPluggedIn && !isCharged { return .holding }
        return .none
    }

    /// The SF Symbol for the level alone. SF Symbols has a bolt only on the
    /// full battery, so the cable's mark is drawn beside this, not inside it.
    public static func levelSymbol(percentage: Int) -> String {
        switch percentage {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    /// The whole gutter indicator in one sentence, for the tooltip and the
    /// accessibility label alike.
    ///
    /// The percentage is repeated even when the gutter draws it, because whether
    /// it draws it is a setting (`showsBatteryPercentage`) and a label that
    /// changes meaning with an unrelated toggle is worse than one redundant word.
    ///
    /// A time estimate is only ever attached to the two states where IOKit has
    /// one that means anything: charging (time to full) and running on the
    /// battery (time to empty). Plugged in and holding — the 80% charge limit,
    /// most of a working day at a desk — is neither, and inventing "3 hours left"
    /// for a Mac on mains would be a lie with a number in it.
    public static func status(percentage: Int,
                              isCharging: Bool,
                              isPluggedIn: Bool,
                              isCharged: Bool,
                              minutesRemaining: Int?) -> String {
        let head = "Battery \(percentage)%"
        if isCharged { return "\(head), fully charged" }
        if isCharging {
            guard let full = duration(minutes: minutesRemaining) else {
                return "\(head), charging, calculating time until full"
            }
            return "\(head), charging, \(full) until full"
        }
        if isPluggedIn { return "\(head), \(holding)" }
        guard let left = remaining(minutes: minutesRemaining) else {
            return "\(head), calculating time left"
        }
        return "\(head), \(left)"
    }
}
