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
            "Risky: \(reason). Airlock asks about this every time."
        }
    }

    /// (regex, human reason). Case-insensitive.
    private static let patterns: [(String, String)] = [
        (#"\brm\s+-[a-z]*r"#, "recursive delete"),
        (#"\bsudo\b"#, "elevated privileges"),
        (#"git\s+push\s+[^|;&]*--force(?!-with-lease)"#, "force push"),
        (#"git\s+push\s+(\S+\s+)*-f\b"#, "force push"),
        (#"git\s+reset\s+--hard"#, "hard reset"),
        (#"git\s+clean\s+-\w*f"#, "deletes untracked files"),
        (#"\bdd\s+if="#, "raw disk write"),
        (#"\bmkfs"#, "filesystem format"),
        (#"(curl|wget)[^|;]*\|\s*(sudo\s+)?\w*sh\b"#, "pipes web content to a shell"),
        (#"chmod\s+(-\w+\s+)*777"#, "world-writable permissions"),
        (#"drop\s+(table|database)"#, "destructive SQL"),
        (#"(deploy[^;|&]*prod|prod[^;|&]*deploy)"#, "production deploy"),
    ]

    public static func assess(_ request: PermissionRequest) -> Risk? {
        // Spoken actions have their own floor, declared by the action itself.
        //
        // Two domains, still one definition of "risky" — which is the point of
        // routing them through here rather than adding a second assessor. The
        // patterns below are shell regexes and would match a spoken subject only
        // by accident: `Voice.Clipboard(Terminal)` is a source app, and a clip
        // whose text happens to contain "sudo" is not an elevated command.
        if VoiceActionCatalog.isVoiceTool(request.toolName) {
            return VoiceActionCatalog.riskFloorReason(toolName: request.toolName)
                .map { Risk(reason: $0) }
        }
        guard let subject = request.target ?? request.command else { return nil }
        for (pattern, reason) in patterns {
            if subject.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return Risk(reason: reason)
            }
        }
        return nil
    }
}
