import XCTest
@testable import AirlockCore

/// An agent that stops talking while work it sent off is still running has
/// paused, not finished. The owner saw it as Done — the chime and the green
/// mark — every time an agent said "waiting on the tests" and went quiet.
///
/// Driven through the Claude decoder with the payload shapes measured in the
/// Claude desktop app on 2026-10-08, so the ids line up the way they do live.
final class BackgroundTaskTests: XCTestCase {
    private let integration = ClaudeCodeIntegration()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var state = SessionState()
    private var clock: TimeInterval = 0

    private func send(_ json: String) throws {
        clock += 1
        let context = HookContext(source: "claude-code", cwd: nil, terminal: nil,
                                  receivedAt: now.addingTimeInterval(clock))
        for event in try integration.decodeEvents(from: Data(json.utf8), context: context) {
            state.apply(event)
        }
    }

    private var session: AgentSession? { state.sessions["s1"] }

    private func prompt(_ text: String) throws {
        let body = String(data: try JSONSerialization.data(withJSONObject: [
            "session_id": "s1", "hook_event_name": "UserPromptSubmit", "prompt": text,
        ]), encoding: .utf8)!
        try send(body)
    }

    private func backgroundCommand(call: String, task: String) throws {
        try send(#"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"\#(call)","tool_input":{"command":"swift test","run_in_background":true},"tool_response":{"stdout":"","stderr":"","interrupted":false,"backgroundTaskId":"\#(task)"}}"#)
    }

    private func backgroundHelper(call: String, agent: String) throws {
        try send(#"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Agent","tool_use_id":"\#(call)","tool_input":{"description":"Look around","prompt":"…"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"\#(agent)"}}"#)
    }

    private func stop(_ reply: String = "Started the tests, waiting on them.") throws {
        try send(#"{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":"\#(reply)"}"#)
    }

    private func notification(task: String, call: String, status: String = "completed") -> String {
        """
        <task-notification>
        <task-id>\(task)</task-id>
        <tool-use-id>\(call)</tool-use-id>
        <output-file>/private/tmp/claude-501/tasks/\(task).output</output-file>
        <status>\(status)</status>
        <summary>Background command "swift test" completed (exit code 0)</summary>
        </task-notification>
        """
    }

    func testATurnEndingWithWorkOutIsNotAFinish() throws {
        try prompt("run the tests")
        try backgroundCommand(call: "toolu_A", task: "bq1")
        let before = session
        try stop()

        XCTAssertEqual(session?.status, .running)
        XCTAssertEqual(session?.lastSummary, "Waiting on a background task")
        XCTAssertEqual(session?.lastResponse, "Started the tests, waiting on them.", "what it said still shows")
        XCTAssertEqual(session?.finishedTurn(since: before), false, "no chime, no ✓")
    }

    func testTheFinishComesWhenTheWorkReportsBack() throws {
        try prompt("run the tests")
        try backgroundCommand(call: "toolu_A", task: "bq1")
        try stop()

        try prompt(notification(task: "bq1", call: "toolu_A"))
        XCTAssertNil(session?.backgroundTasks)
        XCTAssertEqual(session?.lastSummary, "Background task finished")

        let before = session
        try stop("All 2698 tests pass.")
        XCTAssertEqual(session?.status, .idle)
        XCTAssertEqual(session?.finishedTurn(since: before), true)
    }

    /// Several out at once: the agent is done only when the last one is back.
    func testEveryTaskHasToReportBack() throws {
        try prompt("look into it")
        try backgroundHelper(call: "toolu_A", agent: "a1")
        try backgroundHelper(call: "toolu_B", agent: "a2")
        try stop()
        XCTAssertEqual(session?.lastSummary, "Waiting on 2 background tasks")

        try prompt(notification(task: "a1", call: "toolu_A"))
        try stop("One helper is back, waiting on the other.")
        XCTAssertEqual(session?.status, .running)
        XCTAssertEqual(session?.lastSummary, "Waiting on a background task")

        try prompt(notification(task: "a2", call: "toolu_B"))
        try stop("Both are back.")
        XCTAssertEqual(session?.status, .idle)
    }

    /// Seen live: a task can end while the agent is still busy, and the host
    /// tells the hook then too. By the time the turn ends there is nothing out.
    func testATaskEndingMidTurnIsAlreadyBackAtTheEnd() throws {
        try prompt("build it")
        try backgroundCommand(call: "toolu_A", task: "bq1")
        try send(#"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Read","tool_use_id":"toolu_R","tool_input":{"file_path":"/x/a.swift"}}"#)
        try prompt(notification(task: "bq1", call: "toolu_A"))
        try stop("Done.")
        XCTAssertEqual(session?.status, .idle)
    }

    func testAForegroundCallLeavesNothingOut() throws {
        try prompt("run it")
        try send(#"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"toolu_A","tool_input":{"command":"ls"},"tool_response":{"stdout":"a","stderr":"","interrupted":false}}"#)
        try send(#"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Agent","tool_use_id":"toolu_B","tool_input":{"description":"x","prompt":"y"},"tool_response":{"status":"completed","content":[]}}"#)
        XCTAssertNil(session?.backgroundTasks)
        try stop()
        XCTAssertEqual(session?.status, .idle)
    }

    func testStoppingATaskTakesItOff() throws {
        try prompt("start the server")
        try backgroundCommand(call: "toolu_A", task: "bq1")
        try send(#"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"TaskStop","tool_use_id":"toolu_S","tool_input":{"task_id":"bq1"}}"#)
        try stop()
        XCTAssertEqual(session?.status, .idle)
    }

    /// A server left running never reports back. Once somebody types, the
    /// next turn is judged on its own, or no later finish would ever count.
    func testTypingLetsGoOfWorkThatNeverReportsBack() throws {
        try prompt("start the dev server")
        try backgroundCommand(call: "toolu_A", task: "bq1")
        try stop("The server is up on port 3000.")
        XCTAssertEqual(session?.status, .running)

        try prompt("now fix the header")
        let before = session
        try stop("Fixed.")
        XCTAssertEqual(session?.status, .idle)
        XCTAssertEqual(session?.finishedTurn(since: before), true)
    }

    func testRestoreLetsGoOfWorkItCannotHearAbout() throws {
        try prompt("run the tests")
        try backgroundCommand(call: "toolu_A", task: "bq1")
        let restored = state.preparedForRestore(now: now.addingTimeInterval(60))
        XCTAssertNil(restored.sessions["s1"]?.backgroundTasks)
    }

    func testANotificationIsReadForItsIds() {
        let ids = SubmittedPrompt.notifiedTask(in: notification(task: "bq1", call: "toolu_A"))
        XCTAssertEqual(ids?.taskID, "bq1")
        XCTAssertEqual(ids?.callID, "toolu_A")
        XCTAssertNil(SubmittedPrompt.notifiedTask(in: "fix the <task-id> parser"))
    }

    func testOnlyTheToolsThatCanLeaveSomethingRunning() {
        XCTAssertNil(BackgroundTask.launched(tool: "Read", input: ["run_in_background": true], response: nil,
                                             callID: "c", at: now))
        XCTAssertNotNil(BackgroundTask.launched(tool: "Bash", input: ["run_in_background": true], response: "started",
                                                callID: "c", at: now), "the call's own flag when the result says nothing")
        XCTAssertNil(BackgroundTask.launched(tool: "Bash", input: ["run_in_background": true], response: nil,
                                             callID: nil, at: now), "no id, nothing could ever name it")
    }
}
