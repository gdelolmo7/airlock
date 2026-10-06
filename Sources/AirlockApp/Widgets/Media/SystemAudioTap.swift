import Accelerate
import AirlockCore
import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Reads the audio a music player is actually producing, so the wave can follow
/// it instead of looping a canned animation.
///
/// A Core Audio **process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+):
/// it taps one named process rather than the whole output device, so nothing of
/// anyone else's audio — a call, a video, another app — is ever in the buffer.
/// The tap is `private` (visible only to us) and `unmuted` (the user keeps
/// hearing their music, which should not need saying but is one property away
/// from being false).
///
/// **This is the honest cost of a reactive glyph.** It is off unless switched
/// on, it runs only while something is playing, and it exists because a wave
/// that ignores the music was the thing being complained about. Everything it
/// computes — five band magnitudes — is thrown at a 16pt view and never stored,
/// never written to disk and never sent anywhere.
///
/// Failure is silent and total: every path that cannot get a tap returns false
/// and leaves the caller on the canned animation. There is no degraded mode
/// worth having here, and a decoration must never be able to break the app.
/// Owner-only log of what the tap did, for the same reason `DictationDiagnostics`
/// exists: this runs inside a packaged, signed app on a real-time thread, where
/// neither a debugger nor stderr is available, and "it doesn't move" is not a
/// diagnosis. Records shape only — how many processes resolved, the sample rate,
/// whether any band was non-zero. Never the audio, which is never kept at all.
enum WaveDiagnostics {
    /// Not private so that `OwnerLogsTests` checks this exact file.
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Airlock/wave.log")
    }

    /// `@MainActor`, and that is the point of this change rather than a
    /// decoration. It was being called from the CoreAudio IOProc — stat, open,
    /// seek, write, sometimes remove, all on a realtime thread against a ~10ms
    /// deadline, in a tap inserted into the user's own audio path. The symptom
    /// is a click in their music with nothing wrong-looking in the app.
    ///
    /// Isolating it means the audio thread cannot call it AT ALL: the next
    /// person to reach for a log line inside `consume` gets a compile error
    /// instead of a written assurance that the constraints are satisfied, which
    /// is exactly how the two calls this replaces got there.
    @MainActor
    static func log(_ message: String) {
        guard OwnerLogs.areOpen else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size > 64 * 1024 {
            try? manager.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

final class SystemAudioTap: @unchecked Sendable {
    /// The most recent frame of band magnitudes, published rather than pushed.
    ///
    /// The IOProc fires per audio buffer — around ninety times a second — and
    /// the glyph is redrawn twenty. Calling back on every buffer would have been
    /// seventy wasted main-actor hops a second, so the audio thread overwrites
    /// this and the UI reads it at its own pace. Whole frames are dropped by
    /// design: there is nothing to gain from a magnitude nobody drew.
    ///
    /// `NSLock` around an array of five doubles — the same shape the socket
    /// layer is allowed: lock-isolated, moving values only, no domain state.
    private let lock = NSLock()
    private var latest = [Double](repeating: 0, count: WaveEnvelope.bandCount)

    var latestBands: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var fft: FFTSetup?
    private var sampleRate: Double = 48_000

    /// One FFT frame. 1024 at 48kHz is ~21ms — fine enough to separate bass from
    /// treble, coarse enough that the whole thing costs almost nothing.
    private static let frameCount = 1024
    private static let log2n = vDSP_Length(10) // 2^10 == frameCount

    /// Band edges in Hz, spaced roughly logarithmically because hearing is.
    /// Linear bins would put four of the five bars in the treble, where music
    /// has the least energy, and the wave would barely move.
    private static let bandEdges: [(Double, Double)] = [
        (20, 120), (120, 500), (500, 2_000), (2_000, 6_000), (6_000, 16_000),
    ]

    /// Samples waiting for a full frame. See `FrameAccumulator` — the chunking
    /// rules live in Core with tests, because the version inlined here shipped
    /// a bug that produced silence with no error anywhere in it.
    private var accumulator = FrameAccumulator(frameCount: SystemAudioTap.frameCount)
    private var pending = [Float](repeating: 0, count: SystemAudioTap.frameCount)

    private var window = [Float](repeating: 0, count: SystemAudioTap.frameCount)
    private var scratch = [Float](repeating: 0, count: SystemAudioTap.frameCount)
    private var real = [Float](repeating: 0, count: SystemAudioTap.frameCount / 2)
    private var imaginary = [Float](repeating: 0, count: SystemAudioTap.frameCount / 2)
    private var magnitudes = [Float](repeating: 0, count: SystemAudioTap.frameCount / 2)

    init() {
        vDSP_hann_window(&window, vDSP_Length(Self.frameCount), Int32(vDSP_HANN_NORM))
        fft = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        stop()
        if let fft { vDSP_destroy_fftsetup(fft) }
    }

    var isRunning: Bool { procID != nil }

    /// Start tapping the given bundle IDs. False means we could not — no such
    /// process, permission refused, Core Audio said no — and the caller should
    /// stay on the canned wave.
    /// `@MainActor` because it logs, and logging is now main-actor-only. That
    /// is the right home for it anyway: this is the lifecycle half — it creates
    /// the tap, the aggregate device and the IOProc, and it is only ever called
    /// from `MediaWidgetModel`, which is already on the main actor. `stop()` and
    /// `deinit` stay nonisolated deliberately: `deinit` calls `stop()`, and a
    /// main-actor hop from a deallocation the audio thread could trigger is how
    /// you deadlock inside the callback you are stopping.
    @discardableResult
    @MainActor
    func start(bundleIDs: [String]) -> Bool {
        stop()
        let objects = bundleIDs.compactMap(Self.audioProcess(bundleID:))
        WaveDiagnostics.log("start \(bundleIDs) → \(objects.count) audio process(es) \(objects)")
        guard !objects.isEmpty else {
            WaveDiagnostics.log("  no audio process resolved — is the player running?")
            return false
        }

        let description = CATapDescription(monoMixdownOfProcesses: objects)
        description.name = "agentic-notch wave"
        description.isPrivate = true      // nobody else can see this tap
        description.muteBehavior = .unmuted // the user keeps hearing their music
        description.isExclusive = false

        var tap = AudioObjectID(kAudioObjectUnknown)
        let created = AudioHardwareCreateProcessTap(description, &tap)
        guard created == noErr, tap != kAudioObjectUnknown else {
            WaveDiagnostics.log("  AudioHardwareCreateProcessTap FAILED status=\(created)")
            return false
        }
        tapID = tap

        guard let aggregate = makeAggregate(tapUUID: description.uuid.uuidString) else {
            WaveDiagnostics.log("  aggregate device creation FAILED")
            stop()
            return false
        }
        aggregateID = aggregate
        sampleRate = Self.nominalSampleRate(of: aggregate) ?? 48_000

        var proc: AudioDeviceIOProcID?
        // `@Sendable` IS LOAD-BEARING, and it is not a formality.
        //
        // `start()` is `@MainActor`, so a plain closure written here INHERITS
        // that isolation — and Core Audio calls this one on its own realtime
        // thread. Swift 6 checks that at runtime: the first audio callback hits
        // `swift_task_checkIsolated`, `dispatch_assert_queue` fails, and the
        // process takes SIGTRAP. Not a warning, not a glitch — the app does not
        // launch on any Mac with a player running.
        //
        // A `@Sendable` closure does not inherit actor isolation, which is
        // exactly what a realtime callback needs. It compiles identically either
        // way and fails only at runtime, on the first buffer, which is why it
        // says so here.
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) {
            @Sendable [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard status == noErr, let proc else {
            WaveDiagnostics.log("  AudioDeviceCreateIOProcIDWithBlock FAILED status=\(status)")
            stop()
            return false
        }
        procID = proc
        let started = AudioDeviceStart(aggregate, proc)
        guard started == noErr else {
            WaveDiagnostics.log("  AudioDeviceStart FAILED status=\(started)")
            stop()
            return false
        }
        WaveDiagnostics.log("  tap running: aggregate=\(aggregate) rate=\(sampleRate)")
        callbackCount.store(0, ordering: .relaxed)
        analysisCount.store(0, ordering: .relaxed)
        return true
    }

    /// Counted so the log can distinguish "no callbacks at all" (the tap is not
    /// wired to anything) from "callbacks full of zeroes" (permission denied, or
    /// the wrong process). Those look identical from the UI and need opposite
    /// fixes.
    /// Atomics, not `var`. `start()` reset this from the MAIN ACTOR while the
    /// IOProc was already running and incrementing it — an unsynchronised write
    /// racing an unsynchronised read-modify-write, which is undefined behaviour
    /// rather than merely a lost count. Lock-free, wait-free, and safe to touch
    /// from the audio thread, which an `NSLock` is not.
    private let callbackCount = Atomic<UInt64>(0)

    /// Whether Core Audio has ever called the IOProc.
    ///
    /// The counter above existed for the log; this exposes it because the same
    /// distinction decides what the app TELLS somebody, and it was getting that
    /// wrong. A tap that produces no wave has two causes with opposite fixes:
    ///
    /// - **Callbacks arrive, every sample zero** — audio capture was denied.
    /// - **No callbacks at all** — the tapped process is feeding the tap
    ///   nothing. `AudioHardwareCreateProcessTap`, the aggregate device, the
    ///   IOProc and `AudioDeviceStart` all return `noErr`, the tap reports a
    ///   correct format, and then not one buffer arrives. No permission is
    ///   involved, so granting one changes nothing.
    ///
    /// The measured cause of the second is a player stranded on an output device
    /// it can no longer reach: it keeps reporting itself as playing and produces
    /// silence. **Hog mode is NOT the hazard it looks like** — that was the first
    /// guess and it is wrong. Taking hog on the device a real player is using
    /// makes macOS move the default output; the player follows, and the tap goes
    /// on delivering audio untouched. Only a client that ignores the device
    /// change (`afplay` does) gets stranded. Do not "fix" this by watching hog
    /// mode; watch for buffers, which is the thing that actually matters.
    ///
    /// Reading an atomic is safe from any thread, so this needs no isolation.
    var hasFired: Bool { callbackCount.load(ordering: .relaxed) > 0 }

    /// The shape of the most recent buffer, for the diagnostics the main actor
    /// renders. Three integers, published without a lock or an allocation.
    private let lastFrameFloats = Atomic<UInt64>(0)
    private let lastChannels = Atomic<UInt64>(0)
    private let lastPeakBits = Atomic<UInt32>(0)

    func stop() {
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
        accumulator.reset()
        clearLatest()
    }

    // MARK: - The audio thread

    /// Runs on a real-time thread. Two of the three hazards are now gone.
    ///
    /// It once claimed "No allocation, no locks, no main-actor hops" while doing
    /// the first two and writing files besides — and that sentence is how the
    /// file acquired two `WaveDiagnostics.log` calls beneath it, added under a
    /// written assurance that the constraints held. So, precisely:
    ///
    /// FIXED — no file I/O. `WaveDiagnostics.log` is `@MainActor`, so calling it
    /// from here does not compile. The same two milestones still reach wave.log;
    /// `drainDiagnostics()` renders them from atomics on the 20Hz pump.
    ///
    /// FIXED — no torn counters. `callbackCount` was a plain `var` reset from
    /// the main actor while this thread incremented it: an unsynchronised write
    /// racing a read-modify-write, which is undefined behaviour and not merely a
    /// lost count. Both counters are `Atomic` now, which is lock-free and safe
    /// here in a way `NSLock` is not.
    ///
    /// STILL TRUE, and deferred — `analyse` allocates a `[Double]` per frame
    /// (~47/s) and takes the `NSLock` the 20Hz main-actor pump also takes, which
    /// is priority inversion by construction. Fixing that is the type split
    /// described in CLAUDE.md, "Not yet built": it needs Instruments
    /// and real music to verify, and half a split is worse than none.
    ///
    /// Do not add work to this function.
    private func consume(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return }

        let total = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let count = callbackCount.wrappingAdd(1, ordering: .relaxed).newValue
        // PUBLISH, never log. The same two milestones still reach wave.log —
        // `drainDiagnostics()` renders them from these atomics on the main
        // actor, one 20Hz tick later. That tick is the only difference, and the
        // "#200" line was always measuring "once audio has had time to flow"
        // rather than that exact callback.
        if count == 1 || count == 200 {
            var peak: Float = 0
            if total > 0 {
                vDSP_maxmgv(data.bindMemory(to: Float.self, capacity: total), 1,
                            &peak, vDSP_Length(total))
            }
            lastFrameFloats.store(UInt64(total), ordering: .relaxed)
            lastChannels.store(UInt64(first.mNumberChannels), ordering: .relaxed)
            lastPeakBits.store(peak.bitPattern, ordering: .relaxed)
        }
        guard total > 0 else { return }
        let samples = data.bindMemory(to: Float.self, capacity: total)
        // Mono mixdown should mean one channel, but a tap whose format changed
        // under us would otherwise be read as a signal at double speed.
        let stride = max(1, Int(first.mNumberChannels))
        let available = total / stride

        accumulator.append(count: available, sample: { samples[$0 * stride] }) { frame in
            // Copied into `pending` because `analyse` hands it to vDSP as a
            // mutable working buffer; the accumulator's own is only valid for
            // the duration of this call.
            pending.withUnsafeMutableBufferPointer { destination in
                _ = destination.update(fromContentsOf: frame)
            }
            analyse()
        }
    }

    /// One full frame, windowed, transformed and reduced to band magnitudes.
    private func analyse() {
        guard let fft else { return }
        vDSP_vmul(pending, 1, window, 1, &scratch, 1, vDSP_Length(Self.frameCount))

        var bands = [Double](repeating: 0, count: WaveEnvelope.bandCount)
        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!,
                                            imagp: imagPtr.baseAddress!)
                scratch.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: Self.frameCount / 2
                    ) { reinterpreted in
                        vDSP_ctoz(reinterpreted, 2, &split, 1,
                                  vDSP_Length(Self.frameCount / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(Self.frameCount / 2))
            }
        }

        // vDSP's real FFT returns twice the true magnitude, and the window took
        // energy out. Neither matters: `WaveEnvelope` normalises against its own
        // rolling peak, so only the RATIO between bands has to be right.
        let binWidth = sampleRate / Double(Self.frameCount)
        // `&magnitudes[low]` was the whole bug, and it is a quiet one.
        //
        // An inout pointer to a single ELEMENT is not a pointer into the array's
        // buffer — Swift may hand vDSP a temporary holding that one value — so
        // summing thirty bins from it read whatever happened to follow in
        // memory. Constant garbage in, constant bars out: four of the five bands
        // came back as unchanging numbers around 1e29, some of them negative,
        // which is not a magnitude any FFT can produce. The wave was static
        // because it was faithfully drawing uninitialised memory.
        //
        // Reading through the buffer pointer is the only form that is defined.
        magnitudes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for (index, edge) in Self.bandEdges.enumerated() {
                let low = max(1, Int(edge.0 / binWidth))
                let high = min(buffer.count - 1, Int(edge.1 / binWidth))
                guard low <= high else { continue }
                var sum: Float = 0
                vDSP_sve(base + low, 1, &sum, vDSP_Length(high - low + 1))
                bands[index] = Double(sum) / Double(high - low + 1)
            }
        }
        lock.lock()
        latest = bands
        lock.unlock()

        // Counted here, rendered on the main actor. One sample per 4000 frames
        // is ~85 SECONDS at 1024 samples and 48 kHz — the comment used to say
        // "a few minutes", so the cost of the write was signed off against a
        // number about twice too large. It is moot now: this thread no longer
        // writes anything.
        analysisCount.wrappingAdd(1, ordering: .relaxed)
    }

    private let analysisCount = Atomic<UInt64>(0)

    /// Render the milestones the audio thread published, on the main actor.
    ///
    /// Called by the 20Hz pump that already reads `latestBands`, so it costs no
    /// new timer and no new lock acquisition. Everything it needs was written
    /// lock-free by `consume`/`analyse`; all that crosses is integers.
    @MainActor
    func drainDiagnostics() {
        let callbacks = callbackCount.load(ordering: .relaxed)
        let analyses = analysisCount.load(ordering: .relaxed)

        for milestone in [UInt64(1), UInt64(200)] where callbacks >= milestone && loggedCallbacks < milestone {
            let floats = lastFrameFloats.load(ordering: .relaxed)
            let channels = lastChannels.load(ordering: .relaxed)
            let peak = Float(bitPattern: lastPeakBits.load(ordering: .relaxed))
            WaveDiagnostics.log("  callback #\(milestone): \(floats) floats, \(channels)ch, peak=\(peak)")
            loggedCallbacks = milestone
        }

        if analyses >= 1, loggedAnalyses == 0 {
            WaveDiagnostics.log("  analysis #1 bands="
                                + latestBands.map { String(format: "%.5f", $0) }.joined(separator: " "))
            loggedAnalyses = analyses
        } else if analyses / 4000 > loggedAnalyses / 4000 {
            WaveDiagnostics.log("  analysis #\(analyses) bands="
                                + latestBands.map { String(format: "%.5f", $0) }.joined(separator: " "))
            loggedAnalyses = analyses
        }
    }

    /// What `drainDiagnostics` has already written. Main-actor only, so no
    /// synchronisation — the audio thread never reads these.
    @MainActor private var loggedCallbacks: UInt64 = 0
    @MainActor private var loggedAnalyses: UInt64 = 0

    /// Called when the tap stops, so a paused player cannot leave one last loud
    /// frame sitting here for the UI to keep reading.
    private func clearLatest() {
        lock.lock()
        latest = [Double](repeating: 0, count: WaveEnvelope.bandCount)
        lock.unlock()
    }

    // MARK: - Core Audio lookups

    /// Bundle ID → running PID → Core Audio process object.
    ///
    /// Via NSWorkspace rather than Core Audio's own process list, because that
    /// list includes processes with no audio and identifying the right one still
    /// comes back to the bundle ID.
    private static func audioProcess(bundleID: String) -> AudioObjectID? {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else { return nil }
        var pid = app.processIdentifier
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    /// A tap is not readable on its own — it has to be a sub-device of a private
    /// aggregate, which is what an IOProc can then be attached to.
    private func makeAggregate(tapUUID: String) -> AudioObjectID? {
        let uid = "com.airlock.wave.\(tapUUID)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "agentic-notch wave",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func nominalSampleRate(of device: AudioObjectID) -> Double? {
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
}
