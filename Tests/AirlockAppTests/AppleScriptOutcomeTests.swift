import XCTest
@testable import AirlockApp

/// Telling "was refused" apart from "worked, said nothing".
///
/// **`run` cannot, and a caller that guessed instead is the bug this file was
/// written for.** It returns `String?`, so a script that TCC refused and a
/// script that succeeded without a result both come back nil. The appearance
/// toggle needed the difference, could not get it here, and inferred it by
/// re-reading `NSApp.effectiveAppearance` after the script — which AppKit
/// updates a run loop or two after the system setting actually changes. Every
/// press that worked therefore read the OLD appearance and reported a missing
/// Automation permission; the press after it came back clean, because by then
/// AppKit had caught up.
///
/// These scripts are all local — no application is told anything, so nothing
/// here needs Automation and nothing prompts.
final class AppleScriptOutcomeTests: XCTestCase {

    func testAScriptThatRunsReportsItsResult() async {
        let outcome = await AppleScriptClient.perform("1 + 1")
        XCTAssertEqual(outcome, .ok("2"))
    }

    /// The half `run` erases. A command with nothing to return is a SUCCESS,
    /// and must not be mistaken for a refusal by anyone deciding whether to
    /// blame a permission.
    func testAScriptWithNothingToReturnStillSucceeds() async {
        let outcome = await AppleScriptClient.perform("set _x to 1\nreturn")
        XCTAssertEqual(outcome, .ok(nil), "no result is not a failure")
        XCTAssertFalse(outcome.isNotPermitted)
        // ...and this is precisely why `run` could not be used to decide:
        // indistinguishable from the refusal below.
        let quiet = await AppleScriptClient.run("set _x to 1\nreturn")
        XCTAssertNil(quiet)
    }

    /// -1743 is `errAEEventNotPermitted` — the refusal that means "the user has
    /// not allowed Airlock to control this app", and the only one worth naming
    /// a permission for in the UI.
    func testARefusedScriptReportsThatItWasNotPermitted() async {
        let outcome = await AppleScriptClient.perform("error number -1743")
        XCTAssertEqual(outcome, .failed(code: AppleScriptClient.notPermitted))
        XCTAssertTrue(outcome.isNotPermitted)
        let refused = await AppleScriptClient.run("error number -1743")
        XCTAssertNil(refused, "same nil as the success above — which is the whole problem")
    }

    /// Any other refusal is still a failure, but not a permission problem —
    /// telling the user to grant something they have already granted is worse
    /// than saying macOS refused.
    func testAnUnrelatedFailureIsNotAPermissionProblem() async {
        let outcome = await AppleScriptClient.perform("error number -128")
        XCTAssertEqual(outcome, .failed(code: -128))
        XCTAssertFalse(outcome.isNotPermitted)
    }

    /// A source that will not compile used to come back as nil from `run`,
    /// which reads as "worked, said nothing".
    func testAMalformedScriptIsAFailureRatherThanSilence() async {
        let outcome = await AppleScriptClient.perform("tell tell tell")
        XCTAssertFalse(outcome.isNotPermitted)
        guard case .failed = outcome else {
            return XCTFail("a script that cannot compile is not a success: \(outcome)")
        }
    }
}
