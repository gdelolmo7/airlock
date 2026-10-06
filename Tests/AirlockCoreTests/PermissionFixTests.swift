import XCTest
@testable import AirlockCore

final class PermissionFixTests: XCTestCase {
    /// The wrong service name resets a grant that was working.
    func testEachResetNamesItsOwnService() {
        let expected: [PermissionKind: String] = [
            .screenRecording: "tccutil reset ScreenCapture com.airlock.app",
            .accessibility: "tccutil reset Accessibility com.airlock.app",
            .inputMonitoring: "tccutil reset ListenEvent com.airlock.app",
            .microphone: "tccutil reset Microphone com.airlock.app",
            .calendar: "tccutil reset Calendar com.airlock.app",
        ]
        for kind in PermissionKind.allCases {
            XCTAssertEqual(kind.resetCommand(bundleIdentifier: "com.airlock.app"), expected[kind])
        }
    }

    /// The Input Monitoring command is the one Settings has shown since it
    /// was found: the two must not drift apart.
    func testInputMonitoringMatchesTheKnownFix() {
        XCTAssertEqual(PermissionKind.inputMonitoring.resetCommand(bundleIdentifier: "x"), "tccutil reset ListenEvent x")
    }

    func testOnlyTheMacWideRecordsAskForAPassword() {
        XCTAssertEqual(PermissionKind.allCases.filter(\.needsAdministrator), [.screenRecording, .accessibility])
        XCTAssertTrue(PermissionKind.accessibility.fixExplanation.contains("password"))
        XCTAssertFalse(PermissionKind.microphone.fixExplanation.contains("password"))
    }

    func testEveryPermissionOpensItsOwnPage() {
        for kind in PermissionKind.allCases {
            XCTAssertEqual(kind.settingsURL?.absoluteString,
                           "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)")
        }
        XCTAssertEqual(Set(PermissionKind.allCases.map(\.settingsAnchor)).count, PermissionKind.allCases.count)
    }

    func testOnlyScreenRecordingNeedsAReopen() {
        XCTAssertEqual(PermissionKind.allCases.filter(\.needsReopen), [.screenRecording])
        XCTAssertTrue(PermissionKind.screenRecording.afterFix.contains("Quit & Reopen"))
    }

    /// A "no" to a dialog is cleared so the dialog can come back; the others
    /// are switched on in System Settings.
    func testTheDialogPermissionsAskAgainInsteadOfOpeningSettings() {
        XCTAssertEqual(PermissionKind.allCases.filter(\.asksWithADialog), [.microphone, .calendar])
        XCTAssertTrue(PermissionKind.calendar.afterFix.contains("Press Allow"))
        XCTAssertTrue(PermissionKind.accessibility.afterFix.contains("switch Airlock on again"))
    }

    /// One name for "allow this" across Settings: the buttons say Allow, so
    /// the sentences do too (X36).
    func testNoSentenceSaysGrant() {
        for kind in PermissionKind.allCases {
            for text in [kind.fixQuestion, kind.fixExplanation, kind.afterFix,
                         kind.oldApprovalSentence, kind.oldApprovalSteps] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains("grant"), "\(kind): \(text)")
            }
        }
    }

    /// The known old approval says what it is and what to do, and never
    /// sends anyone to Terminal (X34).
    func testTheOldApprovalIsPlainWordsWithNoCommand() {
        let kind = PermissionKind.inputMonitoring
        XCTAssertTrue(kind.oldApprovalSentence.contains("old approval from an earlier version of Airlock"))
        XCTAssertTrue(kind.oldApprovalSteps.contains("remove it with –"))
        XCTAssertTrue(kind.oldApprovalSteps.contains("add it back with +"))
        for text in [kind.oldApprovalSentence, kind.oldApprovalSteps] {
            XCTAssertFalse(text.contains("tccutil"))
            XCTAssertFalse(text.contains("Terminal"))
        }
    }
}
