import AirlockTestSupport
import XCTest
@testable import AirlockCore

/// End-to-end verification of the live Claude loop over a real Unix socket:
/// hook payload → transport → decode → reducer-ready event → resolve → directive
/// back to the (blocking) client. Exercises the exact code path the real hook
/// binary and the app use, without touching the user's ~/.claude config.
final class BridgeIntegrationTests: XCTestCase {
    private let scratch = TestScratch("an-itest")

    override func tearDownWithError() throws { scratch.remove() }

    func testPreToolUseRoundTripApprove() async throws {
        let path = scratch.socket()
        // Empty temp policy → deterministic "ask" regardless of the host's files.
        let policyURL = scratch.file("policy.yaml")
        let bridge = BridgeServer(
            registry: .shared, path: path,
            policy: PolicyEngine(store: PolicyStore(globalFileURL: policyURL))
        )
        try await bridge.start()

        let claudePayload = Data(#"""
        {"session_id":"sess-1","hook_event_name":"PreToolUse","cwd":"/tmp/proj","tool_name":"Bash","tool_input":{"command":"rm -rf ./dist"}}
        """#.utf8)
        let hookPayload = HookPayload(
            source: "claude-code", eventName: "PreToolUse", wantsDirective: true,
            cwd: "/tmp/proj", terminal: TerminalInfo(app: "iTerm.app", tty: "/dev/ttys002"),
            agentPID: 4242,
            payload: claudePayload, receivedAt: Date()
        )

        // Consume events until the gate, resolving it like a click on Approve.
        // The bridge must prepend the transport-level jump/liveness enrichment.
        let observed = Task { () -> [AgentEvent] in
            var collected: [AgentEvent] = []
            for await event in bridge.events {
                collected.append(event)
                if case .permissionRequested(let request) = event.kind {
                    await bridge.resolve(sessionID: event.sessionID,
                                         requestID: request.id, decision: .allowOnce)
                    return collected
                }
            }
            return collected
        }

        // The hook client blocks on a background thread until the directive lands.
        let directive: HookDirective? = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let result = try UnixSocketClient.send(
                        path: path,
                        envelopes: [.hello(protocolVersion: 1), .hookPayload(hookPayload)],
                        awaitDirective: true, timeout: 5
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        let events = await observed.value
        guard case let .jumpTargetUpdated(target) = events.first?.kind else {
            return XCTFail("expected the bridge to prepend jump enrichment, got \(events)")
        }
        XCTAssertEqual(target.agentPID, 4242)
        XCTAssertEqual(target.tty, "/dev/ttys002")
        guard case let .permissionRequested(request) = events.last?.kind else {
            return XCTFail("expected a permissionRequested event to reach the app")
        }
        XCTAssertEqual(events.last?.sessionID, "sess-1")
        XCTAssertEqual(request.command, "rm -rf ./dist")
        XCTAssertEqual(directive?.action, .allow, "Approve must round-trip back to the waiting hook")

        await bridge.stop()
    }
}
