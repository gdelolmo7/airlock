import XCTest
@testable import AirlockCore

final class NotesPlaceTests: XCTestCase {
    private let on = CallNotesOffers.Online(exists: true, settingOn: true, blocked: false)

    func testAPlanThatWritesOnlineSaysOnline() {
        XCTAssertEqual(NotesPlace.of(online: on, planWritesOnline: true, availability: .ready),
                       .online(macFallback: true))
        // No Apple Intelligence to fall back on: they wait to be online.
        XCTAssertEqual(NotesPlace.of(online: on, planWritesOnline: true, availability: .deviceNotEligible),
                       .online(macFallback: false))
        XCTAssertFalse(NotesPlace.online(macFallback: true).offerLine.contains("on this Mac"))
    }

    func testFreeWritesOnTheMac() {
        XCTAssertEqual(NotesPlace.of(online: on, planWritesOnline: false, availability: .ready), .mac)
        XCTAssertEqual(NotesPlace.mac.offerLine, "Words only, written on this Mac. No audio is kept.")
        XCTAssertEqual(NotesPlace.mac.settingsLine, "Written on your Mac")
    }

    func testSwitchedOffOrUsedUpWritesOnTheMac() {
        let off = CallNotesOffers.Online(exists: true, settingOn: false, blocked: false)
        XCTAssertEqual(NotesPlace.of(online: off, planWritesOnline: true, availability: .ready), .mac)
        let usedUp = CallNotesOffers.Online(exists: true, settingOn: true, blocked: true)
        XCTAssertEqual(NotesPlace.of(online: usedUp, planWritesOnline: true, availability: .ready), .mac)
        XCTAssertEqual(NotesPlace.of(online: .none, planWritesOnline: true, availability: .ready), .mac)
    }

    func testAppleIntelligenceOffSaysToTurnItOn() {
        let place = NotesPlace.of(online: on, planWritesOnline: false, availability: .needsAppleIntelligence)
        XCTAssertEqual(place, .needsAppleIntelligence)
        XCTAssertTrue(place.offerLine.contains("Turn on Apple Intelligence"))
        XCTAssertTrue(place.settingsLine.contains("Apple Intelligence"))
    }

    func testAMacThatCantWriteNotesNeverPromisesThem() {
        let free = NotesPlace.of(online: on, planWritesOnline: false, availability: .deviceNotEligible)
        XCTAssertEqual(free, .transcriptOnly(.upgrade))
        XCTAssertTrue(free.offerLine.contains("Plus also writes notes"))

        let off = CallNotesOffers.Online(exists: true, settingOn: false, blocked: false)
        XCTAssertEqual(NotesPlace.of(online: off, planWritesOnline: true, availability: .deviceNotEligible),
                       .transcriptOnly(.switchOn))
        // No online notes in this copy: nothing to sell or switch on.
        XCTAssertEqual(NotesPlace.of(online: .none, planWritesOnline: false, availability: .deviceNotEligible),
                       .transcriptOnly(.none))

        for place: NotesPlace in [.transcriptOnly(.none), .transcriptOnly(.upgrade), .transcriptOnly(.switchOn),
                                  .needsAppleIntelligence] {
            XCTAssertFalse(place.offerLine.contains("written on this Mac"), "\(place)")
            XCTAssertFalse(place.settingsLine.contains("Written on your Mac"), "\(place)")
        }
    }

    func testAModelStillDownloadingStaysOnTheMac() {
        XCTAssertEqual(NotesPlace.of(online: on, planWritesOnline: false, availability: .modelNotReady), .mac)
        XCTAssertEqual(NotesPlace.of(online: on, planWritesOnline: false, availability: .unknown("new")), .mac)
    }

    func testEveryStopSaysWhatToDoNext() {
        for reason in [CallLive.Stopped.noFolder, CallLive.Stopped.noSpeechModel] {
            XCTAssertTrue(reason.hasSuffix("then take notes again."), reason)
        }
        XCTAssertTrue(CallLive.Stopped.notSaved.contains("kept in Calls"))
    }
}
