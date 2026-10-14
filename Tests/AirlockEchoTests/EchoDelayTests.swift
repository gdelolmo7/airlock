import XCTest
@testable import AirlockEcho

/// Finding how late the speakers reach the microphone.
final class EchoDelayTests: XCTestCase {
    typealias Room = SimulatedRoom

    private func estimate(lag: Int, flipped: Bool = false, seed: UInt64) -> EchoDelay.Estimate? {
        let maxLag = 16_000
        let maxLead = 6_400
        let window = 64_000
        // The speakers on the clocks' timeline; the microphone hears them
        // `lag` samples later, through a room, over its own noise.
        let speakers = Room.talk(seconds: 6, level: 0.1, seed: seed)
        let response = Room.room(delay: 0, gain: flipped ? -0.5 : 0.5, seed: seed + 1)
        let heard = Room.convolve(speakers, with: response)
        let noise = Room.noise(count: window, level: 1e-3, seed: seed + 2)
        let start = maxLag + 8_000
        let mic = (0..<window).map { heard[start + $0 - lag] + noise[$0] }
        let reference = Array(speakers[(start - maxLag)..<(start + window + maxLead)])
        return EchoDelay.estimate(mic: mic, reference: reference, maxLag: maxLag, maxLead: maxLead)
    }

    /// At the direct sound, or a little after it when a reflection off a
    /// wall came in louder. Either does: the canceller starts listening
    /// 48 ms before the delay found.
    private func assertFound(_ found: EchoDelay.Estimate?, near lag: Int, line: UInt = #line) {
        guard let found else { return XCTFail("nothing found", line: line) }
        XCTAssertTrue((lag...(lag + 200)).contains(found.lag), "found \(found.lag), not \(lag)", line: line)
        XCTAssertGreaterThan(found.strength, EchoRemover.clearStrength * 2, line: line)
    }

    func testItFindsTheDelay() {
        for (lag, seed) in [(640, UInt64(1)), (3_520, 2), (0, 3), (15_000, 4)] {
            assertFound(estimate(lag: lag, seed: seed), near: lag)
        }
    }

    /// The clocks can put the microphone ahead of the speakers.
    func testItFindsTheMicrophoneAhead() {
        assertFound(estimate(lag: -4_000, seed: 5), near: -4_000)
    }

    /// A speaker wired the other way round.
    func testItFindsAFlippedEcho() {
        assertFound(estimate(lag: 900, flipped: true, seed: 6), near: 900)
    }

    /// The microphone hearing something else entirely is not a delay.
    func testUnrelatedSoundIsNotClear() {
        let maxLag = 16_000
        let maxLead = 6_400
        let mic = Room.talk(seconds: 4, level: 0.1, seed: 7)
        let reference = Room.talk(seconds: 4 + 1.4, level: 0.1, seed: 8)
        let found = EchoDelay.estimate(mic: mic, reference: Array(reference.prefix(mic.count + maxLag + maxLead)),
                                       maxLag: maxLag, maxLead: maxLead)
        XCTAssertLessThan(found?.strength ?? 0, EchoRemover.clearStrength)
    }
}
