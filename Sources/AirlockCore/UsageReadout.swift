import Foundation

/// What the Claude usage figures say about themselves: how old they are, and
/// the sentences that explain them.
///
/// The figures reach Airlock only from a Claude Code session running in a
/// terminal (see `UsageConnection`), so they age whenever none is open. The
/// top bar used to say so in a tooltip, in words like "terminal Claude
/// session", and otherwise only by turning the numbers grey — and when another
/// tool took over the link they froze with nothing on the notch saying why.
public enum UsageReadout {
    /// Past this the figures are not presented as current.
    public static let staleAfter: TimeInterval = 30 * 60
    /// Past this there is nothing worth showing at all.
    public static let trustWindow: TimeInterval = 12 * 3600

    public enum Freshness: Equatable, Sendable {
        /// Nothing to show: no reading, or one too old to mean anything.
        case none
        case current
        /// Shown, with how long ago it was read: "2 h ago".
        case old(String)
    }

    public static func freshness(capturedAt: Date?, now: Date) -> Freshness {
        guard let capturedAt else { return .none }
        let age = now.timeIntervalSince(capturedAt)
        if age >= trustWindow { return .none }
        if age > staleAfter { return .old(AgoPhrase.since(capturedAt, now: now)) }
        return .current
    }

    /// The top bar's tooltip while the figures are current.
    public static let currentHelp =
        "Claude usage: how much of your 5-hour and weekly limits you've used. It updates each time Claude Code answers in a terminal."

    /// The tooltip while they are old. The age is also drawn beside them.
    public static func oldHelp(_ age: String) -> String {
        "Claude usage from \(age). It only updates while Claude Code runs in a terminal; the Claude app doesn't send it. Click to open a terminal with Claude Code."
    }

    /// What is spoken for the figures, in the words the drawing abbreviates.
    public static func spoken(fiveHour: Int?, weekly: Int?, age: String?) -> String {
        var parts: [String] = []
        if let fiveHour { parts.append("5-hour limit \(fiveHour)% used") }
        if let weekly { parts.append("weekly limit \(weekly)% used") }
        var line = "Claude usage: " + parts.joined(separator: ", ")
        if let age { line += ", as of \(age)" }
        return line
    }

    /// The Agents tab's card when the link the figures come through is gone.
    ///
    /// Airlock restores only its own entry, and only when asked: another tool
    /// writing Claude's settings is a choice somebody made, so the card names
    /// what happened and offers the one button that puts Airlock back. The
    /// other tool's line keeps running underneath, as it does at launch.
    public static let stoppedSentence =
        "Claude usage stopped updating: another tool replaced Airlock's link to it."
    public static let restoreButton = "Restore"

    /// Whether that card is due: the figures are wanted, Claude Code is
    /// connected, and the link is somebody else's.
    public static func showsStopped(wanted: Bool, connection: UsageConnection.State) -> Bool {
        wanted && connection == .replaced
    }
}
