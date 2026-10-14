import AVFoundation
import AirlockCore
import CoreAudio
import Speech
import Synchronization

/// One side of a call on its way to the transcriber: one stream out however
/// many times the sound behind it has to be started again, and a note of
/// when sound and speech last came through, which is what the panel's
/// "isn't reaching Airlock" lines and the stop rules read.
///
/// **One stream out, many in.** A transcriber takes one stream for its whole
/// life, and the microphone's stream dies whenever the Mac's microphone
/// changes (a headset switch, AirPods in or out). Each new stream is joined
/// onto the same output, so your side carries on in the same notes.
///
/// **Silence where a stream was missing.** The transcriber times its lines
/// by counting samples, so the moment between a stream dying and the next
/// one starting is filled with zeros of the same length; left out, every line
/// after it would be written earlier than it was said (`CallMuteGate` does
/// the same for muted stretches).
///
/// Measured off the audio thread, on the task that passes the buffers on,
/// and shared with the main actor through a `Mutex`: Sendable by
/// construction, nothing unchecked.
final class MeetingInput: Sendable {
    /// What has come through so far.
    struct Reading: Equatable, Sendable {
        /// The last buffer of any kind, silence included.
        var lastBuffer: Date?
        /// The last buffer with a sample above zero.
        var lastSound: Date?
        /// The last buffer loud enough to be someone talking
        /// (`CallChannelHealth.isSpeech`), not counting while muted.
        var lastSpeech: Date?
        var heardAnything = false
    }

    /// A gap shorter than this is the ordinary unevenness of buffers
    /// arriving, not a missing stretch.
    static let smallestGap: TimeInterval = 0.25
    /// The longest stretch filled with silence. Past the silence limit the
    /// notes have stopped anyway (`MeetingNotesFlow.silenceLimit`).
    static let longestGap: TimeInterval = MeetingNotesFlow.silenceLimit

    let output: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let isMuted: @Sendable (Date) -> Bool
    private let state = Mutex(State())

    private struct State {
        var reading = Reading()
        var feeding: Task<Void, Never>?
        var closed = false
    }

    /// `isMuted` is the call app's mute button at a moment: speech while
    /// muted is not the call, so it never counts as speech here.
    init(isMuted: @escaping @Sendable (Date) -> Bool = { _ in false }) {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        output = stream
        self.continuation = continuation
        self.isMuted = isMuted
    }

    var reading: Reading { state.withLock { $0.reading } }

    /// Passes `source` on after whatever was fed before has finished. The
    /// stream before is normally over already (starting the microphone again
    /// ends the old one); one that is not is given a second, then cut.
    func feed(_ source: AsyncStream<AnalyzerInput>) {
        state.withLock { state in
            guard !state.closed else { return }
            let previous = state.feeding
            state.feeding = Task.detached { [self] in
                await Self.settle(previous, within: .seconds(1))
                await pump(source)
            }
        }
    }

    /// No more streams: the output ends once the last one has been passed on,
    /// or after two seconds if it never ends by itself.
    func close() {
        let last: Task<Void, Never>? = state.withLock { state in
            state.closed = true
            return state.feeding
        }
        let continuation = continuation
        Task.detached {
            await Self.settle(last, within: .seconds(2))
            continuation.finish()
        }
    }

    private static func settle(_ task: Task<Void, Never>?, within limit: Duration) async {
        guard let task else { return }
        let cutoff = Task.detached {
            try? await Task.sleep(for: limit)
            task.cancel()
        }
        await task.value
        cutoff.cancel()
    }

    private func pump(_ source: AsyncStream<AnalyzerInput>) async {
        var first = true
        for await input in source {
            let now = Date()
            if first {
                first = false
                fillGap(before: input.buffer, arrivingAt: now)
            }
            measure(input.buffer, at: now)
            continuation.yield(input)
        }
    }

    /// Silence for the stretch between the last buffer handed on and the
    /// start of this one, which is `buffer`'s length before it arrived.
    private func fillGap(before buffer: AVAudioPCMBuffer, arrivingAt now: Date) {
        guard let last = state.withLock({ $0.reading.lastBuffer }) else { return }
        let rate = buffer.format.sampleRate
        guard rate > 0 else { return }
        let covered = Double(buffer.frameLength) / rate
        let gap = min(now.timeIntervalSince(last) - covered, Self.longestGap)
        guard gap >= Self.smallestGap else { return }
        var frames = AVAudioFrameCount(gap * rate)
        // A second at a time, so no one buffer is large.
        let chunk = AVAudioFrameCount(rate)
        while frames > 0 {
            let count = min(frames, chunk)
            guard let silence = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count)
            else { return }
            silence.frameLength = count
            for audio in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
            }
            continuation.yield(AnalyzerInput(buffer: silence))
            frames -= count
        }
    }

    private func measure(_ buffer: AVAudioPCMBuffer, at now: Date) {
        let level = Self.level(of: buffer)
        let speech = CallChannelHealth.isSpeech(level: level) && !isMuted(now)
        state.withLock { state in
            state.reading.lastBuffer = now
            if level > 0 {
                state.reading.lastSound = now
                state.reading.heardAnything = true
            }
            if speech { state.reading.lastSpeech = now }
        }
    }

    /// The first channel's level; the recogniser's format is mono.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        if let channels = buffer.int16ChannelData {
            return CallChannelHealth.level(UnsafeBufferPointer(start: channels[0], count: frames))
        }
        if let channels = buffer.floatChannelData {
            return CallChannelHealth.level(UnsafeBufferPointer(start: channels[0], count: frames))
        }
        return 0
    }
}

/// The Mac's microphone as the system has it set, so the notes can tell
/// when it changes under them.
enum SystemMicrophone {
    static func currentID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr, id != 0
        else { return nil }
        return id
    }

    /// The device's UID, which `AudioCapture` routes to by name.
    static func uid(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let uid = value?.takeRetainedValue() as String?, !uid.isEmpty
        else { return nil }
        return uid
    }
}
