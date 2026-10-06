import Foundation

/// The set of agents the build supports. One line per agent.
public struct AgentRegistry: Sendable {
    private let bySource: [String: any AgentIntegration]

    public init(integrations: [any AgentIntegration]) {
        var map: [String: any AgentIntegration] = [:]
        for integration in integrations {
            map[integration.source] = integration
        }
        bySource = map
    }

    public func integration(source: String) -> (any AgentIntegration)? {
        bySource[source]
    }

    public func integration(kind: AgentKind) -> (any AgentIntegration)? {
        bySource.values.first { $0.kind == kind }
    }

    public var all: [any AgentIntegration] {
        Array(bySource.values)
    }

    /// One line per supported agent — this is the whole cost of adding one
    /// (plus its integration file).
    public static let shared = AgentRegistry(integrations: [
        ClaudeCodeIntegration(),
        CodexIntegration(),
    ])
}
