import XCTest
@testable import AirlockCore

/// The Always loop, all the way through a real policy file.
///
/// This is the thing that separates Airlock from a confirmation dialog: a dialog
/// is a speed bump you clear every time, and this is a rule you write once, over
/// a floor no rule can lift. So it is tested end to end — the rule the card
/// SHOWS, written by the same `PolicyStore` the app calls, reloaded from disk,
/// and evaluated against the same request — rather than asserted a piece at a
/// time and hoped to join up.
final class VoiceStandingPermissionTests: XCTestCase {
    private var root: URL!
    private var store: PolicyStore!
    private let epoch = Date(timeIntervalSince1970: 0)

    private let context = VoiceContext(audioOutputs: [
        AudioOutputDevice(uid: "u1", name: "MacBook Pro Speakers"),
        AudioOutputDevice(uid: "u2", name: "AirPods Pro"),
    ])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("an-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = PolicyStore(globalFileURL: root.appendingPathComponent("global/policy.yaml"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Spoken phrase → grammar → proposal → card → Always → the same phrase
    /// performing without a card. Every step is the app's own code.
    private func spoken(_ phrase: String) throws -> (ActionProposal, PermissionRequest) {
        let match = try XCTUnwrap(VoiceGrammar.match(phrase), "grammar missed: \(phrase)")
        let proposal = try XCTUnwrap(
            VoiceActionCatalog.propose(actionNamed: match.name, arguments: match.arguments,
                                       in: context),
            "resolved to nothing: \(phrase)")
        return (proposal, proposal.request(id: "r", at: epoch))
    }

    private func outcome(for request: PermissionRequest) -> VoiceActionOutcome {
        let verdict = PolicyEngine.evaluate(request, policy: store.load(projectRoot: nil).policy)
        return VoiceActionOutcome.resolve(verdict: verdict, for: request, isEntitled: true)
    }

    func testAlwaysWritesARuleThatThenPerformsWithoutACard() throws {
        let (_, request) = try spoken("put the sound on the airpods")

        // First time: a card, offering a rule.
        guard case .ask(let risk, let always) = outcome(for: request) else {
            return XCTFail("expected a card the first time")
        }
        XCTAssertNil(risk)
        let candidate = try XCTUnwrap(always)
        XCTAssertEqual(candidate.text, "Voice.AudioOutput(AirPods Pro)")

        // The click.
        XCTAssertTrue(try store.appendAllowRule(candidate.text, projectRoot: nil))

        // Second time: the same phrase, no card.
        let (_, again) = try spoken("put the sound on the airpods")
        XCTAssertEqual(outcome(for: again), .perform(rule: candidate.text))

        // And clicking Always twice does not write it twice.
        XCTAssertFalse(try store.appendAllowRule(candidate.text, projectRoot: nil))
    }

    /// A rule is about one device, not about being allowed to move sound.
    func testAnotherDeviceStillAsks() throws {
        let (_, airpods) = try spoken("put the sound on the airpods")
        guard case .ask(_, let always) = outcome(for: airpods) else { return XCTFail("expected ask") }
        try store.appendAllowRule(XCTUnwrap(always).text, projectRoot: nil)

        let (_, speakers) = try spoken("switch the audio to the macbook pro speakers")
        guard case .ask = outcome(for: speakers) else {
            return XCTFail("a rule for one device authorised another")
        }
    }

    /// The file is edited textually so hand-written comments survive — a policy
    /// file that eats your notes is one you stop editing by hand.
    func testTheUsersOwnCommentsSurviveTheWrite() throws {
        try FileManager.default.createDirectory(
            at: store.globalFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = """
        # my rules, do not delete
        allow:
          # safe reads
          - Read
        """
        try original.write(to: store.globalFileURL, atomically: true, encoding: .utf8)

        try store.appendAllowRule("Voice.AudioOutput(AirPods Pro)", projectRoot: nil)

        let written = try String(contentsOf: store.globalFileURL, encoding: .utf8)
        XCTAssertTrue(written.contains("# my rules, do not delete"))
        XCTAssertTrue(written.contains("# safe reads"))
        XCTAssertTrue(written.contains("- Read"))
        XCTAssertTrue(written.contains("Voice.AudioOutput(AirPods Pro)"))
    }

    /// A deny rule someone wrote by hand outranks everything, and says so.
    func testAHandWrittenDenyRefusesAndNamesItself() throws {
        try FileManager.default.createDirectory(
            at: store.globalFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "deny:\n  - Voice.AudioOutput(*)\nallow:\n  - Voice.AudioOutput(AirPods Pro)"
            .write(to: store.globalFileURL, atomically: true, encoding: .utf8)

        let (_, request) = try spoken("put the sound on the airpods")
        XCTAssertEqual(outcome(for: request), .refused(rule: "Voice.AudioOutput(*)"))
    }

    /// An expired trial outranks a rule the user wrote themselves. Answering
    /// carries on; performing does not.
    func testAFinishedTrialOutranksAnAllowRule() throws {
        let (_, request) = try spoken("put the sound on the airpods")
        try store.appendAllowRule("Voice.AudioOutput(AirPods Pro)", projectRoot: nil)

        let verdict = PolicyEngine.evaluate(request, policy: store.load(projectRoot: nil).policy)
        XCTAssertEqual(verdict, .allow(rule: "Voice.AudioOutput(AirPods Pro)"))
        XCTAssertEqual(
            VoiceActionOutcome.resolve(verdict: verdict, for: request, isEntitled: false),
            .blocked)
    }

    /// What the gate log records, which is what Settings later turns into
    /// suggestions. An auto-allow is not a human decision and must not be
    /// offered back as one.
    func testTheLogDistinguishesAHumanClickFromARuleDoingItsJob() throws {
        let (_, request) = try spoken("put the sound on the airpods")

        let clicked = GateRecord(request: request, outcome: .alwaysAllowed,
                                 agent: "voice", decidedAt: epoch)
        let automatic = GateRecord(request: request, outcome: .autoAllowed,
                                   agent: "voice", decidedAt: epoch)
        XCTAssertEqual(clicked.ruleText, "Voice.AudioOutput(AirPods Pro)")
        XCTAssertEqual(clicked.agent, "voice")
        XCTAssertFalse(automatic.outcome.isHumanDecision)
        XCTAssertNil(clicked.riskReason, "an ordinary action must not carry a risk badge")
    }
}
