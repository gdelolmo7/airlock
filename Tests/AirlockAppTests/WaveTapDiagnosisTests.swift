import XCTest
@testable import AirlockApp

/// The wave had one explanation for two failures, and it was the wrong one half
/// the time: a tap that never received a single buffer was reported as "reading
/// silence — macOS most likely denied audio capture", which sends somebody to a
/// permission that is already granted.
///
/// The second cause was measured rather than guessed. When the tapped player is
/// producing nothing — stranded on an output device it can no longer reach —
/// `AudioHardwareCreateProcessTap`, the aggregate device,
/// `AudioDeviceCreateIOProcIDWithBlock` and `AudioDeviceStart` all return
/// `noErr`, the tap reports a correct 48kHz/2ch format, and then zero callbacks
/// arrive, indefinitely. A denied permission looks nothing like it: the callbacks
/// DO arrive, roughly ninety a second, carrying only zeroes.
///
/// So `fired` is the whole discriminator, and these tests pin it. They are cheap
/// because the rule is pure; the tap itself has no test coverage available at
/// all, since there is no IOProc in a test process.
final class WaveTapDiagnosisTests: XCTestCase {

    func testAudioArrivingBeatsEverythingElse() {
        // Heard audio wins even before the settle window, and even if `fired`
        // were somehow false — bands cannot be non-zero without buffers, so the
        // ordering here is about not letting a timer contradict evidence.
        XCTAssertEqual(.following,
                       WaveTapDiagnosis.of(heardAudio: true, fired: true, settled: false))
        XCTAssertEqual(.following,
                       WaveTapDiagnosis.of(heardAudio: true, fired: true, settled: true))
    }

    func testSilenceIsNotJudgedBeforeTheTapHasSettled() {
        // The window between "the player says it is playing" and the first
        // buffer is real. A verdict inside it is a race with the audio thread,
        // and both verdicts would be wrong.
        XCTAssertEqual(.starting,
                       WaveTapDiagnosis.of(heardAudio: false, fired: false, settled: false))
        XCTAssertEqual(.starting,
                       WaveTapDiagnosis.of(heardAudio: false, fired: true, settled: false))
    }

    func testCallbacksCarryingSilenceMeanCaptureWasDenied() {
        XCTAssertEqual(.deniedCapture,
                       WaveTapDiagnosis.of(heardAudio: false, fired: true, settled: true))
    }

    func testNoCallbacksAtAllIsNotAPermissionProblem() {
        XCTAssertEqual(.neverDelivered,
                       WaveTapDiagnosis.of(heardAudio: false, fired: false, settled: true))
    }

    /// The regression this whole type exists for. Whatever the wording becomes,
    /// the two silent failures must never be given the same explanation, and the
    /// one that is NOT about permissions must not mention granting one.
    func testTheTwoSilentFailuresGiveDifferentAdvice() {
        let denied = WaveTapDiagnosis.deniedCapture.message(player: "Spotify")
        let never = WaveTapDiagnosis.neverDelivered.message(player: "Spotify")

        XCTAssertNotEqual(denied, never)
        XCTAssertTrue(denied.contains("Privacy & Security"),
                      "the permission failure is the one that should point at permissions")
        XCTAssertFalse(never.localizedCaseInsensitiveContains("permission"),
                       "a player producing no audio is not a permission problem, and saying "
                       + "so sends people to a setting that is already correct")
        XCTAssertTrue(never.localizedCaseInsensitiveContains("output device"),
                      "the actionable part is the routing, not the permission")
    }

    /// Both silent failures have to LOOK like failures. They render with the
    /// same icon and colour as "Following Spotify." until something says they
    /// are problems, because neither sets `tapFailure` — the tap started fine.
    func testBothSilentFailuresReadAsProblemsAndProgressDoesNot() {
        XCTAssertTrue(WaveTapDiagnosis.deniedCapture.isProblem)
        XCTAssertTrue(WaveTapDiagnosis.neverDelivered.isProblem)
        XCTAssertFalse(WaveTapDiagnosis.following.isProblem)
        XCTAssertFalse(WaveTapDiagnosis.starting.isProblem,
                       "a tap that has not settled yet is not a problem, it is a wait")
    }

    /// Every message names the player. "Following the audio" was useless the one
    /// time it mattered — macOS asked to record Apple Music while Spotify was
    /// playing, and nothing in the app could say which process it had tapped.
    func testEveryMessageNamesThePlayer() {
        for diagnosis: WaveTapDiagnosis in [.following, .starting, .deniedCapture, .neverDelivered] {
            XCTAssertTrue(diagnosis.message(player: "Apple Music").contains("Apple Music"),
                          "\(diagnosis) dropped the player name")
        }
    }

    /// The audio path's words stay in the audio path. "Tapped Spotify but every
    /// buffer is silent" was accurate and meant nothing to the person reading it.
    func testNoMessageUsesTheAudioPathsWords() {
        for diagnosis: WaveTapDiagnosis in [.following, .starting, .deniedCapture, .neverDelivered] {
            let message = diagnosis.message(player: "Spotify")
            for word in ["tapped", "buffer"] {
                XCTAssertFalse(message.localizedCaseInsensitiveContains(word), "\(diagnosis) says \"\(word)\"")
            }
        }
        XCTAssertFalse(MediaWidgetModel.tapRefused.localizedCaseInsensitiveContains("capture"))
    }

    /// Only the denied case gets the button to the permission: the other
    /// silent failure is the player's, and that page has nothing to change.
    func testOnlyTheDeniedCaseOffersThePermission() {
        XCTAssertTrue(WaveTapDiagnosis.deniedCapture.needsPermission)
        for diagnosis: WaveTapDiagnosis in [.following, .starting, .neverDelivered] {
            XCTAssertFalse(diagnosis.needsPermission, "\(diagnosis)")
        }
    }
}
