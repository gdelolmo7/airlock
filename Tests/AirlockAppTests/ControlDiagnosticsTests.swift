import XCTest
@testable import AirlockApp

/// What a rail press writes down — see `ControlDiagnostics`.
///
/// Only the sentences are tested here, and deliberately: pressing a control for
/// real would take a screenshot of whoever is running the tests, or put their
/// display to sleep. What can be checked without touching the Mac is that each
/// outcome is written in the form somebody can act on — a system code as the
/// system prints it — and that a file the user made is never named.
@MainActor
final class ControlDiagnosticsTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    func testALineNamesTheControlAndWhatHappened() {
        let line = ControlDiagnostics.line(.sleepDisplay, "launched /usr/bin/pmset displaysleepnow", at: at)
        XCTAssertTrue(line.contains("sleepDisplay"), line)
        XCTAssertTrue(line.contains("/usr/bin/pmset displaysleepnow"), line)
        XCTAssertTrue(line.hasSuffix("\n"), "one press, one line")
    }

    /// The whole point of writing the code down is that it can be looked up,
    /// so it is written the way the system prints it rather than summarised.
    func testAnIOReturnIsWrittenAsTheSystemPrintsIt() {
        XCTAssertEqual(ControlDiagnostics.describe(ioReturn: kIOReturnSuccess), "kIOReturnSuccess")
        let refused = ControlDiagnostics.describe(ioReturn: Int32(bitPattern: 0xe00002e2))
        XCTAssertEqual(refused, "failed, 0xe00002e2")
    }

    /// A screenshot the user cancelled exits non-zero, and so does one macOS
    /// refused; a tool that was killed did neither. The log keeps them apart.
    func testAToolThatWasKilledIsNotAToolThatExited() {
        XCTAssertEqual(ControlDiagnostics.describe(exitStatus: 0, wasSignalled: false), "exited 0")
        XCTAssertEqual(ControlDiagnostics.describe(exitStatus: 1, wasSignalled: false), "exited 1")
        XCTAssertEqual(ControlDiagnostics.describe(exitStatus: 9, wasSignalled: true), "killed by signal 9")
    }

    /// Where it went and what kind of file it was, never which file: the name
    /// is a timestamp of something the user made, and a diagnostic has no use
    /// for it.
    func testTheDestinationKeepsTheFolderAndTheKindButNotTheName() {
        let spoken = ControlDiagnostics.destination("/Users/someone/Desktop/Screenshot 2026-08-18 at 16.42.10.png")
        XCTAssertEqual(spoken, "~/Desktop/*.png")
        XCTAssertFalse(spoken.contains("someone"))
        XCTAssertFalse(spoken.contains("2026"))
        XCTAssertEqual(ControlDiagnostics.destination("/Users/someone/Movies/Recording 1.mov"),
                       "~/Movies/*.mov", "the folder is read, not assumed")
    }

    /// -1743 is the refusal that means a permission is missing rather than a
    /// script being wrong, and it is the only one the log names — the same
    /// distinction the rail's own message makes.
    func testARefusedAppearanceScriptNamesAutomation() {
        XCTAssertEqual(ControlDiagnostics.describe(appleScript: .ok(nil)), "ok")
        let refused = ControlDiagnostics.describe(appleScript: .failed(code: AppleScriptClient.notPermitted))
        XCTAssertTrue(refused.contains("-1743"), refused)
        XCTAssertTrue(refused.contains("Automation"), refused)
        let other = ControlDiagnostics.describe(appleScript: .failed(code: -128))
        XCTAssertTrue(other.contains("-128"), other)
        XCTAssertFalse(other.contains("Automation"), "not every refusal is a permission")
    }
}
