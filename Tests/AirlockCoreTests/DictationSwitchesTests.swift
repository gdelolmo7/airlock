import XCTest
@testable import AirlockCore

/// The walk setup shows for hold to talk: one switch at a time, in the order
/// the feature fails in, ticking itself as each comes on.
final class DictationSwitchesTests: XCTestCase {
    private func switches(_ microphone: DictationSwitches.Microphone = .notAsked,
                          keyNoticed: Bool = false, canType: Bool = false) -> DictationSwitches {
        DictationSwitches(microphone: microphone, keyNoticed: keyNoticed, canType: canType)
    }

    func testTheStepsComeInTheOrderTheFeatureFailsIn() {
        XCTAssertEqual(switches().current, .microphone)
        XCTAssertEqual(switches(.allowed).current, .inputMonitoring)
        XCTAssertEqual(switches(.allowed, keyNoticed: true).current, .accessibility)
        XCTAssertNil(switches(.allowed, keyNoticed: true, canType: true).current)
    }

    /// A later switch already on never pulls the walk ahead: skipping forward
    /// and coming back reads as the app changing its mind.
    func testALaterSwitchAlreadyOnDoesNotSkipAhead() {
        XCTAssertEqual(switches(.notAsked, keyNoticed: true, canType: true).current, .microphone)
        XCTAssertEqual(switches(.allowed, keyNoticed: false, canType: true).current, .inputMonitoring)
    }

    func testProgressCountsFromOneAndEndsReady() {
        XCTAssertEqual(switches().progress, "1 of 3")
        XCTAssertEqual(switches(.allowed).progress, "2 of 3")
        XCTAssertEqual(switches(.allowed, keyNoticed: true).progress, "3 of 3")
        let done = switches(.allowed, keyNoticed: true, canType: true)
        XCTAssertTrue(done.isDone)
        XCTAssertEqual(done.progress, "Ready")
        XCTAssertEqual(done.position, done.count)
    }

    func testOnlyTheSwitchesAndARefusedMicrophoneOpenAList() {
        XCTAssertFalse(switches().opensList)
        XCTAssertTrue(switches(.refused).opensList)
        XCTAssertTrue(switches(.allowed).opensList)
        XCTAssertTrue(switches(.allowed, keyNoticed: true).opensList)
        XCTAssertFalse(switches(.allowed, keyNoticed: true, canType: true).opensList)
    }

    func testTheStepLabelNamesTheListThatOpens() {
        XCTAssertEqual(switches().stepLabel, "1 of 3 · Microphone")
        XCTAssertEqual(switches(.allowed).stepLabel, "2 of 3 · Input Monitoring")
        XCTAssertEqual(switches(.allowed, keyNoticed: true).stepLabel, "3 of 3 · Accessibility")
        XCTAssertNil(switches(.allowed, keyNoticed: true, canType: true).stepLabel)
    }

    /// The microphone is a real question, so its button asks; the two
    /// switches cannot be allowed from a button, so theirs never says Allow.
    func testButtonsSayWhatTheyDo() {
        XCTAssertEqual(switches().button, "Ask macOS")
        XCTAssertEqual(switches(.refused).button, "Open the list")
        XCTAssertEqual(switches(.allowed).button, "Open the list")
        XCTAssertEqual(switches(.allowed, keyNoticed: true).button, "Open the list")
        XCTAssertNil(switches(.allowed, keyNoticed: true, canType: true).button)
        for microphone in [DictationSwitches.Microphone.notAsked, .allowed, .refused, .blocked] {
            for keyNoticed in [false, true] {
                for canType in [false, true] {
                    let walk = switches(microphone, keyNoticed: keyNoticed, canType: canType)
                    XCTAssertNotEqual(walk.button, "Allow", "\(walk)")
                }
            }
        }
    }

    /// macOS never asks about the microphone twice, so a refusal is a switch
    /// like the other two.
    func testARefusedMicrophoneIsASwitch() {
        let walk = switches(.refused, keyNoticed: true, canType: true)
        XCTAssertEqual(walk.current, .microphone)
        XCTAssertEqual(walk.instruction(key: "⌃ Control"),
                       "The microphone is off for Airlock. Switch Airlock on in the list that opens.")
    }

    func testEachInstructionSaysWhatToDoThere() {
        let key = "⌃ Control"
        XCTAssertEqual(switches().instruction(key: key), "macOS asks once if Airlock may hear you. Say Allow.")
        XCTAssertTrue(switches(.allowed).instruction(key: key).contains("holding ⌃ Control"))
        XCTAssertTrue(switches(.allowed).instruction(key: key).contains("not what you type"),
                      "Input Monitoring sounds like a keylogger; the step says it isn't one")
        XCTAssertTrue(switches(.allowed, keyNoticed: true).instruction(key: key).hasPrefix("Last one."))
        XCTAssertEqual(switches(.allowed, keyNoticed: true, canType: true).instruction(key: key),
                       "Hold ⌃ Control and talk. Let go, and your words are typed.")
        for walk in [switches(), switches(.refused), switches(.allowed), switches(.allowed, keyNoticed: true)] {
            let sentence = walk.instruction(key: key)
            XCTAssertTrue(sentence.hasSuffix("."), sentence)
            for word in ["TCC", "permission", "privileges", "`"] {
                XCTAssertFalse(sentence.contains(word), "\(walk.current!) says \"\(word)\": \(sentence)")
            }
        }
    }

    /// The step names match what System Settings calls each list, so the
    /// person can find the one that opened.
    func testNamesMatchSystemSettings() {
        XCTAssertEqual(DictationSwitches.name(.microphone), "Microphone")
        XCTAssertEqual(DictationSwitches.name(.inputMonitoring), "Input Monitoring")
        XCTAssertEqual(DictationSwitches.name(.accessibility), "Accessibility")
    }

    /// Input Monitoring that reads on but passes nothing gets the by-hand fix,
    /// not "switch it on": it already is, and the ask would open nothing.
    func testAnOldKeyApprovalSaysToAddAirlockBack() {
        let stale = DictationSwitches(microphone: .allowed, keyNoticed: false, canType: false,
                                      keyApprovalIsOld: true)
        XCTAssertEqual(stale.current, .inputMonitoring)
        XCTAssertTrue(stale.opensList)
        let sentence = stale.instruction(key: "⌃ Control")
        XCTAssertTrue(sentence.contains("remove Airlock"), sentence)
        XCTAssertFalse(sentence.hasPrefix("Switch Airlock on"), sentence)
        // Never once the key is noticed.
        XCTAssertFalse(DictationSwitches(microphone: .allowed, keyNoticed: true, canType: false,
                                         keyApprovalIsOld: true).keyApprovalIsOld)
    }

    /// Read from the same states the Permissions page shows, so setup and
    /// Settings agree. An old approval that no longer works is not noticed.
    func testReadFromThePermissionsPageStates() {
        let fresh = DictationSwitches(microphone: .asksOnFirstUse, inputMonitoring: .notAllowed,
                                      accessibility: .notAllowed)
        XCTAssertEqual(fresh, switches(.notAsked))
        let refused = DictationSwitches(microphone: .notAllowed, inputMonitoring: .notWorking,
                                        accessibility: .allowed)
        XCTAssertEqual(refused, DictationSwitches(microphone: .refused, keyNoticed: false, canType: true,
                                                  keyApprovalIsOld: true))
        let done = DictationSwitches(microphone: .allowed, inputMonitoring: .allowed,
                                     accessibility: .allowed)
        XCTAssertTrue(done.isDone)
    }

    /// A microphone turned off by whoever manages the Mac has a greyed-out
    /// switch, so the walk says who can change it and offers no button that
    /// would open a list where nothing can be done.
    func testAMicrophoneBlockedByTheMacsManagerHasNoButton() {
        let blocked = DictationSwitches(microphone: .restricted, inputMonitoring: .notAllowed,
                                        accessibility: .notAllowed)
        XCTAssertEqual(blocked.microphone, .blocked)
        XCTAssertEqual(blocked.current, .microphone)
        XCTAssertNil(blocked.button)
        XCTAssertFalse(blocked.opensList)
        let sentence = blocked.instruction(key: "⌃ Control")
        XCTAssertTrue(sentence.contains("manages this Mac"), sentence)
    }
}
