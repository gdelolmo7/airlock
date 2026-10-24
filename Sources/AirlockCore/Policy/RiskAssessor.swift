import Foundation

/// The built-in safety floor: patterns that can never be auto-approved, no
/// matter what allow rules say. A match downgrades the verdict to "ask" so a
/// human always sees it. (Explicit deny rules still win outright.)
///
/// This is also the single source of truth for the red risk badge in the
/// permission card — one definition of "risky", not two drifting copies.
public enum RiskAssessor {
    public struct Risk: Sendable, Equatable {
        public let reason: String

        /// The card's own line about it, in full view rather than a tooltip on
        /// a six-point dot: the reason, and why there is no "Always" — this
        /// floor is asked before any allow rule is read, so one would never be
        /// honoured.
        public var cardLine: String {
            String(localized: "Risky: \(reason). Airlock asks about this every time.")
        }
    }

    /// (regex, human reason). Case-insensitive.
    private static let patterns: [(String, String)] = [
        (#"\brm\s+-[a-z]*r"#, String(localized: "recursive delete")),
        (#"\bsudo\b"#, String(localized: "elevated privileges")),
        (#"git\s+push\s+[^|;&]*--force(?!-with-lease)"#, String(localized: "force push")),
        (#"git\s+push\s+(\S+\s+)*-f\b"#, String(localized: "force push")),
        (#"git\s+reset\s+--hard"#, String(localized: "hard reset")),
        (#"git\s+clean\s+-\w*f"#, String(localized: "deletes untracked files")),
        (#"\bdd\s+if="#, String(localized: "raw disk write")),
        (#"\bmkfs"#, String(localized: "filesystem format")),
        (#"(curl|wget)[^|;]*\|\s*(sudo\s+)?\w*sh\b"#, String(localized: "pipes web content to a shell")),
        (#"chmod\s+(-\w+\s+)*777"#, String(localized: "world-writable permissions")),
        (#"drop\s+(table|database)"#, String(localized: "destructive SQL")),
        (#"(deploy[^;|&]*prod|prod[^;|&]*deploy)"#, String(localized: "production deploy")),
    ]

    public static func assess(_ request: PermissionRequest) -> Risk? {
        guard let subject = request.target ?? request.command else { return nil }
        for (pattern, reason) in patterns {
            if subject.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return Risk(reason: reason)
            }
        }
        return nil
    }
}
