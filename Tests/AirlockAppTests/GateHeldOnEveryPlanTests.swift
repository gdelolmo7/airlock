import AirlockTestSupport
import XCTest
import AirlockCore
@testable import AirlockApp

/// On every plan, an agent's request waits for its card in the notch. A real
/// bridge, a real socket and a hook that waits like the real one.
///
/// A finished trial used to hand every request straight back to the agent's
/// own terminal, because the card that came up could only ask for a
/// subscription. Nothing locks any more, so a card on Free is answered like
/// any other, and a plan ending never takes one away.
@MainActor
final class GateHeldOnEveryPlanTests: XCTestCase {
    private var home: URL!
    private let scratch = TestScratch("an-handback")

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("airlock-handback-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Empty: every gate asks, whatever is on the host.
        try "".write(to: home.appendingPathComponent("policy.yaml"), atomically: true, encoding: .utf8)
        setenv("AIRLOCK_STATE_HOME", home.path, 1)
        setenv("AIRLOCK_POLICY_HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("AIRLOCK_STATE_HOME")
        unsetenv("AIRLOCK_POLICY_HOME")
        try? FileManager.default.removeItem(at: home)
        scratch.remove()
    }

    private func model(path: String) -> AppModel {
        AppModel(bridge: BridgeServer(registry: .shared, path: path, policy: PolicyEngine(store: PolicyStore())))
    }

    /// A hook that waits for its reply, as a real one does. Nil if none came
    /// in time — which is what a held gate looks like from here.
    private func hook(_ tool: String, _ input: String, path: String) -> Task<HookDirective?, Never> {
        let json = Data("""
        {"session_id":"s","hook_event_name":"PreToolUse","cwd":"/tmp/proj",\
        "tool_name":"\(tool)","tool_input":\(input)}
        """.utf8)
        let payload = HookPayload(source: "claude-code", eventName: "PreToolUse", wantsDirective: true,
                                  cwd: "/tmp/proj", terminal: nil,
                                  payload: json, receivedAt: Date())
        return Task.detached {
            try? UnixSocketClient.send(path: path,
                                       envelopes: [.hello(protocolVersion: 1), .hookPayload(payload)],
                                       awaitDirective: true, timeout: 6)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A Mac with no licence and no trial is on Free, which is where a new
    /// install starts: the card goes up, the hook waits for it, and the
    /// answer given in the notch is the one the agent gets.
    func testOnFreeTheCardIsPutUpAndAnswered() async throws {
        let path = scratch.socket()
        let model = model(path: path)
        model.start()
        try await Task.sleep(nanoseconds: 200_000_000)

        let blocked = hook("Bash", #"{"command":"npm test"}"#, path: path)
        await waitUntil { model.state.sessions["s"]?.pendingPermission != nil }
        let session = try XCTUnwrap(model.state.sessions["s"])
        XCTAssertNotNil(session.pendingPermission, "Free asks from the notch")
        XCTAssertEqual(model.state.attentionCount, 1, "attention is what opens the island")

        model.resolve(session, .allowOnce)
        let reply = await blocked.value
        XCTAssertEqual(reply?.action, .allow)
        await model.stop()
    }

    /// Nothing at launch tells the bridge to hand requests back any more. The
    /// line that did was how a finished trial stopped every card, and putting
    /// it back would do that to everybody on Free.
    func testLaunchNeverTellsTheBridgeToHandBack() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AirlockAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/AirlockApp")
        for file in ["AppDelegate.swift", "AppModel.swift"] {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(source.contains("setGateHolding"), "\(file) hands gates back")
            XCTAssertFalse(source.contains(".handBack"), "\(file) hands gates back")
        }
    }
}
