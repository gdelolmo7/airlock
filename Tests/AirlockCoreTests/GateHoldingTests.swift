import AirlockTestSupport
import XCTest
@testable import AirlockCore

/// The bridge's switch for a gate a person would answer: held for a card in
/// the notch, or handed straight back to the agent's own terminal.
///
/// It was set from the licence, so a finished trial handed every question
/// back. Nothing locks any more and the app never sets it (pinned in the app's
/// `GateHeldOnEveryPlanTests`); the switch stays for a plan limit that needs an
/// agent to ask in its own terminal, so its behaviour stays pinned here.
final class GateHoldingTests: XCTestCase {
    /// A bridge nobody has told anything holds gates for a person.
    func testABridgeHoldsForAPersonUntilToldOtherwise() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let blocked = GateSocket.hook(GateSocket.payload(tool: "Bash", input: Self.command), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let requests = await recorder.requests()
        let request = try XCTUnwrap(requests.first)
        let delivered = await rig.bridge.resolve(sessionID: "q", requestID: request.id, decision: .allowOnce)
        XCTAssertTrue(delivered)
        let reply = await blocked.value
        XCTAssertEqual(reply?.action, .allow, "held, and answered from the notch")

        await rig.bridge.stop()
        recording.cancel()
    }

    // MARK: - The bridge, over a real socket

    private static let command = #"{"command":"npm test"}"#
    private static let question = """
    {"questions":[{"question":"Which provider?","header":"Payments",\
    "options":[{"label":"Stripe"},{"label":"Adyen"}]}]}
    """

    private static func handedBack(_ recorder: GateSocket.Recorder) async -> Bool {
        await recorder.all.contains {
            if case let .activity(summary) = $0.kind { return summary == SessionCardText.handedBack }
            return false
        }
    }

    /// No card, so nothing opens the island, and the hook hears at once. A
    /// held gate would leave this hook waiting until its own timeout.
    func testHandingBackSendsACommandStraightBack() async throws {
        let rig = try GateSocket.rig()
        await rig.bridge.setGateHolding(.handBack)
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let reply = await GateSocket.hook(GateSocket.payload(tool: "Bash", input: Self.command),
                                          path: rig.path).value
        XCTAssertEqual(reply?.action, .deferToAgent, "no decision: the agent asks in its own terminal")

        await GateSocket.waitFor { await Self.handedBack(recorder) }
        let requests = await recorder.requests()
        XCTAssertTrue(requests.isEmpty, "a card would open the island")
        let state = await GateSocket.replay(recorder.all)
        XCTAssertEqual(state.attentionCount, 0)
        XCTAssertNil(state.sessions["q"]?.pendingPermission)
        XCTAssertEqual(state.sessions["q"]?.lastSummary, SessionCardText.handedBack)

        await rig.bridge.stop()
        recording.cancel()
    }

    /// Claude Code's questions too: its own picker comes up in the terminal.
    func testHandingBackSendsAQuestionStraightBack() async throws {
        let rig = try GateSocket.rig()
        await rig.bridge.setGateHolding(.handBack)
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let reply = await GateSocket.hook(GateSocket.payload(tool: "AskUserQuestion", input: Self.question),
                                          path: rig.path).value
        XCTAssertEqual(reply?.action, .deferToAgent)

        await GateSocket.waitFor { await Self.handedBack(recorder) }
        let requests = await recorder.requests()
        XCTAssertTrue(requests.isEmpty)
        let state = await GateSocket.replay(recorder.all)
        XCTAssertEqual(state.attentionCount, 0)

        await rig.bridge.stop()
        recording.cancel()
    }

    /// What the policy settles before any card exists is untouched: deny and
    /// allow rules still decide, and the risk floor still never approves —
    /// it goes back to the agent's own prompt, as an ask always could.
    func testRulesStillDecideWhileHandingBack() async throws {
        let rig = try GateSocket.rig(policyYAML: """
        allow:
          - Bash(git status)
          - Bash(sudo rm -rf /tmp/x)
        deny:
          - Bash(git push --force*)
        """)
        await rig.bridge.setGateHolding(.handBack)
        try await rig.bridge.start()

        let allowed = await GateSocket.hook(GateSocket.payload(tool: "Bash", input: #"{"command":"git status"}"#),
                                            path: rig.path).value
        XCTAssertEqual(allowed?.action, .allow)

        let denied = await GateSocket.hook(
            GateSocket.payload(tool: "Bash", input: #"{"command":"git push --force origin main"}"#),
            path: rig.path).value
        XCTAssertEqual(denied?.action, .deny)

        let floored = await GateSocket.hook(
            GateSocket.payload(tool: "Bash", input: #"{"command":"sudo rm -rf /tmp/x"}"#),
            path: rig.path).value
        XCTAssertEqual(floored?.action, .deferToAgent, "an allow rule never approves past the floor")

        await rig.bridge.stop()
    }

    /// A card already up goes back too, rather than waiting out `ask_timeout`
    /// with the terminal showing nothing.
    func testHandingBackLetsGoOfWhatIsAlreadyHeld() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let blocked = GateSocket.hook(GateSocket.payload(tool: "Bash", input: Self.command), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        await rig.bridge.setGateHolding(.handBack)

        let reply = await blocked.value
        XCTAssertEqual(reply?.action, .deferToAgent)
        await GateSocket.waitFor { await recorder.resolutions().count == 1 }
        let state = await GateSocket.replay(recorder.all)
        XCTAssertEqual(state.attentionCount, 0, "the card goes with its hook")

        await rig.bridge.stop()
        recording.cancel()
    }

    /// Holding again brings the cards back: a gate is held for its answer.
    func testHoldingAgainBringsTheCardsBack() async throws {
        let rig = try GateSocket.rig()
        await rig.bridge.setGateHolding(.handBack)
        await rig.bridge.setGateHolding(.holdForPerson)
        try await rig.bridge.start()
        let (recorder, recording) = GateSocket.record(rig.bridge)

        let blocked = GateSocket.hook(GateSocket.payload(tool: "Bash", input: Self.command), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let requests = await recorder.requests()
        let request = try XCTUnwrap(requests.first)
        let delivered = await rig.bridge.resolve(sessionID: "q", requestID: request.id, decision: .allowOnce)
        XCTAssertTrue(delivered)

        let reply = await blocked.value
        XCTAssertEqual(reply?.action, .allow, "held, and answered from the notch")

        await rig.bridge.stop()
        recording.cancel()
    }
}
