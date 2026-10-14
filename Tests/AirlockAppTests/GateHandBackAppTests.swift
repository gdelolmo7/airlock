import AirlockTestSupport
import XCTest
import AirlockCore
@testable import AirlockApp

/// After the trial, the app never puts up a card for an agent's request: the
/// hook goes straight back and the agent asks in its own terminal. A real
/// bridge, a real socket and a hook that waits like the real one.
///
/// It used to hold the request for a card that could not be answered, with
/// Claude Code's terminal showing nothing until the card's × or `ask_timeout`.
@MainActor
final class GateHandBackAppTests: XCTestCase {
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

    /// In launch's order: the bridge is started first and the licence read
    /// later in the same stretch, before the bridge has heard anything.
    func testAfterTheTrialNoCardIsPutUp() async throws {
        let path = scratch.socket()
        let model = model(path: path)
        model.start()
        model.entitlementChanged(.trialExpired)
        try await Task.sleep(nanoseconds: 200_000_000)

        let command = await hook("Bash", #"{"command":"npm test"}"#, path: path).value
        let question = await hook("AskUserQuestion", """
        {"questions":[{"question":"Which provider?","header":"Payments",\
        "options":[{"label":"Stripe"},{"label":"Adyen"}]}]}
        """, path: path).value
        XCTAssertEqual(command?.action, .deferToAgent, "no decision: the agent asks in its own terminal")
        XCTAssertEqual(question?.action, .deferToAgent)

        await waitUntil { model.state.sessions["s"]?.lastSummary == SessionCardText.handedBack }
        XCTAssertEqual(model.state.sessions["s"]?.lastSummary, SessionCardText.handedBack)
        XCTAssertNil(model.state.sessions["s"]?.pendingPermission)
        XCTAssertEqual(model.state.attentionCount, 0, "attention is what opens the island")
        await model.stop()
    }

    /// The card is there while the trial lasts, and goes back with its hook
    /// the moment it ends.
    func testTheTrialEndingLetsAWaitingAgentGo() async throws {
        let path = scratch.socket()
        let model = model(path: path)
        model.start()
        model.entitlementChanged(.trialing(daysRemaining: 1))
        try await Task.sleep(nanoseconds: 200_000_000)

        let blocked = hook("Bash", #"{"command":"npm test"}"#, path: path)
        await waitUntil { model.state.sessions["s"]?.pendingPermission != nil }
        XCTAssertNotNil(model.state.sessions["s"]?.pendingPermission, "a trial still asks from the notch")

        model.entitlementChanged(.trialExpired)

        let reply = await blocked.value
        XCTAssertEqual(reply?.action, .deferToAgent)
        await waitUntil { model.state.sessions["s"]?.pendingPermission == nil }
        XCTAssertNil(model.state.sessions["s"]?.pendingPermission)
        XCTAssertEqual(model.state.attentionCount, 0)
        await model.stop()
    }

    /// The licence reaches the bridge only through the app delegate, and
    /// nothing above would notice that line going: the bridge would hold
    /// every gate again, as it did before it knew.
    func testLaunchHandsTheLicenceToTheBridge() throws {
        let delegate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AirlockAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/AirlockApp/AppDelegate.swift")
        let source = try String(contentsOf: delegate, encoding: .utf8)
        XCTAssertTrue(source.contains("license.onEntitlementChange = { [weak model] in model?.entitlementChanged($0) }"),
                      "every change of entitlement has to reach the bridge")
        XCTAssertTrue(source.contains("model.entitlementChanged(license.entitlement)"),
                      "and the one it starts from, which no change announces")
    }
}
