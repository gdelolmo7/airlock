import AirlockTestSupport
import XCTest
@testable import AirlockCore

/// Several gates in one session: they queue, oldest first, one card at a time,
/// and each ends by its own exit.
final class GateQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func event(_ seq: UInt64, _ kind: AgentEvent.Kind) -> AgentEvent {
        AgentEvent(sessionID: "s1", agent: .claudeCode, sequence: seq, timestamp: t0, kind: kind)
    }

    private func command(_ id: String, _ command: String) -> PermissionRequest {
        PermissionRequest(id: id, toolName: "Bash", summary: "Run \(command)",
                          activity: "Running: \(command)", command: command, target: command,
                          createdAt: t0)
    }

    private func question(_ id: String, _ text: String, parts: Int = 1) -> PermissionRequest {
        var request = PermissionRequest(id: id, toolName: "AskUserQuestion", summary: text, createdAt: t0)
        request.questions = (0..<parts).map { index in
            QuestionPrompt(question: index == 0 ? text : "\(text) (\(index + 1))",
                           header: "Q\(index + 1)", options: [QuestionOption(label: "Yes")])
        }
        return request
    }

    private var a: PermissionRequest { command("A", "npm test") }
    private var b: PermissionRequest { command("B", "npm run lint") }
    private var c: PermissionRequest { command("C", "npm run build") }

    /// A, B and C, requested in that order.
    private func threeWaiting() -> SessionState {
        var state = SessionState()
        state.apply(event(1, .permissionRequested(a)))
        state.apply(event(2, .permissionRequested(b)))
        state.apply(event(3, .permissionRequested(c)))
        return state
    }

    private func session(_ state: SessionState) throws -> AgentSession {
        try XCTUnwrap(state.sessions["s1"])
    }

    // MARK: - Arrival and order

    /// The oldest has the card; the rest wait behind it, in the order they came.
    func testGatesQueueInArrivalOrder() throws {
        let s = try session(threeWaiting())
        XCTAssertEqual(s.pendingPermission, a)
        XCTAssertEqual(s.queuedPermissions, [b, c])
        XCTAssertEqual(s.waitingPermissions, [a, b, c])
        XCTAssertEqual(s.queueCounter, "3 waiting")
        XCTAssertEqual(s.lastSummary, "Run npm test · 2 more after this")
        XCTAssertEqual(s.status, .needsAttention)
    }

    /// A lone card has nothing to count, and says only what it always said.
    func testALoneCardHasNoCounter() throws {
        var state = SessionState()
        state.apply(event(1, .permissionRequested(question("Q", "Ship it?", parts: 2))))
        let s = try session(state)
        XCTAssertNil(s.queueCounter)
        XCTAssertEqual(s.lastSummary, "Waiting for your answer · 2 questions")
    }

    // MARK: - Advancing

    /// Each answer hands the card to the next oldest, and the count follows
    /// what is left: 3 waiting, 2 waiting, then nothing to count.
    func testEachAnswerAdvancesTheQueue() throws {
        var state = threeWaiting()

        state.apply(event(4, .permissionResolved(requestID: "A", decision: .allowOnce)))
        var s = try session(state)
        XCTAssertEqual(s.pendingPermission, b)
        XCTAssertEqual(s.queuedPermissions, [c])
        XCTAssertEqual(s.queueCounter, "2 waiting")
        XCTAssertEqual(s.lastSummary, "Run npm run lint · 1 more after this")
        XCTAssertEqual(s.status, .needsAttention)

        state.apply(event(5, .permissionResolved(requestID: "B", decision: .deny)))
        s = try session(state)
        XCTAssertEqual(s.pendingPermission, c)
        XCTAssertNil(s.queuedPermissions)
        XCTAssertNil(s.queueCounter, "one left is nothing to count")
        XCTAssertEqual(s.lastSummary, "Run npm run build")
        XCTAssertEqual(state.attentionCount, 1)

        state.apply(event(6, .permissionResolved(requestID: "C", decision: .allowOnce)))
        s = try session(state)
        XCTAssertNil(s.pendingPermission)
        XCTAssertNil(s.queueCounter)
        XCTAssertEqual(s.status, .running)
        XCTAssertEqual(s.lastSummary, "Running: npm run build")
        XCTAssertEqual(state.attentionCount, 0)
    }

    /// A request that arrives mid-run joins the end of it.
    func testALateArrivalJoinsTheRun() throws {
        var state = SessionState()
        state.apply(event(1, .permissionRequested(a)))
        state.apply(event(2, .permissionRequested(b)))
        state.apply(event(3, .permissionResolved(requestID: "A", decision: .allowOnce)))
        XCTAssertNil(try session(state).queueCounter, "one left")
        state.apply(event(4, .permissionRequested(c)))
        XCTAssertEqual(try session(state).queueCounter, "2 waiting", "and the late arrival joins it")
        XCTAssertEqual(try session(state).pendingPermission, b, "the card does not change for it")
    }

    // MARK: - Every exit is per gate

    /// A gate waiting behind the card ends by itself — its own timeout, its
    /// hook gone (both `.deferred`), or a rule "Always" wrote (`.allowOnce`) —
    /// and the card, and everything else, is untouched.
    func testAQueuedGateEndsByItselfAndNothingElseMoves() throws {
        for decision in [PermissionDecision.deferred, .allowOnce] {
            var state = threeWaiting()
            state.apply(event(4, .permissionResolved(requestID: "B", decision: decision)))
            let s = try session(state)
            XCTAssertEqual(s.pendingPermission, a, "\(decision)")
            XCTAssertEqual(s.queuedPermissions, [c], "\(decision)")
            XCTAssertEqual(s.queueCounter, "2 waiting", "\(decision)")
            XCTAssertNil(s.questionReceipt, "never shown, so nothing to account for")
            XCTAssertEqual(s.status, .needsAttention)
        }
    }

    /// The card's own exits — answered, denied, dismissed, timed out — each
    /// hand it on.
    func testTheCardEndingInAnyWayHandsItOn() throws {
        for decision in [PermissionDecision.allowOnce, .deny, .alwaysAllow, .deferred] {
            var state = threeWaiting()
            state.apply(event(4, .permissionResolved(requestID: "A", decision: decision)))
            let s = try session(state)
            XCTAssertEqual(s.pendingPermission, b, "\(decision)")
            XCTAssertEqual(s.queuedPermissions, [c], "\(decision)")
            XCTAssertEqual(state.attentionCount, 1, "\(decision)")
        }
    }

    /// Nothing named that is not waiting here ends anything.
    func testAResolutionForNoWaitingGateChangesNothing() throws {
        var state = threeWaiting()
        let before = try session(state)
        state.apply(event(4, .permissionResolved(requestID: "Z", decision: .allowOnce)))
        let after = try session(state)
        XCTAssertEqual(after.waitingPermissions, before.waitingPermissions)
        XCTAssertEqual(after.queueCounter, before.queueCounter)
    }

    /// A question dismissed from the card leaves its receipt; the next card
    /// covers it, and it is there once nothing is waiting. A new request still
    /// outranks it.
    func testADismissedQuestionsReceiptWaitsForTheQueue() throws {
        var state = SessionState()
        state.apply(event(1, .permissionRequested(question("Q", "Which target?"))))
        state.apply(event(2, .permissionRequested(b)))
        state.apply(event(3, .permissionResolved(requestID: "Q", decision: .deferred)))
        XCTAssertEqual(try session(state).pendingPermission, b)
        XCTAssertEqual(try session(state).questionReceipt?.question, "Which target?")

        state.apply(event(4, .permissionResolved(requestID: "B", decision: .allowOnce)))
        XCTAssertNil(try session(state).pendingPermission)
        XCTAssertEqual(try session(state).questionReceipt?.question, "Which target?",
                       "shown once the queue is done")

        state.apply(event(5, .permissionRequested(c)))
        XCTAssertNil(try session(state).questionReceipt, "a live ask outranks the record of a dead one")
    }

    /// A receipt names the question that was on screen, not the first of them.
    ///
    /// An ask can carry four, and the card walks them one at a time — so
    /// dismissing on question three left an account of question one, which
    /// reads as an answer given to something else.
    func testADismissedAskNamesTheQuestionItWasOn() throws {
        var state = SessionState()
        state.apply(event(1, .permissionRequested(question("Q", "Which target?", parts: 3))))

        var dismissed = event(2, .permissionResolved(requestID: "Q", decision: .deferred))
        dismissed.questionStep = 2
        state.apply(dismissed)
        XCTAssertEqual(try session(state).questionReceipt?.question, "Which target? (3)")
        XCTAssertEqual(try session(state).questionReceipt?.header, "Q3")

        // No step, or one past the end: the question the card opened on.
        for step in [nil, 9] as [Int?] {
            var state = SessionState()
            state.apply(event(1, .permissionRequested(question("Q", "Which target?", parts: 3))))
            var end = event(2, .permissionResolved(requestID: "Q", decision: .deferred))
            end.questionStep = step
            state.apply(end)
            XCTAssertEqual(try session(state).questionReceipt?.question, "Which target?",
                           "\(String(describing: step))")
        }
    }

    /// The same for an agent that went away mid-ask.
    func testAnAgentLeavingNamesTheQuestionOnScreen() throws {
        var state = SessionState()
        state.apply(event(1, .permissionRequested(question("Q", "Which target?", parts: 3))))
        var ended = event(2, .sessionEnded)
        ended.questionStep = 1
        state.apply(ended)
        XCTAssertEqual(try session(state).questionReceipt?.question, "Which target? (2)")
        XCTAssertEqual(try session(state).questionReceipt?.reason, .agentExited)
    }

    // MARK: - The session waits while any gate does

    /// Nothing but the last gate's end takes the session out of "Needs you":
    /// not a subagent finishing, not a status nudge, not other activity.
    func testTheSessionWaitsWhileAnyGateDoes() throws {
        var state = threeWaiting()
        state.apply(event(4, .turnEnded(assistantMessage: "A helper finished.")))
        state.apply(event(5, .statusChanged(.idle)))
        state.apply(event(6, .activity(summary: "Read notes.md")))
        let s = try session(state)
        XCTAssertEqual(s.status, .needsAttention)
        XCTAssertEqual(s.lastSummary, "Run npm test · 2 more after this",
                       "the line says what the session is waiting for")
        XCTAssertEqual(state.attentionCount, 1)
    }

    // MARK: - Order cannot lose a gate

    /// Parallel hooks reach the bridge out of the order their clocks say, and
    /// an answer given in the app is stamped on this side. A gate's request or
    /// end carried an older sequence and was dropped as stale: a hook waiting
    /// behind no card, or a card for a hook already answered. Gate events name
    /// their gate, so they are applied whenever they arrive.
    func testGateEventsAreNeverDroppedAsStale() throws {
        var state = SessionState()
        state.apply(event(100, .permissionRequested(a)))
        state.apply(event(200, .activity(summary: "Read notes.md")))
        state.apply(event(150, .permissionRequested(b)))
        XCTAssertEqual(try session(state).queuedPermissions, [b], "a late request still queues")

        state.apply(event(120, .permissionResolved(requestID: "A", decision: .allowOnce)))
        XCTAssertEqual(try session(state).pendingPermission, b, "a late end still ends")
        XCTAssertEqual(try session(state).lastSequence, 200, "and neither winds the sequence back")

        // Everything else keeps the rule.
        state.apply(event(50, .titleChanged(title: "stale")))
        XCTAssertNil(try session(state).title)
    }

    // MARK: - Ending, restoring, decoding

    func testEndingOrRestoringClearsTheWholeQueue() throws {
        var ended = threeWaiting()
        ended.apply(event(4, .sessionEnded))
        XCTAssertTrue(try session(ended).waitingPermissions.isEmpty)
        XCTAssertEqual(try session(ended).status, .done)

        let restored = threeWaiting().preparedForRestore(now: t0.addingTimeInterval(5))
        XCTAssertTrue(try XCTUnwrap(restored.sessions["s1"]).waitingPermissions.isEmpty)
        XCTAssertEqual(restored.sessions["s1"]?.status, .idle)
    }

    /// Sessions are cached. One written before gates could queue has neither
    /// field and must still load; one written now round-trips.
    func testCachedSessionsStillDecode() throws {
        let queued = try session(threeWaiting())
        let data = try JSONEncoder().encode(queued)
        XCTAssertEqual(try JSONDecoder().decode(AgentSession.self, from: data), queued)

        var legacy = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "queuedPermissions")
        let old = try JSONDecoder().decode(AgentSession.self,
                                           from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.pendingPermission, a)
        XCTAssertNil(old.queuedPermissions)
    }

    /// A queue with nothing on the card could never be answered or end. The
    /// oldest takes the card on the next event, whatever it is.
    func testAQueueWithoutACardHealsItself() throws {
        var state = SessionState(sessions: ["s1": AgentSession(
            id: "s1", agent: .claudeCode, projectName: "app", status: .running,
            lastActivity: t0, lastSequence: 1, queuedPermissions: [b, c])])
        state.apply(event(2, .activity(summary: "Read notes.md")))
        let s = try session(state)
        XCTAssertEqual(s.pendingPermission, b)
        XCTAssertEqual(s.queuedPermissions, [c])
        XCTAssertEqual(s.status, .needsAttention)
    }
}

/// The queue over a real socket: concurrent hooks, each getting exactly its own
/// answer, and "Always" settling what its rule covers.
final class GateQueueBridgeTests: XCTestCase {
    /// Three hooks at once — a command, a question and a connector tool — each
    /// answered differently, in the order the app shows them. Every hook hears
    /// its own answer and nothing else.
    func testThreeConcurrentHooksEachGetTheirOwnAnswer() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let bash = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"npm test"}"#), path: rig.path)
        let ask = GateSocket.hook(GateSocket.payload(
            tool: "AskUserQuestion",
            input: #"{"questions":[{"question":"Which target?","options":[{"label":"Prod"},{"label":"Staging"}]}]}"#),
            path: rig.path)
        let trello = GateSocket.hook(GateSocket.payload(
            tool: "mcp__7adb9f71-433e-414a-a8a1-f17b52e5037f__trelloWriteCard", input: #"{"name":"Launch"}"#),
            path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 3 }

        // Answer the card, as the app would, until nothing is waiting.
        var answered: [String] = []
        for _ in 0..<3 {
            let state = GateSocket.replay(await recorder.all)
            XCTAssertEqual(state.sessions["q"]?.status, .needsAttention)
            let card = try XCTUnwrap(state.sessions["q"]?.pendingPermission)
            switch card.toolName {
            case "Bash":
                await rig.bridge.resolve(sessionID: "q", requestID: card.id, decision: .allowOnce)
            case "AskUserQuestion":
                await rig.bridge.answer(sessionID: "q", requestID: card.id, choice: "Staging")
            default:
                await rig.bridge.resolve(sessionID: "q", requestID: card.id, decision: .deny)
            }
            answered.append(card.id)
            // The app applies its own answer locally; do the same here.
            await recorder.append(AgentEvent(sessionID: "q", agent: .claudeCode, sequence: 0, timestamp: Date(),
                                             kind: .permissionResolved(requestID: card.id, decision: .allowOnce)))
        }
        let ids = await recorder.requests().map(\.id)
        XCTAssertEqual(answered, ids, "one card at a time, oldest first")

        let bashReply = await bash.value
        let askReply = await ask.value
        let trelloReply = await trello.value
        XCTAssertEqual(bashReply?.action, .allow)
        XCTAssertEqual(askReply?.action, .deny)
        XCTAssertEqual(askReply?.reason, "The user answered from Airlock: Staging")
        XCTAssertEqual(trelloReply?.action, .deny)
        XCTAssertEqual(trelloReply?.reason, "Denied from Airlock")
        let resolutions = await recorder.resolutions()
        XCTAssertEqual(resolutions.count, 3, "no gate was handed back by the bridge")

        await rig.bridge.stop()
        drain.cancel()
    }

    /// Ended out of order — the middle one first, as its own timeout or its
    /// hook going away would — the others do not move.
    func testTheMiddleGateEndingLeavesTheOthersWaiting() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let first = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"echo 1"}"#), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let second = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"echo 2"}"#), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 2 }
        let third = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"echo 3"}"#), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 3 }
        let ids = await recorder.requests().map(\.id)

        await rig.bridge.resolve(sessionID: "q", requestID: ids[1], decision: .deny)
        let secondReply = await second.value
        XCTAssertEqual(secondReply?.action, .deny)

        await rig.bridge.resolve(sessionID: "q", requestID: ids[2], decision: .allowOnce)
        await rig.bridge.resolve(sessionID: "q", requestID: ids[0], decision: .deny)
        let firstReply = await first.value
        let thirdReply = await third.value
        XCTAssertEqual(firstReply?.action, .deny)
        XCTAssertEqual(thirdReply?.action, .allow)

        await rig.bridge.stop()
        drain.cancel()
    }

    /// Two hooks whose clocks disagree with the order they reached the bridge:
    /// the second-arrived one carries the OLDER time. Both are shown; neither
    /// is dropped as stale.
    func testArrivalOutOfClockOrderLosesNothing() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let now = Date()
        let aHook = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"npm test"}"#, at: now),
                                    path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let bHook = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"npm run lint"}"#,
                                                       at: now.addingTimeInterval(-5)), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 2 }

        let state = GateSocket.replay(await recorder.all)
        XCTAssertEqual(state.sessions["q"]?.waitingPermissions.map(\.command), ["npm test", "npm run lint"])

        let ids = await recorder.requests().map(\.id)
        await rig.bridge.resolve(sessionID: "q", requestID: ids[0], decision: .allowOnce)
        await rig.bridge.resolve(sessionID: "q", requestID: ids[1], decision: .allowOnce)
        let aReply = await aHook.value
        let bReply = await bHook.value
        XCTAssertEqual(aReply?.action, .allow)
        XCTAssertEqual(bReply?.action, .allow)

        await rig.bridge.stop()
        drain.cancel()
    }

    /// "Always" on the card writes a rule; every other gate waiting in the
    /// session that the rule allows is settled as if it had just arrived under
    /// it. One the risk floor holds, and one a deny rule matches, stay queued —
    /// "Always" is a yes, and never becomes a no.
    func testAlwaysSettlesTheQueuedGatesItsRuleCovers() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)
        let decided = DecisionLog()
        await rig.bridge.setAutoDecisionHandler { record in Task { await decided.append(record) } }
        let cwd = rig.project.path

        func held(_ command: String) async -> Task<HookDirective?, Never> {
            let count = await recorder.requests().count
            let hook = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"\#(command)"}"#,
                                                          cwd: cwd), path: rig.path)
            await GateSocket.waitFor { await recorder.requests().count == count + 1 }
            return hook
        }
        let test = await held("npm test")
        let lint = await held("npm run lint")
        let deploy = await held("npm run deploy:prod")          // the risk floor
        let publish = await held("npm publish")
        let ids = await recorder.requests().map(\.id)

        // A deny rule written while `npm publish` was already waiting — the
        // one way a queued gate can match one.
        let store = PolicyStore(globalFileURL: rig.globalPolicy)
        try store.add("Bash(npm publish*)", kind: .deny, projectRoot: cwd)

        // What the app does on "Always": write the rule the card showed, THEN
        // tell the bridge.
        let requested = await recorder.requests()
        let card = try XCTUnwrap(requested.first)
        let rule = RuleGeneralizer.recommended(for: card).text
        XCTAssertEqual(rule, "Bash(npm *)")
        try store.appendAllowRule(rule, projectRoot: cwd)
        await rig.bridge.resolve(sessionID: "q", requestID: ids[0], decision: .alwaysAllow)

        let testReply = await test.value
        let lintReply = await lint.value
        XCTAssertEqual(testReply?.action, .allow)
        XCTAssertEqual(lintReply?.action, .allow)
        XCTAssertEqual(lintReply?.reason, "Approved by Airlock policy rule Bash(npm *)", "settled as if it had just arrived")
        await GateSocket.waitFor { await decided.records.count == 1 }
        let records = await decided.records
        XCTAssertEqual(records.map(\.outcome), [.autoAllowed])
        XCTAssertEqual(records.first?.subject, "npm run lint")

        // The app's own answer for the card, then everything the bridge said.
        var state = GateSocket.replay(await recorder.all)
        state.apply(AgentEvent(sessionID: "q", agent: .claudeCode, sequence: 0, timestamp: Date(),
                               kind: .permissionResolved(requestID: ids[0], decision: .alwaysAllow)))
        XCTAssertEqual(state.sessions["q"]?.waitingPermissions.map(\.command),
                       ["npm run deploy:prod", "npm publish"], "the floor and the deny rule still win")
        XCTAssertEqual(state.sessions["q"]?.status, .needsAttention)

        await rig.bridge.resolve(sessionID: "q", requestID: ids[2], decision: .deny)
        await rig.bridge.resolve(sessionID: "q", requestID: ids[3], decision: .deny)
        let deployReply = await deploy.value
        let publishReply = await publish.value
        XCTAssertEqual(deployReply?.action, .deny)
        XCTAssertEqual(publishReply?.action, .deny)

        await rig.bridge.stop()
        drain.cancel()
    }

    /// No gate outlives its hook: with `ask_timeout: 0` — hold until answered —
    /// and a queue, each gate is still handed back before the hook's own limit.
    /// (The real limit is a day; this bridge is given under one second.)
    func testNoGateOutlivesItsHook() async throws {
        XCTAssertEqual(BridgeServer.longestHold, HookDirective.blockingWait - 60)
        XCTAssertLessThan(BridgeServer.longestHold, HookDirective.blockingWait)

        let rig = try GateSocket.rig(policyYAML: "ask_timeout: 0", holdLimit: 0.8)
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let started = Date()
        let first = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"npm test"}"#), path: rig.path)
        let second = GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"npm run lint"}"#), path: rig.path)
        let firstReply = await first.value
        let secondReply = await second.value
        XCTAssertEqual(firstReply?.action, .deferToAgent)
        XCTAssertEqual(secondReply?.action, .deferToAgent, "a queued gate is held no longer either")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.7)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)

        await GateSocket.waitFor { await recorder.resolutions().count == 2 }
        let settled = GateSocket.replay(await recorder.all)
        XCTAssertEqual(settled.attentionCount, 0, "and nothing is left on the card")

        await rig.bridge.stop()
        drain.cancel()
    }

    /// The limit is measured against what the installer tells the agent: the
    /// hook's own timeout is `HookDirective.blockingWait`.
    func testTheInstallerGivesTheHookTheWaitTheBridgeHoldsAgainst() throws {
        let scratch = TestScratch("an-inst")
        let settings = scratch.file("settings.json")
        try ClaudeHookInstaller(configURL: settings).install(hookBinaryPath: "/x/airlock-hook")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap((hooks["PreToolUse"] as? [[String: Any]])?.first)
        let command = try XCTUnwrap((preToolUse["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(command["timeout"] as? Int, Int(HookDirective.blockingWait))
    }
}

/// Gate records the bridge hands out, collected across its callback.
private actor DecisionLog {
    private(set) var records: [GateRecord] = []
    func append(_ record: GateRecord) { records.append(record) }
}
