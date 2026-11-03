import XCTest
@testable import AirlockApp

/// Your side is silent while you are muted, and, for notes taken by hand of
/// an app, while that app is not using the microphone at all.
final class CallMuteGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_468_600)
    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    func testNothingSeenSilencesNothing() {
        XCTAssertFalse(CallMuteGate().isMuted(at: now))
    }

    /// A webinar with your microphone off: what you say in the room is not
    /// the meeting, so it is silent from the very first look.
    func testAnAppOffTheMicrophoneSilencesYou() {
        let gate = CallMuteGate()
        gate.observeMicrophone(inUse: false, at: now)
        XCTAssertTrue(gate.isMuted(at: now))
        XCTAssertTrue(gate.isMuted(at: at(30)))
    }

    /// Unmuted to ask a question: heard from the look that saw it, silent
    /// again once the app lets go.
    func testTakingTheMicrophoneLetsYouIn() {
        let gate = CallMuteGate()
        gate.observeMicrophone(inUse: false, at: now)
        gate.observeMicrophone(inUse: true, at: at(10))
        XCTAssertTrue(gate.isMuted(at: at(9)))
        XCTAssertFalse(gate.isMuted(at: at(10)))
        gate.observeMicrophone(inUse: true, at: at(20))
        gate.observeMicrophone(inUse: false, at: at(21))
        XCTAssertTrue(gate.isMuted(at: at(20.5)), "dated back to the look before")
        XCTAssertTrue(gate.isMuted(at: at(25)))
    }

    /// On the microphone but muted with the app's own button: still silent.
    func testTheMuteButtonStillCounts() {
        let gate = CallMuteGate()
        gate.observeMicrophone(inUse: true, at: now)
        gate.observe(true, at: now)
        XCTAssertTrue(gate.isMuted(at: at(1)))
        gate.observe(false, at: at(5))
        XCTAssertFalse(gate.isMuted(at: at(6)))
    }
}
