import AVFoundation
import AirlockCore
import AirlockEcho
import AudioToolbox
import CoreAudio
import Speech
import Synchronization

/// Everything the Mac plays, for `SpeakerEcho` to take back out of the
/// microphone. Never transcribed and never written anywhere: it lives a few
/// seconds in the remover's memory and goes.
///
/// A listen-only tap built like the call's (`CallAudioTap`, read its header
/// first): `.unmuted` and private, so you hear exactly what you heard
/// before; the realtime thread only copies, into a buffer it may only ever
/// try to lock; a task off the main actor drains it ten times a second,
/// converts it and hands it on. It differs in two ways:
/// - **Every app, Airlock included.** Whatever comes out of the speakers can
///   reach the microphone, a song or a chime as much as the call, so all of
///   it is what the remover should know about. That is a global tap that
///   excludes nothing, which needs no rescan: an app that starts playing
///   later is heard without a rebuild.
/// - **Timed by Core Audio.** Each buffer carries the host time its first
///   sample was captured at, and the drain hands the remover the time of
///   the last one, on the clock the microphone's stage reads
///   (`SpeakerEcho.now`). The remover finds the room's real delay itself;
///   these times only have to be right to a few tenths of a second.
///
/// The same permission as the call tap (System Audio Recording). Refused, it
/// runs and delivers silence, and the microphone passes through unchanged.
@MainActor
final class SpeakersTap {
    enum Failure: LocalizedError {
        case tap(OSStatus)
        case aggregate
        case ioProc(OSStatus)
        case start(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tap(let status): return "macOS refused to listen to the speakers (tap \(status))."
            case .aggregate: return "macOS refused to listen to the speakers (device)."
            case .ioProc(let status): return "macOS refused to listen to the speakers (proc \(status))."
            case .start(let status): return "macOS refused to listen to the speakers (start \(status))."
            }
        }
    }

    /// Seconds the buffer holds between drains, as for the call tap.
    private static let bufferSeconds = 8.0
    /// Often enough that the microphone seldom waits on it: each microphone
    /// block is held until the speakers' sound for it has come.
    private static let drainInterval: Duration = .milliseconds(100)

    private let log: (String) -> Void
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var state: SpeakersTapState?
    private var drain: Task<Void, Never>?

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    /// Loudest sample since the tap started, and buffers delivered: a tap
    /// that runs but was refused delivers zeros.
    var peakLevel: Float { state.map { Float(bitPattern: $0.peakBits.load(ordering: .relaxed)) } ?? 0 }
    var callbackCount: UInt64 { state?.callbacks.load(ordering: .relaxed) ?? 0 }

    /// The last time the Mac played something loud enough to be a voice
    /// (`CallChannelHealth.isSpeech`): what tells a dead call tap from a
    /// quiet call (`CallTapWatch`).
    var lastSpeech: Date? {
        guard let bits = state?.lastSpeechBits.load(ordering: .relaxed), bits != 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
    }

    /// Everything the Mac plays from now on, in the transcriber's `format`:
    /// the other side's last resort when the call tap has gone dead. Nil
    /// when the tap is not running or the format is not one it can give.
    func otherSide(format: AVAudioFormat) -> AsyncStream<AnalyzerInput>? {
        guard let state, SpeakerEcho.canClean(format) else { return nil }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let previous = state.listener.withLock { listener in
            defer { listener = (continuation, format) }
            return listener?.continuation
        }
        previous?.finish()
        return stream
    }

    func start(into echo: SpeakerEcho) throws {
        stop()
        let rate = try build()
        let capacity = Int(rate * Self.bufferSeconds)
        let state = SpeakersTapState(capacity: capacity)
        self.state = state
        try startIO(state: state)
        drain = Self.drainLoop(state: state, rate: rate, capacity: capacity, echo: echo)
        log("echo: speakers tap up at \(Int(rate)) Hz")
    }

    func stop() {
        tearDownIO()
        drain?.cancel()
        drain = nil
        endOtherSide()
        state = nil
    }

    /// Ends the stream `otherSide` gave, if one is running; the tap goes on.
    func endOtherSide() {
        state?.listener.withLock { listener in
            defer { listener = nil }
            return listener
        }?.continuation.finish()
    }

    // MARK: - Building

    /// Tap plus private aggregate device around it. Returns the sample rate.
    private func build() throws -> Double {
        // A global tap's list is the processes it leaves out: none. The
        // initializer marks it exclusive for that reason, so unlike the
        // call's tap that is left as it is.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "Airlock speakers for call notes"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let created = AudioHardwareCreateProcessTap(description, &tap)
        guard created == noErr, tap != kAudioObjectUnknown else { throw Failure.tap(created) }
        tapID = tap

        let uuid = description.uuid.uuidString
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Airlock speakers for call notes",
            kAudioAggregateDeviceUIDKey: "com.airlock.meetings.speakers.\(uuid)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uuid]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr,
              device != kAudioObjectUnknown else {
            tearDownIO()
            throw Failure.aggregate
        }
        aggregateID = device
        return Self.sampleRate(of: device) ?? 48_000
    }

    private func startIO(state: SpeakersTapState) throws {
        var proc: AudioDeviceIOProcID?
        // `@Sendable` and the strong `state` capture are load-bearing, as in
        // `CallAudioTap.startIO`: without the first the closure is main-actor
        // and traps on Core Audio's thread, and a weak load takes a lock.
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) {
            @Sendable _, input, inputTime, _, _ in
            state.write(input, at: inputTime)
        }
        guard status == noErr, let proc else {
            tearDownIO()
            throw Failure.ioProc(status)
        }
        procID = proc
        let started = AudioDeviceStart(aggregateID, proc)
        guard started == noErr else {
            tearDownIO()
            throw Failure.start(started)
        }
    }

    private func tearDownIO() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func sampleRate(of device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr,
              rate > 0 else { return nil }
        return rate
    }

    // MARK: - Draining

    /// Off the main actor: swaps the filled buffer out, converts it to the
    /// remover's rate and hands it over with the time of its last sample.
    private nonisolated static func drainLoop(state: SpeakersTapState, rate: Double, capacity: Int,
                                              echo: SpeakerEcho) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            var spare = [Float]()
            spare.reserveCapacity(capacity)
            guard let input = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let output = AVAudioFormat(standardFormatWithSampleRate: EchoRemover.sampleRate, channels: 1),
                  let converter = AVAudioConverter(from: input, to: output) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: drainInterval)
                let last = state.captured.withLock { captured -> (host: UInt64, frames: Int) in
                    swap(&captured.samples, &spare)
                    return (captured.lastHostTime, captured.lastFrames)
                }
                let lost = state.dropped.exchange(0, ordering: .relaxed)
                // Silence where samples were lost, so the count keeps pace.
                if lost > 0 { spare.append(contentsOf: repeatElement(0, count: lost)) }
                defer { spare.removeAll(keepingCapacity: true) }
                guard !spare.isEmpty,
                      let converted = CallAudioTap.convert(spare, rate: rate, with: converter, to: output),
                      let channel = converted.floatChannelData?[0] else { continue }
                let end = last.host != 0
                    ? SpeakerEcho.seconds(hostTime: last.host) + Double(last.frames) / rate
                    : SpeakerEcho.now()
                let played = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
                if CallChannelHealth.isSpeech(level: CallChannelHealth.level(played)) {
                    state.lastSpeechBits.store(Date().timeIntervalSinceReferenceDate.bitPattern,
                                               ordering: .relaxed)
                }
                echo.addSpeakers(played, at: end)
                if let listener = state.listener.withLock({ $0 }),
                   let buffer = SpeakerEcho.buffer(played, format: listener.format) {
                    listener.continuation.yield(AnalyzerInput(buffer: buffer))
                }
            }
        }
    }
}

/// Everything the realtime thread touches, and nothing else, as
/// `CallTapState`: a buffer it only ever TRIES to lock, and atomics.
/// Sendable by construction, so it needs no exemption.
final class SpeakersTapState: Sendable {
    struct Captured {
        /// Mono, sized once; appended to only while there is room.
        var samples: [Float]
        /// The last buffer stored: the host time of its first sample (zero
        /// when Core Audio did not give one) and its length.
        var lastHostTime: UInt64 = 0
        var lastFrames = 0
    }

    let captured: Mutex<Captured>
    /// Samples the audio thread could not store; the drain puts silence in
    /// their place.
    let dropped = Atomic<Int>(0)
    let callbacks = Atomic<UInt64>(0)
    /// Loudest sample so far, as `Float` bits.
    let peakBits = Atomic<UInt32>(0)
    /// The drain's, not the audio thread's: when it last handed on a voice,
    /// as the bits of a reference-date interval (zero: never).
    let lastSpeechBits = Atomic<UInt64>(0)
    /// The drain's too: where to hand what was played on to the transcriber
    /// as well, once the call tap has been given up on.
    let listener = Mutex<(continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat)?>(nil)

    init(capacity: Int) {
        var samples = [Float]()
        samples.reserveCapacity(capacity)
        captured = Mutex(Captured(samples: samples))
    }

    /// Called on Core Audio's realtime thread, once per buffer.
    func write(_ list: UnsafePointer<AudioBufferList>, at time: UnsafePointer<AudioTimeStamp>) {
        callbacks.wrappingAdd(1, ordering: .relaxed)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        guard frames > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        let host = time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : 0

        var loudest: Float = 0
        let stored = captured.withLockIfAvailable { captured -> Bool in
            guard captured.samples.capacity - captured.samples.count >= frames else { return false }
            for frame in 0..<frames {
                let sample = samples[frame * channels]
                captured.samples.append(sample)
                loudest = max(loudest, abs(sample))
            }
            captured.lastHostTime = host
            captured.lastFrames = frames
            return true
        }
        if stored != true {
            dropped.wrappingAdd(frames, ordering: .relaxed)
        }
        if loudest > Float(bitPattern: peakBits.load(ordering: .relaxed)) {
            peakBits.store(loudest.bitPattern, ordering: .relaxed)
        }
    }
}
