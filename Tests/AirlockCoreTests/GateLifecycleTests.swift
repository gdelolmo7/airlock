import AirlockTestSupport
import XCTest
@testable import AirlockCore

/// The two ways a gate could end wrongly, both over a real socket.
///
/// Neither of these is a concurrency exemption — they are correctness bugs in
/// the gate lifecycle that a concurrency audit happened to walk into. They get
/// their own file because they are about what the approval layer PROMISES, not
/// about how the transport is isolated.
final class GateLifecycleTests: XCTestCase {

    private let scratch = TestScratch("an-gate")

    override func tearDownWithError() throws { scratch.remove() }

    private func makeBridge() -> (BridgeServer, String) {
        let path = scratch.socket()
        // Empty temp policy → deterministic `.ask`, whatever is on the host.
        let policyURL = scratch.file("policy.yaml")
        return (BridgeServer(registry: .shared, path: path,
                             policy: PolicyEngine(store: PolicyStore(globalFileURL: policyURL))),
                path)
    }

    private func gatingPayload(session: String, command: String, id: String) -> HookPayload {
        let json = Data("""
        {"session_id":"\(session)","hook_event_name":"PreToolUse","cwd":"/tmp/proj",\
        "tool_name":"Bash","tool_input":{"command":"\(command)"}}
        """.utf8)
        return HookPayload(source: "claude-code", eventName: "PreToolUse", wantsDirective: true,
                           cwd: "/tmp/proj",
                           terminal: TerminalInfo(app: "iTerm.app", tty: "/dev/ttys00\(id)"),
                           agentPID: 4242, payload: json, receivedAt: Date())
    }

    // MARK: - A hook that goes away must still end its gate

    /// Ctrl-C an agent sitting at a permission prompt, or close its terminal:
    /// the hook dies, the gate is dropped — and before this fix, silently. The
    /// UI never learned, so `pendingPermission` stayed set and the island stayed
    /// amber permanently, because the ask_timeout that would eventually have
    /// cleared it was cancelled on the way out.
    ///
    /// Without the fix this test hangs to its own timeout: no event ever comes.
    func testDisconnectWhileHoldingAGateResolvesIt() async throws {
        let (bridge, path) = makeBridge()
        try await bridge.start()
        defer { Task { await bridge.stop() } }

        let collected = Task { () -> [AgentEvent] in
            var events: [AgentEvent] = []
            for await event in bridge.events {
                events.append(event)
                if case .permissionResolved = event.kind { return events }
            }
            return events
        }

        // Send a gating payload and then DROP the connection without answering,
        // which is what a killed hook looks like from here.
        let dropped = gatingPayload(session: "sess-drop", command: "rm -rf ./dist", id: "2")
        _ = await Task.detached {
            try? UnixSocketClient.send(
                path: path,
                envelopes: [.hello(protocolVersion: 1), .hookPayload(dropped)],
                awaitDirective: false, timeout: 2)
        }.value

        let events = await collected.value
        guard case let .permissionResolved(_, decision) = events.last?.kind else {
            return XCTFail("a dropped hook must resolve its gate, got \(events.map(\.kind))")
        }
        XCTAssertEqual(decision, .deferred,
                       "the agent asks in its own terminal instead — it is not an approval")

        // And the card is actually gone as far as the reducer is concerned.
        var state = SessionState()
        for event in events { state.apply(event) }
        XCTAssertEqual(state.attentionCount, 0, "a stale gate would hold the island amber")
        XCTAssertNil(state.sessions["sess-drop"]?.pendingPermission)
    }

    // MARK: - A decision must reach the gate it was made for

    /// A session can hold several gates, so a decision addressed by session
    /// alone lands on whichever gate is first when it arrives — not the one
    /// that was on screen. The click travels through an unstructured Task, so
    /// the window is real.
    ///
    /// Written when a newer gate superseded the older one; gates now queue, and
    /// the promise is the same. Before the fix, the second hook received an
    /// allow for a command nobody ever saw.
    func testDecisionForOneGateIsNotDeliveredToTheOther() async throws {
        let (bridge, path) = makeBridge()
        try await bridge.start()
        defer { Task { await bridge.stop() } }

        var seen: [PermissionRequest] = []
        let firstTwo = Task { () -> [PermissionRequest] in
            var requests: [PermissionRequest] = []
            for await event in bridge.events {
                if case let .permissionRequested(request) = event.kind {
                    requests.append(request)
                    if requests.count == 2 { return requests }
                }
            }
            return requests
        }

        // Built out here: the payloads are values, and capturing `self` inside a
        // detached task is exactly the data race Swift 6 refuses to compile.
        // A only. B is built AFTER the sleep below. Ids no longer come from the
        // millisecond alone — see `ClaudeStyleHookDecoder.permissionRequest` —
        // but keeping the two apart in time keeps this test about addressing,
        // not about ids.
        let payloadA = gatingPayload(session: "sess-x", command: "echo A", id: "3")

        // Gate A, held open (the client waits for a directive it will not get).
        let aClient = Task.detached { () -> HookDirective? in
            try? UnixSocketClient.send(
                path: path,
                envelopes: [.hello(protocolVersion: 1), .hookPayload(payloadA)],
                awaitDirective: true, timeout: 4)
        }
        try await Task.sleep(nanoseconds: 250_000_000)

        // Gate B for the SAME session, waiting behind A.
        let payloadB = gatingPayload(session: "sess-x", command: "echo B", id: "4")
        let bClient = Task.detached { () -> HookDirective? in
            try? UnixSocketClient.send(
                path: path,
                envelopes: [.hello(protocolVersion: 1), .hookPayload(payloadB)],
                awaitDirective: true, timeout: 4)
        }

        seen = await firstTwo.value
        XCTAssertEqual(seen.count, 2, "expected both gates to reach the app")
        let gateA = seen[0]

        // Answer A — and only A.
        await bridge.resolve(sessionID: "sess-x", requestID: gateA.id, decision: .allowOnce)

        // B must NOT have been approved by A's click. It is still waiting for
        // its own answer, so it ends at its own client timeout.
        let bResult = await bClient.value
        XCTAssertNotEqual(bResult?.action, .allow,
                          "a click on gate A must never approve gate B — that is a command the user never saw")

        let aResult = await aClient.value
        XCTAssertEqual(aResult?.action, .allow, "and A got the answer that was given for it")
    }
}
