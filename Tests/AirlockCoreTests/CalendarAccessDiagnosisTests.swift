import XCTest
@testable import AirlockCore

final class CalendarAccessDiagnosisTests: XCTestCase {
    private func outcome(_ before: CalendarAuthorization,
                         _ after: CalendarAuthorization,
                         _ elapsed: TimeInterval) -> CalendarAccessOutcome {
        CalendarAccessDiagnosis.outcome(before: before, after: after, elapsed: elapsed)
    }

    // MARK: - The bug

    /// The failure this was written for: launched from a terminal (or a coding
    /// agent driving one), tccd refuses to prompt and answers denied in 16ms.
    func testInstantDenialFromUndeterminedMeansNoDialogWasShown() {
        XCTAssertEqual(outcome(.notDetermined, .denied, 0.016), .promptSuppressed)
    }

    /// And the whole point of separating it: System Settings has no row to
    /// change, because the app never got as far as asking.
    func testSuppressedPromptIsNotFixableInSystemSettings() {
        XCTAssertFalse(CalendarAccessOutcome.promptSuppressed.isFixableInSystemSettings)
        XCTAssertTrue(CalendarAccessOutcome.declined.isFixableInSystemSettings)
        XCTAssertTrue(CalendarAccessOutcome.standingDenial.isFixableInSystemSettings)
    }

    // MARK: - The dialog that did appear

    func testDenialAfterAPauseIsARealAnswer() {
        XCTAssertEqual(outcome(.notDetermined, .denied, 2.4), .declined,
                       "a human read the dialog and said no")
    }

    /// The threshold sits in empty space, but the boundary still has to land
    /// somewhere stated rather than implied.
    func testDialogFloorBoundary() {
        let floor = CalendarAccessDiagnosis.dialogFloor
        XCTAssertEqual(outcome(.notDetermined, .denied, floor - 0.001), .promptSuppressed)
        XCTAssertEqual(outcome(.notDetermined, .denied, floor), .declined)
    }

    // MARK: - Decisions already on file

    /// Denied before we asked: however fast this attempt came back, the record
    /// is the thing to change — so speed must not reroute the advice.
    func testAlreadyDeniedIsAStandingDenialAtAnySpeed() {
        XCTAssertEqual(outcome(.denied, .denied, 0.001), .standingDenial)
        XCTAssertEqual(outcome(.denied, .denied, 3.0), .standingDenial)
    }

    /// Restricted is an administrator's call and never involved a dialog, so it
    /// must not be read as a suppressed prompt and sent to a relaunch that
    /// cannot help.
    func testRestrictedIsNeverASuppressedPrompt() {
        XCTAssertEqual(outcome(.notDetermined, .restricted, 0.01), .standingDenial)
    }

    // MARK: - Granted, and everything else

    func testGrantedIgnoresTiming() {
        XCTAssertEqual(outcome(.notDetermined, .fullAccess, 0.01), .granted,
                       "an instant grant is a grant — a standing allowance answers at once")
        XCTAssertEqual(outcome(.notDetermined, .fullAccess, 4.0), .granted)
    }

    func testUndeterminedAndWriteOnlyAreInconclusive() {
        XCTAssertEqual(outcome(.notDetermined, .notDetermined, 0.01), .inconclusive)
        XCTAssertEqual(outcome(.notDetermined, .other, 0.01), .inconclusive)
    }
}
