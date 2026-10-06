import Foundation

/// A parsed policy file. Scalars are optional so merging knows whether a file
/// actually set them (project scalar wins over global; defaults apply last).
public struct Policy: Sendable, Equatable {
    public var version: Int?
    /// Seconds before an unanswered gate auto-defers to the agent's own
    /// prompt. 0 = wait forever.
    public var askTimeout: TimeInterval?
    public var allow: [PolicyRule]
    public var deny: [PolicyRule]

    public static let defaultAskTimeout: TimeInterval = 300

    public init(
        version: Int? = nil,
        askTimeout: TimeInterval? = nil,
        allow: [PolicyRule] = [],
        deny: [PolicyRule] = []
    ) {
        self.version = version
        self.askTimeout = askTimeout
        self.allow = allow
        self.deny = deny
    }

    /// Merge a project policy over this (global) one. Rule lists concatenate —
    /// deny-first evaluation makes ordering irrelevant; a project deny always
    /// beats a global allow.
    public func merging(project: Policy) -> Policy {
        Policy(
            version: project.version ?? version,
            askTimeout: project.askTimeout ?? askTimeout,
            allow: allow + project.allow,
            deny: deny + project.deny
        )
    }
}
