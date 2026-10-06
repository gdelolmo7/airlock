import XCTest
@testable import AirlockCore

/// A change made on this side — a receipt dismissed, a card answered — must not
/// spend a sequence number the agent's next event can carry.
///
/// The app used to make these as synthetic events stamped
/// `lastSequence + 1`. The reducer drops anything not newer than what it has
/// seen, and real numbers are the hook's own (its clock, plus one per event in
/// a burst), so the next real event could carry exactly that number — and was
/// thrown away: a row that stopped updating, a status change that never landed.
final class LocalMutationSequenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func event(_ seq: UInt64, _ kind: AgentEvent.Kind) -> AgentEvent {
        AgentEvent(sessionID: "s1", agent: .claudeCode, sequence: seq, timestamp: t0, kind: kind)
    }

    private func question(_ id: String = "r1") -> PermissionRequest {
        PermissionRequest(
            id: id,
            toolName: "AskUserQuestion",
            summary: "Which checks?",
            question: QuestionPrompt(question: "Which checks?", header: "Which checks",
                                     options: [QuestionOption(label: "Unit tests")]),
            createdAt: t0
        )
    }

    private func command(_ id: String) -> PermissionRequest {
        PermissionRequest(id: id, toolName: "Bash", summary: "Run shell command",
                          command: "make", createdAt: t0)
    }

    /// A receipt on screen, the session at sequence 3.
    private func withReceipt() -> SessionState {
        var state = SessionState()
        state.apply(event(1, .sessionStarted(project: "app", cwd: "/x", terminal: nil)))
        state.apply(event(2, .permissionRequested(question())))
        state.apply(event(3, .permissionResolved(requestID: "r1", decision: .deferred)))
        return state
    }

    func testDismissingAReceiptLeavesTheNextSequenceToTheAgent() throws {
        var state = withReceipt()
        XCTAssertNotNil(state.sessions["s1"]?.questionReceipt)

        state.dismissReceipt(sessionID: "s1", at: t0)
        XCTAssertNil(state.sessions["s1"]?.questionReceipt)
        XCTAssertEqual(state.sessions["s1"]?.lastSequence, 3, "a local change spends no number")

        state.apply(event(4, .activity(summary: "Reading files")))
        let session = try XCTUnwrap(state.sessions["s1"])
        XCTAssertEqual(session.lastSummary, "Reading files", "the agent's next event was dropped")
        XCTAssertEqual(session.status, .running)
    }

    func testAnsweringACardLeavesTheNextSequenceToTheAgent() throws {
        var state = SessionState()
        state.apply(event(1, .sessionStarted(project: "app", cwd: "/x", terminal: nil)))
        state.apply(event(2, .permissionRequested(command("r1"))))

        state.resolveGate(sessionID: "s1", requestID: "r1", decision: .allowOnce, at: t0)
        XCTAssertNil(state.sessions["s1"]?.pendingPermission)
        XCTAssertEqual(state.sessions["s1"]?.lastSequence, 2, "a local change spends no number")

        state.apply(event(3, .turnEnded(assistantMessage: "Done.")))
        let session = try XCTUnwrap(state.sessions["s1"])
        XCTAssertEqual(session.status, .idle, "the agent's next event was dropped")
        XCTAssertEqual(session.lastResponse, "Done.")
    }

    /// Answering the card still hands it to the next gate waiting, exactly as
    /// the agent's own `permissionResolved` would.
    func testAnsweringACardStillPromotesTheQueue() throws {
        var state = SessionState()
        state.apply(event(1, .sessionStarted(project: "app", cwd: "/x", terminal: nil)))
        state.apply(event(2, .permissionRequested(command("r1"))))
        state.apply(event(3, .permissionRequested(command("r2"))))

        state.resolveGate(sessionID: "s1", requestID: "r1", decision: .deny, at: t0)
        let session = try XCTUnwrap(state.sessions["s1"])
        XCTAssertEqual(session.pendingPermission?.id, "r2")
        XCTAssertNil(session.queuedPermissions)
    }

    /// Ignoring a question from here leaves its receipt, the step it was on
    /// included — the same as when the bridge ends it.
    func testIgnoringAQuestionFromHereLeavesAReceipt() {
        var state = SessionState()
        state.apply(event(1, .sessionStarted(project: "app", cwd: "/x", terminal: nil)))
        state.apply(event(2, .permissionRequested(question())))

        state.resolveGate(sessionID: "s1", requestID: "r1", decision: .deferred, at: t0, questionStep: 0)
        XCTAssertEqual(state.sessions["s1"]?.questionReceipt?.reason, .ignored)
    }

    /// The app names a conversation from the session-name cache or its
    /// transcript. That used to be stamped with the clock, so an event the hook
    /// stamped a moment earlier but which arrived a moment later was dropped.
    func testRetitlingLeavesTheAgentsInFlightEventsAlone() throws {
        var state = SessionState()
        state.apply(event(1_000, .sessionStarted(project: "app", cwd: "/x", terminal: nil)))

        state.retitle(sessionID: "s1", to: "Fix the login bug", at: t0)
        let renamed = try XCTUnwrap(state.sessions["s1"])
        XCTAssertEqual(renamed.title, "Fix the login bug")
        XCTAssertEqual(renamed.titleExplicit, true)
        XCTAssertEqual(renamed.lastSequence, 1_000, "a local change spends no number")

        state.apply(event(1_001, .activity(summary: "Reading files")))
        XCTAssertEqual(state.sessions["s1"]?.lastSummary, "Reading files",
                       "the agent's in-flight event was dropped")
    }

    /// Nothing local creates a session. A synthetic event for an id the list no
    /// longer holds used to bootstrap an empty row out of nothing.
    func testALocalChangeToAMissingSessionIsANoOp() {
        var state = SessionState()
        state.dismissReceipt(sessionID: "gone", at: t0)
        state.resolveGate(sessionID: "gone", requestID: "r1", decision: .allowOnce, at: t0)
        state.retitle(sessionID: "gone", to: "Anything", at: t0)
        XCTAssertTrue(state.sessions.isEmpty)
    }
}
