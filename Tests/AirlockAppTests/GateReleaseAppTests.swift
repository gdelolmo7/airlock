import AirlockTestSupport
import XCTest
import AirlockCore
@testable import AirlockApp

/// The two ways the app itself takes a card off screen without answering it —
/// clearing the list, and a terminal sibling superseding a session — with a
/// real bridge, a real socket and a hook that waits like the real one.
///
/// Both used to leave the agent blocked with nothing on screen able to answer
/// it, until `ask_timeout`. The policy here is `ask_timeout: 0`, which Settings
/// offers as "never — it waits": nothing but the release can end these.
@MainActor
final class GateReleaseAppTests: XCTestCase {
    private var home: URL!
    private let scratch = TestScratch("an-release")

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("airlock-release-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "ask_timeout: 0\n".write(to: home.appendingPathComponent("policy.yaml"),
                                     atomically: true, encoding: .utf8)
        setenv("AIRLOCK_STATE_HOME", home.path, 1)
        setenv("AIRLOCK_POLICY_HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("AIRLOCK_STATE_HOME")
        unsetenv("AIRLOCK_POLICY_HOME")
        try? FileManager.default.removeItem(at: home)
        scratch.remove()
    }

    private func startedModel() async throws -> (AppModel, String) {
        let path = scratch.socket()
        let bridge = BridgeServer(registry: .shared, path: path, policy: PolicyEngine(store: PolicyStore()))
        let model = AppModel(bridge: bridge)
        model.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        return (model, path)
    }

    /// A hook that waits for its reply, as a real one does. `tty` and `pid` are
    /// what make two sessions siblings in one terminal.
    private func hook(_ session: String, _ command: String, path: String,
                      tty: String? = nil, pid: Int32? = nil,
                      at: Date = Date()) -> Task<HookDirective?, Never> {
        let json = Data("""
        {"session_id":"\(session)","hook_event_name":"PreToolUse","cwd":"/tmp/proj",\
        "tool_name":"Bash","tool_input":{"command":"\(command)"}}
        """.utf8)
        let payload = HookPayload(source: "claude-code", eventName: "PreToolUse", wantsDirective: true,
                                  cwd: "/tmp/proj",
                                  terminal: tty.map { TerminalInfo(app: "iTerm.app", tty: $0) },
                                  agentPID: pid, payload: json, receivedAt: at)
        return Task.detached {
            try? UnixSocketClient.send(path: path,
                                       envelopes: [.hello(protocolVersion: 1), .hookPayload(payload)],
                                       awaitDirective: true, timeout: 6)
        }
    }

    private func start(_ session: String, path: String, tty: String, pid: Int32, at: Date) async {
        let json = Data(#"{"session_id":"\#(session)","hook_event_name":"SessionStart","cwd":"/tmp/proj"}"#.utf8)
        let payload = HookPayload(source: "claude-code", eventName: "SessionStart", wantsDirective: false,
                                  cwd: "/tmp/proj", terminal: TerminalInfo(app: "iTerm.app", tty: tty),
                                  agentPID: pid, payload: json, receivedAt: at)
        _ = await Task.detached {
            try? UnixSocketClient.send(path: path,
                                       envelopes: [.hello(protocolVersion: 1), .hookPayload(payload)],
                                       awaitDirective: false, timeout: 2)
        }.value
    }

    private func waitForCard(_ model: AppModel, in session: String) async {
        let deadline = Date().addingTimeInterval(5)
        while model.state.sessions[session]?.pendingPermission == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// "Clear sessions" takes away the only surface that could have answered
    /// them, so the agents are let go rather than left blocked.
    func testClearingTheListLetsEveryHeldAgentGo() async throws {
        let (model, path) = try await startedModel()
        let first = hook("a", "npm test", path: path)
        let second = hook("b", "npm run lint", path: path, at: Date().addingTimeInterval(1))
        await waitForCard(model, in: "a")
        await waitForCard(model, in: "b")

        model.clearAllSessions()

        let firstReply = await first.value
        let secondReply = await second.value
        XCTAssertEqual(firstReply?.action, .deferToAgent)
        XCTAssertEqual(secondReply?.action, .deferToAgent)
        XCTAssertTrue(model.state.sessions.isEmpty)
        // Stopped, or its debounced save writes the sandbox back after the
        // teardown has removed it.
        await model.stop()
    }

    /// `/clear`, `/login`, resume and compact all mint a new session id in the
    /// same terminal. The old one's card goes with it — and so must its gate.
    func testASupersededSessionLetsItsAgentGo() async throws {
        let (model, path) = try await startedModel()
        let start = Date()
        await self.start("old", path: path, tty: "/dev/ttys004", pid: 4242, at: start)
        let blocked = hook("old", "npm test", path: path, tty: "/dev/ttys004", pid: 4242,
                           at: start.addingTimeInterval(1))
        await waitForCard(model, in: "old")

        // Same terminal, same agent process, newer: the reducer supersedes the
        // old conversation and drops its card.
        await self.start("new", path: path, tty: "/dev/ttys004", pid: 4242,
                         at: start.addingTimeInterval(2))

        let reply = await blocked.value
        XCTAssertEqual(reply?.action, .deferToAgent, "the superseded session's hook is let go")
        XCTAssertEqual(model.state.sessions["old"]?.status, .done)
        XCTAssertNil(model.state.sessions["old"]?.pendingPermission)
        await model.stop()
    }
}
