import XCTest
@testable import AirlockCore

/// The grammar, scored on the same cases the language model was scored on —
/// **inside `swift test`**, because there is no model to wait for.
///
/// That is the point of it as much as the accuracy is. `swift run PromptProbe
/// actions` needs Apple Intelligence switched on, takes minutes, and produced a
/// different answer depending on which unrelated actions happened to be
/// registered. This runs in milliseconds on any machine and gives the same
/// answer every time.
final class VoiceGrammarTests: XCTestCase {

    /// Every case that must produce an instruction, end to end: spoken phrase →
    /// grammar → arguments → the same `propose` the app calls → the subject the
    /// card would show.
    func testEveryActionCaseFires() throws {
        for testCase in ActionEvaluation.cases where testCase.toolName != nil {
            let hit = VoiceGrammar.match(testCase.spoken, offering: VoiceActionCatalog.all)
            let match = try XCTUnwrap(hit, "no match: \(testCase.spoken)  [\(testCase.note)]")
            XCTAssertEqual(match.name, testCase.toolName, "wrong action for: \(testCase.spoken)")

            let proposal = try XCTUnwrap(
                VoiceActionCatalog.propose(actionNamed: match.name, arguments: match.arguments,
                                           in: ActionEvaluation.context,
                                           offering: VoiceActionCatalog.all),
                "matched but resolved to nothing: \(testCase.spoken) → \(match.arguments)")
            if let subject = testCase.subject {
                XCTAssertEqual(proposal.subject, subject, "wrong subject for: \(testCase.spoken)")
            }
            for required in testCase.mustContain {
                XCTAssertTrue(
                    "\(proposal.summary) \(proposal.detail ?? "")".lowercased()
                        .contains(required.lowercased()),
                    "card lost \"\(required)\" from: \(testCase.spoken)")
            }
        }
    }

    /// The safety half. A question that becomes a card is the failure that would
    /// make this unsafe to ship, and it is the one every model configuration got
    /// wrong at least once.
    func testEveryQuestionHoldsFire() {
        for testCase in ActionEvaluation.cases where testCase.toolName == nil {
            XCTAssertNil(VoiceGrammar.match(testCase.spoken),
                         "acted on a question: \(testCase.spoken)  [\(testCase.note)]")
        }
    }

    /// And the assistant's own fourteen, which the classifier sees first in this
    /// shape: anything it claims never reaches the answering path at all, so a
    /// false positive here is a lost answer.
    func testTheAnsweringCasesAreNeverClaimed() {
        for testCase in PromptEvaluation.cases {
            XCTAssertNil(VoiceGrammar.match(testCase.question),
                         "claimed a question: \(testCase.question)")
        }
    }

    // MARK: - The pieces

    func testPolitenessAndFillerAreNotInstructionsOrObstacles() {
        // "can you" survives on purpose: it is how people give instructions out
        // loud, and rejecting it would throw away half the real phrasings.
        XCTAssertNotNil(VoiceGrammar.match("um can you put the sound on the airpods please"))
        XCTAssertNotNil(VoiceGrammar.match("switch audio to airpods"))
    }

    func testInterrogativesAreRefusedEvenWhenTheyNameEverything() {
        for question in ["how do I put the sound on the airpods",
                        "what happens if I switch the audio to the tv",
                        "why is the sound going to the speakers",
                        "is the audio going to the airpods"] {
            XCTAssertNil(VoiceGrammar.match(question), "acted on: \(question)")
        }
    }

    /// The grammar is allowed to be loose because resolution is strict. This is
    /// the pair that proves it: the same shape matches, and only one of them
    /// names something real.
    func testALooseMatchStillProposesNothingWithoutARealDevice() {
        let context = VoiceContext(audioOutputs: [
            AudioOutputDevice(uid: "u1", name: "MacBook Pro Speakers"),
        ])
        let desk = VoiceGrammar.match("put it on the desk")
        XCTAssertNotNil(desk, "expected the grammar to match this shape")
        if let desk {
            XCTAssertNil(VoiceActionCatalog.propose(actionNamed: desk.name,
                                                    arguments: desk.arguments, in: context))
        }

        let real = VoiceGrammar.match("put it on the speakers")
        XCTAssertNotNil(real)
        if let real {
            XCTAssertEqual(
                VoiceActionCatalog.propose(actionNamed: real.name, arguments: real.arguments,
                                           in: context)?.subject,
                "MacBook Pro Speakers")
        }
    }

    func testArgumentsLoseTheirArticlesAndPoliteness() {
        XCTAssertEqual(VoiceGrammar.trimmed(["the", "kitchen", "tv", "please"]), "kitchen tv")
        XCTAssertEqual(VoiceGrammar.trimmed(["my", "airpods", "now"]), "airpods")
        XCTAssertNil(VoiceGrammar.trimmed(["the", "please"]), "a name made only of noise is no name")
    }

    /// A phrase that names an action and then names nothing must not propose.
    ///
    /// Asserted against RESOLUTION rather than `match`, which is the contract
    /// that actually matters now: several triggers may capture the same words —
    /// "put the sound on" looks like a volume level of "on" — and the question
    /// is whether any of them yields something doable.
    func testNamingNoTargetProposesNothing() {
        for spoken in ["switch the audio over to the", "put the sound on"] {
            XCTAssertNil(
                VoiceActionCatalog.resolve(spoken: spoken, in: ActionEvaluation.context,
                                           offering: VoiceActionCatalog.offered(shortcuts: true)),
                "\(spoken) resolved to something")
        }
    }

    /// An action outside the offering is unreachable however plainly it is
    /// named. Stated against an explicit offering rather than against whatever
    /// happens to be unregistered today, so it keeps meaning something when the
    /// registered set changes.
    func testAnActionOutsideTheOfferingIsUnreachable() {
        let audioOnly: [any VoiceAction.Type] = [VoiceAudioOutputAction.self]
        XCTAssertNil(VoiceGrammar.match("tell claude to run the tests", offering: audioOnly))
        XCTAssertEqual(VoiceGrammar.match("tell claude to run the tests")?.name, "Voice.Agent")
    }

    /// Every registered action is reachable — a trigger-less registration is a
    /// switch that does nothing, and the only sign would be silence.
    func testEveryRegisteredActionCanBeReached() {
        for action in VoiceActionCatalog.registered {
            XCTAssertFalse(action.triggers.isEmpty,
                           "\(action.toolName) is registered but has no spoken form")
        }
    }
}
