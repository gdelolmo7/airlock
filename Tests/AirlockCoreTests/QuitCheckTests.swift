import CoreServices
import XCTest
@testable import AirlockCore

final class QuitCheckTests: XCTestCase {
    func testNotTakingNotesNeverAsks() {
        for reason in [QuitCheck.Reason.asked, .macEnding, .onPurpose] {
            XCTAssertFalse(QuitCheck.asks(takingNotes: false, reason: reason))
        }
    }

    func testAQuitDuringNotesAsks() {
        XCTAssertTrue(QuitCheck.asks(takingNotes: true, reason: .asked))
    }

    /// A question at log out holds up the whole Mac.
    func testTheMacEndingIsNeverHeldUp() {
        XCTAssertFalse(QuitCheck.asks(takingNotes: true, reason: .macEnding))
    }

    func testQuittingOnPurposeIsNeverHeldUp() {
        XCTAssertFalse(QuitCheck.asks(takingNotes: true, reason: .onPurpose))
    }

    // MARK: - Reading the reason

    /// ⌘Q has no event at all; the Dock's Quit and a script send one with
    /// no reason in it.
    func testNoReasonIsAPersonAsking() {
        XCTAssertEqual(QuitCheck.reason(quitReasonCode: nil, onPurpose: false), .asked)
        XCTAssertEqual(QuitCheck.reason(quitReasonCode: 0, onPurpose: false), .asked)
    }

    /// The codes are spelled out in Core, which cannot see the system's
    /// constants; this pins them to the real ones.
    func testEveryEndOfSessionCodeIsRecognised() {
        let system: [AEEventID] = [AEEventID(kAELogOut), AEEventID(kAEReallyLogOut),
                                   AEEventID(kAEShowRestartDialog), AEEventID(kAEShowShutdownDialog),
                                   AEEventID(kAERestart), AEEventID(kAEShutDown)]
        XCTAssertEqual(QuitCheck.macEndingCodes, Set(system))
        for code in system {
            XCTAssertEqual(QuitCheck.reason(quitReasonCode: code, onPurpose: false), .macEnding)
        }
    }

    func testAnUnknownCodeStillAsks() {
        XCTAssertEqual(QuitCheck.reason(quitReasonCode: QuitCheck.fourCharCode("quit"), onPurpose: false), .asked)
    }

    func testOnPurposeWinsOverAnyCode() {
        XCTAssertEqual(QuitCheck.reason(quitReasonCode: nil, onPurpose: true), .onPurpose)
        XCTAssertEqual(QuitCheck.reason(quitReasonCode: AEEventID(kAEShutDown), onPurpose: true), .onPurpose)
    }

    // MARK: - The words

    func testTheQuestionNamesWhatStops() {
        let call = QuitCheck.question(inPerson: false)
        XCTAssertEqual(call.title, "Airlock is taking notes")
        XCTAssertTrue(call.message.contains("this call"))
        XCTAssertTrue(call.message.contains("kept"))
        XCTAssertEqual(call.keep, "Keep taking notes")
        XCTAssertEqual(call.quit, "Quit anyway")
        XCTAssertTrue(QuitCheck.question(inPerson: true).message.contains("this meeting"))
    }
}
