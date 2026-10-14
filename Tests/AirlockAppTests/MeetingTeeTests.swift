import AVFoundation
import CoreMedia
import Speech
import XCTest
@testable import AirlockApp

/// One side's audio handed to several analyzers, one of them started late
/// and fed what it missed first.
///
/// The bug this prevents is a clock one: a recogniser started two minutes
/// into a call times its first word at 0:00 unless its first buffer says
/// otherwise, and every line it hands over then lands two minutes early,
/// before the change of language it was started for.
final class MeetingTeeTests: XCTestCase {
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                       channels: 1, interleaved: true)!

    /// A tenth of a second of silence.
    private func tenth() -> AnalyzerInput {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        return AnalyzerInput(buffer: buffer)
    }

    /// Everything an output was given, once the tee has ended.
    private func drained(_ stream: AsyncStream<AnalyzerInput>) async -> [AnalyzerInput] {
        var got: [AnalyzerInput] = []
        for await input in stream { got.append(input) }
        return got
    }

    func testALiveOutputGetsWhatComesAfterItUndated() async {
        let tee = MeetingTee(keep: 90)
        let (_, stream) = tee.output(from: nil)
        for _ in 0..<5 { tee.pass(tenth()) }
        tee.end()
        let got = await drained(stream)
        XCTAssertEqual(got.count, 5)
        XCTAssertTrue(got.allSatisfy { $0.bufferStartTime == nil },
                      "an output from the start keeps the stream's own clock")
        XCTAssertEqual(tee.passed, 0.5, accuracy: 1e-9)
    }

    /// The one that matters: a late output hears from the moment asked for,
    /// and says when that was.
    func testALateOutputStartsWhereItWasAskedAndSaysWhen() async throws {
        let tee = MeetingTee(keep: 90)
        for _ in 0..<30 { tee.pass(tenth()) }
        let (_, stream) = tee.output(from: 1.25)
        for _ in 0..<3 { tee.pass(tenth()) }
        tee.end()
        let got = await drained(stream)
        // 1.2–1.3 holds 1.25: eighteen kept tenths from there, three live.
        XCTAssertEqual(got.count, 21)
        let first = try XCTUnwrap(got.first?.bufferStartTime)
        XCTAssertEqual(first.seconds, 1.2, accuracy: 1e-6)
        XCTAssertTrue(got.dropFirst().allSatisfy { $0.bufferStartTime == nil },
                      "only the first buffer moves the clock; the rest follow on")
    }

    func testOnlyTheLastStretchIsKept() async throws {
        let tee = MeetingTee(keep: 1)
        for _ in 0..<30 { tee.pass(tenth()) }
        XCTAssertEqual(tee.oldest, 1.9, accuracy: 1e-6, "what ends before 3.0 − 1.0 has gone")
        let (_, stream) = tee.output(from: 0)
        tee.end()
        let got = await drained(stream)
        XCTAssertEqual(got.count, 11)
        XCTAssertEqual(try XCTUnwrap(got.first?.bufferStartTime).seconds, 1.9, accuracy: 1e-6,
                       "asked for more than is kept: it starts at the oldest, timed as such")
    }

    /// Asked from a moment nothing kept reaches, the output still has to be
    /// timed: its first live buffer says when it starts.
    func testAnOutputPastWhatIsKeptDatesItsFirstLiveBuffer() async throws {
        let tee = MeetingTee(keep: 90)
        for _ in 0..<10 { tee.pass(tenth()) }
        let (_, stream) = tee.output(from: 5)
        tee.pass(tenth())
        tee.pass(tenth())
        tee.end()
        let got = await drained(stream)
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(try XCTUnwrap(got.first?.bufferStartTime).seconds, 1.0, accuracy: 1e-6)
        XCTAssertNil(got.last?.bufferStartTime)
    }

    func testStoppingOneOutputLeavesTheOthers() async {
        let tee = MeetingTee(keep: 90)
        let (first, stopped) = tee.output(from: nil)
        let (_, kept) = tee.output(from: nil)
        tee.pass(tenth())
        tee.stop(first)
        tee.pass(tenth())
        tee.end()
        let stoppedGot = await drained(stopped)
        let keptGot = await drained(kept)
        XCTAssertEqual(stoppedGot.count, 1)
        XCTAssertEqual(keptGot.count, 2)
    }

    /// An analyzer finalizes only once its input ends: an output asked for
    /// after the side went quiet must not be left open.
    func testAnOutputAfterTheEndIsEndedToo() async {
        let tee = MeetingTee(keep: 90)
        tee.pass(tenth())
        tee.end()
        let got = await drained(tee.output(from: 0).stream)
        XCTAssertEqual(got.count, 1)
    }
}

/// A finished result read into lines, the way the notes and the follow read
/// them.
final class CallListeningLinesTests: XCTestCase {
    private func time(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1_000),
                    end: CMTime(seconds: end, preferredTimescale: 1_000))
    }

    private func run(_ text: String, _ start: Double, _ end: Double, confidence: Double?) -> AttributedString {
        var run = AttributedString(text)
        run.audioTimeRange = time(start, end)
        if let confidence { run.transcriptionConfidence = confidence }
        return run
    }

    func testSpeechIsOneLineWithItsMeanConfidence() throws {
        let text = run("Hola, ", 10, 10.5, confidence: 0.9) + run("bon dia", 10.5, 11, confidence: 0.5)
        let lines = CallListening.lines(of: text, range: time(10, 11), cut: false)
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(line.text, "Hola, bon dia")
        XCTAssertEqual(line.start ?? 0, 10, accuracy: 1e-6)
        XCTAssertEqual(line.end ?? 0, 11, accuracy: 1e-6)
        XCTAssertEqual(line.scored, 13)
        XCTAssertEqual(line.weighted / Double(line.scored), (0.9 * 6 + 0.5 * 7) / 13, accuracy: 1e-9)
    }

    /// Dictation hands over 5–23 s at once: cut where the speaker paused,
    /// each piece timed from its own words and carrying its share of the
    /// result's confidence.
    func testDictationIsCutWhereTheSpeakerPaused() {
        let text = run("Bon dia a tothom. ", 10, 11.5, confidence: 0.6)
            + run("Comencem la reunió.", 12.5, 14, confidence: 0.6)
        let lines = CallListening.lines(of: text, range: time(10, 14), cut: true)
        XCTAssertEqual(lines.map(\.text), ["Bon dia a tothom.", "Comencem la reunió."])
        XCTAssertEqual(lines.map { $0.start ?? -1 }, [10, 12.5])
        XCTAssertEqual(lines.map { $0.end ?? -1 }, [11.5, 14])
        for line in lines {
            XCTAssertEqual(line.weighted / Double(line.scored), 0.6, accuracy: 1e-9)
        }
    }

    /// Catalan dictation gives no confidence at all: lines still come, with
    /// nothing scored, which the comparison reads as "no confidence".
    func testNoConfidenceIsNothingScored() {
        let text = run("Bon dia a tothom.", 10, 11.5, confidence: nil)
        let lines = CallListening.lines(of: text, range: time(10, 11.5), cut: true)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.scored, 0)
        XCTAssertEqual(lines.first?.weighted, 0)
    }
}
