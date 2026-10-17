import AirlockTestSupport
import XCTest
@testable import AirlockCore

/// Free answers one agent at a time from the notch: the first to ask has it
/// until that session ends, then the next to ask takes over. Every other
/// agent gets "no decision" and asks in its own terminal, never approved and
/// never left waiting, and the rules and the risk floor decide for all of
/// them first.
final class OneAgentAtATimeTests: XCTestCase {
    private static let command = #"{"command":"npm test"}"#

    private func gate(_ session: String, _ input: String = OneAgentAtATimeTests.command,
                      in rig: GateSocket.Rig, at: Date = Date()) -> Task<HookDirective?, Never> {
        GateSocket.hook(GateSocket.payload(session: session, tool: "Bash", input: input, at: at), path: rig.path)
    }

    private func end(_ session: String, in rig: GateSocket.Rig) async {
        await GateSocket.dyingHook(
            GateSocket.payload(session: session, tool: "Bash", input: "{}",
                               at: Date().addingTimeInterval(2), event: "SessionEnd"),
            path: rig.path)
    }

    private static func requests(of session: String, _ recorder: GateSocket.Recorder) async -> [PermissionRequest] {
        await recorder.all.compactMap { event in
            guard event.sessionID == session, case let .permissionRequested(request) = event.kind else { return nil }
            return request
        }
    }

    private static func handedBack(_ session: String, _ recorder: GateSocket.Recorder) async -> Bool {
        await recorder.all.contains { event in
            guard event.sessionID == session, case let .activity(summary) = event.kind else { return false }
            return summary == SessionCardText.handedBack
        }
    }

    /// Answers the session's first card from the notch.
    private func answer(_ session: String, in rig: GateSocket.Rig, _ recorder: GateSocket.Recorder) async throws {
        let requests = await Self.requests(of: session, recorder)
        let request = try XCTUnwrap(requests.first)
        let delivered = await rig.bridge.resolve(sessionID: session, requestID: request.id, decision: .allowOnce)
        XCTAssertTrue(delivered)
    }

    func testTheFirstToAskHasTheNotchAndTheOthersAskInTheirTerminal() async throws {
        let rig = try GateSocket.rig()
        await rig.bridge.setOneAgentAtATime(true)
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let first = gate("a", in: rig)
        await GateSocket.waitFor { await Self.requests(of: "a", recorder).count == 1 }
        let other = await gate("b", in: rig).value
        XCTAssertEqual(other?.action, .deferToAgent, "no decision: never approved, never left waiting")
        await GateSocket.waitFor { await Self.handedBack("b", recorder) }
        let bCards = await Self.requests(of: "b", recorder)
        XCTAssertTrue(bCards.isEmpty, "no card for the other agent")

        try await answer("a", in: rig, recorder)
        let firstReply = await first.value
        XCTAssertEqual(firstReply?.action, .allow)

        // Answered, it keeps the notch: its next question is held too.
        let again = gate("a", in: rig)
        await GateSocket.waitFor { await Self.requests(of: "a", recorder).count == 2 }
        let stillOther = await gate("b", in: rig).value
        XCTAssertEqual(stillOther?.action, .deferToAgent)
        let answering = await rig.bridge.answeringSession()
        XCTAssertEqual(answering, "a")

        await rig.bridge.stop()
        _ = await again.value
        recording.cancel()
    }

    /// Two agents asking at the same moment: one card, one terminal.
    func testTwoAgentsAskingAtOnceGetOneCard() async throws {
        let rig = try GateSocket.rig()
        await rig.bridge.setOneAgentAtATime(true)
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let a = gate("a", in: rig)
        let b = gate("b", in: rig)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        await GateSocket.waitFor {
            let a = await Self.handedBack("a", recorder)
            let b = await Self.handedBack("b", recorder)
            return a || b
        }
        let answering = await rig.bridge.answeringSession()
        let owner = try XCTUnwrap(answering)
        let cards = await recorder.requests()
        XCTAssertEqual(cards.count, 1)

        try await answer(owner, in: rig, recorder)
        let replies = [await a.value?.action, await b.value?.action]
        XCTAssertEqual(Set(replies.compactMap { $0 }), [.allow, .deferToAgent])

        await rig.bridge.stop()
        recording.cancel()
    }

    func testWhenTheFirstEndsTheNextToAskTakesOver() async throws {
        let rig = try GateSocket.rig()
        await rig.bridge.setOneAgentAtATime(true)
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let first = gate("a", in: rig)
        await GateSocket.waitFor { await Self.requests(of: "a", recorder).count == 1 }
        await end("a", in: rig)
        let firstReply = await first.value
        XCTAssertEqual(firstReply?.action, .deferToAgent, "its own card goes back with it")
        let answering = await rig.bridge.answeringSession()
        XCTAssertNil(answering)

        let next = gate("b", in: rig, at: Date().addingTimeInterval(3))
        await GateSocket.waitFor { await Self.requests(of: "b", recorder).count == 1 }
        let owner = await rig.bridge.answeringSession()
        XCTAssertEqual(owner, "b")
        try await answer("b", in: rig, recorder)
        let nextReply = await next.value
        XCTAssertEqual(nextReply?.action, .allow)

        await rig.bridge.stop()
        recording.cancel()
    }

    /// Deny rules, allow rules and the risk floor are asked first, for the
    /// agent with the notch and every other.
    func testTheRulesDecideForEveryAgentFirst() async throws {
        let rig = try GateSocket.rig(policyYAML: """
        allow:
          - Bash(git status)
          - Bash(sudo rm -rf /tmp/x)
        deny:
          - Bash(git push --force*)
        """)
        await rig.bridge.setOneAgentAtATime(true)
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let first = gate("a", in: rig)
        await GateSocket.waitFor { await Self.requests(of: "a", recorder).count == 1 }

        let allowed = await gate("b", #"{"command":"git status"}"#, in: rig).value
        XCTAssertEqual(allowed?.action, .allow)
        let denied = await gate("b", #"{"command":"git push --force origin main"}"#, in: rig).value
        XCTAssertEqual(denied?.action, .deny, "a deny rule still denies the other agent")
        let floored = await gate("b", #"{"command":"sudo rm -rf /tmp/x"}"#, in: rig).value
        XCTAssertEqual(floored?.action, .deferToAgent, "past the floor: asked in its terminal, never approved")

        let ownerDenied = await gate("a", #"{"command":"git push --force origin main"}"#, in: rig).value
        XCTAssertEqual(ownerDenied?.action, .deny)

        await rig.bridge.stop()
        _ = await first.value
        recording.cancel()
    }

    func testOnAPaidPlanEveryAgentIsHeld() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let a = gate("a", in: rig)
        let b = gate("b", in: rig)
        await GateSocket.waitFor { await recorder.requests().count == 2 }
        try await answer("a", in: rig, recorder)
        try await answer("b", in: rig, recorder)
        let aReply = await a.value
        let bReply = await b.value
        XCTAssertEqual(aReply?.action, .allow)
        XCTAssertEqual(bReply?.action, .allow)

        await rig.bridge.stop()
        recording.cancel()
    }

    /// A plan ending never takes a card away: both stay up and are answered
    /// from the notch. From then on, the one that waited longest has it.
    func testDroppingToFreeKeepsTheCardsAlreadyUp() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let a = gate("a", in: rig)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let b = gate("b", in: rig, at: Date().addingTimeInterval(1))
        await GateSocket.waitFor { await recorder.requests().count == 2 }
        await rig.bridge.setOneAgentAtATime(true)
        let owner = await rig.bridge.answeringSession()
        XCTAssertEqual(owner, "a")

        let late = await gate("c", in: rig).value
        XCTAssertEqual(late?.action, .deferToAgent, "a third agent asks in its terminal")
        try await answer("a", in: rig, recorder)
        try await answer("b", in: rig, recorder)
        let aReply = await a.value
        let bReply = await b.value
        XCTAssertEqual(aReply?.action, .allow)
        XCTAssertEqual(bReply?.action, .allow, "the card already up stays, and is answered")

        await rig.bridge.stop()
        recording.cancel()
    }

    /// The agent with the notch ends while another's card, from before the
    /// plan changed, is still up: that one has the notch now.
    func testAnEndHandsTheNotchToTheCardStillUp() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let a = gate("a", in: rig)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let b = gate("b", in: rig, at: Date().addingTimeInterval(1))
        await GateSocket.waitFor { await recorder.requests().count == 2 }
        await rig.bridge.setOneAgentAtATime(true)
        await end("a", in: rig)
        _ = await a.value
        let owner = await rig.bridge.answeringSession()
        XCTAssertEqual(owner, "b")

        await rig.bridge.stop()
        _ = await b.value
        recording.cancel()
    }

    /// A session replaced by its next one (`/clear`, a resume) hands the
    /// notch on to it.
    func testASupersededSessionHandsTheNotchToItsSuccessor() async throws {
        let rig = try GateSocket.rig()
        await rig.bridge.setOneAgentAtATime(true)
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let first = gate("a", in: rig)
        await GateSocket.waitFor { await Self.requests(of: "a", recorder).count == 1 }
        try await answer("a", in: rig, recorder)
        _ = await first.value
        await rig.bridge.sessionSuperseded("a", by: "a2")
        let owner = await rig.bridge.answeringSession()
        XCTAssertEqual(owner, "a2")

        let other = await gate("b", in: rig).value
        XCTAssertEqual(other?.action, .deferToAgent)
        let successor = gate("a2", in: rig)
        await GateSocket.waitFor { await Self.requests(of: "a2", recorder).count == 1 }

        await rig.bridge.stop()
        _ = await successor.value
        recording.cancel()
    }

    /// An agent the app finds gone (its process ended, or it went quiet for
    /// too long) lets the next one have the notch, as a SessionEnd does.
    func testASessionTheAppFindsGoneLetsTheNextTakeOver() async throws {
        let rig = try GateSocket.rig()
        await rig.bridge.setOneAgentAtATime(true)
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let first = gate("a", in: rig)
        await GateSocket.waitFor { await Self.requests(of: "a", recorder).count == 1 }
        await rig.bridge.sessionEnded("a")
        let firstReply = await first.value
        XCTAssertEqual(firstReply?.action, .deferToAgent)

        let next = gate("b", in: rig)
        await GateSocket.waitFor { await Self.requests(of: "b", recorder).count == 1 }

        await rig.bridge.stop()
        _ = await next.value
        recording.cancel()
    }

    /// Buying a plan lets every agent's next question come to the notch.
    func testUpgradingHoldsEveryAgentAgain() async throws {
        let rig = try GateSocket.rig()
        await rig.bridge.setOneAgentAtATime(true)
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let first = gate("a", in: rig)
        await GateSocket.waitFor { await Self.requests(of: "a", recorder).count == 1 }
        let refused = await gate("b", in: rig).value
        XCTAssertEqual(refused?.action, .deferToAgent)

        await rig.bridge.setOneAgentAtATime(false)
        let held = gate("b", in: rig)
        await GateSocket.waitFor { await Self.requests(of: "b", recorder).count == 1 }

        await rig.bridge.stop()
        _ = await first.value
        _ = await held.value
        recording.cancel()
    }

    /// The app hears which agent asked in its terminal and which one had the
    /// notch, for Free's row and its reminders.
    func testTheAppHearsWhoHadTheNotch() async throws {
        actor Heard {
            var pairs: [[String]] = []
            func add(_ asking: String, _ answering: String) { pairs.append([asking, answering]) }
        }
        let heard = Heard()
        let rig = try GateSocket.rig()
        await rig.bridge.setOneAgentAtATime(true)
        await rig.bridge.setPassedOverHandler { asking, answering in
            Task { await heard.add(asking, answering) }
        }
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let first = gate("a", in: rig)
        await GateSocket.waitFor { await Self.requests(of: "a", recorder).count == 1 }
        _ = await gate("b", in: rig).value
        await GateSocket.waitFor { await heard.pairs.count == 1 }
        let pairs = await heard.pairs
        XCTAssertEqual(pairs, [["b", "a"]])

        await rig.bridge.stop()
        _ = await first.value
        recording.cancel()
    }
}
