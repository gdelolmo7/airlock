import Foundation

/// What became of one permission gate.
public enum GateOutcome: String, Codable, Sendable, Equatable {
    /// The human approved this occurrence only.
    case allowedOnce
    case denied
    /// The human approved and a rule was written, so this will not be asked again.
    case alwaysAllowed
    /// Nobody answered in time; the agent's own prompt took over.
    case deferred
    /// A policy allow rule matched — never reached a human.
    case autoAllowed
    /// A policy deny rule matched — never reached a human.
    case autoDenied

    /// Decisions the human actually made. Only these say anything about what
    /// the human *wants*, which is the only thing worth turning into a
    /// suggestion. A `deferred` gate is a question nobody answered, and an
    /// auto-decision is a rule already doing its job.
    public var isHumanDecision: Bool {
        self == .allowedOnce || self == .denied
    }

    /// The outcome a user decision amounts to. `deferred` is the timeout, and
    /// it is deliberately not a human decision — nobody answered.
    public init(_ decision: PermissionDecision) {
        switch decision {
        case .allowOnce: self = .allowedOnce
        case .deny: self = .denied
        case .alwaysAllow: self = .alwaysAllowed
        case .deferred: self = .deferred
        }
    }

    public var label: String {
        switch self {
        case .allowedOnce: return "Allowed once"
        case .denied: return "Denied"
        case .alwaysAllowed: return "Always allowed"
        case .deferred: return "Deferred to terminal"
        case .autoAllowed: return "Auto-approved"
        case .autoDenied: return "Auto-denied"
        }
    }
}

/// One resolved gate, kept so the app can answer two questions it currently
/// cannot: "what have you been letting through?" and "what do you keep asking
/// me about?".
public struct GateRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let toolName: String
    /// The command or path the rule would match on. Nil for tools that take
    /// neither, where a rule can only ever be tool-wide.
    public let subject: String?
    /// The exact rule this gate would produce — also the grouping key.
    public let ruleText: String
    public let outcome: GateOutcome
    /// Set when the built-in floor triggered. Load-bearing: such a gate can
    /// never be auto-approved, so it must never be suggested as an allow rule.
    public let riskReason: String?
    public let agent: String?
    /// The working directory of the session that asked — the folder a
    /// "just this project" rule for this gate would be written into. Nil when
    /// there was none (a spoken action) and on every record logged before the
    /// field existed, which decode without it.
    public let projectRoot: String?
    public let decidedAt: Date

    public init(id: UUID = UUID(), toolName: String, subject: String?, ruleText: String,
                outcome: GateOutcome, riskReason: String? = nil, agent: String? = nil,
                projectRoot: String? = nil, decidedAt: Date) {
        self.id = id
        self.toolName = toolName
        self.subject = subject
        self.ruleText = ruleText
        self.outcome = outcome
        self.riskReason = riskReason
        self.agent = agent
        self.projectRoot = projectRoot
        self.decidedAt = decidedAt
    }

    /// Built from a live request, so the rule text here is exactly the one
    /// "Always" would have written.
    public init(request: PermissionRequest, outcome: GateOutcome, agent: String? = nil,
                projectRoot: String? = nil, decidedAt: Date) {
        self.init(toolName: request.toolName,
                  subject: PolicyRule.subject(of: request),
                  ruleText: PolicyRule.exactRuleText(for: request),
                  outcome: outcome,
                  riskReason: RiskAssessor.assess(request)?.reason,
                  agent: agent,
                  projectRoot: projectRoot,
                  decidedAt: decidedAt)
    }

    /// A stand-in request, for asking the policy whether this is already covered.
    public var asRequest: PermissionRequest {
        PermissionRequest(id: id.uuidString, toolName: toolName, summary: ruleText,
                          command: subject, target: subject, createdAt: decidedAt)
    }
}

/// The gate history, newest first.
public struct GateLog: Codable, Sendable, Equatable {
    public private(set) var records: [GateRecord]

    /// Enough to see a pattern, small enough that the file stays trivial. This
    /// is a log of commands, so keeping it short is a privacy property as much
    /// as a performance one.
    public static let defaultCapacity = 500

    public init(records: [GateRecord] = []) {
        self.records = records
    }

    public mutating func append(_ record: GateRecord, capacity: Int = defaultCapacity) {
        records.insert(record, at: 0)
        if records.count > capacity { records.removeLast(records.count - capacity) }
    }

    public mutating func clear() { records.removeAll() }
}

/// A rule the app thinks you might want, and why.
public struct PolicySuggestion: Equatable, Sendable, Identifiable {
    public let ruleText: String
    public let kind: PolicyRuleKind
    public let toolName: String
    /// How many times you answered this way.
    public let count: Int
    public let lastSeen: Date
    /// Set when this gate trips the risk floor. Only ever attached to deny
    /// suggestions — see `PolicySuggestions`.
    public let riskReason: String?
    /// Narrowest first. The literal rule is always `[0]`; anything after it
    /// covers a family, which is the difference between a rule that works twice
    /// and one that works forever.
    public let candidates: [RuleCandidate]
    /// The one project every decision behind this suggestion came from, or nil.
    ///
    /// **Nil is a refusal, not a default.** Decisions from two projects, or any
    /// decision with no folder, mean there is no single project to scope the
    /// rule to — so "just this project" is not offered, and must not be written.
    /// Falling back to global would do the opposite of what the button says,
    /// and guessing a project would auto-allow commands somewhere nobody chose.
    public let projectRoot: String?

    public var id: String { "\(kind.rawValue):\(ruleText)" }

    /// What the button writes unless you pick otherwise.
    public var recommended: RuleCandidate {
        candidates.count > 1 ? candidates[1] : (candidates.first
            ?? RuleCandidate(text: ruleText, summary: "", isExact: true))
    }
}

/// Turns the log into rules worth offering.
///
/// The point is to stop asking people to author policy in the abstract. Nobody
/// sits down wanting to write `Bash(npm test)`; they want to stop being asked
/// about `npm test`. So the app watches what you actually answer and offers the
/// rule, and the syntax becomes a detail you can ignore.
///
/// Pure, and worth testing carefully, because the one thing this must never do
/// is offer to auto-approve something dangerous.
public enum PolicySuggestions {
    /// Twice is a pattern; once is an accident.
    public static let defaultMinimumCount = 2

    public static func from(_ log: GateLog, policy: Policy,
                            minimumCount: Int = defaultMinimumCount) -> [PolicySuggestion] {
        var grouped: [String: [GateRecord]] = [:]
        for record in log.records where record.outcome.isHumanDecision {
            grouped[record.ruleText, default: []].append(record)
        }

        var suggestions: [PolicySuggestion] = []
        for (ruleText, records) in grouped {
            // A rule text answered both ways is genuinely ambiguous — the same
            // command approved sometimes and refused others. Offering either
            // would be guessing, so offer neither.
            let allowed = records.filter { $0.outcome == .allowedOnce }
            let denied = records.filter { $0.outcome == .denied }
            guard allowed.isEmpty != denied.isEmpty else { continue }

            let kind: PolicyRuleKind = denied.isEmpty ? .allow : .deny
            let matching = denied.isEmpty ? allowed : denied
            guard matching.count >= minimumCount else { continue }

            let risk = matching.compactMap(\.riskReason).first

            // The floor overrides allow rules, so an allow rule here would be a
            // promise the engine will not keep — it would still ask, and the
            // user would reasonably conclude the feature is broken. Deny
            // suggestions for the same command are fine, and more use.
            if kind == .allow && risk != nil { continue }

            // Already handled. Note this matches by *behaviour*, not text: a
            // broad `Bash(git *)` covers `Bash(git status)`, and re-suggesting
            // it would be noise.
            let request = matching[0].asRequest
            let existing = kind == .allow ? policy.allow : policy.deny
            if existing.contains(where: { $0.matches(request) }) { continue }

            suggestions.append(PolicySuggestion(
                ruleText: ruleText,
                kind: kind,
                toolName: matching[0].toolName,
                count: matching.count,
                lastSeen: matching.map(\.decidedAt).max() ?? matching[0].decidedAt,
                riskReason: risk,
                candidates: RuleGeneralizer.candidates(for: request),
                projectRoot: soleProject(of: matching)))
        }

        return suggestions.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.lastSeen > $1.lastSeen
        }
    }

    /// The project all of these were decided in, or nil when they span several
    /// or any has none. See `PolicySuggestion.projectRoot`.
    static func soleProject(of records: [GateRecord]) -> String? {
        guard let first = records.first?.projectRoot,
              records.allSatisfy({ $0.projectRoot == first }) else { return nil }
        return first
    }
}
