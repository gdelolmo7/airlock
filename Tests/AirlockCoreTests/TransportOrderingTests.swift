import AirlockTestSupport
import XCTest
@testable import AirlockCore

/// The transport delivers one ordered stream.
///
/// What this can prove: that a connection's envelopes arrive before its
/// disconnect, and that a burst of gating hooks all end resolved.
///
/// What it cannot prove, and no test can: that the OLD two-callback shape
/// reordered. That was a scheduler mood — a test asserting it would be flaky by
/// construction and deleted within a month. The value of the change is that the
/// bad ordering is now unwritable, not that a test catches it.
final class TransportOrderingTests: XCTestCase {
    private let scratch = TestScratch("an-order")

    override func tearDownWithError() throws { scratch.remove() }

    private func gatingPayload(session: String) -> HookPayload {
        let json = Data("""
        {"session_id":"\(session)","hook_event_name":"PreToolUse","cwd":"/tmp/proj",\
        "tool_name":"Bash","tool_input":{"command":"echo \(session)"}}
        """.utf8)
        return HookPayload(source: "claude-code", eventName: "PreToolUse", wantsDirective: true,
                           cwd: "/tmp/proj",
                           terminal: TerminalInfo(app: "iTerm.app", tty: "/dev/ttys009"),
                           agentPID: 4242, payload: json, receivedAt: Date())
    }

    /// The ordering the gate lifecycle depends on: `hold` must never register a
    /// gate for a connection whose disconnect has already been processed.
    func testEnvelopesPrecedeTheirConnectionsDisconnect() async throws {
        let path = scratch.socket()
        let server = UnixSocketServer(path: path)
        try server.start()
        defer { server.stop() }

        let observed = Task { () -> [String] in
            var trace: [String] = []
            for await event in server.events {
                switch event {
                case .envelope: trace.append("envelope")
                case .disconnected:
                    trace.append("disconnected")
                    return trace
                }
            }
            return trace
        }

        _ = await Task.detached {
            try? UnixSocketClient.send(
                path: path,
                envelopes: [.hello(protocolVersion: 1)],
                awaitDirective: false, timeout: 2)
        }.value

        let trace = await observed.value
        XCTAssertEqual(trace.last, "disconnected")
        XCTAssertTrue(trace.dropLast().allSatisfy { $0 == "envelope" },
                      "a disconnect must not overtake its own connection's payloads, got \(trace)")
        XCTAssertGreaterThanOrEqual(trace.count, 2, "expected at least the hello and the disconnect")
    }

    /// Several hooks arriving at once, each gating and each then dying. Every one
    /// must end resolved: this is the multi-connection form of the stranded-gate
    /// bug, and the case a bounded buffer would silently reintroduce.
    func testConcurrentGatingHooksAllEndResolved() async throws {
        let path = scratch.socket()
        let policyURL = scratch.file("policy.yaml")
        let bridge = BridgeServer(registry: .shared, path: path,
                                  policy: PolicyEngine(store: PolicyStore(globalFileURL: policyURL)))
        try await bridge.start()
        defer { Task { await bridge.stop() } }

        let sessions = (0..<5).map { "sess-burst-\($0)" }
        let resolved = Task { () -> Set<String> in
            var done: Set<String> = []
            for await event in bridge.events {
                if case .permissionResolved = event.kind {
                    done.insert(event.sessionID)
                    if done.count == sessions.count { return done }
                }
            }
            return done
        }

        let payloads = sessions.map { gatingPayload(session: $0) }
        await withTaskGroup(of: Void.self) { group in
            for payload in payloads {
                group.addTask {
                    _ = try? UnixSocketClient.send(
                        path: path,
                        envelopes: [.hello(protocolVersion: 1), .hookPayload(payload)],
                        awaitDirective: false, timeout: 2)
                }
            }
        }

        let done = await resolved.value
        XCTAssertEqual(done, Set(sessions), "every dropped hook must end its own gate")
    }
}
