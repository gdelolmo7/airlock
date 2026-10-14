import AVFoundation
import AirlockEcho
import CoreAudio
import Speech
import Synchronization

/// Your side of a call with what the Mac's speakers played taken back out
/// of it (`EchoRemover`), so that on speakers the other side is not written
/// down as you.
///
/// On a Mac's own speakers the microphone hears the other side as well as
/// you, and until this their words came out as yours: the text filter
/// (`MeetingEcho`) could only drop the lines the call tap had also written
/// down, and a tap that failed left nothing to compare with. The remover
/// needs what was played next to what was heard; `SpeakersTap` hands it
/// everything the Mac plays. This stage sits on the microphone's way to the
/// transcriber, before the mute button's (`CallMuteWatcher.silencing`): the
/// remover lines the two streams up by when they arrived, so nothing may
/// hold the microphone back ahead of it.
///
/// On headphones nothing changes: the microphone hears no speakers, nothing
/// lines up, and it comes out as it went in. With no speakers' sound at all
/// (the tap refused or off), the same, sample for sample.
///
/// The two streams come from their own tasks and the remover is one object,
/// so it lives behind a `Mutex`: Sendable by construction, nothing unchecked.
/// Nothing is kept beyond the remover's last few seconds, and nothing is
/// written anywhere.
final class SpeakerEcho: Sendable {
    private let remover = Mutex(EchoRemover())
    /// The microphone's format, when it is not one the remover takes; the
    /// stage then passes the microphone on untouched.
    private let unusable = Mutex<String?>(nil)

    /// Seconds on the clock both streams are timed by: the host clock, which
    /// Core Audio stamps the speakers' buffers with.
    static func now() -> Double { seconds(hostTime: AudioGetCurrentHostTime()) }

    static func seconds(hostTime: UInt64) -> Double {
        Double(AudioConvertHostTimeToNanos(hostTime)) / 1e9
    }

    /// What the Mac played, mono at `EchoRemover.sampleRate`; `time` is when
    /// its last sample was played, by `now()`.
    func addSpeakers(_ samples: [Float], at time: Double) {
        remover.withLock { $0.addReference(samples, at: time) }
    }

    var report: EchoRemover.Report { remover.withLock { $0.currentReport } }
    var unusableFormat: String? { unusable.withLock { $0 } }

    /// The microphone, cleaned: the same samples in the same format, a
    /// little later (at most `EchoRemover.maxWait`, when the speakers' sound
    /// is slow to come). Ends when `source` ends, with everything still held.
    func cleaning(_ source: AsyncStream<AnalyzerInput>) -> AsyncStream<AnalyzerInput> {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let task = Task.detached { [self] in
            // Decided on the first buffer: the format holds for the stream's
            // life (`MeetingInput` hands on the analyzer's own).
            var format: AVAudioFormat?
            var passing = false
            for await input in source {
                let buffer = input.buffer
                if format == nil, !passing {
                    if Self.canClean(buffer.format) {
                        format = buffer.format
                    } else {
                        passing = true
                        unusable.withLock { $0 = "\(buffer.format)" }
                    }
                }
                guard let format else {
                    continuation.yield(input)
                    continue
                }
                let samples = Self.samples(of: buffer)
                let time = Self.now()
                let cleaned = remover.withLock { $0.addMicrophone(samples, at: time) }
                if let out = Self.buffer(cleaned, format: format) {
                    continuation.yield(AnalyzerInput(buffer: out))
                }
            }
            if let format {
                let rest = remover.withLock { $0.finish() }
                if let out = Self.buffer(rest, format: format) {
                    continuation.yield(AnalyzerInput(buffer: out))
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Mono at the remover's rate, as whole numbers or as floats.
    static func canClean(_ format: AVAudioFormat) -> Bool {
        format.sampleRate == EchoRemover.sampleRate && format.channelCount == 1
            && (format.commonFormat == .pcmFormatInt16 || format.commonFormat == .pcmFormatFloat32)
    }

    private static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        if let data = buffer.int16ChannelData {
            return (0..<count).map { Float(data[0][$0]) / 32_768 }
        }
        if let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: count))
        }
        return [Float](repeating: 0, count: count)
    }

    /// Samples in `format` (one `canClean` takes); nil for nothing, since an
    /// empty buffer is not worth handing on.
    static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        out.frameLength = AVAudioFrameCount(samples.count)
        if let data = out.int16ChannelData {
            for (index, sample) in samples.enumerated() {
                // Rounded, so a microphone passed through unchanged comes
                // out as the same whole numbers it went in as.
                data[0][index] = Int16(max(-32_768, min(32_767, (sample * 32_768).rounded())))
            }
        } else if let data = out.floatChannelData {
            samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: samples.count) }
        }
        return out
    }
}
