import XCTest
@testable import AirlockCore

final class FrameAccumulatorTests: XCTestCase {
    /// Feed `chunks` of consecutive numbers and collect whatever frames emerge.
    private func run(frameCount: Int, chunks: [Int]) -> [[Float]] {
        var accumulator = FrameAccumulator(frameCount: frameCount)
        var frames: [[Float]] = []
        var next: Float = 0
        for chunk in chunks {
            let base = next
            next += Float(chunk)
            accumulator.append(count: chunk, sample: { base + Float($0) }) { buffer in
                frames.append(Array(buffer))
            }
        }
        return frames
    }

    /// THE bug. Core Audio delivers 512 samples per callback and the FFT needs
    /// 1024, so a version that only acts on a full callback acts on none of
    /// them — every callback is short. The tap ran perfectly and produced
    /// silence forever.
    func testHalfSizedChunksStillProduceFrames() {
        let frames = run(frameCount: 1024, chunks: Array(repeating: 512, count: 8))
        XCTAssertEqual(frames.count, 4, "two 512-sample callbacks make one 1024 frame")
        XCTAssertEqual(frames[0].first, 0)
        XCTAssertEqual(frames[0].last, 1023)
        XCTAssertEqual(frames[1].first, 1024)
    }

    func testNothingComesOutUntilAFrameIsFull() {
        XCTAssertTrue(run(frameCount: 1024, chunks: [512]).isEmpty)
        XCTAssertTrue(run(frameCount: 1024, chunks: [100, 100, 100]).isEmpty)
    }

    func testAChunkLargerThanAFrameProducesSeveral() {
        let frames = run(frameCount: 256, chunks: [1024])
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[3].last, 1023)
    }

    func testExactMultiplesLandCleanly() {
        let frames = run(frameCount: 512, chunks: [512, 512])
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].first, 0)
        XCTAssertEqual(frames[1].first, 512)
    }

    /// Buffer size is not a constant — it varies with device, sample rate and
    /// whatever else is using audio. Ragged input must not lose or repeat a
    /// sample at the seams.
    func testRaggedChunksLoseNothingAndRepeatNothing() {
        let frames = run(frameCount: 64, chunks: [7, 100, 3, 250, 1, 40, 99])
        XCTAssertEqual(frames.count, 7, "500 samples at 64 per frame")
        let flattened = frames.flatMap { $0 }
        XCTAssertEqual(flattened, (0..<448).map(Float.init),
                       "consecutive, in order, with the tail still pending")
    }

    func testPendingReportsThePartialFrame() {
        var accumulator = FrameAccumulator(frameCount: 100)
        accumulator.append(count: 30, sample: Float.init) { _ in }
        XCTAssertEqual(accumulator.pendingCount, 30)
        accumulator.append(count: 70, sample: Float.init) { _ in }
        XCTAssertEqual(accumulator.pendingCount, 0, "a completed frame leaves nothing behind")
    }

    /// A stopped tap must not hand the next one a few hundred samples of the
    /// last track.
    func testResetDropsThePartialFrame() {
        var accumulator = FrameAccumulator(frameCount: 100)
        accumulator.append(count: 90, sample: Float.init) { _ in }
        accumulator.reset()
        XCTAssertEqual(accumulator.pendingCount, 0)

        var frames = 0
        accumulator.append(count: 100, sample: Float.init) { _ in frames += 1 }
        XCTAssertEqual(frames, 1, "a full frame after a reset, not 10 samples early")
    }

    // MARK: - Hostile input

    func testAnEmptyChunkIsHarmless() {
        var accumulator = FrameAccumulator(frameCount: 64)
        accumulator.append(count: 0, sample: Float.init) { _ in XCTFail("nothing to emit") }
        accumulator.append(count: -5, sample: Float.init) { _ in XCTFail("nothing to emit") }
        XCTAssertEqual(accumulator.pendingCount, 0)
    }

    func testAZeroFrameCountDoesNotDivideByZeroOrSpin() {
        var accumulator = FrameAccumulator(frameCount: 0)
        XCTAssertEqual(accumulator.frameCount, 1, "clamped to something emittable")
        var frames = 0
        accumulator.append(count: 3, sample: Float.init) { _ in frames += 1 }
        XCTAssertEqual(frames, 3)
    }

    /// The caller reads interleaved audio by striding inside the closure, so
    /// the accumulator never needs to know about channels.
    func testStridingIsTheCallersBusiness() {
        let interleaved: [Float] = [1, -1, 2, -2, 3, -3, 4, -4]
        var accumulator = FrameAccumulator(frameCount: 4)
        var frame: [Float] = []
        accumulator.append(count: 4, sample: { interleaved[$0 * 2] }) { frame = Array($0) }
        XCTAssertEqual(frame, [1, 2, 3, 4], "left channel only")
    }
}
