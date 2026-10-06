import XCTest
@testable import AirlockCore

/// The one action whose vocabulary the user wrote.
///
/// Two halves, and the second is the one that decides whether this can ship: a
/// Shortcut is named by its author, so the useful verbs are the most generic in
/// the language, and the literal word "shortcut" is the only thing standing
/// between them and ordinary speech.
final class VoiceShortcutTests: XCTestCase {

    private let library = ["Morning Focus", "Evening Focus", "Start Recording", "Backup"]

    private func context(_ shortcuts: [String]? = nil) -> VoiceContext {
        VoiceContext(shortcuts: shortcuts ?? library)
    }

    /// Grammar → arguments → proposal, the whole way, on the registered set that
    /// includes this action.
    private func propose(_ spoken: String, in context: VoiceContext) -> ActionProposal? {
        let offering = VoiceActionCatalog.offered(shortcuts: true)
        guard let match = VoiceGrammar.match(spoken, offering: offering) else { return nil }
        return VoiceActionCatalog.propose(actionNamed: match.name, arguments: match.arguments,
                                          in: context, offering: offering)
    }

    // MARK: - Firing

    func testTheNameBeforeTheAnchor() throws {
        let proposal = try XCTUnwrap(propose("run my morning focus shortcut", in: context()))
        XCTAssertEqual(proposal.toolName, "Voice.Shortcut")
        XCTAssertEqual(proposal.subject, "Morning Focus")
        XCTAssertEqual(proposal.effect, .runShortcut(name: "Morning Focus"))
    }

    func testTheNameAfterAPreposition() throws {
        let proposal = try XCTUnwrap(propose("launch the shortcut called backup", in: context()))
        XCTAssertEqual(proposal.subject, "Backup")
    }

    /// Filler and politeness cost nothing, the same as every other action.
    func testFillerAroundTheInstruction() throws {
        let proposal = try XCTUnwrap(
            propose("um can you start the start recording shortcut please", in: context()))
        XCTAssertEqual(proposal.subject, "Start Recording")
    }

    // MARK: - Refusing

    /// Ambiguity resolves to nothing. With a real library this is the common
    /// case, not the edge.
    func testTwoShortcutsSharingAWordProposeNothing() {
        XCTAssertNil(propose("run my focus shortcut", in: context()),
                     "\"focus\" matches two Shortcuts and must not pick one")
    }

    func testAnUnknownNameProposesNothing() {
        XCTAssertNil(propose("run my pay the rent shortcut", in: context()))
    }

    func testAnEmptyLibraryProposesNothing() {
        XCTAssertNil(propose("run my morning focus shortcut", in: context([])))
    }

    /// The action names itself and then names nothing — "run the shortcut" alone
    /// captures no argument.
    func testNamingNoShortcutProposesNothing() {
        XCTAssertNil(propose("run the shortcut", in: context()))
    }

    // MARK: - The safety half

    /// Without the literal word, the generic verbs must reach nothing. This is
    /// the entire reason the anchor is required.
    func testGenericVerbsWithoutTheWordMatchNothing() {
        let offering = VoiceActionCatalog.offered(shortcuts: true)
        for spoken in ["run my backup", "start the recording", "do the morning focus",
                       "run the tests", "play something", "launch it", "execute that"] {
            let match = VoiceGrammar.match(spoken, offering: offering)
            XCTAssertNotEqual(match?.name, "Voice.Shortcut",
                              "\"\(spoken)\" reached Shortcuts without naming one")
        }
    }

    /// Every question the app is scored on, against the catalogue WITH Shortcuts
    /// offered. A new action must not cost a single one of them.
    func testTheQuestionsStillHoldFireWithShortcutsOffered() {
        let offering = VoiceActionCatalog.offered(shortcuts: true)
        for testCase in ActionEvaluation.cases where testCase.toolName == nil {
            XCTAssertNil(VoiceGrammar.match(testCase.spoken, offering: offering),
                         "acted on a question: \(testCase.spoken)  [\(testCase.note)]")
        }
        for testCase in PromptEvaluation.cases {
            XCTAssertNil(VoiceGrammar.match(testCase.question, offering: offering),
                         "claimed a question: \(testCase.question)")
        }
    }

    /// And the actions that already worked must resolve exactly as before —
    /// appending to the catalogue may claim only phrases nothing else wanted.
    func testTheExistingActionsAreUnchangedByAppendingThisOne() throws {
        let offering = VoiceActionCatalog.offered(shortcuts: true)
        for testCase in ActionEvaluation.cases where testCase.toolName != nil {
            let match = try XCTUnwrap(VoiceGrammar.match(testCase.spoken, offering: offering),
                                      "no match: \(testCase.spoken)")
            XCTAssertEqual(match.name, testCase.toolName,
                           "\(testCase.spoken) was re-ranked by adding Shortcuts")
        }
    }

    /// Off means unreachable, not merely unresolvable.
    func testItIsNotOfferedWhenSwitchedOff() {
        XCTAssertNil(VoiceGrammar.match("run my morning focus shortcut",
                                        offering: VoiceActionCatalog.offered(shortcuts: false)))
        XCTAssertEqual(VoiceActionCatalog.offered(shortcuts: false).count,
                       VoiceActionCatalog.registered.count)
    }

    // MARK: - Policy

    /// A Shortcut's steps can be rewritten after a rule names it, so no rule may
    /// ever pre-approve one.
    func testNoAllowRuleCanEverApproveAShortcut() throws {
        let proposal = try XCTUnwrap(propose("run my backup shortcut", in: context()))
        let request = proposal.request(id: "r", at: Date(timeIntervalSince1970: 0))

        let risk = try XCTUnwrap(RiskAssessor.assess(request),
                                 "Voice.Shortcut is not on the risk floor")
        XCTAssertTrue(risk.reason.contains("changed"),
                      "the reason should say why it can never be pre-approved: it is editable")

        // Even with the most specific allow rule imaginable, the floor wins.
        let policy = try PolicyParser.parse("allow:\n  - Voice.Shortcut(Backup)")
        let verdict = PolicyEngine.evaluate(request, policy: policy)
        guard case .ask(let risk) = verdict else {
            return XCTFail("an allow rule approved a floored action — got \(verdict)")
        }
        XCTAssertNotNil(risk)

        // And the card must not offer a button that would write one.
        guard case .ask(_, let always) = VoiceActionOutcome.resolve(
            verdict: verdict, for: request, isEntitled: true) else { return XCTFail("expected ask") }
        XCTAssertNil(always, "Always was offered on a Shortcut")
    }

    /// The catalogue line is in the prompt on every spoken word, so it is capped.
    func testTheSummaryFitsTheCatalogueBudget() {
        XCTAssertLessThanOrEqual(VoiceShortcutAction.summary.count,
                                 VoiceActionCatalog.maximumSummaryLength)
    }

    /// A rule left in a `policy.yaml` from a build where this was switched on
    /// must still read as itself — `action(named:)` looks through `all`.
    func testAnUnofferedRuleStillResolvesToThisAction() {
        XCTAssertNotNil(VoiceActionCatalog.action(named: "Voice.Shortcut"))
        XCTAssertNotNil(VoiceActionCatalog.riskFloorReason(toolName: "Voice.Shortcut"))
    }
}
