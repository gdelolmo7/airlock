import XCTest
@testable import AirlockCore

/// "Push the volume to 50."
///
/// That exact phrase shipped broken: `push` was not in the verb list, nothing
/// captured, and the local model politely explained it could not adjust the
/// volume. The lesson is in the trigger shape now — wide on verbs, narrow on
/// objects — and this file is the evidence.
final class VoiceVolumeTests: XCTestCase {

    private func context(volume: Double? = 0.4) -> VoiceContext {
        VoiceContext(audioOutputs: [AudioOutputDevice(uid: "u2", name: "AirPods Pro")],
                     apps: [VoiceAppTarget(path: "/Applications/Spotify.app", name: "Spotify")],
                     sites: VoiceSiteAliases.merged(user: []),
                     volume: volume)
    }

    private func propose(_ spoken: String, volume: Double? = 0.4) -> ActionProposal? {
        VoiceActionCatalog.resolve(spoken: spoken, in: context(volume: volume),
                                   offering: VoiceActionCatalog.offered(shortcuts: false))
    }

    /// The phrase from the bug report, verbatim including the filler.
    func testTheReportedPhrase() throws {
        let proposal = try XCTUnwrap(propose("okay push the volume to 50"))
        XCTAssertEqual(proposal.toolName, "Voice.Volume")
        XCTAssertEqual(proposal.subject, "50%")
        XCTAssertEqual(proposal.effect, .setVolume(0.5))
    }

    /// Every verb people actually use, with and without the preposition.
    func testTheWaysPeopleSayIt() throws {
        let phrasings = [
            "set the volume to 30", "set volume 30", "change the volume to 30",
            "put the volume at 30", "make the volume 30", "bump the volume to 30",
            "turn the volume to 30", "crank the volume to 30", "lower the volume to 30",
            "bring the volume to 30 percent",
        ]
        for spoken in phrasings {
            let proposal = try XCTUnwrap(propose(spoken), "no match: \(spoken)")
            XCTAssertEqual(proposal.effect, .setVolume(0.3), "wrong level for: \(spoken)")
        }
    }

    func testWordsForTheEnds() throws {
        XCTAssertEqual(try XCTUnwrap(propose("turn the volume off")).effect, .setVolume(0))
        XCTAssertEqual(try XCTUnwrap(propose("set the volume to half")).effect, .setVolume(0.5))
        XCTAssertEqual(try XCTUnwrap(propose("set the volume to max")).effect, .setVolume(1))
    }

    // MARK: - Relative

    func testUpAndDownMoveFromWhereItIs() throws {
        XCTAssertEqual(try XCTUnwrap(propose("turn the volume down", volume: 0.4)).effect,
                       .setVolume(0.3))
        XCTAssertEqual(try XCTUnwrap(propose("turn the volume up", volume: 0.4)).effect,
                       .setVolume(0.5))
    }

    func testRelativeMovesClampRatherThanWrap() throws {
        XCTAssertEqual(try XCTUnwrap(propose("turn the volume down", volume: 0.02)).effect,
                       .setVolume(0))
        XCTAssertEqual(try XCTUnwrap(propose("turn the volume up", volume: 0.98)).effect,
                       .setVolume(1))
    }

    /// A device with no software volume — HDMI, many USB interfaces — has no
    /// "where it is now", so a relative move proposes nothing instead of
    /// guessing a starting point.
    func testRelativeNeedsAKnownLevel() {
        XCTAssertNil(propose("turn the volume down", volume: nil))
        // An absolute one still works: it does not need to know.
        XCTAssertNotNil(propose("set the volume to 30", volume: nil))
    }

    /// A KNOWN GAP, asserted so it is a decision rather than a surprise: a bare
    /// "volume up" has no verb, and every trigger requires one. Supporting it
    /// needs a verb-less placement, which is a wider change than it looks —
    /// see the note in `VoiceGrammar.candidates` about greedy triggers.
    func testABareObjectPhraseIsNotYetSupported() {
        XCTAssertNil(propose("volume up"))
        XCTAssertNil(propose("volume 50"))
    }

    // MARK: - "by", which is a step and not a destination

    /// The reported phrase. Read as absolute it would have set the volume to
    /// 10% — near-silence — instead of nudging it down a notch.
    func testDecreaseByIsAStep() throws {
        let proposal = try XCTUnwrap(propose("okay decrease the music by 10", volume: 0.6))
        XCTAssertEqual(proposal.effect, .setVolume(0.5))
    }

    func testIncreaseByGoesTheOtherWay() throws {
        XCTAssertEqual(try XCTUnwrap(propose("increase the volume by 20", volume: 0.3)).effect,
                       .setVolume(0.5))
    }

    /// "to" is a destination and "by" is a step. Same number, same verb, and
    /// the difference must survive.
    func testToAndByFromTheSameNumberDiffer() throws {
        XCTAssertEqual(try XCTUnwrap(propose("lower the volume to 20", volume: 0.6)).effect,
                       .setVolume(0.2))
        XCTAssertEqual(try XCTUnwrap(propose("lower the volume by 20", volume: 0.6)).effect,
                       .setVolume(0.4))
    }

    /// A step needs a direction, and only the verb has one — the captured words
    /// are identical either way. "Set … by 10" means nothing, so it proposes
    /// nothing rather than guessing a sign.
    func testAStepWithNoDirectionProposesNothing() {
        XCTAssertNil(propose("set the volume by 10", volume: 0.5))
    }

    func testStepsClamp() throws {
        XCTAssertEqual(try XCTUnwrap(propose("decrease the volume by 40", volume: 0.1)).effect,
                       .setVolume(0))
        XCTAssertEqual(try XCTUnwrap(propose("increase the volume by 40", volume: 0.9)).effect,
                       .setVolume(1))
    }

    /// "music" is a word three actions want. Volume takes it only when a level
    /// comes with it; everything else still falls through.
    func testMusicReachesVolumeOnlyWithALevel() throws {
        XCTAssertEqual(try XCTUnwrap(propose("turn the music down", volume: 0.5)).toolName,
                       "Voice.Volume")
        XCTAssertEqual(try XCTUnwrap(propose("pause the music")).toolName, "Voice.Media")
    }

    // MARK: - Not volume

    /// The collision that made fall-through necessary: this shares the verb,
    /// the object and the preposition, and must still reach the audio action.
    func testMovingSoundToADeviceStillReachesTheAudioAction() throws {
        let proposal = try XCTUnwrap(propose("change the sound to the airpods"))
        XCTAssertEqual(proposal.toolName, "Voice.AudioOutput")
        XCTAssertEqual(proposal.subject, "AirPods Pro")
    }

    func testAnOutOfRangeNumberProposesNothing() {
        XCTAssertNil(propose("set the volume to 400"))
    }

    func testAPhraseWithNoLevelProposesNothing() {
        XCTAssertNil(propose("set the volume to the thing", volume: nil))
    }

    /// Questions, against a catalogue that now owns the word "volume".
    func testTheQuestionsStillHoldFire() {
        let offering = VoiceActionCatalog.offered(shortcuts: true)
        for testCase in ActionEvaluation.cases where testCase.toolName == nil {
            XCTAssertNil(VoiceGrammar.candidates(testCase.spoken, offering: offering).first
                            .flatMap { VoiceActionCatalog.propose(actionNamed: $0.name,
                                                                  arguments: $0.arguments,
                                                                  in: ActionEvaluation.context,
                                                                  offering: offering) },
                         "acted on a question: \(testCase.spoken)")
        }
        for testCase in PromptEvaluation.cases {
            XCTAssertNil(VoiceActionCatalog.resolve(spoken: testCase.question,
                                                    in: ActionEvaluation.context,
                                                    offering: offering),
                         "claimed a question: \(testCase.question)")
        }
    }
}
