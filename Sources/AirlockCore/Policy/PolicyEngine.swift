import Foundation

/// The verdict for one permission gate.
public enum PolicyVerdict: Sendable, Equatable {
    case allow(rule: String)
    case deny(rule: String)
    /// Interrupt the human. `risk` is set when the built-in floor triggered.
    case ask(risk: String?)
}

/// What the bridge should do with a gate: the verdict plus how long to hold it
/// open before deferring to the agent's own prompt.
public struct GateDecision: Sendable, Equatable {
    public let verdict: PolicyVerdict
    public let askTimeout: TimeInterval
}

/// Evaluates permission requests against the merged policy.
///
/// Precedence (safety first):
///   1. any deny rule matches            → deny
///   2. built-in risk floor triggers     → ask (never auto-approve danger)
///   3. any allow rule matches           → allow
///   4. otherwise                        → ask
public struct PolicyEngine: Sendable {
    public let store: PolicyStore

    public init(store: PolicyStore = PolicyStore()) {
        self.store = store
    }

    /// Load-and-decide for one gate. File I/O is two tiny local reads on the
    /// rare permission path — fine to do inline.
    public func plan(for request: PermissionRequest, projectRoot: String?) -> GateDecision {
        let result = store.load(projectRoot: projectRoot)
        for problem in result.problems {
            // Private: a parse problem quotes the offending rule, which is a
            // command pattern off the user's machine.
            Log.policy.error("\(problem, privacy: .private)")
        }
        return GateDecision(
            verdict: Self.evaluate(request, policy: result.policy),
            askTimeout: result.policy.askTimeout ?? Policy.defaultAskTimeout
        )
    }

    /// Pure evaluation — unit-testable without a filesystem.
    public static func evaluate(_ request: PermissionRequest, policy: Policy) -> PolicyVerdict {
        if let rule = policy.deny.first(where: { $0.matches(request) }) {
            return .deny(rule: rule.text)
        }
        if let risk = RiskAssessor.assess(request) {
            return .ask(risk: risk.reason)
        }
        if let rule = policy.allow.first(where: { $0.matches(request) }) {
            return .allow(rule: rule.text)
        }
        return .ask(risk: nil)
    }
}
