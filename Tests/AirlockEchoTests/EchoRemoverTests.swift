import XCTest
@testable import AirlockEcho

/// The echo remover in a simulated room. What matters for call notes: on
/// speakers, the other side's voice must leave the microphone; with no
/// speakers in the microphone (headphones, a quiet call), your voice must
/// come through as it went in; and while both talk, your voice must stay.
final class EchoRemoverTests: XCTestCase {
    typealias Room = SimulatedRoom
    let rate = SimulatedRoom.rate

    /// The other side, on a MacBook's own speakers: 40 ms away, loud.
    private func macBookEcho(_ far: [Float]) -> [Float] {
        Room.convolve(far, with: Room.room(delay: 640, gain: 0.5, seed: 11))
    }

    func testTheSpeakersAloneAreTakenOut() {
        let far = Room.talk(seconds: 16, level: 0.1, seed: 1)
        let mic = Room.add(macBookEcho(far), Room.noise(count: far.count, level: 1e-4, seed: 2))
        let remover = EchoRemover()
        let out = Room.run(remover, mic: mic, reference: far)

        let late = Room.span(6, 16)
        let reduction = Room.decibels(Room.power(mic[late]) / Room.power(out[late]))
        let report = remover.currentReport
        XCTAssertGreaterThan(reduction, 25, "\(report)")
        XCTAssertNotNil(report.delayMilliseconds)
        XCTAssertEqual(report.delayMilliseconds ?? 0, 40, accuracy: 2, "\(report)")
    }

    /// No speakers' sound at all, as when the tap never started: the
    /// microphone comes out exactly as it went in, lined up sample for
    /// sample.
    func testWithNoSpeakersTheMicrophoneIsUntouched() {
        let near = Room.talk(seconds: 6, level: 0.1, seed: 3)
        let out = Room.run(EchoRemover(), mic: near, reference: nil)
        XCTAssertEqual(out.count, near.count)
        let worst = zip(out, near).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(worst, 1e-5)
    }

    /// Headphones: the call plays, the microphone hears only you.
    func testOnHeadphonesYourVoiceIsLeftAlone() {
        let far = Room.talk(seconds: 14, level: 0.1, seed: 4)
        let near = Room.talk(seconds: 14, level: 0.05, seed: 5)
        let mic = Room.add(near, Room.noise(count: near.count, level: 1e-3, seed: 6))
        let remover = EchoRemover()
        let out = Room.run(remover, mic: mic, reference: far)

        let late = Room.span(2, 14)
        let level = Room.decibels(Room.power(out[late]) / Room.power(mic[late]))
        XCTAssertEqual(level, 0, accuracy: 1, "\(remover.currentReport)")
        let changed = zip(out[late], mic[late]).map { $0 - $1 }
        let change = Room.decibels(Room.power(changed[...]) / Room.power(mic[late]))
        XCTAssertLessThan(change, -15, "\(remover.currentReport)")
        XCTAssertNil(remover.currentReport.delayMilliseconds, "nothing to line up with")
    }

    /// Both talking at once: the echo goes, most of you stays.
    func testWhileBothTalkYourVoiceStays() {
        let far = Room.talk(seconds: 20, level: 0.1, seed: 7)
        let near = Room.talk(seconds: 20, level: 0.05, seed: 8, startsTalking: false)
        let echo = macBookEcho(far)
        let mic = Room.add(Room.add(echo, near), Room.noise(count: far.count, level: 1e-4, seed: 9))
        let remover = EchoRemover()
        let out = Room.run(remover, mic: mic, reference: far)

        let late = Room.span(8, 20)
        let nearPart = Array(near[late])
        let outPart = Array(out[late])
        let kept = zip(outPart, nearPart).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            / nearPart.reduce(0.0) { $0 + Double($1) * Double($1) }
        let left = zip(outPart, nearPart).map { $0 - Float(kept) * $1 }
        let before = Room.decibels(Room.power(echo[late]) / Room.power(near[late]))
        let after = Room.decibels(Room.power(left[...]) / (kept * kept * Room.power(near[late])))
        XCTAssertGreaterThan(kept, 0.7, "your voice turned down too far")
        XCTAssertGreaterThan(before - after, 12, "echo to voice \(before) dB before, \(after) dB after; \(remover.currentReport)")
    }

    /// Bluetooth speakers a quarter of a second behind, and the speakers'
    /// stream starting late and arriving unevenly: the delay is still found
    /// and the echo still goes.
    func testItFindsALongDelayThroughUnevenArrivals() {
        let far = Room.talk(seconds: 18, level: 0.1, seed: 10)
        let echo = Room.convolve(far, with: Room.room(delay: 3_520, gain: 0.4, seed: 12))
        let mic = Room.add(echo, Room.noise(count: far.count, level: 1e-4, seed: 13))
        let late = Int(0.3 * Double(rate))
        let remover = EchoRemover()
        let out = Room.run(remover, mic: mic, reference: Array(far[late...]), referenceStart: 0.3)

        let report = remover.currentReport
        XCTAssertEqual(report.delayMilliseconds ?? 0, 220, accuracy: 2, "\(report)")
        let window = Room.span(9, 18)
        let reduction = Room.decibels(Room.power(mic[window]) / Room.power(out[window]))
        XCTAssertGreaterThan(reduction, 20, "\(report)")
    }

    /// Whatever the pieces, the same number of samples comes out as went in.
    func testNothingIsLostOrAdded() {
        let far = Room.talk(seconds: 7.3, level: 0.1, seed: 14)
        let mic = Room.add(macBookEcho(far), Room.noise(count: far.count, level: 1e-4, seed: 15))
        for (micPiece, referencePiece) in [(1_000, 333), (4_096, 512), (100, 1_777), (256, 256)] {
            let out = Room.run(EchoRemover(), mic: mic, reference: far, micPiece: micPiece,
                               referencePiece: referencePiece, jitter: 0.02)
            XCTAssertEqual(out.count, mic.count, "pieces \(micPiece)/\(referencePiece)")
        }
        XCTAssertEqual(EchoRemover().finish(), [])
        let short = Room.run(EchoRemover(), mic: Array(mic.prefix(100)), reference: nil)
        XCTAssertEqual(short.count, 100)
        XCTAssertLessThan(zip(short, mic.prefix(100)).map { abs($0 - $1) }.max() ?? 1, 1e-5)
    }

    /// The speakers' stream stops (the tap died): the microphone keeps
    /// coming out, at most a little over `maxWait` behind.
    func testSpeakersThatStopDoNotHoldTheMicrophoneBack() {
        let far = Room.talk(seconds: 3, level: 0.1, seed: 16)
        let mic = Room.talk(seconds: 10, level: 0.05, seed: 17)
        let remover = EchoRemover()
        for (index, sample) in far.enumerated() where index % 480 == 479 {
            _ = sample
            remover.addReference(Array(far[(index - 479)...index]), at: Double(index + 1) / Double(rate))
        }
        var returned = 0
        var from = 0
        while from < mic.count {
            let to = min(mic.count, from + 1_600)
            returned += remover.addMicrophone(Array(mic[from..<to]), at: Double(to) / Double(rate)).count
            from = to
        }
        let held = Double(mic.count - returned) / Double(rate)
        XCTAssertLessThan(held, EchoRemover.maxWait + 0.15)
        XCTAssertEqual(returned + remover.finish().count, mic.count)
    }

    /// Your voice over speakers that play next to nothing (a hiss, the
    /// call's comfort noise), then the other side loud with you quiet:
    /// what the filter learned from your voice must never come out as a
    /// roar. On a call it did, for minutes, the filter's leftover thirty
    /// times the microphone's. Whatever happens, no stretch comes out
    /// louder than the microphone went in.
    func testItNeverMakesTheMicrophoneLouder() {
        let seconds = 24.0
        let count = Int(seconds * Double(rate))
        let hiss = Room.noise(count: count, level: 2e-4, seed: 20)
        var far = Room.talk(seconds: seconds, level: 0.2, seed: 21)
        // The other side silent but for the hiss for the first 10 seconds.
        for index in 0..<count where index < 10 * rate { far[index] = 0 }
        far = Room.add(far, hiss)
        var near = Room.talk(seconds: seconds, level: 0.1, seed: 22)
        for index in 0..<count where index >= 10 * rate { near[index] *= 0.05 }
        let echo = macBookEcho(far)
        let mic = Room.add(Room.add(echo, near), Room.noise(count: count, level: 1e-4, seed: 23))
        let remover = EchoRemover()
        let out = Room.run(remover, mic: mic, reference: far)

        let tenth = rate / 10
        var worst = -Double.infinity
        var from = rate
        while from + tenth <= count {
            let span = from..<(from + tenth)
            worst = max(worst, Room.decibels(Room.power(out[span]) / Room.power(mic[span])))
            from += tenth
        }
        XCTAssertLessThan(worst, 1.5, "\(remover.currentReport)")
        let late = Room.span(16, 24)
        let reduction = Room.decibels(Room.power(mic[late]) / Room.power(out[late]))
        XCTAssertGreaterThan(reduction, 15, "\(remover.currentReport)")
    }

    /// The room changing for real (a Bluetooth speaker taking over from the
    /// Mac's own): the line-up follows, once fresh seconds agree, and the
    /// echo goes again.
    func testTheLineUpFollowsARoomThatChanges() {
        let far = Room.talk(seconds: 30, level: 0.1, seed: 24)
        let first = macBookEcho(far)
        let second = Room.convolve(far, with: Room.room(delay: 4_800, gain: 0.4, seed: 25))
        let change = 10 * rate
        let echo = (0..<far.count).map { $0 < change ? first[$0] : second[$0] }
        let mic = Room.add(echo, Room.noise(count: far.count, level: 1e-4, seed: 26))
        let remover = EchoRemover()
        let out = Room.run(remover, mic: mic, reference: far)

        let report = remover.currentReport
        XCTAssertEqual(report.delayMilliseconds ?? 0, 300, accuracy: 2, "\(report)")
        let late = Room.span(22, 30)
        let reduction = Room.decibels(Room.power(mic[late]) / Room.power(out[late]))
        XCTAssertGreaterThan(reduction, 15, "\(report)")
    }

    /// A clear line-up and one stray reading of another delay, read from
    /// the same seconds again: the line-up never moves (each move throws
    /// away what the filter learned). The room's 40 ms is close enough to
    /// the guess it starts from that it is never moved at all.
    func testTheLineUpHoldsAgainstAStrayReading() {
        let far = Room.talk(seconds: 30, level: 0.1, seed: 27)
        let echo = macBookEcho(far)
        // Two seconds where the microphone also hears the speakers' sound
        // again, 0.8 s later and fainter, as off a far wall or the other
        // side's own speakers.
        let stray = Room.convolve(far, with: Room.room(delay: 12_800, gain: 0.2, seed: 28))
        let mic = Room.add(Room.add(echo, (0..<far.count).map { (15 * rate..<17 * rate).contains($0) ? stray[$0] : 0 }),
                           Room.noise(count: far.count, level: 1e-4, seed: 29))
        let remover = EchoRemover()
        _ = Room.run(remover, mic: mic, reference: far)

        let report = remover.currentReport
        XCTAssertEqual(report.realigned, 0, "\(report)")
        XCTAssertEqual(report.delayMilliseconds ?? 0, 40, accuracy: 2, "\(report)")
    }
}
