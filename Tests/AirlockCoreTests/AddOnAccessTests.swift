import XCTest
@testable import AirlockCore

final class AddOnAccessTests: XCTestCase {
    // MARK: - What each add-on needs

    func testWhatEachAddOnNeeds() {
        XCTAssertEqual(AddOn.shelf.needs, [])
        XCTAssertEqual(AddOn.clipboard.needs, [])
        XCTAssertEqual(AddOn.codingAgents.needs, [])
        XCTAssertEqual(AddOn.meetingNotes.needs, [.microphone, .systemAudio])
        XCTAssertEqual(AddOn.windowLayouts.needs, [.accessibility])
        XCTAssertEqual(AddOn.dictation.needs, [.microphone, .inputMonitoring, .accessibility])
    }

    /// Its question sends the person to System Settings, so nothing may be
    /// asked after it.
    func testAccessibilityIsAlwaysAskedLast() {
        for addOn in AddOn.allCases where addOn.needs.contains(.accessibility) {
            XCTAssertEqual(addOn.needs.last, .accessibility, "\(addOn)")
        }
    }

    /// The card's small print and the note on Add must say the same thing:
    /// one that needs something names it, one that needs nothing says so.
    func testTheCardNamesWhatAddingAsks() {
        for addOn in AddOn.allCases {
            if addOn.needs.isEmpty {
                XCTAssertTrue(addOn.asks.hasPrefix("Asks for nothing"), "\(addOn)")
                XCTAssertNil(addOn.needsBecause, "\(addOn)")
            } else {
                XCTAssertNotNil(addOn.needsBecause, "\(addOn)")
            }
        }
        XCTAssertTrue(AddOn.dictation.asks.contains("Input Monitoring"))
        XCTAssertTrue(AddOn.dictation.asks.contains("Accessibility"))
        XCTAssertTrue(AddOn.windowLayouts.asks.contains("Accessibility"))
        XCTAssertTrue(AddOn.meetingNotes.asks.contains("system audio"))
    }

    func testOnlySystemAudioCannotBeAskedAhead() {
        XCTAssertEqual(MacAccess.allCases.filter { !$0.canBeAskedAhead }, [.systemAudio])
    }

    // MARK: - The added row's check

    private func check(_ addOn: AddOn, _ states: [MacAccess: MacAccessState]) -> AddOnAccessCheck {
        AddOnAccessCheck.check(addOn) { states[$0] ?? .allowed }
    }

    func testNothingNeededIsAlwaysComplete() {
        for addOn in [AddOn.shelf, .clipboard, .codingAgents] {
            let result = AddOnAccessCheck.check(addOn) { _ in .notAllowed }
            XCTAssertTrue(result.isComplete, "\(addOn)")
            XCTAssertNil(result.sentence(for: addOn))
            XCTAssertNil(result.buttonTitle)
        }
    }

    func testEverythingAllowedSaysNothing() {
        let result = check(.dictation, [:])
        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.sentence(for: .dictation))
    }

    /// Saying no keeps the add-on added; the row names what is missing and
    /// offers the way back.
    func testARefusedAccessibilityAsksAgain() {
        let result = check(.windowLayouts, [.accessibility: .notAllowed])
        XCTAssertEqual(result.missing, [.accessibility])
        XCTAssertEqual(result.remedy, .askAgain)
        XCTAssertEqual(result.buttonTitle, "Try again")
        XCTAssertEqual(result.sentence(for: .windowLayouts), "Not working yet. Still to allow: Accessibility.")
    }

    func testANeverAskedMicrophoneAsks() {
        XCTAssertEqual(check(.dictation, [.microphone: .notAsked]).remedy, .askAgain)
    }

    func testARefusedMicrophoneOpensSystemSettings() {
        let result = check(.dictation, [.microphone: .notAllowed])
        XCTAssertEqual(result.remedy, .openSystemSettings)
        XCTAssertEqual(result.buttonTitle, "Open System Settings")
    }

    func testAnOldApprovalIsFixedInSystemSettings() {
        XCTAssertEqual(check(.dictation, [.inputMonitoring: .notWorking]).remedy, .openSystemSettings)
    }

    func testRestrictedHasNoButton() {
        let result = check(.windowLayouts, [.accessibility: .restricted])
        XCTAssertEqual(result.remedy, .none)
        XCTAssertNil(result.buttonTitle)
        XCTAssertTrue(result.sentence(for: .windowLayouts)?.contains("administrator") == true)
    }

    /// Every missing one is named, in asking order; the button is about the first.
    func testSeveralMissingAreAllNamed() {
        let result = check(.dictation, [.inputMonitoring: .notAllowed, .accessibility: .notAllowed])
        XCTAssertEqual(result.missing, [.inputMonitoring, .accessibility])
        XCTAssertEqual(result.sentence(for: .dictation),
                       "Not working yet. Still to allow: Input Monitoring and Accessibility.")
    }

    /// System audio is asked on the first call. Before then nothing has said
    /// no, so it is not counted missing; after a refused call it is.
    func testSystemAudioCountsOnlyOnceACallHasFoundIt() {
        XCTAssertTrue(check(.meetingNotes, [.systemAudio: .asksOnFirstUse]).isComplete)
        let refused = check(.meetingNotes, [.systemAudio: .notAllowed])
        XCTAssertEqual(refused.missing, [.systemAudio])
        XCTAssertEqual(refused.remedy, .openSystemSettings)
    }
}
