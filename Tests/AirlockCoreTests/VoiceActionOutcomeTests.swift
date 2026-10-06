import XCTest
@testable import AirlockCore

/// What the notch does with a proposal once policy has spoken.
///
/// Pure, which is the point: every one of these combinations otherwise needs a
/// microphone, a language model and a licence state to reach by hand.
final class VoiceActionOutcomeTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 0)

    private func request(_ tool: String = "Voice.AudioOutput",
                         _ subject: String = "AirPods Pro") -> PermissionRequest {
        PermissionRequest(id: "r", toolName: tool, summary: "Send sound to \(subject)",
                          target: subject, createdAt: epoch)
    }

    func testAllowPerformsWithoutACard() {
        let outcome = VoiceActionOutcome.resolve(verdict: .allow(rule: "Voice.AudioOutput(*)"),
                                                 for: request(), isEntitled: true)
        XCTAssertEqual(outcome, .perform(rule: "Voice.AudioOutput(*)"))
        XCTAssertTrue(outcome.performsImmediately)
    }

    func testDenyRefusesAndOffersNothingToClick() {
        let outcome = VoiceActionOutcome.resolve(verdict: .deny(rule: "Voice.AudioOutput(*)"),
                                                 for: request(), isEntitled: true)
        XCTAssertEqual(outcome, .refused(rule: "Voice.AudioOutput(*)"))
        XCTAssertFalse(outcome.performsImmediately)
    }

    func testAskOffersTheRuleAlwaysWouldWrite() {
        let outcome = VoiceActionOutcome.resolve(verdict: .ask(risk: nil),
                                                 for: request(), isEntitled: true)
        guard case .ask(let risk, let always) = outcome else { return XCTFail("expected ask") }
        XCTAssertNil(risk)
        XCTAssertEqual(always?.text, "Voice.AudioOutput(AirPods Pro)")
        XCTAssertEqual(always?.summary, VoiceAudioOutputAction.exactRuleSummary)
    }

    /// A floored action must not offer Always — the rule would be written and
    /// then ignored forever, which is a button that appears to work and does not.
    func testAFlooredAskOffersNoAlwaysButton() {
        let outcome = VoiceActionOutcome.resolve(verdict: .ask(risk: "sends a spoken instruction"),
                                                 for: request("Voice.Agent", "airlock"),
                                                 isEntitled: true)
        guard case .ask(let risk, let always) = outcome else { return XCTFail("expected ask") }
        XCTAssertEqual(risk, "sends a spoken instruction")
        XCTAssertNil(always, "Always was offered on an action the floor can never approve")
    }

    /// A rule in `policy.yaml` reading `Voice.AudioOutput(AirPods Pro)` says on
    /// its face that a microphone was granted it — see `VoiceAction.toolName`.
    /// A keyboard may therefore not write one.
    func testAKeyboardIsNeverOfferedStandingPermission() {
        let outcome = VoiceActionOutcome.resolve(verdict: .ask(risk: nil), for: request(),
                                                 isEntitled: true,
                                                 offersStandingPermission: false)
        guard case .ask(let risk, let always) = outcome else { return XCTFail("expected ask") }
        XCTAssertNil(risk, "withholding Always must not invent a risk that is not there")
        XCTAssertNil(always, "a typed command was offered a rule claiming spoken provenance")
    }

    /// Withholding the button withholds only the button. Everything else about
    /// the verdict is untouched — including performing under a rule that already
    /// exists, which a keyboard is perfectly entitled to do.
    func testWithholdingAlwaysMovesNothingElse() {
        for entitled in [true, false] {
            for verdict: PolicyVerdict in [.allow(rule: "r"), .deny(rule: "r"), .ask(risk: "x")] {
                XCTAssertEqual(
                    VoiceActionOutcome.resolve(verdict: verdict, for: request(),
                                               isEntitled: entitled,
                                               offersStandingPermission: false),
                    VoiceActionOutcome.resolve(verdict: verdict, for: request(),
                                               isEntitled: entitled),
                    "\(verdict) changed shape when Always was withheld")
            }
        }
    }

    /// The default is the spoken path, so every existing caller keeps its button.
    func testTheDefaultStillOffersIt() {
        guard case .ask(_, let always) = VoiceActionOutcome.resolve(
            verdict: .ask(risk: nil), for: request(), isEntitled: true)
        else { return XCTFail("expected ask") }
        XCTAssertNotNil(always)
    }

    /// A finished trial stops performing and nothing else. It outranks even a
    /// deny rule, because it is not a statement about this action at all.
    func testAnExpiredTrialBlocksEveryVerdict() {
        for verdict: PolicyVerdict in [.allow(rule: "x"), .deny(rule: "y"), .ask(risk: nil)] {
            XCTAssertEqual(
                VoiceActionOutcome.resolve(verdict: verdict, for: request(), isEntitled: false),
                .blocked, "\(verdict) should be blocked when unentitled")
        }
    }

    /// The whole chain, from a spoken argument to what the card shows, with the
    /// real policy engine in the middle.
    func testEndToEndFromArgumentsToCard() throws {
        let context = VoiceContext(audioOutputs: [
            AudioOutputDevice(uid: "u2", name: "AirPods Pro"),
        ])
        let proposal = try XCTUnwrap(
            VoiceActionCatalog.propose(actionNamed: "audiooutput",
                                       arguments: ["device": "airpods"], in: context))
        let request = proposal.request(id: "r", at: epoch)

        let policy = try PolicyParser.parse("allow:\n  - Voice.AudioOutput(AirPods Pro)")
        let verdict = PolicyEngine.evaluate(request, policy: policy)
        XCTAssertEqual(VoiceActionOutcome.resolve(verdict: verdict, for: request,
                                                  isEntitled: true),
                       .perform(rule: "Voice.AudioOutput(AirPods Pro)"))

        // And the rule the card would have offered is exactly the one that then
        // matches — the invariant `RuleGeneralizer` exists to keep.
        let empty = try PolicyParser.parse("allow:\n  - Read")
        guard case .ask(_, let always) = VoiceActionOutcome.resolve(
            verdict: PolicyEngine.evaluate(request, policy: empty),
            for: request, isEntitled: true) else { return XCTFail("expected ask") }
        let rule = try PolicyRule(parsing: try XCTUnwrap(always).text)
        XCTAssertTrue(rule.matches(request))
    }
}
