import XCTest
@testable import AirlockCore

/// What to send the player, given that dictation may have moved it first.
final class MediaCommandPlanTests: XCTestCase {

    private func decide(_ command: VoiceMediaCommand, playing: Bool?,
                        dictationPaused: Bool = false) -> MediaCommandPlan.Action {
        MediaCommandPlan.decide(command: command, isPlaying: playing,
                                dictationPaused: dictationPaused)
    }

    // MARK: - The ordinary cases

    func testPauseWhilePlayingSends() {
        XCTAssertEqual(decide(.pause, playing: true), .toggle)
    }

    func testPlayWhilePausedSends() {
        XCTAssertEqual(decide(.play, playing: false), .toggle)
    }

    /// The player offers only a toggle, so sending one here would do the exact
    /// opposite of what the card said.
    func testAskingForWhatIsAlreadyHappeningSendsNothing() {
        XCTAssertEqual(decide(.play, playing: true), .alreadyThere)
        XCTAssertEqual(decide(.pause, playing: false), .alreadyThere)
    }

    // MARK: - After dictation has already paused it

    /// The case that reads as the command being ignored: dictation paused the
    /// track for the hold, so by the time "pause the music" is understood the
    /// player is already stopped. Sending a toggle would START it.
    func testPauseAfterDictationAlreadyPausedSendsNothing() {
        XCTAssertEqual(decide(.pause, playing: false, dictationPaused: true), .alreadyThere)
    }

    /// And the mirror: "play" while dictation has it paused must resume, which
    /// is a toggle — the user never saw it stop, so from their side this is the
    /// command working rather than an undo.
    func testPlayAfterDictationPausedResumes() {
        XCTAssertEqual(decide(.play, playing: false, dictationPaused: true), .toggle)
    }

    /// Skipping does not care who paused it or whether anything is playing.
    func testSkippingIsUnaffected() {
        for playing in [true, false] {
            for paused in [true, false] {
                XCTAssertEqual(decide(.next, playing: playing, dictationPaused: paused), .toggle)
                XCTAssertEqual(decide(.previous, playing: playing, dictationPaused: paused), .toggle)
            }
        }
    }

    // MARK: - No player

    /// `MediaWidgetModel.send` needs `state.player` to know which controller to
    /// talk to, so with no state there is no toggle to send and the card must
    /// say so rather than claim to have paused silence.
    func testNoPlayerIsReportedRatherThanClaimed() {
        for command: VoiceMediaCommand in [.play, .pause, .next, .previous] {
            XCTAssertEqual(decide(command, playing: nil), .noPlayer,
                           "\(command) claimed to work with no player")
        }
    }

    /// The end state is what matters, and it is right in every combination:
    /// after acting on the plan, the player is doing what was asked.
    func testEveryCombinationEndsInTheRequestedState() {
        for asked: VoiceMediaCommand in [.play, .pause] {
            for playing in [true, false] {
                for paused in [true, false] {
                    let action = decide(asked, playing: playing, dictationPaused: paused)
                    let ends = action == .toggle ? !playing : playing
                    XCTAssertEqual(ends, asked == .play,
                                   "\(asked) with playing=\(playing) paused=\(paused) "
                                   + "ended \(ends ? "playing" : "stopped")")
                }
            }
        }
    }
}
