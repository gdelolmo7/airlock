import AirlockTestSupport
import XCTest
@testable import AirlockCore

/// End-to-end policy behavior over a real Unix socket: the hook client sends a
/// PreToolUse gate and the bridge auto-decides (or times out) per policy.
final class BridgePolicyTests: XCTestCase {
    private let scratch = TestScratch("an-bp")

    override func tearDownWithError() throws { scratch.remove() }

    private func makeBridge(policyYAML: String) throws -> (BridgeServer, String) {
        let policyURL = scratch.file("policy.yaml")
        try policyYAML.write(to: policyURL, atomically: true, encoding: .utf8)

        let socketPath = scratch.socket()
        let bridge = BridgeServer(
            registry: .shared, path: socketPath,
            policy: PolicyEngine(store: PolicyStore(globalFileURL: policyURL))
        )
        return (bridge, socketPath)
    }

    private func sendGate(_ command: String, to socketPath: String) async throws -> HookDirective? {
        let claudeJSON = """
        {"session_id":"bp-1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"\(command)"}}
        """
        let payload = HookPayload(
            source: "claude-code", eventName: "PreToolUse", wantsDirective: true,
            cwd: nil, terminal: nil, payload: Data(claudeJSON.utf8), receivedAt: Date()
        )
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let directive = try UnixSocketClient.send(
                        path: socketPath,
                        envelopes: [.hello(protocolVersion: 1), .hookPayload(payload)],
                        awaitDirective: true, timeout: 10
                    )
                    continuation.resume(returning: directive)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func testAllowRuleAutoApprovesWithoutUI() async throws {
        let (bridge, socket) = try makeBridge(policyYAML: "allow:\n  - Bash(git status)")
        try await bridge.start()

        let events = Task { () -> AgentEvent? in
            for await event in bridge.events { return event }
            return nil
        }

        let directive = try await sendGate("git status", to: socket)
        XCTAssertEqual(directive?.action, .allow)
        XCTAssertEqual(directive?.reason, "Approved by Airlock policy rule Bash(git status)")

        // The UI sees a passive activity line, not a permission card.
        let event = await events.value
        guard case let .activity(summary) = event?.kind else {
            return XCTFail("expected activity, got \(String(describing: event))")
        }
        XCTAssertTrue(summary.contains("Auto-approved"))
        await bridge.stop()
    }

    func testDenyRuleAutoDeniesWithReason() async throws {
        let (bridge, socket) = try makeBridge(policyYAML: "deny:\n  - Bash(git push --force*)")
        try await bridge.start()

        let events = Task { () -> AgentEvent? in
            for await event in bridge.events { return event }
            return nil
        }

        let directive = try await sendGate("git push --force origin main", to: socket)
        XCTAssertEqual(directive?.action, .deny)
        XCTAssertEqual(directive?.reason, "Denied by Airlock policy rule Bash(git push --force*). "
                       + "The user's policy file is .airlock/policy.yaml.",
                       "Claude reads this: it names Airlock and the rule, not the old app name")

        // And the row says a call was refused, not that one is under way: the
        // line was built from the RUNNING phrase, so a blocked `rm -rf` read
        // "Auto-denied · Running: rm -rf ./dist".
        let event = await events.value
        guard case let .activity(summary)? = event?.kind else {
            return XCTFail("expected an activity line, got \(String(describing: event))")
        }
        XCTAssertEqual(summary, "Auto-denied · git push --force origin main")
        await bridge.stop()
    }

    func testUnmatchedGateTimesOutToDefer() async throws {
        let (bridge, socket) = try makeBridge(policyYAML: "ask_timeout: 1")
        try await bridge.start()

        let events = Task { () -> [AgentEvent.Kind] in
            var collected: [AgentEvent.Kind] = []
            for await event in bridge.events {
                collected.append(event.kind)
                if case .permissionResolved = event.kind { break }
            }
            return collected
        }

        let started = Date()
        let directive = try await sendGate("npm test", to: socket)
        XCTAssertEqual(directive?.action, .deferToAgent, "unanswered gate must defer, not hang")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9)

        let seen = await events.value
        guard case .permissionRequested = seen.first else {
            return XCTFail("UI should have seen the card first")
        }
        guard case let .permissionResolved(_, decision) = seen.last else {
            return XCTFail("UI should see the card clear on timeout")
        }
        XCTAssertEqual(decision, .deferred)
        await bridge.stop()
    }

    /// A gate handed back writes nothing — Claude's normal permission flow —
    /// and not Claude's `"defer"`, which ends a `-p` run instead.
    func testDeferDirectiveWritesNothingForClaude() {
        let integration = ClaudeCodeIntegration()
        XCTAssertNil(integration.directiveOutput(
            for: HookDirective(action: .deferToAgent), eventName: "PreToolUse"))
    }
}
