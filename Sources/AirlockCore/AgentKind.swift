import Foundation

/// Identity of a supported coding agent.
///
/// Adding an agent starts here, but the real integration is a single
/// `AgentIntegration` conformer registered in `AgentRegistry` — never a
/// scatter of `if agent == .x` branches across the codebase.
public enum AgentKind: String, Codable, Sendable, CaseIterable, Hashable {
    case claudeCode = "claude-code"
    case codex
    case cursor
    case unknown

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .unknown: return "Agent"
        }
    }

    /// Two-letter monogram used by the notch avatar (replaces the original's
    /// 10-colour "confetti" palette with a calm, family-of-one look).
    public var monogram: String {
        switch self {
        case .claudeCode: return "CC"
        case .codex: return "Cx"
        case .cursor: return "Cu"
        case .unknown: return "··"
        }
    }
}
