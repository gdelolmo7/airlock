import XCTest
@testable import AirlockCore

final class SessionStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func event(_ id: String, _ seq: UInt64, _ kind: AgentEvent.Kind) -> AgentEvent {
        AgentEvent(sessionID: id, agent: .claudeCode, sequence: seq, timestamp: t0, kind: kind)
    }

    func testFirstEventBootstrapsSession() {
        var state = SessionState()
        state.apply(event("s1", 10, .sessionStarted(project: "app", cwd: "/x", terminal: nil)))
        XCTAssertEqual(state.sessions.count, 1)
        XCTAssertEqual(state.sessions["s1"]?.projectName, "app")
        // Started ≠ running: a session earns "running" from real activity.
        XCTAssertEqual(state.sessions["s1"]?.status, .idle)
        state.apply(event("s1", 11, .promptSubmitted(prompt: "go")))
        XCTAssertEqual(state.sessions["s1"]?.status, .running)
    }

    /// Found live: a desktop session anchored to the immortal Claude.app host
    /// PID (no tty) showed "Running" 24h later — PID-liveness can't retire it,
    /// and single-session host PIDs looked "unique" so TTL skipped them.
    func testNoTTYHostSessionsAreTTLEvictable() {
        var state = SessionState()
        let old = t0
        let now = t0.addingTimeInterval(20 * 60)

        // Desktop host: has a (unique) PID but NO tty → unvouchable → evict.
        state.apply(AgentEvent(sessionID: "desktop", agent: .claudeCode, sequence: 1, timestamp: old,
                               kind: .jumpTargetUpdated(JumpTarget(agentPID: 646))))
        // Terminal agent: unique PID WITH a tty → ps vouches → never TTL-evicted.
        state.apply(AgentEvent(sessionID: "terminal", agent: .claudeCode, sequence: 2, timestamp: old,
                               kind: .jumpTargetUpdated(JumpTarget(tty: "/dev/ttys002", agentPID: 900))))

        let evicted = Set(state.ttlEvictionCandidates(now: now, olderThan: 15 * 60).map(\.id))
        XCTAssertEqual(evicted, ["desktop"])
    }

    func testStaleEventsAreDropped() {
        var state = SessionState()
        state.apply(event("s1", 10, .sessionStarted(project: "app", cwd: nil, terminal: nil)))
        state.apply(event("s1", 20, .activity(summary: "newer")))
        // An out-of-order older event must not overwrite newer state.
        state.apply(event("s1", 15, .activity(summary: "stale")))
        XCTAssertEqual(state.sessions["s1"]?.lastSummary, "newer")
        XCTAssertEqual(state.sessions["s1"]?.lastSequence, 20)
    }

    func testDuplicateSequenceIgnored() {
        var state = SessionState()
        state.apply(event("s1", 10, .activity(summary: "first")))
        state.apply(event("s1", 10, .activity(summary: "dup")))
        XCTAssertEqual(state.sessions["s1"]?.lastSummary, "first")
    }

    func testPermissionLifecycle() {
        var state = SessionState()
        let request = PermissionRequest(id: "r1", toolName: "Bash", summary: "Run", command: "ls", createdAt: t0)
        state.apply(event("s1", 10, .permissionRequested(request)))
        XCTAssertEqual(state.sessions["s1"]?.status, .needsAttention)
        XCTAssertEqual(state.attentionCount, 1)

        state.apply(event("s1", 11, .permissionResolved(requestID: "r1", decision: .allowOnce)))
        XCTAssertNil(state.sessions["s1"]?.pendingPermission)
        XCTAssertEqual(state.sessions["s1"]?.status, .running)
        XCTAssertEqual(state.attentionCount, 0)
    }

    func testOrderingPutsAttentionFirst() {
        var state = SessionState()
        state.apply(event("running", 10, .sessionStarted(project: "a", cwd: nil, terminal: nil)))
        let req = PermissionRequest(id: "r", toolName: "Bash", summary: "x", createdAt: t0)
        state.apply(event("needs", 11, .permissionRequested(req)))
        XCTAssertEqual(state.ordered.first?.id, "needs")
    }

    func testJumpTargetMergePreservesFields() {
        var state = SessionState()
        state.apply(event("s1", 10, .jumpTargetUpdated(JumpTarget(terminalApp: "iTerm", tty: "ttys1", agentPID: 4242))))
        state.apply(event("s1", 11, .jumpTargetUpdated(JumpTarget(tmuxPane: "%3"))))
        let target = state.sessions["s1"]?.jumpTarget
        XCTAssertEqual(target?.terminalApp, "iTerm") // preserved across a partial update
        XCTAssertEqual(target?.tmuxPane, "%3")
        XCTAssertEqual(target?.agentPID, 4242)
    }

    /// Found live: 9 of 10 sessions shared one host PID (the Claude desktop
    /// process), so per-PID liveness kept demo debris alive for hours.
    func testTTLEvictionTargetsOnlyUnvouchableSessions() {
        var state = SessionState()
        let old = t0
        let now = t0.addingTimeInterval(20 * 60)

        // Shared PID (two sessions on 646) + quiet → both candidates.
        state.apply(AgentEvent(sessionID: "shared-a", agent: .claudeCode, sequence: 1, timestamp: old,
                               kind: .jumpTargetUpdated(JumpTarget(agentPID: 646))))
        state.apply(AgentEvent(sessionID: "shared-b", agent: .claudeCode, sequence: 2, timestamp: old,
                               kind: .jumpTargetUpdated(JumpTarget(agentPID: 646))))
        // No PID + quiet → candidate.
        state.apply(AgentEvent(sessionID: "no-pid", agent: .claudeCode, sequence: 3, timestamp: old,
                               kind: .activity(summary: "x")))
        // Unique PID WITH a tty → a real terminal agent; ps vouches for it
        // individually; NEVER ttl-evicted.
        state.apply(AgentEvent(sessionID: "unique", agent: .claudeCode, sequence: 4, timestamp: old,
                               kind: .jumpTargetUpdated(JumpTarget(tty: "/dev/ttys009", agentPID: 999))))
        // Quiet but holding a gate → exempt (ask_timeout resolves it first).
        state.apply(AgentEvent(sessionID: "gated", agent: .claudeCode, sequence: 5, timestamp: old,
                               kind: .permissionRequested(PermissionRequest(id: "r", toolName: "Bash",
                                                                            summary: "x", createdAt: old))))
        // Fresh no-PID session → not yet.
        state.apply(AgentEvent(sessionID: "fresh", agent: .claudeCode, sequence: 6,
                               timestamp: now.addingTimeInterval(-60), kind: .activity(summary: "y")))

        let evicted = Set(state.ttlEvictionCandidates(now: now, olderThan: 15 * 60).map(\.id))
        XCTAssertEqual(evicted, ["shared-a", "shared-b", "no-pid"])
    }

    /// Found live: /login minted a new session_id in the same terminal; the
    /// old id lingered as a zombie "Running" row for the whole TTL.
    func testSameTerminalSupersedesOlderSession() {
        var state = SessionState()
        let target = JumpTarget(tty: "/dev/ttys004", agentPID: 900)

        state.apply(event("old", 10, .jumpTargetUpdated(target)))
        state.apply(event("old", 11, .activity(summary: "pre-login")))
        // New session_id, same pid+tty (post-/login), later activity.
        state.apply(AgentEvent(sessionID: "new", agent: .claudeCode, sequence: 20,
                               timestamp: t0.addingTimeInterval(60),
                               kind: .jumpTargetUpdated(target)))

        XCTAssertEqual(state.sessions["old"]?.status, .done, "same tty → superseded now, not at TTL")
        XCTAssertNotEqual(state.sessions["new"]?.status, .done)

        // Desktop-host shape: same PID, no tty — many conversations coexist.
        var desktop = SessionState()
        let hostA = JumpTarget(agentPID: 646)
        desktop.apply(event("conv-a", 10, .jumpTargetUpdated(hostA)))
        desktop.apply(AgentEvent(sessionID: "conv-b", agent: .claudeCode, sequence: 20,
                                 timestamp: t0.addingTimeInterval(60),
                                 kind: .jumpTargetUpdated(hostA)))
        XCTAssertNotEqual(desktop.sessions["conv-a"]?.status, .done, "no tty → never superseded")

        // Different tty, same pid (tmux panes) — both live.
        var tmux = SessionState()
        tmux.apply(event("pane-1", 10, .jumpTargetUpdated(JumpTarget(tty: "/dev/ttys001", agentPID: 900))))
        tmux.apply(AgentEvent(sessionID: "pane-2", agent: .claudeCode, sequence: 20,
                              timestamp: t0.addingTimeInterval(60),
                              kind: .jumpTargetUpdated(JumpTarget(tty: "/dev/ttys002", agentPID: 900))))
        XCTAssertNotEqual(tmux.sessions["pane-1"]?.status, .done)
    }

    /// Found live: a desktop session sat "Running" for an hour after its turn
    /// ended — desktop hosts never fire Stop, and the host PID never dies.
    func testIdleDemotionCandidates() {
        var state = SessionState()
        state.apply(event("silent", 10, .activity(summary: "old work")))
        state.apply(AgentEvent(sessionID: "chatty", agent: .claudeCode, sequence: 11,
                               timestamp: t0.addingTimeInterval(11 * 60), kind: .activity(summary: "fresh")))
        let req = PermissionRequest(id: "r", toolName: "Bash", summary: "x", createdAt: t0)
        state.apply(event("gated", 12, .permissionRequested(req)))
        state.apply(event("idler", 13, .statusChanged(.idle)))

        let now = t0.addingTimeInterval(12 * 60)
        let ids = Set(state.idleDemotionCandidates(now: now, olderThan: 10 * 60).map(\.id))
        XCTAssertEqual(ids, ["silent"], "only silent running sessions demote — not fresh, gated, or already idle")
    }

    /// Found live: a markdown table flattened into "| A | B ||---|---|" noise
    /// in the row. Block structure is skipped, not flattened.
    func testDisplayLineSkipsTablesAndCodeBlocks() {
        let withTable = """
        Shipped it.

        | Before | Now |
        |---|---|
        | raw | styled |

        Try it now.
        """
        XCTAssertEqual(SessionState.displayLine(withTable), "Shipped it. Try it now.")

        let withFence = "Fixed the parser.\n\n```swift\nlet x = 1\n```\n\nDone."
        XCTAssertEqual(SessionState.displayLine(withFence), "Fixed the parser. Done.")

        // Headings go, list items become inline separators.
        XCTAssertEqual(
            SessionState.displayLine("## Summary\n\n- fixed   parser\n- added tests"),
            "Summary · fixed parser · added tests")

        // Inline emphasis survives for the renderer to style.
        XCTAssertEqual(SessionState.displayLine("**Try** `code` [sha](x)"), "**Try** `code` [sha](x)")

        // A reply that is ONLY a table must not render empty.
        XCTAssertFalse(SessionState.displayLine("| A | B |\n|---|---|").isEmpty)

        // Long replies truncate with an ellipsis.
        XCTAssertTrue(SessionState.displayLine(String(repeating: "a", count: 500)).hasSuffix("…"))
    }

    // MARK: - A title from the first prompt

    /// It used to be the first 60 characters, wherever the 60th fell: "plan the
    /// tap-home change and the website update, ask me what".
    func testATitleFromAPromptEndsBetweenWords() {
        var state = SessionState()
        state.apply(event("s1", 1, .promptSubmitted(
            prompt: "plan the tap-home change and the website update, ask me whatever you need")))
        XCTAssertEqual(state.sessions["s1"]?.title,
                       "plan the tap-home change and the website update, ask me…")
    }

    func testATitleThatFitsIsLeftWhole() {
        var state = SessionState()
        state.apply(event("s1", 1, .promptSubmitted(prompt: "yes, push it and fix both")))
        XCTAssertEqual(state.sessions["s1"]?.title, "yes, push it and fix both")

        // Exactly the limit is not "shortened", so it gets no ellipsis.
        let sixty = String(repeating: "abcd ", count: 11) + "abcde"
        XCTAssertEqual(sixty.count, 60)
        XCTAssertEqual(SessionState.promptTitle(sixty), sixty)
    }

    /// One line, whatever was typed, and no comma left hanging before the "…".
    func testATitleIsOneLineAndEndsCleanly() {
        XCTAssertEqual(SessionState.promptTitle("fix the flaky test\n\nit fails on CI"),
                       "fix the flaky test it fails on CI")
        XCTAssertEqual(SessionState.promptTitle(
            "move the settings pane into the notch panel itself, then delete the old window"),
            "move the settings pane into the notch panel itself, then…")
        // The 60th character falls just after "website, ".
        XCTAssertEqual(SessionState.promptTitle(
            "check the onboarding copy and the settings and the website, then ship it all"),
            "check the onboarding copy and the settings and the website…")
        // Only the end is tidied; a prompt may start with a dash.
        XCTAssertEqual(SessionState.promptTitle(
            "— start with a dash and then keep going for quite a long while past the limit"),
            "— start with a dash and then keep going for quite a long…")
    }

    /// Backing up to a space would leave "fix…" of an address — a long token
    /// is cut instead.
    func testALongTokenIsCutRatherThanLost() {
        let title = SessionState.promptTitle(
            "fix https://github.com/owner/repository/issues/12345/some-very-long-path")
        XCTAssertEqual(title, "fix https://github.com/owner/repository/issues/12345/some-ve…")
        XCTAssertTrue(title.hasSuffix("…"))
    }

    /// A real title is shown as it arrived: only the derived one is shortened.
    func testARealTitleIsNeverShortened() {
        let long = "Plain-language tool names, the You line and every question an ask carries"
        var state = SessionState()
        state.apply(event("s1", 1, .titleChanged(title: long)))
        state.apply(event("s1", 2, .promptSubmitted(prompt: "and then a second prompt that is long enough to cut")))
        XCTAssertEqual(state.sessions["s1"]?.title, long)

        var later = SessionState()
        later.apply(event("s2", 1, .promptSubmitted(
            prompt: "plan the tap-home change and the website update, ask me whatever you need")))
        later.apply(event("s2", 2, .titleChanged(title: long)))
        XCTAssertEqual(later.sessions["s2"]?.title, long)
    }

    // MARK: - The row's line around a gate

    private func question(_ count: Int) -> PermissionRequest {
        var request = PermissionRequest(id: "q", toolName: "AskUserQuestion",
                                        summary: "Which auth method?", createdAt: t0)
        request.questions = (1...count).map {
            QuestionPrompt(question: "Question \($0)?", header: "H\($0)",
                           options: [QuestionOption(label: "A")])
        }
        return request
    }

    /// The card under the row says the question in full. The row said it again,
    /// cut short — and on question two, still said question one.
    func testAQuestionsRowLineSaysItIsWaitingRatherThanRepeatingIt() {
        var state = SessionState()
        state.apply(event("s1", 1, .permissionRequested(question(2))))
        XCTAssertEqual(state.sessions["s1"]?.lastSummary, "Waiting for your answer · 2 questions")

        var single = SessionState()
        single.apply(event("s1", 1, .permissionRequested(question(1))))
        XCTAssertEqual(single.sessions["s1"]?.lastSummary, "Waiting for your answer")
    }

    /// A permission gate's summary is already a line — and a Bash gate's
    /// description sits usefully above the raw command in its card.
    func testAPermissionsRowLineIsUnchanged() {
        var state = SessionState()
        state.apply(event("s1", 1, .permissionRequested(PermissionRequest(
            id: "p", toolName: "Bash", summary: "Clean the build output",
            activity: "Clean the build output", command: "rm -rf dist", createdAt: t0))))
        XCTAssertEqual(state.sessions["s1"]?.lastSummary, "Clean the build output")
    }

    /// Once the card has gone, the line stops reading it.
    func testTheLineMovesOnWhenTheGateEnds() {
        var answered = SessionState()
        answered.apply(event("s1", 1, .permissionRequested(question(2))))
        answered.apply(event("s1", 2, .permissionResolved(requestID: "q", decision: .allowOnce)))
        XCTAssertEqual(answered.sessions["s1"]?.lastSummary, "Working…")

        let mcp = PermissionRequest(id: "m", toolName: "mcp__trello__trelloWriteCard",
                                    summary: "Allow Trello: write card?",
                                    activity: "Using Trello: write card", createdAt: t0)
        var approved = SessionState()
        approved.apply(event("s1", 1, .permissionRequested(mcp)))
        XCTAssertEqual(approved.sessions["s1"]?.lastSummary, "Allow Trello: write card?")
        approved.apply(event("s1", 2, .permissionResolved(requestID: "m", decision: .allowOnce)))
        XCTAssertEqual(approved.sessions["s1"]?.lastSummary, "Using Trello: write card",
                       "not a question over a tool that is already running")

        var denied = SessionState()
        denied.apply(event("s1", 1, .permissionRequested(mcp)))
        denied.apply(event("s1", 2, .permissionResolved(requestID: "m", decision: .deny)))
        XCTAssertEqual(denied.sessions["s1"]?.lastSummary, "Working…")

        // Handed back: the agent is asking in its own prompt. The line says
        // so rather than keeping the question, which read as the agent still
        // being on it — the receipt below carries the question and where.
        var ignored = SessionState()
        ignored.apply(event("s1", 1, .permissionRequested(question(2))))
        ignored.apply(event("s1", 2, .permissionResolved(requestID: "q", decision: .deferred)))
        XCTAssertEqual(ignored.sessions["s1"]?.lastSummary, SessionCardText.handedBack)
        XCTAssertNotNil(ignored.sessions["s1"]?.questionReceipt)
    }

    /// A resolution for some other gate is not this one ending.
    func testAStaleResolutionLeavesTheLineAlone() {
        var state = SessionState()
        state.apply(event("s1", 1, .permissionRequested(question(2))))
        state.apply(event("s1", 2, .permissionResolved(requestID: "older", decision: .deferred)))
        XCTAssertEqual(state.sessions["s1"]?.lastSummary, "Waiting for your answer · 2 questions")
    }

    func testPruneRemovesLongDoneKeepsRest() {
        var state = SessionState()
        state.apply(event("dead", 10, .sessionEnded))
        state.apply(event("live", 11, .activity(summary: "working")))
        state.prune(now: t0.addingTimeInterval(300), olderThan: 120)
        XCTAssertNil(state.sessions["dead"])
        XCTAssertNotNil(state.sessions["live"], "prune only touches done sessions")

        // A freshly-done session survives until the retention window passes.
        state.apply(AgentEvent(sessionID: "live", agent: .claudeCode, sequence: 12,
                               timestamp: t0.addingTimeInterval(299), kind: .sessionEnded))
        state.prune(now: t0.addingTimeInterval(300), olderThan: 120)
        XCTAssertNotNil(state.sessions["live"])
    }
}
