import Foundation

/// A raw agent hook payload forwarded by the `agentic-notch-hook` CLI.
///
/// The hook stays tiny: it forwards the agent's bytes verbatim and lets the app
/// decode them via the registry. It only peeks at `eventName` to decide whether
/// to block waiting for a directive.
public struct HookPayload: Codable, Sendable {
    public var source: String          // AgentKind.rawValue, e.g. "claude-code"
    public var eventName: String?      // "PreToolUse", "Stop", ...
    public var wantsDirective: Bool    // true when this is a permission gate
    public var cwd: String?
    public var terminal: TerminalInfo?
    /// PID of the agent process, resolved by the hook's parent-chain walk.
    public var agentPID: Int32?
    public var payload: Data           // the agent's raw stdin JSON
    public var receivedAt: Date

    public init(
        source: String,
        eventName: String?,
        wantsDirective: Bool,
        cwd: String?,
        terminal: TerminalInfo?,
        agentPID: Int32? = nil,
        payload: Data,
        receivedAt: Date
    ) {
        self.source = source
        self.eventName = eventName
        self.wantsDirective = wantsDirective
        self.cwd = cwd
        self.terminal = terminal
        self.agentPID = agentPID
        self.payload = payload
        self.receivedAt = receivedAt
    }
}

/// One newline-delimited message on the bridge socket.
public enum BridgeEnvelope: Codable, Sendable {
    case hello(protocolVersion: Int)
    case hookPayload(HookPayload)
    case directive(HookDirective)
    case ack

    public static let protocolVersion = 1
}
