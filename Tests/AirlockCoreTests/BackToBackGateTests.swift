import XCTest
@testable import AirlockCore

/// Two gates in one session, back to back.
///
/// First found as a status bug: the bridge held one gate per session, a newer
/// request took the card, and the older one's hand-back reached the reducer
/// after the newer card was up — which set the session "running" with a card
/// still showing. `attentionCount` fell to zero, the island took that for
/// "answered", and the agent sat behind a card nobody had been told about.
/// Gates now queue (see `GateQueueTests`), and these pin the same promise
/// under the queue: while any gate waits, the session is waiting.
final class BackToBackGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func event(_ seq: UInt64, _ kind: AgentEvent.Kind) -> AgentEvent {
        AgentEvent(sessionID: "s1", agent: .claudeCode, sequence: seq, timestamp: t0, kind: kind)
    }

    private func command(_ id: String, _ command: String) -> PermissionRequest {
        PermissionRequest(id: id, toolName: "Bash", summary: "Run \(command)",
                          activity: "Running: \(command)", command: command, target: command,
                          createdAt: t0)
    }

    private func question(_ id: String, _ text: String, count: Int = 1) -> PermissionRequest {
        var request = PermissionRequest(id: id, toolName: "AskUserQuestion", summary: text, createdAt: t0)
        request.questions = (0..<count).map { index in
            QuestionPrompt(question: index == 0 ? text : "\(text) (\(index + 1))",
                           header: "Q\(index + 1)", options: [QuestionOption(label: "Yes")])
        }
        return request
    }

    /// A on the card, then B waiting behind it.
    private func twoGates(_ a: PermissionRequest, _ b: PermissionRequest) -> SessionState {
        var state = SessionState()
        state.apply(event(1, .permissionRequested(a)))
        state.apply(event(2, .permissionRequested(b)))
        return state
    }

    private func assertWaiting(on b: PermissionRequest, _ state: SessionState, _ context: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let session = state.sessions["s1"]
        XCTAssertEqual(session?.status, .needsAttention, context, file: file, line: line)
        XCTAssertEqual(session?.pendingPermission, b, "the waiting card stays current — \(context)",
                       file: file, line: line)
        XCTAssertEqual(session?.lastSummary, b.waitingLine ?? b.summary, context, file: file, line: line)
        XCTAssertEqual(state.attentionCount, 1, context, file: file, line: line)
    }

    // MARK: - The bug

    /// A, B, then A ends — in every way a gate can end: `.deferred` is a
    /// timeout, a dismissal or a hook that went away, and the other three are
    /// answers. B takes the card, and the session stays waiting.
    func testTheFirstGateEndingLeavesTheSecondWaiting() {
        let b = command("B", "npm run build")
        for decision in [PermissionDecision.deferred, .allowOnce, .deny, .alwaysAllow] {
            var state = twoGates(command("A", "npm test"), b)
            state.apply(event(3, .permissionResolved(requestID: "A", decision: decision)))
            assertWaiting(on: b, state, "A ended as \(decision)")
            XCTAssertNil(state.sessions["s1"]?.questionReceipt)
        }
    }

    func testQuestionsAndPermissionsBehaveAlike() {
        let pairs = [
            (question("A", "Which deploy target?"), command("B", "npm run build")),
            (command("A", "npm test"), question("B", "Which deploy target?", count: 2)),
            (question("A", "Which checks?", count: 3), question("B", "Ship it?")),
        ]
        for (a, b) in pairs {
            for decision in [PermissionDecision.deferred, .allowOnce] {
                var state = twoGates(a, b)
                state.apply(event(3, .permissionResolved(requestID: a.id, decision: decision)))
                assertWaiting(on: b, state, "\(a.toolName) then \(b.toolName), A \(decision)")
            }
        }
    }

    /// And B still ends itself, the way a single gate always has.
    func testTheSecondGateStillEndsWhenItIsAnswered() {
        var state = twoGates(command("A", "npm test"), command("B", "npm run build"))
        state.apply(event(3, .permissionResolved(requestID: "A", decision: .deferred)))
        state.apply(event(4, .permissionResolved(requestID: "B", decision: .allowOnce)))
        XCTAssertNil(state.sessions["s1"]?.pendingPermission)
        XCTAssertEqual(state.sessions["s1"]?.status, .running)
        XCTAssertEqual(state.sessions["s1"]?.lastSummary, "Running: npm run build")
        XCTAssertEqual(state.attentionCount, 0)
    }

    /// A resolution for a gate that was never on screen here is not news
    /// either — a late deferral must not wake an idle session to "running".
    func testAResolutionForAnotherGateChangesNothing() {
        var state = SessionState()
        state.apply(event(1, .promptSubmitted(prompt: "fix it")))
        state.apply(event(2, .turnEnded(assistantMessage: "Fixed.")))
        state.apply(event(3, .permissionResolved(requestID: "gone", decision: .deferred)))
        XCTAssertEqual(state.sessions["s1"]?.status, .idle)
    }

    // MARK: - Nothing else takes a waiting card's attention away

    /// A policy rule settling a parallel request reaches the reducer as
    /// activity. The cards it did not touch are still waiting — and the row
    /// goes on saying so, rather than reporting the other request's approval.
    func testActivityWhileACardIsUpLeavesItUp() {
        let a = command("A", "npm test")
        let b = command("B", "npm run build")
        var state = twoGates(a, b)
        state.apply(event(3, .activity(summary: "Auto-approved · Running: git status")))
        XCTAssertEqual(state.sessions["s1"]?.status, .needsAttention)
        XCTAssertEqual(state.sessions["s1"]?.pendingPermission, a)
        XCTAssertEqual(state.sessions["s1"]?.queuedPermissions, [b])
        XCTAssertEqual(state.sessions["s1"]?.lastSummary, "Run npm test · 1 more after this")
    }

    /// A turn ending while another part of the session waits on a card: the
    /// session is not idle.
    func testATurnEndingElsewhereDoesNotHideACard() {
        let a = command("A", "npm test")
        var state = twoGates(a, command("B", "npm run build"))
        state.apply(event(3, .turnEnded(assistantMessage: "The helper finished.")))
        XCTAssertEqual(state.sessions["s1"]?.status, .needsAttention)
        XCTAssertEqual(state.sessions["s1"]?.pendingPermission, a)
        XCTAssertEqual(state.sessions["s1"]?.turns, 1, "the turn is still counted")
    }

    /// Idle demotion only ever asks about running sessions — but a status change
    /// must not be able to demote a card either, whoever asks.
    func testAStatusChangeCannotDemoteACard() {
        var state = twoGates(command("A", "npm test"), command("B", "npm run build"))
        state.apply(event(3, .statusChanged(.idle)))
        XCTAssertEqual(state.sessions["s1"]?.status, .needsAttention)
        XCTAssertEqual(state.attentionCount, 1)
    }

    /// The ways a session legitimately stops waiting still work, and clear
    /// every gate: it ends, or it is restored after a restart, where no hook
    /// survived. Only the question on the card leaves a receipt — one waiting
    /// behind it was never shown.
    func testEndingOrRestoringStillClearsEveryGate() {
        var ended = twoGates(question("A", "Ship it?"), question("B", "Which target?"))
        ended.apply(event(3, .sessionEnded))
        XCTAssertEqual(ended.sessions["s1"]?.status, .done)
        XCTAssertNil(ended.sessions["s1"]?.pendingPermission)
        XCTAssertNil(ended.sessions["s1"]?.queuedPermissions)
        XCTAssertEqual(ended.sessions["s1"]?.questionReceipt?.question, "Ship it?")

        let restored = twoGates(command("A", "npm test"), command("B", "npm run build"))
            .preparedForRestore(now: t0.addingTimeInterval(5))
        XCTAssertNil(restored.sessions["s1"]?.pendingPermission)
        XCTAssertNil(restored.sessions["s1"]?.queuedPermissions)
        XCTAssertEqual(restored.sessions["s1"]?.status, .idle)
    }

    // MARK: - Every gate has its own id

    private func gateID(tool: String, _ input: [String: Any], at date: Date,
                        toolUseID: String? = nil) throws -> String {
        var root: [String: Any] = ["session_id": "s1", "hook_event_name": "PreToolUse",
                                   "tool_name": tool, "tool_input": input]
        if let toolUseID { root["tool_use_id"] = toolUseID }
        let events = try ClaudeStyleHookDecoder.decode(
            payload: JSONSerialization.data(withJSONObject: root),
            context: HookContext(source: "claude-code", cwd: nil, terminal: nil, receivedAt: date),
            agent: .claudeCode, gatesPermissions: true)
        guard case let .permissionRequested(request)? = events.last?.kind else {
            throw XCTSkip("expected a gate, got \(events)")
        }
        return request.id
    }

    /// Parallel calls to one tool can reach the hook in the same millisecond.
    /// The id was "<tool>-<ms>", so they came out identical — and every guard
    /// that keeps one gate's answer off another compares ids.
    func testTwoCallsInOneMillisecondStillGetTwoIDs() throws {
        let at = Date(timeIntervalSince1970: 1_785_160_000.123)
        let first = try gateID(tool: "Read", ["file_path": "/x/a.swift"], at: at)
        let second = try gateID(tool: "Read", ["file_path": "/x/b.swift"], at: at)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(try gateID(tool: "Read", ["file_path": "/x/a.swift"], at: at), first,
                          "not even the same call twice")
    }

    /// The agent's own id for the call is the natural one, when it sends it.
    func testTheAgentsOwnCallIDIsUsed() throws {
        let at = Date(timeIntervalSince1970: 1_785_160_000.123)
        let id = try gateID(tool: "Bash", ["command": "ls"], at: at, toolUseID: "toolu_01XQ4ibg1CH1zoHBVxnMG4t5")
        XCTAssertTrue(id.hasSuffix("toolu_01XQ4ibg1CH1zoHBVxnMG4t5"), id)
        XCTAssertEqual(try gateID(tool: "Bash", ["command": "ls"], at: at, toolUseID: "toolu_01XQ4ibg1CH1zoHBVxnMG4t5"),
                       id, "and it is stable for the same call")
    }
}

/// The same two gates over a real socket: the bridge, its hooks, and the events
/// they produce replayed through the reducer the app uses.
final class BackToBackBridgeTests: XCTestCase {
    /// End to end: B queues behind A. Neither hook is handed back for the
    /// other's sake; the session is waiting on both; and each answer reaches
    /// only the hook it was given for.
    func testASecondRequestQueuesBehindTheFirst() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let aHook = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"npm test"}"#), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let bHook = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"npm run build"}"#), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 2 }

        let requests = await recorder.requests()
        let waiting = GateSocket.replay(await recorder.all)
        XCTAssertEqual(waiting.sessions["q"]?.status, .needsAttention)
        XCTAssertEqual(waiting.sessions["q"]?.pendingPermission?.id, requests[0].id, "the older one has the card")
        XCTAssertEqual(waiting.sessions["q"]?.queuedPermissions?.map(\.id), [requests[1].id])
        let resolvedEarly = await recorder.resolutions()
        XCTAssertEqual(resolvedEarly, [], "nothing was handed back for arriving second")

        await rig.bridge.resolve(sessionID: "q", requestID: requests[0].id, decision: .allowOnce)
        let aReply = await aHook.value
        XCTAssertEqual(aReply?.action, .allow)

        await rig.bridge.resolve(sessionID: "q", requestID: requests[1].id, decision: .deny)
        let bReply = await bHook.value
        XCTAssertEqual(bReply?.action, .deny)

        await rig.bridge.stop()
        drain.cancel()
    }

    /// Same tool, same millisecond — the case where two ids used to be one. Each
    /// answer reaches its own hook, and one for a gate that has already ended
    /// reaches nobody.
    func testEachAnswerReachesOnlyItsOwnHook() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let sameMoment = Date().addingTimeInterval(-1)
        let aHook = GateSocket.hook(GateSocket.payload(
            tool: "AskUserQuestion",
            input: #"{"questions":[{"question":"Which target?","options":[{"label":"Prod"},{"label":"Staging"}]}]}"#,
            at: sameMoment), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let bHook = GateSocket.hook(GateSocket.payload(
            tool: "AskUserQuestion",
            input: #"{"questions":[{"question":"Ship it?","options":[{"label":"Yes"},{"label":"No"}]}]}"#,
            at: sameMoment), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 2 }
        let seen = await recorder.requests()
        let (a, b) = (seen[0], seen[1])
        XCTAssertNotEqual(a.id, b.id)

        await rig.bridge.answer(sessionID: "q", requestID: a.id, choice: "Prod")
        let aReply = await aHook.value
        XCTAssertEqual(aReply?.reason, "The user answered from Airlock: Prod")

        // Late answers for A, every way one could arrive.
        await rig.bridge.answer(sessionID: "q", requestID: a.id, choice: "Staging")
        await rig.bridge.resolve(sessionID: "q", requestID: a.id, decision: .allowOnce)
        await rig.bridge.resolve(sessionID: "q", requestID: a.id, decision: .deferred)

        await rig.bridge.answer(sessionID: "q", requestID: b.id, choice: "No")
        let bReply = await bHook.value
        XCTAssertEqual(bReply?.action, .deny)
        XCTAssertEqual(bReply?.reason, "The user answered from Airlock: No",
                       "B heard its own answer, and nothing meant for A")

        await rig.bridge.stop()
        drain.cancel()
    }

    /// `ask_timeout` runs from when a gate is SHOWN. A times out on its own
    /// clock; B's starts only when it takes the card — so B is still waiting at
    /// the moment an arrival clock would have ended it, and ends a full timeout
    /// after it was shown.
    ///
    /// Timed on the bridge's clock: it stamps each hand-back as the gate ends,
    /// and A's is the moment B took the card. B used to be timed from a `Date()`
    /// the test read after a poll and a sleep. On a busy Mac that read ran
    /// 0.1–0.17s late, the whole margin, so the test failed straight after a
    /// build and passed alone. B is also sent as soon as A is on the card, not
    /// 0.6s into its second, so the two clocks would end it about a second
    /// apart instead of 0.4s.
    func testAQueuedGatesClockStartsWhenItIsShown() async throws {
        let rig = try GateSocket.rig(policyYAML: "ask_timeout: 1")
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let aHook = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"npm test"}"#), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let bHook = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"npm run build"}"#), path: rig.path)

        let aReply = await aHook.value
        XCTAssertEqual(aReply?.action, .deferToAgent, "A ends on its own clock")
        let bReply = await bHook.value
        XCTAssertEqual(bReply?.action, .deferToAgent, "B ends on its own clock")

        await GateSocket.waitFor { await recorder.resolutions().count == 2 }
        let resolutions = await recorder.resolutions()
        let requests = await recorder.requests()
        XCTAssertEqual(resolutions, requests.map(\.id), "each once, each on its own clock")
        guard requests.count == 2 else { return XCTFail("two gates, not \(requests.count)") }
        let (a, b) = (requests[0], requests[1])
        let events = await recorder.all
        func handBack(_ gate: PermissionRequest) throws -> Int {
            try XCTUnwrap(events.firstIndex { $0.kind == .permissionResolved(requestID: gate.id, decision: .deferred) },
                          "\(gate.summary) is handed back on its clock")
        }
        let aEnd = try handBack(a), bEnd = try handBack(b)

        // Until A's hand-back B waited behind it, so a clock started on arrival
        // was already running. From then until its own, B had the card,
        // waiting, with nothing behind it.
        let queued = GateSocket.replay(Array(events[..<aEnd]))
        XCTAssertEqual(queued.sessions["q"]?.queuedPermissions?.map(\.id), [b.id], "B waits behind A")
        let shown = GateSocket.replay(Array(events[..<bEnd]))
        XCTAssertEqual(shown.sessions["q"]?.pendingPermission?.id, b.id)
        XCTAssertEqual(shown.sessions["q"]?.status, .needsAttention, "B is on the card, waiting")
        XCTAssertNil(shown.sessions["q"]?.queuedPermissions)

        // A full second each, A from when it was asked and B from A's hand-back,
        // where a clock started on arrival would have left B next to nothing.
        // Checked against 0.9 because B's clock starts a moment before A's
        // hand-back is stamped, so B's second can measure a hair short.
        let aEnded = events[aEnd].timestamp, bEnded = events[bEnd].timestamp
        XCTAssertGreaterThanOrEqual(aEnded.timeIntervalSince(a.createdAt), 0.9, "A is held a full ask_timeout")
        XCTAssertGreaterThanOrEqual(bEnded.timeIntervalSince(aEnded), 0.9,
                                    "a full ask_timeout after it was shown, not after it arrived")

        let settled = GateSocket.replay(events)
        XCTAssertEqual(settled.attentionCount, 0)

        await rig.bridge.stop()
        drain.cancel()
    }

    /// A rule settling a parallel request answers it at once and never queues
    /// it, and never touches the card that is waiting.
    func testARuleSettlingAnotherRequestNeverQueuesIt() async throws {
        let rig = try GateSocket.rig(policyYAML: "allow:\n  - Bash(git status)")
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let bHook = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"npm run build"}"#), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let ruled = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"git status"}"#), path: rig.path)
        let ruledReply = await ruled.value
        XCTAssertEqual(ruledReply?.action, .allow)

        let state = GateSocket.replay(await recorder.all)
        XCTAssertEqual(state.sessions["q"]?.status, .needsAttention)
        XCTAssertNil(state.sessions["q"]?.queuedPermissions, "settled on arrival, so never queued")
        let waiting = try XCTUnwrap(state.sessions["q"]?.pendingPermission)
        XCTAssertEqual(waiting.command, "npm run build")

        await rig.bridge.resolve(sessionID: "q", requestID: waiting.id, decision: .deny)
        let bReply = await bHook.value
        XCTAssertEqual(bReply?.action, .deny)

        await rig.bridge.stop()
        drain.cancel()
    }

    /// A queued gate's hook going away takes that gate off the queue — and only
    /// it. The card stays, still waiting for its own answer.
    func testAQueuedHookGoingAwayEndsOnlyItsOwnGate() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let aHook = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"npm test"}"#), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        await GateSocket.dyingHook(GateSocket.payload(tool: "Bash", input: #"{"command":"npm run build"}"#), path: rig.path)
        await GateSocket.waitFor { await recorder.resolutions().count == 1 }

        let requests = await recorder.requests()
        let resolved = await recorder.resolutions()
        XCTAssertEqual(resolved, [requests[1].id], "only the gate whose hook went away")
        let state = GateSocket.replay(await recorder.all)
        XCTAssertEqual(state.sessions["q"]?.pendingPermission?.id, requests[0].id)
        XCTAssertNil(state.sessions["q"]?.queuedPermissions)
        XCTAssertEqual(state.attentionCount, 1)

        await rig.bridge.resolve(sessionID: "q", requestID: requests[0].id, decision: .allowOnce)
        let aReply = await aHook.value
        XCTAssertEqual(aReply?.action, .allow, "and A still gets its own answer")

        await rig.bridge.stop()
        drain.cancel()
    }
}
