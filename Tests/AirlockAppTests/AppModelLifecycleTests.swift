import AirlockTestSupport
import XCTest
@testable import AirlockApp
@testable import AirlockCore

/// `AppModel.start()` had no test coverage at all — not because it is hard to
/// test, but because there was no way to stop one. Three of its tasks were
/// unstored, so a test that started a model left it running for the rest of the
/// process, holding a bound socket. `BridgeServer.start()` has always been
/// tested; the only difference was `stop()`.
@MainActor
final class AppModelLifecycleTests: XCTestCase {

    private var stateHome: URL!
    private let scratch = TestScratch("an-life")

    override func setUpWithError() throws {
        stateHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("airlock-lifecycle-\(UUID().uuidString)")
        setenv("AIRLOCK_STATE_HOME", stateHome.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("AIRLOCK_STATE_HOME")
        try? FileManager.default.removeItem(at: stateHome)
        scratch.remove()
    }

    private func makeModel() -> (AppModel, String) {
        let path = scratch.socket()
        let policyURL = scratch.file("policy.yaml")
        let bridge = BridgeServer(registry: .shared, path: path,
                                  policy: PolicyEngine(store: PolicyStore(globalFileURL: policyURL)))
        return (AppModel(bridge: bridge), path)
    }

    /// The plain fact that was untestable before: start, then stop, and the
    /// model is genuinely finished — no listener, no liveness loop.
    func testStartThenStopReleasesTheSocket() async throws {
        let (model, path) = makeModel()
        model.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the bridge should be listening")

        await model.stop()

        // A second model can take the same path, which it could not do if the
        // first were still bound to it.
        let second = BridgeServer(registry: .shared, path: path)
        try await second.start()
        await second.stop()
    }

    /// Events stop being applied once stopped — the ingest loop is really over,
    /// not merely detached and still running.
    func testStateIsFrozenAfterStop() async throws {
        let (model, path) = makeModel()
        model.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        await model.stop()

        let payload = HookPayload(
            source: "claude-code", eventName: "PreToolUse", wantsDirective: false,
            cwd: "/tmp/proj", terminal: TerminalInfo(app: "iTerm.app", tty: "/dev/ttys005"),
            agentPID: 4242,
            payload: Data("""
            {"session_id":"after-stop","hook_event_name":"PreToolUse","cwd":"/tmp/proj",\
            "tool_name":"Bash","tool_input":{"command":"echo hi"}}
            """.utf8),
            receivedAt: Date())

        _ = await Task.detached {
            try? UnixSocketClient.send(path: path,
                                       envelopes: [.hello(protocolVersion: 1), .hookPayload(payload)],
                                       awaitDirective: false, timeout: 1)
        }.value
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(model.sessions.first { $0.id == "after-stop" },
                     "a stopped model must not still be ingesting")
    }

    /// `stop()` is called on quit paths and on teardown; calling it twice, or
    /// without a `start()`, must not trap.
    func testStopIsSafeToCallTwiceAndWithoutStart() async throws {
        let (model, _) = makeModel()
        await model.stop()
        model.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        await model.stop()
        await model.stop()
    }
}
