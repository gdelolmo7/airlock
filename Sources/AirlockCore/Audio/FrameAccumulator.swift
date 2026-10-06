import Foundation

/// Collects audio arriving in whatever sizes the system feels like, and hands
/// out fixed-size frames.
///
/// This exists because of a specific bug, and the bug is worth stating: the
/// audio tap needed 1024 samples for its FFT, Core Audio delivers 512 per
/// callback, and the first version simply skipped any callback carrying less
/// than a full frame. That is EVERY callback. The tap opened correctly, ran
/// correctly, reported healthy, and produced silence forever — a failure with
/// no error anywhere in it, which took three rounds of "it still doesn't move"
/// to find.
///
/// Buffer size is not a constant you get to assume. It varies by device, by
/// sample rate, and by what else on the machine is using audio.
///
/// Deliberately in Core and deliberately pure: the real one runs on a real-time
/// audio thread, where a mistake is invisible and a debugger is not an option.
public struct FrameAccumulator {
    public let frameCount: Int
    private var pending: [Float]
    private var filled = 0

    public init(frameCount: Int) {
        self.frameCount = max(1, frameCount)
        pending = [Float](repeating: 0, count: self.frameCount)
    }

    /// How much of a frame is currently held. Only interesting to tests and to
    /// anyone wondering why nothing has come out yet.
    public var pendingCount: Int { filled }

    /// Feed `count` samples, read through `sample`, and get `onFrame` once per
    /// complete frame.
    ///
    /// Reading through a closure rather than taking an array is what lets the
    /// caller pull straight from an `AudioBufferList` — including striding over
    /// interleaved channels — without copying anything first. The buffer handed
    /// to `onFrame` is the accumulator's own and is valid only for that call.
    public mutating func append(count: Int,
                                sample: (Int) -> Float,
                                onFrame: (UnsafeBufferPointer<Float>) -> Void) {
        guard count > 0 else { return }
        var offset = 0
        while offset < count {
            let take = min(frameCount - filled, count - offset)
            for index in 0..<take {
                pending[filled + index] = sample(offset + index)
            }
            filled += take
            offset += take
            guard filled == frameCount else { continue }
            filled = 0
            pending.withUnsafeBufferPointer(onFrame)
        }
    }

    /// Throw away a partial frame — when the tap stops, so the next one does not
    /// begin with a few hundred samples of the last track.
    public mutating func reset() { filled = 0 }
}
