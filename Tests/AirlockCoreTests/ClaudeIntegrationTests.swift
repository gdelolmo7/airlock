import XCTest
@testable import AirlockCore

/// Verifies the Claude Code wire contract: input decoding and the PreToolUse
/// decision output, both against the shapes in the official hooks docs.
final class ClaudeIntegrationTests: XCTestCase {
    private let integration = ClaudeCodeIntegration()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func context(at time: Date? = nil) -> HookContext {
        HookContext(source: "claude-code", cwd: nil, terminal: TerminalInfo(app: "iTerm.app"),
                    receivedAt: time ?? now)
    }

    private func decode(_ json: String, at time: Date? = nil) throws -> [AgentEvent] {
        try integration.decodeEvents(from: Data(json.utf8), context: context(at: time))
    }

    func testBlockingOnlyForTheEventsClaudeWaitsOn() {
        XCTAssertTrue(integration.isBlocking(eventName: "PreToolUse"))
        XCTAssertTrue(integration.isBlocking(eventName: "PermissionRequest"))
        XCTAssertFalse(integration.isBlocking(eventName: "Notification"))
        XCTAssertFalse(integration.isBlocking(eventName: "Stop"))
        XCTAssertFalse(integration.isBlocking(eventName: nil))
    }

    func testSessionStartDerivesProjectFromCwd() throws {
        let events = try decode(#"{"session_id":"s1","hook_event_name":"SessionStart","cwd":"/Users/me/storefront","source":"startup"}"#)
        guard case let .sessionStarted(project, cwd, _) = events.first?.kind else {
            return XCTFail("expected sessionStarted")
        }
        XCTAssertEqual(project, "storefront")
        XCTAssertEqual(cwd, "/Users/me/storefront")
        XCTAssertEqual(events.first?.sessionID, "s1")
    }

    func testPreToolUseBashBecomesPermissionWithCommand() throws {
        let events = try decode(#"{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf ./dist"}}"#)
        guard case let .permissionRequested(request) = events.first?.kind else {
            return XCTFail("expected permissionRequested")
        }
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.command, "rm -rf ./dist")
    }

    func testPromptAndTitleCapture() throws {
        var state = SessionState()
        for event in try decode(#"{"session_id":"s1","hook_event_name":"SessionStart","cwd":"/x/app","session_title":"fix auth bug"}"#) {
            state.apply(event)
        }
        XCTAssertEqual(state.sessions["s1"]?.title, "fix auth bug")
        XCTAssertNotNil(state.sessions["s1"]?.startedAt)

        // Later invocation → later sequence base, as in reality.
        for event in try decode(#"{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"fix the auth bug in middleware"}"#,
                                at: now.addingTimeInterval(5)) {
            state.apply(event)
        }
        XCTAssertEqual(state.sessions["s1"]?.lastPrompt, "fix the auth bug in middleware")
        XCTAssertEqual(state.sessions["s1"]?.title, "fix auth bug", "explicit title outranks prompts")

        // Without a session_title, the first prompt names the conversation.
        var fresh = SessionState()
        for event in try decode(#"{"session_id":"s2","hook_event_name":"UserPromptSubmit","prompt":"optimize queries"}"#) {
            fresh.apply(event)
        }
        XCTAssertEqual(fresh.sessions["s2"]?.title, "optimize queries")
    }

    /// PostToolUse is after the fact, so it says what happened — "Writing"
    /// read as work still going on while Claude had moved on.
    func testPostToolUseRichSummaries() throws {
        let write = try decode(#"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"/x/middleware.ts"}}"#)
        XCTAssertEqual(write.last?.kind, .activity(summary: "Wrote middleware.ts"))
        let bash = try decode(#"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"npm test"}}"#)
        XCTAssertEqual(bash.last?.kind, .activity(summary: "Ran: npm test"))
    }

    /// Claude authors a natural-language description for every Bash call —
    /// the island shows that, never raw shell text (user ask).
    func testBashDescriptionBeatsRawCommand() throws {
        let post = try decode(#"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"zsh scripts/package-app.sh && git commit","description":"Package, relaunch, and commit"}}"#)
        XCTAssertEqual(post.last?.kind, .activity(summary: "Package, relaunch, and commit"))

        let pre = try decode(#"{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf dist","description":"Clean the build output"}}"#)
        guard case let .permissionRequested(request) = pre.last?.kind else { return XCTFail() }
        XCTAssertEqual(request.summary, "Clean the build output")
        XCTAssertEqual(request.command, "rm -rf dist", "raw command still shown in the card body")
    }

    func testTranscriptPathRidesAlong() throws {
        let events = try decode(#"{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"go","transcript_path":"/x/t.jsonl"}"#)
        XCTAssertEqual(events.first?.kind, .metadata(transcriptPath: "/x/t.jsonl"))
        var state = SessionState()
        events.forEach { state.apply($0) }
        XCTAssertEqual(state.sessions["s1"]?.transcriptPath, "/x/t.jsonl")
    }

    func testStopEndsTurnWithReply() throws {
        var state = SessionState()
        for e in try decode(#"{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"fix it"}"#) { state.apply(e) }
        XCTAssertEqual(state.sessions["s1"]?.status, .running)
        XCTAssertNil(state.sessions["s1"]?.lastResponse, "new turn clears the prior reply")

        for e in try decode(#"{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":"Fixed the null check in middleware.ts."}"#,
                            at: now.addingTimeInterval(5)) { state.apply(e) }
        XCTAssertEqual(state.sessions["s1"]?.status, .idle)
        XCTAssertEqual(state.sessions["s1"]?.lastResponse, "Fixed the null check in middleware.ts.")
    }

    /// A helper coming back is not the agent finishing: it is still at work,
    /// and the helper's last words are not its reply.
    func testSubagentStopLeavesTheAgentWorking() throws {
        var state = SessionState()
        for e in try decode(#"{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"look around"}"#) { state.apply(e) }
        for e in try decode(#"{"session_id":"s1","hook_event_name":"SubagentStop","last_assistant_message":"Found three files."}"#,
                            at: now.addingTimeInterval(5)) { state.apply(e) }
        XCTAssertEqual(state.sessions["s1"]?.status, .running)
        XCTAssertNil(state.sessions["s1"]?.lastResponse)
        XCTAssertEqual(state.sessions["s1"]?.turns, 0)
    }

    /// The Done chime: a session coming to rest is a finish only when the
    /// agent ended its turn. Seen live 2026-10-06: another agent compacting
    /// its conversation chimed Done in the middle of its work.
    func testOnlyAStopIsAFinishedTurn() throws {
        var state = SessionState()
        func look() -> AgentSession? { state.sessions["s1"] }

        for e in try decode(#"{"session_id":"s1","hook_event_name":"SessionStart","cwd":"/x/app","source":"startup"}"#) { state.apply(e) }
        var before = look()
        for e in try decode(#"{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"fix it"}"#,
                            at: now.addingTimeInterval(1)) { state.apply(e) }
        XCTAssertEqual(look()?.finishedTurn(since: before), false, "a prompt starts a turn")

        before = look()
        for e in try decode(#"{"session_id":"s1","hook_event_name":"SessionStart","cwd":"/x/app","source":"compact"}"#,
                            at: now.addingTimeInterval(2)) { state.apply(e) }
        XCTAssertEqual(look()?.status, .idle)
        XCTAssertEqual(look()?.finishedTurn(since: before), false, "compacting is not finishing")

        for e in try decode(#"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Read"}"#,
                            at: now.addingTimeInterval(3)) { state.apply(e) }
        before = look()
        state.apply(AgentEvent(sessionID: "s1", agent: .claudeCode, sequence: UInt64(now.addingTimeInterval(4).timeIntervalSince1970 * 1000),
                               timestamp: now.addingTimeInterval(4), kind: .statusChanged(.idle)))
        XCTAssertEqual(look()?.finishedTurn(since: before), false, "ten silent minutes are a guess")

        for e in try decode(#"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Read"}"#,
                            at: now.addingTimeInterval(20)) { state.apply(e) }
        before = look()
        for e in try decode(#"{"session_id":"s1","hook_event_name":"Stop"}"#,
                            at: now.addingTimeInterval(21)) { state.apply(e) }
        XCTAssertEqual(look()?.finishedTurn(since: before), true)
        XCTAssertEqual(look()?.finishedTurn(since: nil), false, "a session first seen has no turn to finish")
    }

    /// A turn that ends just after you answered from the notch still finishes
    /// (the ✓), but it is not news worth the Done chime. Heard live
    /// 2026-10-06: an answer, then the agent stopped to wait on a build, then
    /// Done two seconds later.
    func testAFinishRightAfterYouAnswerIsQuiet() throws {
        var state = SessionState()
        let ask = #"{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Install now?","header":"Install","multiSelect":false,"options":[{"label":"Yes"},{"label":"Later"}]}]}}"#
        for e in try decode(#"{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"ship it"}"#) { state.apply(e) }
        for e in try decode(ask, at: now.addingTimeInterval(1)) { state.apply(e) }
        let card = try XCTUnwrap(state.sessions["s1"]?.pendingPermission)
        XCTAssertNil(state.sessions["s1"]?.answeredAt)

        state.resolveGate(sessionID: "s1", requestID: card.id, decision: .allowOnce, at: now.addingTimeInterval(2))
        XCTAssertEqual(state.sessions["s1"]?.answeredAt, now.addingTimeInterval(2))

        let before = state.sessions["s1"]
        for e in try decode(#"{"session_id":"s1","hook_event_name":"Stop"}"#, at: now.addingTimeInterval(4)) { state.apply(e) }
        let after = try XCTUnwrap(state.sessions["s1"])
        XCTAssertTrue(after.finishedTurn(since: before), "it did finish: the ✓ still pulses")
        XCTAssertFalse(after.finishIsNews(at: now.addingTimeInterval(4)), "you are right there")
        XCTAssertFalse(after.finishIsNews(at: now.addingTimeInterval(2 + AgentSession.quietAfterAnswer - 1)))
        XCTAssertTrue(after.finishIsNews(at: now.addingTimeInterval(2 + AgentSession.quietAfterAnswer)),
                      "long after the answer, a finish calls you back again")
    }

    /// Only a person answering counts. A card handed back to the terminal was
    /// not answered here, and a session nobody answered always chimes.
    func testHandingACardBackIsNotAnAnswer() throws {
        var state = SessionState()
        let ask = #"{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?","header":"Pick","multiSelect":false,"options":[{"label":"A"},{"label":"B"}]}]}}"#
        for e in try decode(ask) { state.apply(e) }
        let card = try XCTUnwrap(state.sessions["s1"]?.pendingPermission)
        state.resolveGate(sessionID: "s1", requestID: card.id, decision: .deferred, at: now.addingTimeInterval(1))
        XCTAssertNil(state.sessions["s1"]?.answeredAt)
        XCTAssertEqual(state.sessions["s1"]?.finishIsNews(at: now.addingTimeInterval(2)), true)
    }

    /// Replies are multi-line markdown; the row is two lines. Collapse.
    func testMessagesCollapseToOneLine() throws {
        var state = SessionState()
        let reply = "Done — shipped it.\n\n- fixed the parser\n- added   tests"
        let json = #"{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":"\#(reply.replacingOccurrences(of: "\n", with: "\\n"))"}"#
        for e in try decode(json) { state.apply(e) }
        let stored = try XCTUnwrap(state.sessions["s1"]?.lastResponse)
        XCTAssertFalse(stored.contains("\n"), "no newlines survive into the row")
        XCTAssertEqual(stored, "Done — shipped it. · fixed the parser · added tests")
    }

    /// AskUserQuestion arrives as a blocking PreToolUse gate: surface it as a
    /// pickable question, not an Approve/Deny card.
    func testAskUserQuestionBecomesPickableOptions() throws {
        let json = #"""
        {"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which deployment target?","header":"Deploy target","multiSelect":false,"options":[{"label":"Production","description":"live traffic"},{"label":"Staging"},{"label":"Local only"}]}]}}
        """#
        let events = try decode(json)
        guard case let .permissionRequested(request) = events.last?.kind else {
            return XCTFail("expected a gate, got \(events)")
        }
        let question = try XCTUnwrap(request.question)
        XCTAssertEqual(question.question, "Which deployment target?")
        XCTAssertEqual(question.header, "Deploy target")
        XCTAssertEqual(question.options.map(\.label), ["Production", "Staging", "Local only"])
        XCTAssertEqual(question.options.first?.detail, "live traffic")
        XCTAssertEqual(request.summary, "Which deployment target?", "the question titles the card")
        XCTAssertFalse(question.multiSelect)
    }

    func testNonQuestionToolsHaveNoOptions() throws {
        let events = try decode(#"{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        guard case let .permissionRequested(request) = events.last?.kind else { return XCTFail() }
        XCTAssertNil(request.question)
    }

    // Jump/liveness enrichment happens at the bridge, not in decoders —
    // see BridgeIntegrationTests.testPreToolUseRoundTripApprove.

    /// Found live: bypass-mode sessions were stalled up to ask_timeout per tool
    /// call. If the user told the session not to ask, the notch must not ask.
    func testBypassModesNeverGate() throws {
        // `plan` moved into this list on live evidence. It was previously
        // asserted to gate, under the belief that "Claude itself still prompts"
        // — it does not. In plan mode Claude works out what it WOULD do and
        // never runs the tool, so no approval appears in the chat. The card had
        // nowhere to be answered from, and the held hook stalled the planning
        // run it interrupted.
        for mode in ["bypassPermissions", "dontAsk", "auto", "plan"] {
            let events = try decode(#"{"session_id":"s1","hook_event_name":"PreToolUse","permission_mode":"\#(mode)","tool_name":"Bash","tool_input":{"command":"swift build"}}"#)
            guard case let .activity(summary) = events.last?.kind else {
                return XCTFail("\(mode) must never raise a gate, got \(events)")
            }
            XCTAssertTrue(summary.contains("swift build"))
        }
        // Modes where Claude itself still prompts keep the notch gate.
        // `acceptEdits` stays here on purpose: it auto-accepts FILE EDITS, and
        // still asks about everything else — which a Bash command is.
        for mode in ["default", "acceptEdits"] {
            let events = try decode(#"{"session_id":"s1","hook_event_name":"PreToolUse","permission_mode":"\#(mode)","tool_name":"Bash","tool_input":{"command":"swift build"}}"#)
            guard case .permissionRequested = events.last?.kind else {
                return XCTFail("\(mode) should still gate, got \(events)")
            }
        }
    }

    func testAllowOutputMatchesDocsSchema() throws {
        let data = try XCTUnwrap(integration.directiveOutput(
            for: HookDirective(action: .allow), eventName: "PreToolUse"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(specific["permissionDecision"] as? String, "allow")
        XCTAssertNotNil(specific["permissionDecisionReason"])
    }

    /// Sorted keys, so the same answer is always the same bytes.
    func testAllowOutputBytes() throws {
        let data = try XCTUnwrap(integration.directiveOutput(
            for: .from(.allowOnce), eventName: "PreToolUse"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved from Airlock"}}"#)
    }

    func testDenyOutputMatchesDocsSchema() throws {
        let data = try XCTUnwrap(integration.directiveOutput(
            for: HookDirective(action: .deny, reason: "nope"), eventName: "PreToolUse"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["permissionDecision"] as? String, "deny")
        XCTAssertEqual(specific["permissionDecisionReason"] as? String, "nope")
    }

    func testNoDirectiveOutputForNonGateEvents() {
        XCTAssertNil(integration.directiveOutput(for: HookDirective(action: .allow), eventName: "Stop"))
    }
}
