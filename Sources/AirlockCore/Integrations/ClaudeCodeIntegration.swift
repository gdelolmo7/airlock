import Foundation

/// Claude Code integration.
///
/// Claude fires hooks with JSON on stdin (the schema `ClaudeStyleHookDecoder`
/// speaks natively) and honours a decision written to stdout on exit 0 — so
/// Claude gates permissions through the notch for real.
public struct ClaudeCodeIntegration: AgentIntegration {
    public init() {}

    public var kind: AgentKind { .claudeCode }
    public var source: String { AgentKind.claudeCode.rawValue }
    public var installer: HookInstaller { ClaudeHookInstaller() }

    /// The two events Claude waits on and takes an answer from: PreToolUse,
    /// before a call runs, and PermissionRequest, when Claude is about to ask in
    /// its own window. Which of them opens a card is the decoder's business;
    /// either one that does not is acknowledged at once and writes nothing.
    /// Notification is informational (decoded for display, not blocked).
    public func isBlocking(eventName: String?) -> Bool {
        eventName == "PreToolUse" || eventName == "PermissionRequest"
    }

    /// Claude Code shows up as `claude …` or as an interpreter running the
    /// script (`node …/claude …`). The second token only counts behind a known
    /// interpreter, so `grep claude notes.txt` or the `sh -c …claude-code…`
    /// hook wrapper never match.
    public func matchesProcess(command: String) -> Bool {
        let tokens = command.split(separator: " ")
        func basename(_ index: Int) -> String {
            guard index < tokens.count else { return "" }
            let token = tokens[index]
            return String(token.split(separator: "/").last ?? token).lowercased()
        }
        if basename(0) == "claude" { return true }
        let interpreters: Set<String> = ["node", "bun", "deno"]
        return interpreters.contains(basename(0)) && basename(1) == "claude"
    }

    public func decodeEvents(from payload: Data, context: HookContext) throws -> [AgentEvent] {
        try ClaudeStyleHookDecoder.decode(
            payload: payload, context: context, agent: .claudeCode, gatesPermissions: true)
    }

    /// Each of the two events has its own schema; anything else writes nothing.
    public func directiveOutput(for directive: HookDirective, eventName: String?) -> Data? {
        switch eventName {
        case "PreToolUse": return preToolUseOutput(for: directive)
        case "PermissionRequest": return permissionRequestOutput(for: directive)
        default: return nil
        }
    }

    /// PreToolUse decision schema (verified against the Claude Code hooks docs):
    /// `{ "hookSpecificOutput": { "hookEventName": "PreToolUse",
    ///     "permissionDecision": "allow|deny|ask", … } }` on exit 0.
    /// Writing nothing = "no decision", so Claude's own prompt runs — exactly
    /// the fallback we want if the notch never answers.
    ///
    /// Which is why a gate the notch hands back writes nothing, and never
    /// `"defer"`, whatever the directive's raw value says. Claude's `"defer"` is
    /// not "no decision". It is honoured only in `-p` runs, where it ENDS the
    /// run (`stop_reason: "tool_deferred"`) so that the program driving it can
    /// ask its own user and resume later — and nothing resumes a run because a
    /// card was dismissed. In an interactive session it is ignored with a
    /// warning. Nothing at all is the normal permission flow in both.
    private func preToolUseOutput(for directive: HookDirective) -> Data? {
        let permissionDecision: String
        switch directive.action {
        case .allow: permissionDecision = "allow"
        case .deny: permissionDecision = "deny"
        case .ask: permissionDecision = "ask"
        case .deferToAgent: return nil
        }
        return encoded([
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": permissionDecision,
                "permissionDecisionReason": directive.reason ?? defaultReason(permissionDecision),
            ],
        ])
    }

    /// PermissionRequest decision schema (verified against the Claude Code
    /// hooks docs): `{ "hookSpecificOutput": { "hookEventName":
    /// "PermissionRequest", "decision": { "behavior": "allow" } } }` on exit 0,
    /// or `"behavior": "deny"` with a `message` — the reason, which Claude reads.
    /// A different shape from PreToolUse's, and the only thing this event
    /// takes as an answer: not even exit code 2 denies here.
    ///
    /// There is no "ask" on this event, because Claude is already asking, and
    /// nothing written is its documented "flow unchanged": Claude's own dialog
    /// takes the question. So a card handed back — dismissed, timed out, or the
    /// app gone — puts it back in the window where Claude asked it.
    private func permissionRequestOutput(for directive: HookDirective) -> Data? {
        let decision: [String: Any]
        switch directive.action {
        case .allow:
            decision = ["behavior": "allow"]
        case .deny:
            decision = ["behavior": "deny", "message": directive.reason ?? defaultReason("deny")]
        case .ask, .deferToAgent:
            return nil
        }
        return encoded([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ],
        ])
    }

    /// Sorted keys, so one answer is always the same bytes.
    private func encoded(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func defaultReason(_ decision: String) -> String {
        switch decision {
        case "allow": return "Approved from Airlock"
        case "deny": return "Denied from Airlock"
        default: return "No decision from Airlock — using the normal permission flow"
        }
    }
}
