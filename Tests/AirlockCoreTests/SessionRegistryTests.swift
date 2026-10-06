import XCTest
@testable import AirlockCore

final class SessionRegistryTests: XCTestCase {
    private var fileURL: URL!
    private var registry: SessionRegistry!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000) // whole ms — survives the codec

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("an-reg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("sessions.json")
        registry = SessionRegistry(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func sampleState() -> SessionState {
        var state = SessionState()
        state.apply(AgentEvent(sessionID: "s1", agent: .claudeCode, sequence: 100, timestamp: t0,
                               kind: .sessionStarted(project: "app", cwd: "/x",
                                                     terminal: TerminalInfo(app: "iTerm.app", tty: "/dev/ttys002"))))
        state.apply(AgentEvent(sessionID: "s1", agent: .claudeCode, sequence: 101, timestamp: t0,
                               kind: .jumpTargetUpdated(JumpTarget(tty: "/dev/ttys002", agentPID: 4242))))
        return state
    }

    func testRoundTripPreservesEverything() throws {
        let state = sampleState()
        try registry.save(state)
        let loaded = try XCTUnwrap(registry.load())
        XCTAssertEqual(loaded, state, "sessions, jump targets, and sequences survive the disk")
        XCTAssertEqual(loaded.sessions["s1"]?.lastSequence, 101,
                       "restored sequence keeps the monotonic guard effective")
    }

    func testExcludingFiltersSessions() throws {
        var state = sampleState()
        state.apply(AgentEvent(sessionID: "demo-claude", agent: .claudeCode, sequence: 1,
                               timestamp: t0, kind: .activity(summary: "fake")))
        try registry.save(state, excluding: ["demo-claude"])
        let loaded = try XCTUnwrap(registry.load())
        XCTAssertNil(loaded.sessions["demo-claude"])
        XCTAssertNotNil(loaded.sessions["s1"])
    }

    func testMissingAndCorruptFilesLoadAsNil() throws {
        XCTAssertNil(registry.load())
        try Data("not json{".utf8).write(to: fileURL)
        XCTAssertNil(registry.load(), "corrupt cache is ignored, never fatal")
    }

    func testSavedFileIsPrivate() throws {
        try registry.save(sampleState())
        let perms = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "session cache contains commands — owner-only")
    }
}

final class PreparedForRestoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ id: String, _ seq: UInt64, _ kind: AgentEvent.Kind) -> AgentEvent {
        AgentEvent(sessionID: id, agent: .claudeCode, sequence: seq, timestamp: t0, kind: kind)
    }

    func testPendingGatesClearAndAttentionDemotes() {
        var state = SessionState()
        state.apply(event("s1", 10, .permissionRequested(
            PermissionRequest(id: "r1", toolName: "Bash", summary: "Run", command: "ls", createdAt: t0))))
        state.apply(event("s2", 11, .questionAsked(prompt: "Which file?")))

        let restored = state.preparedForRestore(now: t0)
        for id in ["s1", "s2"] {
            XCTAssertNil(restored.sessions[id]?.pendingPermission)
            XCTAssertNil(restored.sessions[id]?.pendingQuestion)
            XCTAssertEqual(restored.sessions[id]?.status, .idle,
                           "a blocked gate cannot survive a restart — demote, don't lie")
        }
        XCTAssertEqual(restored.attentionCount, 0)
    }

    func testRunningSurvivesForLivenessToVerify() {
        var state = SessionState()
        state.apply(event("s1", 10, .sessionStarted(project: "p", cwd: nil, terminal: nil)))
        state.apply(event("s1", 11, .activity(summary: "working"))) // earns "running"
        state.apply(event("s1", 12, .jumpTargetUpdated(JumpTarget(agentPID: 4242))))

        let restored = state.preparedForRestore(now: t0)
        XCTAssertEqual(restored.sessions["s1"]?.status, .running)
        XCTAssertEqual(restored.sessions["s1"]?.jumpTarget?.agentPID, 4242)
        XCTAssertEqual(restored.sessions["s1"]?.lastSequence, 12)
    }

    func testStartingSettlesToIdle() {
        var state = SessionState()
        state.apply(event("s1", 10, .jumpTargetUpdated(JumpTarget(tty: "/dev/ttys001"))))
        XCTAssertEqual(state.sessions["s1"]?.status, .starting)
        XCTAssertEqual(state.preparedForRestore(now: t0).sessions["s1"]?.status, .idle)
    }

    func testDoneRetentionAtRestore() {
        var state = SessionState()
        state.apply(event("old", 10, .sessionEnded))
        state.apply(AgentEvent(sessionID: "fresh", agent: .claudeCode, sequence: 11,
                               timestamp: t0.addingTimeInterval(299), kind: .sessionEnded))

        let restored = state.preparedForRestore(now: t0.addingTimeInterval(300), retention: 120)
        XCTAssertNil(restored.sessions["old"], "long-done sessions drop at restore")
        XCTAssertNotNil(restored.sessions["fresh"], "recently-done sessions stay visible")
    }
}
