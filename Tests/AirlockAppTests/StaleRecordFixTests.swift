import XCTest
@testable import AirlockApp
@testable import AirlockCore

/// The one remedy the app cannot perform for you, so it has to get right.
///
/// When Input Monitoring reads as allowed and the taps are still dead, the
/// record is pinned to a certificate the installed app no longer carries and
/// nothing in System Settings can fix it — there is usually not even a row to
/// remove, because an app with no ListenEvent record of its own falls back to
/// its Accessibility grant and so never appears in that pane. What is left is a
/// command the user pastes into a terminal on our say-so, which is a high bar
/// for a string to meet.
@MainActor
final class StaleRecordFixTests: XCTestCase {

    /// **`Accessibility` here would break the thing they came to fix.** With no
    /// ListenEvent record, event tapping falls back to the Accessibility grant
    /// — so resetting *that* one takes away the permission doing the work, and
    /// the user is worse off for having followed our advice.
    func testItResetsListenEventAndNotAccessibility() {
        let command = InputMonitoring.staleRecordFix(bundleIdentifier: "com.airlock.app")
        XCTAssertEqual(command, "tccutil reset ListenEvent com.airlock.app")
        XCTAssertFalse(command.contains("Accessibility"),
                       "resetting Accessibility would revoke the grant that makes taps work")
    }

    /// Named from the running bundle, so a build under another identifier prints
    /// a command that works on that build rather than quietly resetting a
    /// different app's permissions.
    func testItNamesTheBundleItIsTold() {
        XCTAssertEqual(InputMonitoring.staleRecordFix(bundleIdentifier: "com.airlock.app.langtest"),
                       "tccutil reset ListenEvent com.airlock.app.langtest")
    }

    /// No `sudo`, and nothing recursive. `tccutil reset <service> <bundle>`
    /// touches one app's record for one service; the two-argument form is what
    /// keeps it that narrow, and dropping the bundle id resets the service for
    /// EVERY app on the Mac.
    func testItIsScopedToOneAppAndNeedsNoPassword() {
        let command = InputMonitoring.staleRecordFix(bundleIdentifier: "com.airlock.app")
        XCTAssertFalse(command.contains("sudo"), "this must not need their password")
        XCTAssertEqual(command.split(separator: " ").count, 4,
                       "tccutil reset ListenEvent <bundle> — a missing bundle id would reset "
                       + "event listening for every app on the Mac")
    }

    /// The fault this remedy belongs to, so the two cannot drift apart: advice
    /// about a stale record must only ever be shown for the stale-record case.
    func testTheRemedyBelongsToTheGrantedButDeadFault() {
        let dead = EventTapHealth.inert(isEnabled: false, missingEvents: 0x400)
        XCTAssertEqual(EventTapCheck.fault(health: dead, isListenEventGranted: true),
                       .grantIsNotWorking)
        XCTAssertEqual(EventTapCheck.fault(health: dead, isListenEventGranted: false),
                       .notGranted,
                       "somebody who has never granted it needs the prompt, not a terminal")
    }
}
