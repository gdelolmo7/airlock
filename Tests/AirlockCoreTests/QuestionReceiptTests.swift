import XCTest
@testable import AirlockCore

/// A question that ends without an answer leaves an account of itself.
///
/// Both endings used to look identical on screen — the card vanished — so a
/// question you dismissed and a question that died with its agent were the same
/// non-event. These pin the two apart, and pin down the cases where a receipt
/// must NOT appear: a receipt for a command gate would be a second copy of the
/// gate log, and a receipt surviving a relaunch would be dated before the app
/// started.
final class QuestionReceiptTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func event(_ id: String, _ seq: UInt64, _ kind: AgentEvent.Kind,
                       at: Date? = nil) -> AgentEvent {
        AgentEvent(sessionID: id, agent: .claudeCode, sequence: seq,
                   timestamp: at ?? t0, kind: kind)
    }

    private func question(_ text: String = "Which checks?") -> PermissionRequest {
        PermissionRequest(
            id: "r1",
            toolName: "AskUserQuestion",
            summary: text,
            question: QuestionPrompt(question: text, header: "Which checks",
                                     options: [QuestionOption(label: "Unit tests")]),
            createdAt: t0
        )
    }

    private func asked(_ state: inout SessionState, _ request: PermissionRequest) {
        state.apply(event("s1", 1, .sessionStarted(project: "app", cwd: "/x", terminal: nil)))
        state.apply(event("s1", 2, .permissionRequested(request)))
    }

    // MARK: - Ignored

    func testIgnoringAQuestionLeavesAReceipt() {
        var state = SessionState()
        asked(&state, question())
        state.apply(event("s1", 3, .permissionResolved(requestID: "r1", decision: .deferred)))

        let receipt = state.sessions["s1"]?.questionReceipt
        XCTAssertEqual(receipt?.reason, .ignored)
        XCTAssertEqual(receipt?.question, "Which checks?")
        XCTAssertEqual(receipt?.header, "Which checks")
        XCTAssertNil(state.sessions["s1"]?.pendingPermission,
                     "nothing is waiting, so nothing may look like it is")
    }

    /// Answering is not ignoring. Only the hand-back leaves a record.
    func testAnsweringLeavesNoReceipt() {
        for decision in [PermissionDecision.allowOnce, .deny, .alwaysAllow] {
            var state = SessionState()
            asked(&state, question())
            state.apply(event("s1", 3, .permissionResolved(requestID: "r1", decision: decision)))
            XCTAssertNil(state.sessions["s1"]?.questionReceipt,
                         "\(decision) is an answer, not an abandonment")
        }
    }

    /// A deferred COMMAND gate leaves nothing: the gate log already has it, and
    /// the command is not something to re-read in a card.
    func testADeferredCommandGateLeavesNoReceipt() {
        var state = SessionState()
        let gate = PermissionRequest(id: "r1", toolName: "Bash", summary: "rm -rf build",
                                     command: "rm -rf build", createdAt: t0)
        asked(&state, gate)
        state.apply(event("s1", 3, .permissionResolved(requestID: "r1", decision: .deferred)))
        XCTAssertNil(state.sessions["s1"]?.questionReceipt)
    }

    // MARK: - The agent died

    func testAnAgentExitingMidQuestionLeavesAReceipt() {
        var state = SessionState()
        asked(&state, question("Which checks should run before I push?"))
        state.apply(event("s1", 3, .sessionEnded))

        let receipt = state.sessions["s1"]?.questionReceipt
        XCTAssertEqual(receipt?.reason, .agentExited)
        XCTAssertEqual(receipt?.question, "Which checks should run before I push?")
        XCTAssertEqual(state.sessions["s1"]?.status, .done)
        XCTAssertNil(state.sessions["s1"]?.pendingPermission,
                     "the options would be delivered to a pid that is gone")
    }

    func testASessionEndingWithNoQuestionLeavesNoReceipt() {
        var state = SessionState()
        state.apply(event("s1", 1, .sessionStarted(project: "app", cwd: "/x", terminal: nil)))
        state.apply(event("s1", 2, .sessionEnded))
        XCTAssertNil(state.sessions["s1"]?.questionReceipt)
    }

    // MARK: - Clearing

    func testDismissingClearsTheReceipt() {
        var state = SessionState()
        asked(&state, question())
        state.apply(event("s1", 3, .sessionEnded))
        XCTAssertNotNil(state.sessions["s1"]?.questionReceipt)

        state.apply(event("s1", 4, .questionReceiptDismissed))
        XCTAssertNil(state.sessions["s1"]?.questionReceipt)
    }

    /// A live ask outranks the record of a dead one — otherwise the panel shows
    /// an account of the last question above the one waiting on you now.
    func testANewQuestionClearsTheOldReceipt() {
        var state = SessionState()
        asked(&state, question())
        state.apply(event("s1", 3, .permissionResolved(requestID: "r1", decision: .deferred)))
        XCTAssertNotNil(state.sessions["s1"]?.questionReceipt)

        state.apply(event("s1", 4, .permissionRequested(question("Something else?"))))
        XCTAssertNil(state.sessions["s1"]?.questionReceipt)
    }

    /// Restore drops it for the same reason it drops pending gates: it describes
    /// a moment the user was present for, and they were not present for this one.
    func testRestoreDropsReceipts() {
        var state = SessionState()
        asked(&state, question())
        state.apply(event("s1", 3, .permissionResolved(requestID: "r1", decision: .deferred)))

        let restored = state.preparedForRestore(now: t0.addingTimeInterval(30))
        XCTAssertNil(restored.sessions["s1"]?.questionReceipt)
    }

    /// The timestamp is the event's, not `Date()` — the reducer is pure, and a
    /// receipt that read "now" on replay would be a clock in a value type.
    func testTheReceiptCarriesTheEventsOwnTimestamp() {
        var state = SessionState()
        asked(&state, question())
        let later = t0.addingTimeInterval(90)
        state.apply(event("s1", 3, .permissionResolved(requestID: "r1", decision: .deferred),
                          at: later))
        XCTAssertEqual(state.sessions["s1"]?.questionReceipt?.at, later)
    }
}
