import AVFoundation
import CoreMedia
import Speech
import Synchronization

/// One side's audio, handed to every analyzer listening to it, with the
/// last stretch kept so an analyzer started late can hear it from earlier.
///
/// A second language is only tried once enough lines have come out in it,
/// two to three minutes after the change (`CallLanguageFollow.Watch`), so a
/// recogniser started then has missed where it began. The last
/// `CallLanguageFollow.replay` seconds are kept, in the analyzer's own
/// format: about 2.9 MB at 16 kHz mono. A late output starts with what is
/// kept from the moment asked for, the first buffer saying when it starts
/// (`AnalyzerInput(buffer:bufferStartTime:)`), then carries on live, so its
/// results are timed on the same clock as everyone else's.
///
/// Times are seconds of audio passed on, counted in frames: the same clock
/// an analyzer keeps, which is why a gap in the sound is filled with silence
/// upstream rather than left out (`MeetingInput`). Frames, not added-up
/// seconds: ten tenths of a second come to 0.99999 s, which the analyzer's
/// 1/16,000 s clock reads as a frame early.
///
/// Fed from one task, read from the main actor, shared through a `Mutex`:
/// Sendable by construction, nothing unchecked.
final class MeetingTee: Sendable {
    private struct Piece {
        /// As it came, without a start time.
        let input: AnalyzerInput
        /// In frames since the first.
        let start: Int64
        let end: Int64
    }

    private struct State {
        /// Oldest first; `head` is the first still kept, so dropping the
        /// oldest is not a copy of everything after it.
        var pieces: [Piece] = []
        var head = 0
        var frames: Int64 = 0
        /// The stream's, from its first buffer: one format throughout.
        var rate: Double = 0
        var outputs: [Int: AsyncStream<AnalyzerInput>.Continuation] = [:]
        /// Outputs whose next buffer has to say when it starts: asked for
        /// from a time nothing kept reaches.
        var dated: Set<Int> = []
        var next = 0
        var ended = false
    }

    let keep: TimeInterval
    private let state = Mutex(State())

    init(keep: TimeInterval) {
        self.keep = keep
    }

    /// Seconds of audio passed on so far.
    var passed: TimeInterval { state.withLock { Self.seconds($0.frames, $0.rate) } }

    /// Where the oldest audio still kept starts.
    var oldest: TimeInterval {
        state.withLock { Self.seconds($0.head < $0.pieces.count ? $0.pieces[$0.head].start : $0.frames, $0.rate) }
    }

    /// Hands `input` to every output and keeps it.
    func pass(_ input: AnalyzerInput) {
        let buffer = input.buffer
        let length = Int64(buffer.frameLength)
        state.withLock { state in
            if state.rate == 0 { state.rate = buffer.format.sampleRate }
            let rate = state.rate
            let start = state.frames
            state.frames += length
            state.pieces.append(Piece(input: input, start: start, end: state.frames))
            let kept = state.frames - Int64((keep * rate).rounded())
            while state.head < state.pieces.count, state.pieces[state.head].end < kept {
                state.head += 1
            }
            if state.head > 512, state.head * 2 > state.pieces.count {
                state.pieces.removeFirst(state.head)
                state.head = 0
            }
            for (id, output) in state.outputs {
                if state.dated.remove(id) != nil {
                    output.yield(AnalyzerInput(buffer: input.buffer, bufferStartTime: Self.time(start, rate)))
                } else {
                    output.yield(input)
                }
            }
        }
    }

    /// No more audio: every output ends.
    func end() {
        state.withLock { state in
            state.ended = true
            for output in state.outputs.values { output.finish() }
            state.outputs = [:]
        }
    }

    /// A stream of this side's audio. From `time` (seconds of audio) when
    /// set: what is kept from the buffer holding that moment, then live.
    /// Live only when nil, timed from the start like the stream itself.
    func output(from time: TimeInterval?) -> (id: Int, stream: AsyncStream<AnalyzerInput>) {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let id = state.withLock { state in
            let id = state.next
            state.next += 1
            if let time {
                let rate = state.rate
                let kept = state.pieces[state.head...]
                let from = kept.firstIndex { Self.seconds($0.end, rate) > time } ?? kept.endIndex
                for index in from..<kept.endIndex {
                    let piece = kept[index]
                    continuation.yield(index == from
                        ? AnalyzerInput(buffer: piece.input.buffer, bufferStartTime: Self.time(piece.start, rate))
                        : piece.input)
                }
                if from == kept.endIndex { state.dated.insert(id) }
            }
            if state.ended {
                continuation.finish()
            } else {
                state.outputs[id] = continuation
            }
            return id
        }
        return (id, stream)
    }

    /// Ends one output, leaving the others.
    func stop(_ id: Int) {
        state.withLock { state in
            state.outputs.removeValue(forKey: id)?.finish()
            state.dated.remove(id)
        }
    }

    private static func seconds(_ frames: Int64, _ rate: Double) -> TimeInterval {
        rate > 0 ? Double(frames) / rate : 0
    }

    /// Exact: the analyzer's own clock is frames at the stream's rate.
    private static func time(_ frames: Int64, _ rate: Double) -> CMTime {
        CMTime(value: frames, timescale: CMTimeScale(max(1, rate.rounded())))
    }
}
