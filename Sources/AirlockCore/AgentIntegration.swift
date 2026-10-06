import Foundation

/// Context captured by the hook at invocation time and passed to decoding.
public struct HookContext: Sendable {
    public var source: String
    public var cwd: String?
    public var terminal: TerminalInfo?
    /// PID of the agent process that invoked the hook (parent-chain walk).
    public var agentPID: Int32?
    public var receivedAt: Date

    public init(
        source: String,
        cwd: String?,
        terminal: TerminalInfo?,
        agentPID: Int32? = nil,
        receivedAt: Date
    ) {
        self.source = source
        self.cwd = cwd
        self.terminal = terminal
        self.agentPID = agentPID
        self.receivedAt = receivedAt
    }
}

public enum HookInstallStatus: Sendable, Equatable {
    case installed
    case notInstalled
    case conflict(String)
}

/// How to wire an agent's config file so it calls our hook binary.
/// Installs are idempotent and reversible — never clobber a user's own entries.
public protocol HookInstaller: Sendable {
    var configPath: String { get }
    func install(hookBinaryPath: String) throws
    func status() -> HookInstallStatus
    func uninstall() throws
    /// Subscribe an existing install to events added since it was written,
    /// touching nothing else, and return them. Never installs.
    @discardableResult func upgrade() throws -> [String]
}

extension HookInstaller {
    /// An installer whose events have not grown has nothing to add.
    @discardableResult public func upgrade() throws -> [String] { [] }
}

/// What launch does with every agent's hooks: `HookInstaller.upgrade`, one
/// installer at a time.
public enum HookUpgrade {
    public struct Outcome: Sendable, Equatable {
        public let agent: AgentKind
        /// The events added; empty when there was nothing to add.
        public let added: [String]
        /// Why this agent's config could not be read or written, when it could not.
        public let failure: String?
    }

    /// Never throws, and one agent failing does not stop the next. At launch, a
    /// config file that cannot be read or written costs that agent its new
    /// events and nothing more: the app starts, and the install goes on
    /// working as it did.
    public static func run(_ installers: [(agent: AgentKind, installer: any HookInstaller)]) -> [Outcome] {
        installers.map { entry in
            do {
                return Outcome(agent: entry.agent, added: try entry.installer.upgrade(), failure: nil)
            } catch {
                return Outcome(agent: entry.agent, added: [], failure: error.localizedDescription)
            }
        }
    }
}

/// Everything the app and hook need to support one agent, in one place.
///
/// Adding an agent = one conformer + one line in `AgentRegistry`. No branches
/// scattered across a 2,700-line dispatcher.
public protocol AgentIntegration: Sendable {
    var kind: AgentKind { get }
    /// Wire identifier, matches `AgentKind.rawValue` (the `--source` value).
    var source: String { get }

    /// Does an event of this name block the agent waiting for a decision?
    func isBlocking(eventName: String?) -> Bool

    /// Translate a raw agent hook payload into domain events.
    func decodeEvents(from payload: Data, context: HookContext) throws -> [AgentEvent]

    /// Serialize a decision into the agent's expected stdout bytes for the hook
    /// event that is blocking. Return `nil` to write nothing (fall back to the
    /// agent's normal permission flow).
    func directiveOutput(for directive: HookDirective, eventName: String?) -> Data?

    /// Does this `ps` command line look like this agent's process? Used by the
    /// hook's parent-chain walk and by liveness re-checks (PID-reuse guard).
    func matchesProcess(command: String) -> Bool

    var installer: HookInstaller { get }
}

public extension AgentIntegration {
    func matchesProcess(command: String) -> Bool { false }
}
