import AVFoundation
import AirlockCore
import AudioToolbox
import CoreAudio
import Speech
import Synchronization

/// The other side of a call, as audio for the recogniser: a listen-only tap
/// on the call app's own sound.
///
/// Built like the per-app volume tap (`AppVolumeTap`), not the wave's older
/// one (`SystemAudioTap`, see CLAUDE.md "Not yet built"), and differs from it
/// in the ways listening needs:
/// - **`.unmuted`.** You keep hearing the call exactly as before. Nothing is
///   routed anywhere; the tap only reads.
/// - **Only the call app's sound**, found by the rule that found the call
///   (`CallMonitor.audioProcesses(ofCallApp:)`), so a song playing in another
///   app never ends up in the transcript, and Airlock never hears itself. A
///   browser's tabs share the helper that plays them, so a video in another
///   tab of the same browser is heard too; no tap can split them.
/// - **Named by bundle ID, with process restore, when that is safe.** A
///   browser moves a call's sound between hidden helpers as it likes, and a
///   tap pinned to the helpers it started with went quiet mid-call. Described
///   by their bundle IDs (macOS 26), the tap follows a helper that quits and
///   one that starts under the same ID, with no rebuild and no gap. The
///   processes found are named as well, so however Core Audio reads the
///   bundle IDs it hears at least what the old tap heard. `CallTapScope`
///   (Core, tested) decides when bundle IDs are safe: only when each is the
///   call app's by its name, because a shared helper ID would bring another
///   app's sound in. Otherwise, or when macOS refuses the bundle-ID tap, it
///   is the old fixed list of processes. The log says which one is up, with
///   the bundle IDs Core Audio reported back rather than the ones asked for.
/// - **The realtime thread only copies.** It appends samples to a buffer it
///   may only ever *try* to lock, and counts what it could not store; a task
///   off the main actor drains that buffer a few times a second, converts it
///   to the recogniser's format and hands it on. No allocation, no wait and
///   no file on the audio thread, and nothing main-actor in the callback.
///
/// **The rescan stays, doing less.** The app's processes are still checked
/// every few seconds, and the tap rebuilt only when the app has one it cannot
/// hear (`CallTapCoverage`). For a bundle-ID tap that is a process under an ID
/// it never named, such as FaceTime's daemons handing a call over or a kind of
/// helper the app had not started yet, or one with no ID; a new helper under
/// a known ID is the tap's own job now. For a process-list tap it is any new
/// process, as before. A rebuild plans the tap afresh, so it can move from one
/// kind to the other. Refused permission is not an error Core Audio reports:
/// the tap runs and delivers silence. `peakLevel` is how that shows.
@MainActor
final class CallAudioTap {
    enum Failure: LocalizedError {
        case noProcesses
        case tap(OSStatus)
        case aggregate
        case ioProc(OSStatus)
        case start(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noProcesses: return "The call app isn't playing any sound yet."
            case .tap(let status): return "macOS refused to listen to the call (tap \(status))."
            case .aggregate: return "macOS refused to listen to the call (device)."
            case .ioProc(let status): return "macOS refused to listen to the call (proc \(status))."
            case .start(let status): return "macOS refused to listen to the call (start \(status))."
            }
        }
    }

    /// Seconds of audio the buffer holds between drains: enough to ride out a
    /// main thread stall or a slow drain without dropping a word.
    private static let bufferSeconds = 8.0
    private static let drainInterval: Duration = .milliseconds(200)
    private static let rescanInterval: Duration = .seconds(4)

    private let log: (String) -> Void
    private var bundleID = ""
    private var coverage = CallTapCoverage()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var state: CallTapState?
    private var drain: Task<Void, Never>?
    private var rescan: Task<Void, Never>?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    /// Loudest sample since the tap started; zero after half a minute of a
    /// running call means the permission was refused (or nobody spoke).
    var peakLevel: Float { state.map { Float(bitPattern: $0.peakBits.load(ordering: .relaxed)) } ?? 0 }
    var callbackCount: UInt64 { state?.callbacks.load(ordering: .relaxed) ?? 0 }

    func start(bundleID: String, analyzerFormat: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        stop()
        self.bundleID = bundleID
        let found = Self.processes(ofCallApp: bundleID)
        guard !found.isEmpty else { throw Failure.noProcesses }

        let (rate, how) = try build(for: found)
        let state = CallTapState(capacity: Int(rate * Self.bufferSeconds), sampleRate: rate)
        self.state = state
        try startIO(state: state)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        drain = Self.drainLoop(state: state, analyzerFormat: analyzerFormat,
                               capacity: Int(rate * Self.bufferSeconds),
                               continuation: continuation)
        rescan = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.rescanInterval)
                guard !Task.isCancelled else { return }
                self?.rescanProcesses()
            }
        }
        log("call tap up \(how): \(bundleID) \(found.count) process(es) at \(Int(rate)) Hz")
        return stream
    }

    /// Ends the stream, which is what lets the recogniser finish.
    func stop() {
        rescan?.cancel()
        rescan = nil
        tearDownIO()
        drain?.cancel()
        drain = nil
        continuation?.finish()
        continuation = nil
        state = nil
        coverage = CallTapCoverage()
    }

    // MARK: - Building

    /// The call app's sound processes with the bundle ID each reports, which
    /// is the ID a bundle-ID tap would have to name.
    private static func processes(ofCallApp bundleID: String) -> [CallAudioProcess] {
        CallMonitor.audioProcesses(ofCallApp: bundleID).map {
            CallAudioProcess(objectID: $0,
                             bundleID: AudioProcesses.string($0, kAudioProcessPropertyBundleID))
        }
    }

    /// The tap `CallTapScope` chooses, falling back to the process list when
    /// macOS refuses a bundle-ID one. Returns the sample rate and, for the
    /// log, which kind is up.
    private func build(for found: [CallAudioProcess]) throws -> (rate: Double, how: String) {
        let objects = found.map { AudioObjectID($0.objectID) }
        let named = Set(found.map(\.objectID))
        let why: String
        switch CallTapScope.choose(callApp: bundleID, processes: found,
                                   ownBundleID: Bundle.main.bundleIdentifier) {
        case .bundleIDs(let names):
            do {
                let rate = try build(processes: objects, bundleIDs: names)
                let reported = Self.reported(by: tapID)
                let followed = reported?.bundleIDs ?? names
                coverage = CallTapCoverage(bundleIDs: Set(followed), processes: named)
                guard !followed.isEmpty else { return (rate, "by process list (bundle IDs not kept)") }
                let restore = reported.map { $0.restores ? "restore on" : "restore off" } ?? "not read back"
                return (rate, "by bundle ID [\(followed.sorted().joined(separator: ", "))], \(restore)")
            } catch {
                log("call tap by bundle ID refused: \(error.localizedDescription)")
                why = "fallback"
            }
        case .processes(let reason):
            why = reason
        }
        let rate = try build(processes: objects, bundleIDs: nil)
        coverage = CallTapCoverage(processes: named)
        return (rate, "by process list (\(why))")
    }

    /// Tap plus private aggregate device around it. Returns the sample rate.
    /// With `bundleIDs`, the tap also names those and restores processes
    /// under them; `processes` are named either way.
    private func build(processes found: [AudioObjectID], bundleIDs: [String]?) throws -> Double {
        let description = CATapDescription(monoMixdownOfProcesses: found)
        description.name = "Airlock meeting notes"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isExclusive = false
        if let bundleIDs {
            description.bundleIDs = bundleIDs
            description.isProcessRestoreEnabled = true
        }

        var tap = AudioObjectID(kAudioObjectUnknown)
        let created = AudioHardwareCreateProcessTap(description, &tap)
        guard created == noErr, tap != kAudioObjectUnknown else { throw Failure.tap(created) }
        tapID = tap

        let uuid = description.uuid.uuidString
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Airlock meeting notes",
            kAudioAggregateDeviceUIDKey: "com.airlock.meetings.\(uuid)",
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

    /// What the tap says it was built with, read back from Core Audio rather
    /// than assumed: a tap that dropped its bundle IDs must be rescanned like
    /// a process list, or a new helper would never be heard. Nil when the
    /// description cannot be read.
    private static func reported(by tap: AudioObjectID) -> (bundleIDs: [String], restores: Bool)? {
        guard let description = try? AudioHardwareTap(id: tap).description else { return nil }
        return (description.bundleIDs, description.isProcessRestoreEnabled)
    }

    private func startIO(state: CallTapState) throws {
        var proc: AudioDeviceIOProcID?
        // `@Sendable` is load-bearing: without it the closure inherits this
        // class's main-actor isolation and the first buffer, on Core Audio's
        // realtime thread, traps (see `SystemAudioTap.start`). `state` is
        // captured strongly, never through `self` — a weak load takes a lock.
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) {
            @Sendable _, input, _, _, _ in
            state.write(input)
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

    /// Rebuilt only when the app has a process the tap cannot hear
    /// (`CallTapCoverage.isOutgrown`): one that went away simply stops
    /// contributing, a new helper under a followed bundle ID is already
    /// heard, and a rebuild costs a moment of audio.
    private func rescanProcesses() {
        guard let state, !bundleID.isEmpty else { return }
        let found = Self.processes(ofCallApp: bundleID)
        guard coverage.isOutgrown(by: found) else { return }
        tearDownIO()
        do {
            let (rate, how) = try build(for: found)
            state.sampleRateBits.store(rate.bitPattern, ordering: .relaxed)
            try startIO(state: state)
            log("call tap rebuilt \(how): \(found.count) process(es) at \(Int(rate)) Hz")
        } catch {
            log("call tap rebuild FAILED: \(error.localizedDescription)")
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

    /// Off the main actor: swaps the filled buffer out, converts it and
    /// yields it. Owns its converter and its spare buffer outright, so
    /// nothing here is shared but `state`.
    private nonisolated static func drainLoop(state: CallTapState, analyzerFormat: AVAudioFormat,
                                              capacity: Int,
                                              continuation: AsyncStream<AnalyzerInput>.Continuation)
        -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            var spare = [Float]()
            spare.reserveCapacity(capacity)
            var converter: AVAudioConverter?
            var converterRate = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: drainInterval)
                state.pending.withLock { swap(&$0, &spare) }
                let lost = state.dropped.exchange(0, ordering: .relaxed)
                // Silence where samples were lost keeps the timeline honest:
                // the recogniser's clock is the sample count.
                if lost > 0 { spare.append(contentsOf: repeatElement(0, count: lost)) }
                defer { spare.removeAll(keepingCapacity: true) }
                guard !spare.isEmpty else { continue }

                let rate = Double(bitPattern: state.sampleRateBits.load(ordering: .relaxed))
                if converter == nil || rate != converterRate,
                   let input = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) {
                    converter = AVAudioConverter(from: input, to: analyzerFormat)
                    converterRate = rate
                }
                guard let converter,
                      let output = convert(spare, rate: rate, with: converter, to: analyzerFormat)
                else { continue }
                continuation.yield(AnalyzerInput(buffer: output))
            }
        }
    }

    nonisolated static func convert(_ samples: [Float], rate: Double,
                                            with converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / rate
        // Generous, like the microphone's converter: output counts jitter.
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        // The input buffer is made INSIDE the block, from plain samples, so
        // nothing that isn't Sendable crosses into it: the converter's input
        // block is imported `@Sendable`, and smuggling a buffer in is the
        // pattern that once compiled clean and crashed (`AudioCapture.Pipeline`).
        let once = OneShot()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            guard once.claim(), let input = pcmBuffer(samples, rate: rate) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }
        // `.inputRanDry` is the normal result of feeding one buffer at a time.
        guard status == .haveData || status == .inputRanDry, output.frameLength > 0 else { return nil }
        return output
    }

    private nonisolated static func pcmBuffer(_ samples: [Float], rate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

/// True exactly once: the converter asks for input until told there is none.
final class OneShot: Sendable {
    private let done = Atomic<Bool>(false)

    func claim() -> Bool { !done.exchange(true, ordering: .relaxed) }
}

/// Everything the realtime thread touches, and nothing else: a buffer it only
/// ever TRIES to lock, and atomics. Sendable by construction, so it needs no
/// exemption (CLAUDE.md, "Concurrency by the compiler").
final class CallTapState: Sendable {
    /// Samples waiting for the drain, mono. Sized once; the audio thread
    /// appends only while there is room, so it never allocates.
    let pending: Mutex<[Float]>
    /// Samples the audio thread could not store (lock busy or buffer full);
    /// the drain puts silence in their place.
    let dropped = Atomic<Int>(0)
    let callbacks = Atomic<UInt64>(0)
    /// Loudest sample so far, as `Float` bits.
    let peakBits = Atomic<UInt32>(0)
    let sampleRateBits: Atomic<UInt64>

    init(capacity: Int, sampleRate: Double) {
        var buffer = [Float]()
        buffer.reserveCapacity(capacity)
        pending = Mutex(buffer)
        sampleRateBits = Atomic(sampleRate.bitPattern)
    }

    /// Called on Core Audio's realtime thread, once per buffer.
    func write(_ list: UnsafePointer<AudioBufferList>) {
        callbacks.wrappingAdd(1, ordering: .relaxed)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        guard frames > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)

        var loudest: Float = 0
        let stored = pending.withLockIfAvailable { buffer -> Bool in
            guard buffer.capacity - buffer.count >= frames else { return false }
            for frame in 0..<frames {
                // A mono mixdown is one channel; anything else is read as its
                // first, never as a signal at double speed.
                let sample = samples[frame * channels]
                buffer.append(sample)
                loudest = max(loudest, abs(sample))
            }
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
