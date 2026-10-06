import XCTest
@testable import AirlockCore

/// The words on the Agents tab: one word per state, no line that repeats the
/// pill or a title that repeats the line, and an empty tab that tells a broken
/// setup from a healthy one.
final class AgentsCardTextTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(status: SessionStatus = .running, line: String = "",
                         project: String = "storefront", cwd: String? = nil,
                         title: String? = nil, prompt: String? = nil,
                         response: String? = nil, explicit: Bool? = nil,
                         turns: Int = 0, agent: AgentKind = .claudeCode) -> AgentSession {
        AgentSession(id: "s1", agent: agent, projectName: project, cwd: cwd, status: status,
                     lastSummary: line, title: title, lastPrompt: prompt, lastResponse: response,
                     titleExplicit: explicit, lastActivity: t0, turns: turns)
    }

    // MARK: One word per state (A12)

    func testEveryStateHasOneWordAndTheLineNeverRestatesIt() {
        let all: [SessionStatus] = [.starting, .running, .needsAttention, .waitingQuestion,
                                    .idle, .done, .error]
        XCTAssertEqual(Set(all.map(\.word)).count, all.count, "two states, one word")
        for status in all {
            XCTAssertNil(SessionCardText.activity(of: session(status: status, line: status.word)),
                         "\(status) said twice")
            XCTAssertNil(SessionCardText.activity(of: session(status: status, line: status.word + "…")))
        }
        XCTAssertNil(SessionCardText.activity(of: session(status: .running, line: "Running")),
                     "the old fallback word for the same state")
        XCTAssertNil(SessionCardText.activity(of: session(status: .running, line: "Working…")))
    }

    func testARealLineIsKeptAndARestingSessionHasNone() {
        XCTAssertEqual(SessionCardText.activity(of: session(line: "Editing Login.swift")),
                       "Editing Login.swift")
        XCTAssertNil(SessionCardText.activity(of: session(line: "   ")))
        XCTAssertNil(SessionCardText.activity(of: session(status: .idle, line: "Editing Login.swift")),
                     "a stale description reads as work that isn't happening")
        XCTAssertNil(SessionCardText.activity(of: session(status: .done, line: "Editing Login.swift")))
    }

    // MARK: Names (A10, A11, A13, A14)

    func testAnUntitledSessionIsNamedByWhereItIsNeverOurPlaceholder() {
        XCTAssertEqual(SessionCardText.title(of: session()), "storefront")
        XCTAssertEqual(SessionCardText.title(of: session(project: SessionState.unknownProject,
                                                         cwd: "/Users/me/api")), "api")
        XCTAssertEqual(SessionCardText.title(of: session(project: SessionState.unknownProject)),
                       AgentKind.claudeCode.displayName)
        XCTAssertEqual(SessionCardText.title(of: session(project: "", agent: .codex)),
                       AgentKind.codex.displayName)
    }

    func testAPromptTitleGivesWayWhileItIsTheLineUnderIt() {
        let first = session(title: "Fix the **login** bug", prompt: "Fix the **login** bug")
        XCTAssertEqual(SessionCardText.title(of: first), "storefront", "the prompt twice says nothing")

        var answered = first
        answered.lastResponse = "Done — the token now refreshes."
        XCTAssertEqual(SessionCardText.title(of: answered), "Fix the **login** bug")

        var later = first
        later.turns = 2
        XCTAssertEqual(SessionCardText.title(of: later), "Fix the **login** bug")

        let named = session(title: "Login refresh", prompt: "Fix the login bug", explicit: true)
        XCTAssertEqual(SessionCardText.title(of: named), "Login refresh", "Claude's own name always wins")
    }

    func testAnEventWithNoWordsLeavesTheLineAlone() throws {
        let integration = ClaudeCodeIntegration()
        let context = HookContext(source: "claude-code", cwd: nil, terminal: nil, receivedAt: t0)
        func decode(_ json: String) throws -> [AgentEvent] {
            try integration.decodeEvents(from: Data(json.utf8), context: context)
        }
        XCTAssertEqual(try decode(#"{"session_id":"s1","hook_event_name":"SubagentStart"}"#).count, 0,
                       "an event's internal name is not a line")
        XCTAssertEqual(try decode(#"{"session_id":"s1","hook_event_name":"Notification"}"#).count, 0)

        let compact = try decode(#"{"session_id":"s1","hook_event_name":"PreCompact"}"#)
        guard case let .activity(summary)? = compact.first?.kind else { return XCTFail("expected a line") }
        XCTAssertEqual(summary, ClaudeStyleHookDecoder.compactingLine)

        let start = try decode(#"{"session_id":"s1","hook_event_name":"SessionStart"}"#)
        guard case let .sessionStarted(project, _, _)? = start.first?.kind else { return XCTFail() }
        XCTAssertEqual(project, SessionState.unknownProject, "the placeholder the card knows to replace")
    }

    // MARK: Terminal and time words (A28)

    func testTerminalsAreNamedAsPeopleNameThem() {
        XCTAssertEqual(TerminalName.pretty("iTerm.app"), "iTerm")
        XCTAssertEqual(TerminalName.pretty("Apple_Terminal"), "Terminal")
        XCTAssertEqual(TerminalName.pretty("vscode"), "VS Code")
        XCTAssertEqual(TerminalName.pretty("Warp.app"), "Warp")
        XCTAssertNil(TerminalName.pretty("terminal"))
        XCTAssertNil(TerminalName.pretty(nil))
        XCTAssertNil(TerminalName.pretty(""))
    }

    func testAgoNeverSaysInTheFuture() {
        XCTAssertEqual(AgoPhrase.since(t0.addingTimeInterval(2), now: t0), "just now",
                       "a stamp a hair ahead of the clock is a moment ago, not 'in 0s'")
        XCTAssertEqual(AgoPhrase.since(t0, now: t0.addingTimeInterval(59)), "just now")
        XCTAssertEqual(AgoPhrase.since(t0, now: t0.addingTimeInterval(4 * 60)), "4 min ago")
        XCTAssertEqual(AgoPhrase.since(t0, now: t0.addingTimeInterval(2 * 3600 + 50 * 60)), "2 h ago")
        XCTAssertEqual(AgoPhrase.since(t0, now: t0.addingTimeInterval(30 * 3600)), "1 day ago")
        XCTAssertEqual(AgoPhrase.since(t0, now: t0.addingTimeInterval(80 * 3600)), "3 days ago")
    }

    // MARK: Handed back (A24, A28)

    func testAHandedBackRequestSaysWhereItWentWhateverItWas() {
        var state = SessionState()
        state.apply(AgentEvent(sessionID: "s1", agent: .claudeCode, sequence: 1, timestamp: t0,
                               kind: .permissionRequested(PermissionRequest(
                                   id: "p", toolName: "Bash", summary: "Run shell command",
                                   command: "make", createdAt: t0))))
        state.apply(AgentEvent(sessionID: "s1", agent: .claudeCode, sequence: 2, timestamp: t0,
                               kind: .permissionResolved(requestID: "p", decision: .deferred)))
        XCTAssertEqual(state.sessions["s1"]?.lastSummary, SessionCardText.handedBack,
                       "not 'Run shell command', as if the agent were still on it")
        XCTAssertEqual(state.sessions["s1"].flatMap(SessionCardText.activity(of:)), SessionCardText.handedBack)

        var asked = session(line: SessionCardText.handedBack)
        asked.questionReceipt = QuestionReceipt(question: "Which?", reason: .ignored, at: t0)
        XCTAssertNil(SessionCardText.activity(of: asked), "the receipt under it already says so")
    }

    // MARK: Asked in the terminal (A17)

    func testCodexAskingInItsTerminalSaysWhatAndWhere() throws {
        let codex = CodexIntegration()
        let context = HookContext(source: "codex", cwd: nil, terminal: nil, receivedAt: t0)
        let events = try codex.decodeEvents(from: Data(#"{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm install express-rate-limit"}}"#.utf8),
                                            context: context)
        var state = SessionState()
        state.apply(AgentEvent(sessionID: "s1", agent: .codex, sequence: 1, timestamp: t0,
                               kind: .sessionStarted(project: "api", cwd: nil,
                                                     terminal: TerminalInfo(app: "tmux"))))
        for (n, var event) in events.enumerated() {
            event.sequence = UInt64(2 + n)
            state.apply(event)
        }
        let session = try XCTUnwrap(state.sessions["s1"])
        XCTAssertEqual(SessionCardText.terminalAsk(of: session),
                       .init(heading: "Codex is asking in tmux", subject: "npm install express-rate-limit"))
        XCTAssertNil(SessionCardText.activity(of: session), "the card says it; the line would say it again")
        XCTAssertNil(SessionCardText.terminalAsk(of: self.session()), "nothing asked")
    }

    // MARK: Always (A20, A27)

    func testAlwaysIsOfferedOnlyWhereARuleWouldBeHonoured() {
        let plain = PermissionRequest(id: "a", toolName: "Bash", summary: "Run tests",
                                      command: "npm test", createdAt: t0)
        XCTAssertTrue(plain.offersAlways)

        let risky = PermissionRequest(id: "b", toolName: "Bash", summary: "Delete build",
                                      command: "rm -rf dist", createdAt: t0)
        XCTAssertFalse(risky.offersAlways, "the risk floor is read before any allow rule")
        XCTAssertEqual(RiskAssessor.assess(risky)?.cardLine,
                       "Risky: recursive delete. Airlock asks about this every time.")

        let question = PermissionRequest(id: "c", toolName: "AskUserQuestion", summary: "Which?",
                                         question: QuestionPrompt(question: "Which?", options: []),
                                         createdAt: t0)
        XCTAssertFalse(question.offersAlways, "a rule for a question is a rule named after a tool")
    }

    // MARK: The empty tab (A6, A7, A8)

    func testTheThreeEmptyTabsAreThreeDifferentThings() {
        let claude = AgentsConnection.Link(name: "Claude Code", status: .installed, settingsPath: "/c")
        let codexOff = AgentsConnection.Link(name: "Codex", status: .notInstalled, settingsPath: "/x")
        let codexStuck = AgentsConnection.Link(name: "Codex", status: .conflict("lines"), settingsPath: "/x")

        let none = AgentsConnection([AgentsConnection.Link(name: "Claude Code", status: .notInstalled,
                                                           settingsPath: "/c"), codexOff])
        XCTAssertTrue(none.isNothingConnected)

        let healthy = AgentsConnection([claude, codexOff])
        XCTAssertFalse(healthy.isNothingConnected)
        XCTAssertEqual(healthy.blocked, [])
        XCTAssertEqual(healthy.emptyLine,
                       "Claude Code is connected. Start it in any terminal and it shows up here, with anything it asks.")

        let stuck = AgentsConnection([claude, codexStuck])
        XCTAssertEqual(stuck.blocked, [codexStuck])
        XCTAssertTrue(AgentsConnection.blockedSentence(codexStuck).hasPrefix("Codex can't connect"))

        let both = AgentsConnection(connected: ["Claude Code", "Codex"])
        XCTAssertTrue(both.emptyLine.hasPrefix("Claude Code and Codex are connected. Start either"))
        XCTAssertEqual(AgentsConnection.names(["A", "B", "C"]), "A, B and C")
    }

    // MARK: Terminal trouble (A19, A34)

    func testARefusedTerminalSaysWhyAndOnlyAPermissionGetsTheButton() {
        let refused = TerminalTrouble(appleScriptCode: TerminalTrouble.notPermittedCode, app: "iTerm")
        XCTAssertEqual(refused, .notAllowed(app: "iTerm"))
        XCTAssertTrue(refused.opensAutomationSettings)
        XCTAssertTrue(refused.sentence.contains("Automation"))

        let silent = TerminalTrouble(appleScriptCode: -1728, app: "Terminal")
        XCTAssertEqual(silent, .didNotOpen(app: "Terminal"))
        XCTAssertFalse(silent.opensAutomationSettings)
    }

    // MARK: Claude usage (I14, I15, A33)

    func testUsageSaysHowOldItIs() {
        XCTAssertEqual(UsageReadout.freshness(capturedAt: nil, now: t0), UsageReadout.Freshness.none)
        XCTAssertEqual(UsageReadout.freshness(capturedAt: t0.addingTimeInterval(-60), now: t0), .current)
        XCTAssertEqual(UsageReadout.freshness(capturedAt: t0.addingTimeInterval(-3 * 3600), now: t0),
                       .old("3 h ago"))
        XCTAssertEqual(UsageReadout.freshness(capturedAt: t0.addingTimeInterval(-13 * 3600), now: t0),
                       UsageReadout.Freshness.none, "too old to mean anything")
        XCTAssertEqual(UsageReadout.spoken(fiveHour: 42, weekly: 7, age: nil),
                       "Claude usage: 5-hour limit 42% used, weekly limit 7% used")
    }

    func testTheStoppedCardOnlyWhenTheLinkIsSomebodyElses() {
        XCTAssertTrue(UsageReadout.showsStopped(wanted: true, connection: .replaced))
        XCTAssertFalse(UsageReadout.showsStopped(wanted: false, connection: .replaced))
        XCTAssertFalse(UsageReadout.showsStopped(wanted: true, connection: .connected))
        XCTAssertFalse(UsageReadout.showsStopped(wanted: true, connection: .hooksMissing),
                       "nothing connected is the connect card's job")
    }
}
