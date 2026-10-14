import AVFoundation
import Speech
import XCTest
@testable import AirlockApp

/// The echo stage on your side of a call: the plumbing around the remover,
/// whose cleaning is tested on its own (`AirlockEchoTests`). What matters
/// here is that the transcriber's clock is the sample count, so the stage
/// must hand on exactly as many samples as it was given, and that with
/// nothing played it must change nothing at all.
final class SpeakerEchoTests: XCTestCase {
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                       channels: 1, interleaved: true)!

    /// Something like a voice, as whole numbers.
    private func voice(_ count: Int, from start: Int = 0) -> [Int16] {
        (start..<(start + count)).map { index in
            let time = Double(index) / 16_000
            return Int16(6_000 * sin(2 * .pi * 220 * time) + 2_000 * sin(2 * .pi * 1_330 * time))
        }
    }

    private func input(_ samples: [Int16]) -> AnalyzerInput {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { buffer.int16ChannelData![0][index] = sample }
        return AnalyzerInput(buffer: buffer)
    }

    /// Your side in pieces, as the microphone hands it over, through the
    /// stage; everything that came out, once it has ended.
    private func run(_ echo: SpeakerEcho, _ mic: [Int16], piece: Int = 1_600) async -> [Int16] {
        let (source, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let cleaned = echo.cleaning(source)
        var from = 0
        while from < mic.count {
            let to = min(mic.count, from + piece)
            feed.yield(input(Array(mic[from..<to])))
            from = to
        }
        feed.finish()
        var out: [Int16] = []
        for await input in cleaned {
            let buffer = input.buffer
            XCTAssertEqual(buffer.format, format, "handed on in the analyzer's own format")
            out += UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength))
        }
        return out
    }

    /// Headphones, or a tap that never started: your side comes out sample
    /// for sample as it went in.
    func testWithNothingPlayedYourSideIsUnchanged() async {
        let mic = voice(40_700)
        let out = await run(SpeakerEcho(), mic)
        XCTAssertEqual(out.count, mic.count)
        XCTAssertEqual(out, mic)
    }

    /// With the speakers playing, however the pieces fall, the count holds.
    func testWithTheSpeakersPlayingNothingIsLostOrAdded() async {
        for piece in [1_600, 333, 4_096] {
            let echo = SpeakerEcho()
            let start = SpeakerEcho.now() - 3
            let played = voice(48_000, from: 900).map { Float($0) / 32_768 }
            for from in stride(from: 0, to: played.count, by: 480) {
                let to = min(played.count, from + 480)
                echo.addSpeakers(Array(played[from..<to]), at: start + Double(to) / 16_000)
            }
            let mic = voice(30_000).map { $0 / 2 }
            let out = await run(echo, mic, piece: piece)
            XCTAssertEqual(out.count, mic.count, "pieces of \(piece)")
        }
    }

    /// A format the remover does not take goes through as it came, and the
    /// log can say why nothing was cleaned.
    func testAnotherFormatGoesThroughUntouched() async {
        let other = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: other, frameCapacity: 480)!
        buffer.frameLength = 480
        for index in 0..<480 { buffer.floatChannelData![0][index] = Float(index) / 480 }
        let echo = SpeakerEcho()
        let (source, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let cleaned = echo.cleaning(source)
        feed.yield(AnalyzerInput(buffer: buffer))
        feed.finish()
        var got: [AVAudioPCMBuffer] = []
        for await input in cleaned { got.append(input.buffer) }
        XCTAssertEqual(got.count, 1)
        XCTAssertTrue(got.first === buffer)
        XCTAssertNotNil(echo.unusableFormat)
    }
}
