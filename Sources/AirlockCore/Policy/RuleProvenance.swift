import Foundation

/// What a rule has actually been doing, and where it came from.
///
/// **A rule you wrote and a rule an Always click wrote are indistinguishable in
/// the file** — both are one line of YAML — so the only evidence of authorship
/// is the gate log: an `alwaysAllowed` record carrying that rule text is a rule
/// somebody clicked into being, on a day the log can name. Anything with no
/// such record was in the file before the log started caring, which in practice
/// means the starter template.
///
/// The match count is what makes a **dead rule visible**. A rules pane without
/// it is a list of sentences that all look equally true; with it, the line
/// nothing has matched in three months is obvious, and that is the line worth
/// deleting.
public struct RuleProvenance: Equatable, Sendable {
    /// How many gates this rule has decided without asking.
    public let matches: Int
    /// The day somebody clicked Always to create it, or nil for template rules.
    public let authoredAt: Date?

    public init(matches: Int, authoredAt: Date?) {
        self.matches = matches
        self.authoredAt = authoredAt
    }

    /// True when nothing in the log was ever decided by this rule.
    ///
    /// Distinct from `matches == 0` only in intent, and named because that is
    /// the whole question the column exists to answer.
    public var hasNeverMatched: Bool { matches == 0 }

    /// What a rule has decided and who put it there, for every rule at once.
    ///
    /// One pass over the log rather than one per rule: a pane with forty rules
    /// and a 500-record log would otherwise be 20,000 comparisons on every
    /// redraw of a window that is open while somebody reads it.
    public static func index(_ log: GateLog) -> [String: RuleProvenance] {
        var matches: [String: Int] = [:]
        var authored: [String: Date] = [:]
        for record in log.records {
            // Only the automatic outcomes are the RULE deciding. A gate you
            // answered by hand is evidence the rule did NOT cover it, and
            // counting those would make the deadest rule in the file look like
            // the busiest.
            switch record.outcome {
            case .autoAllowed, .autoDenied:
                matches[record.ruleText, default: 0] += 1
            case .alwaysAllowed:
                // The click that wrote it. Earliest wins: a rule is created
                // once, and later Always clicks on the same text are the same
                // rule being re-confirmed rather than re-authored.
                if let existing = authored[record.ruleText] {
                    authored[record.ruleText] = min(existing, record.decidedAt)
                } else {
                    authored[record.ruleText] = record.decidedAt
                }
            case .allowedOnce, .denied, .deferred:
                continue
            }
        }
        var index: [String: RuleProvenance] = [:]
        for text in Set(matches.keys).union(authored.keys) {
            index[text] = RuleProvenance(matches: matches[text] ?? 0,
                                         authoredAt: authored[text])
        }
        return index
    }

    /// A rule with no record at all: never matched, never clicked into being.
    public static let unrecorded = RuleProvenance(matches: 0, authoredAt: nil)
}
