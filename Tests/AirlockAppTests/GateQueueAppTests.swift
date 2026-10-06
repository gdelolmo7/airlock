import AirlockTestSupport
import XCTest
import AirlockCore
@testable import AirlockApp

/// The queue through the app: a real `AppModel` on its own bridge and socket,
/// real hooks, and the calls the card makes.
@MainActor
final class GateQueueAppTests: XCTestCase {
    private var home: URL!
    /// The socket lives here rather than in `home`, whose name is too long for
    /// one: a Unix path stops at 104 bytes.
    private let scratch = TestScratch("an-qapp")

    /// Sessions, the gate log and policy all go to a sandbox — "Always" writes
    /// a rule, and it must not land in anybody's real policy file.
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("airlock-queue-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("project"),
                                                withIntermediateDirectories: true)
        setenv("AIRLOCK_STATE_HOME", home.path, 1)
        setenv("AIRLOCK_POLICY_HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("AIRLOCK_STATE_HOME")
        unsetenv("AIRLOCK_POLICY_HOME")
        try? FileManager.default.removeItem(at: home)
        scratch.remove()
    }

    private var project: String { home.appendingPathComponent("project").path }

    private func startedModel() async throws -> (AppModel, String) {
        let path = scratch.socket()
        let bridge = BridgeServer(registry: .shared, path: path,
                                  policy: PolicyEngine(store: PolicyStore()))
        let model = AppModel(bridge: bridge)
        model.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        return (model, path)
    }

    /// A hook that waits for its reply, as a real one does.
    private func hook(_ command: String, path: String) -> Task<HookDirective?, Never> {
        let json = Data("""
        {"session_id":"q","hook_event_name":"PreToolUse","cwd":"\(project)",\
        "tool_name":"Bash","tool_input":{"command":"\(command)"}}
        """.utf8)
        let payload = HookPayload(source: "claude-code", eventName: "PreToolUse", wantsDirective: true,
                                  cwd: project, terminal: nil, payload: json, receivedAt: Date())
        return Task.detached {
            try? UnixSocketClient.send(path: path,
                                       envelopes: [.hello(protocolVersion: 1), .hookPayload(payload)],
                                       awaitDirective: true, timeout: 6)
        }
    }

    /// What every real session opens with — and what gives it the working
    /// directory "Always" writes its rule under.
    private func sessionStart(path: String) async {
        let json = Data(#"{"session_id":"q","hook_event_name":"SessionStart","cwd":"\#(project)"}"#.utf8)
        let payload = HookPayload(source: "claude-code", eventName: "SessionStart", wantsDirective: false,
                                  cwd: project, terminal: nil, payload: json, receivedAt: Date())
        _ = await Task.detached {
            try? UnixSocketClient.send(path: path,
                                       envelopes: [.hello(protocolVersion: 1), .hookPayload(payload)],
                                       awaitDirective: false, timeout: 2)
        }.value
    }

    /// The gate log is written after the bridge confirms delivery.
    private func logCount(_ model: AppModel, reaches count: Int) async {
        let deadline = Date().addingTimeInterval(3)
        while model.gateLog.records.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waiting(_ model: AppModel, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while (model.state.sessions["q"]?.waitingPermissions.count ?? 0) != count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A double-click on Approve approves the card it was on — and not the one
    /// that slides into its place. The second click carries the card that was
    /// drawn, which is no longer the one waiting.
    func testADoubleClickApprovesOnlyTheCardItWasOn() async throws {
        let (model, path) = try await startedModel()
        let first = hook("npm test", path: path)
        await waiting(model, count: 1)
        let second = hook("npm run lint", path: path)
        await waiting(model, count: 2)

        let drawn = try XCTUnwrap(model.state.sessions["q"])
        XCTAssertEqual(drawn.queueCounter, "2 waiting")
        let logged = model.gateLog.records.count
        model.resolve(drawn, .allowOnce)
        model.resolve(drawn, .allowOnce)

        let firstReply = await first.value
        XCTAssertEqual(firstReply?.action, .allow)
        let now = try XCTUnwrap(model.state.sessions["q"])
        XCTAssertEqual(now.pendingPermission?.command, "npm run lint", "the next card took its place…")
        XCTAssertNil(now.queueCounter, "one left is nothing to count")
        XCTAssertEqual(model.attentionCount, 1, "…and the session is still waiting on it")
        // The log is written once the bridge says the decision was delivered,
        // so it lands a beat after the click — see `AppModel.resolve`.
        await logCount(model, reaches: logged + 1)
        XCTAssertEqual(model.gateLog.records.count, logged + 1, "one decision, not two")

        model.resolve(now, .deny)
        let secondReply = await second.value
        XCTAssertEqual(secondReply?.action, .deny, "it got its own answer, not the second click")
        XCTAssertEqual(model.attentionCount, 0)
        await model.stop()
    }

    /// "Always" through the app: the rule is written, then the other gates in
    /// the session it now covers are settled; one the risk floor holds stays.
    func testAlwaysSettlesTheQueueItCovers() async throws {
        let (model, path) = try await startedModel()
        await sessionStart(path: path)
        let test = hook("npm test", path: path)
        await waiting(model, count: 1)
        let lint = hook("npm run lint", path: path)
        await waiting(model, count: 2)
        let deploy = hook("npm run deploy:prod", path: path)
        await waiting(model, count: 3)

        let drawn = try XCTUnwrap(model.state.sessions["q"])
        model.resolve(drawn, .alwaysAllow)

        let testReply = await test.value
        let lintReply = await lint.value
        XCTAssertEqual(testReply?.action, .allow)
        XCTAssertEqual(lintReply?.action, .allow)
        XCTAssertEqual(lintReply?.reason, "Approved by Airlock policy rule Bash(npm *)")

        await waiting(model, count: 1)
        let session = try XCTUnwrap(model.state.sessions["q"])
        XCTAssertEqual(session.pendingPermission?.command, "npm run deploy:prod", "the risk floor still asks")
        XCTAssertNil(session.queuedPermissions)
        // The reviewer's case: two of these were settled by the rule and never
        // seen, and the card said "3 of 3 waiting" over a queue holding one.
        XCTAssertNil(session.queueCounter, "one waiting is nothing to count")
        XCTAssertEqual(model.attentionCount, 1)
        let policy = try String(contentsOfFile: project + "/.airlock/policy.yaml", encoding: .utf8)
        XCTAssertTrue(policy.contains("Bash(npm *)"))

        // Wait for BOTH entries: each is logged when its own reply is
        // delivered, so under load the card's can land after the rule's.
        let deadline = Date().addingTimeInterval(3)
        while Set(model.gateLog.records.map(\.outcome)) != [.alwaysAllowed, .autoAllowed], Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(Set(model.gateLog.records.map(\.outcome)), [.alwaysAllowed, .autoAllowed],
                       "the card as the user's decision, the other as the rule's")

        model.resolve(session, .deny)
        let deployReply = await deploy.value
        XCTAssertEqual(deployReply?.action, .deny)
        await model.stop()
    }
}
