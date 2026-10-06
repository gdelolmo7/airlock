import XCTest
@testable import AirlockCore

/// Gates whose card the UI has stopped showing — see
/// `BridgeServer.releaseSession`.
///
/// Three things take a card and its queue off screen without anybody answering
/// them: the session ending, a sibling in the same terminal superseding it, and
/// the user clearing the list. The hooks used to go on waiting for
/// `ask_timeout` — and the policy here is the one Settings offers as
/// "never — it waits", where that wait is the hook's own 24-hour limit.
final class GateReleaseTests: XCTestCase {
    private func rig() throws -> GateSocket.Rig {
        try GateSocket.rig(policyYAML: "ask_timeout: 0")
    }

    private func gate(_ session: String, _ command: String, in rig: GateSocket.Rig,
                      at: Date = Date()) -> Task<HookDirective?, Never> {
        GateSocket.hook(GateSocket.payload(session: session, tool: "Bash",
                                           input: #"{"command":"\#(command)"}"#, at: at),
                        path: rig.path)
    }

    /// The agent is gone; what it was blocked on goes back to it now.
    func testASessionEndingHandsBackEverythingItWasHolding() async throws {
        let rig = try rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let first = gate("s", "npm test", in: rig)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let second = gate("s", "npm run lint", in: rig, at: Date().addingTimeInterval(1))
        await GateSocket.waitFor { await recorder.requests().count == 2 }

        // Later than both gates: the decoder stamps its sequence from the
        // hook's own clock, and the reducer drops anything behind what it has
        // already seen. (The release below does not depend on that — the
        // bridge acts on the payload, not on what the reducer made of it.)
        await GateSocket.dyingHook(
            GateSocket.payload(session: "s", tool: "Bash", input: "{}",
                               at: Date().addingTimeInterval(2), event: "SessionEnd"),
            path: rig.path)

        let firstReply = await first.value
        let secondReply = await second.value
        XCTAssertEqual(firstReply?.action, .deferToAgent, "the card's gate")
        XCTAssertEqual(secondReply?.action, .deferToAgent, "and the one queued behind it")

        // The UI is told, so nothing is left pending in a session that ended.
        await GateSocket.waitFor { await recorder.resolutions().count == 2 }
        let state = GateSocket.replay(await recorder.all)
        XCTAssertNil(state.sessions["s"]?.pendingPermission)
        XCTAssertEqual(state.sessions["s"]?.status, .done)

        await rig.bridge.stop()
        drain.cancel()
    }

    /// What supersede and "clear all" call. One session's gates go; every
    /// other session is untouched.
    func testReleasingOneSessionLeavesTheOthersWaiting() async throws {
        let rig = try rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let mine = gate("gone", "npm test", in: rig)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let theirs = gate("staying", "npm run lint", in: rig, at: Date().addingTimeInterval(1))
        await GateSocket.waitFor { await recorder.requests().count == 2 }

        await rig.bridge.releaseSession("gone")

        let mineReply = await mine.value
        XCTAssertEqual(mineReply?.action, .deferToAgent)
        XCTAssertFalse(theirs.isCancelled)
        // The hook hears back before the event reaches the recorder.
        await GateSocket.waitFor { await recorder.resolutions().count == 1 }
        let resolutions = await recorder.resolutions()
        XCTAssertEqual(resolutions.count, 1, "only the released session's gate ended")

        // The other one still answers to its own card.
        let requests = await recorder.requests()
        let staying = try XCTUnwrap(requests.last)
        await rig.bridge.resolve(sessionID: "staying", requestID: staying.id, decision: .allowOnce)
        let theirsReply = await theirs.value
        XCTAssertEqual(theirsReply?.action, .allow)

        await rig.bridge.stop()
        drain.cancel()
    }

    /// Releasing a session that holds nothing is a no-op, and releasing twice
    /// does not answer anything twice — it runs from the UI, which can ask more
    /// than once.
    func testReleasingNothingIsHarmless() async throws {
        let rig = try rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        await rig.bridge.releaseSession("never-existed")
        let hook = gate("s", "npm test", in: rig)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        await rig.bridge.releaseSession("s")
        await rig.bridge.releaseSession("s")

        let reply = await hook.value
        XCTAssertEqual(reply?.action, .deferToAgent)
        await GateSocket.waitFor { await recorder.resolutions().count == 1 }
        let resolutions = await recorder.resolutions()
        XCTAssertEqual(resolutions.count, 1)

        await rig.bridge.stop()
        drain.cancel()
    }

    /// The bridge says whether a decision reached a hook.
    ///
    /// The app writes its gate log and its usage count from that answer: a card
    /// can be clicked a moment after its own gate ended — its `ask_timeout`,
    /// its hook going away, a rule settling it — and the log used to record a
    /// decision the agent never heard.
    func testTheBridgeSaysWhetherADecisionWasDelivered() async throws {
        let rig = try rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let hook = gate("s", "npm test", in: rig)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let requests = await recorder.requests()
        let card = try XCTUnwrap(requests.first)

        let delivered = await rig.bridge.resolve(sessionID: "s", requestID: card.id, decision: .allowOnce)
        XCTAssertTrue(delivered)
        let reply = await hook.value
        XCTAssertEqual(reply?.action, .allow)

        let again = await rig.bridge.resolve(sessionID: "s", requestID: card.id, decision: .allowOnce)
        XCTAssertFalse(again, "that gate has ended — nothing was sent")
        let elsewhere = await rig.bridge.resolve(sessionID: "other", requestID: card.id, decision: .deny)
        XCTAssertFalse(elsewhere)
        let answered = await rig.bridge.answer(sessionID: "s", requestID: card.id, choice: "Yes")
        XCTAssertFalse(answered, "and the same for an answer to a question")

        await rig.bridge.stop()
        drain.cancel()
    }
}
