import Foundation

/// Codex CLI integration.
///
/// Codex's lifecycle hooks (config-reference: PreToolUse, PermissionRequest,
/// PostToolUse, SessionStart, UserPromptSubmit, Stop, …) use "the same event
/// schema as hooks.json" — i.e. the Claude-style payload — but are
/// **observational**: they cannot block or approve. So Codex sessions get
/// status, attention ("approve in terminal"), jump-back, and liveness; actual
/// approval stays in the terminal until Codex exposes a gating channel.
public struct CodexIntegration: AgentIntegration {
    public init() {}

    public var kind: AgentKind { .codex }
    public var source: String { AgentKind.codex.rawValue }
    public var installer: HookInstaller { CodexHookInstaller() }

    /// Codex hooks are fire-and-forget; nothing ever waits on a directive.
    public func isBlocking(eventName: String?) -> Bool { false }

    public func directiveOutput(for directive: HookDirective, eventName: String?) -> Data? { nil }

    /// Codex is a native binary: `codex`, `codex exec …`, or a platform binary
    /// like `codex-aarch64-apple-darwin` behind the npm wrapper.
    public func matchesProcess(command: String) -> Bool {
        let tokens = command.split(separator: " ")
        func basename(_ index: Int) -> String {
            guard index < tokens.count else { return "" }
            let token = tokens[index]
            return String(token.split(separator: "/").last ?? token).lowercased()
        }
        let first = basename(0)
        if first == "codex" || first.hasPrefix("codex-") { return true }
        let interpreters: Set<String> = ["node", "bun", "deno"]
        return interpreters.contains(first) && basename(1) == "codex"
    }

    public func decodeEvents(from payload: Data, context: HookContext) throws -> [AgentEvent] {
        try ClaudeStyleHookDecoder.decode(
            payload: payload, context: context, agent: .codex, gatesPermissions: false)
    }
}
