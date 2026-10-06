import Accelerate
import AirlockCore
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Puts one app's audio through us so its level can be changed, then puts it
/// back out. macOS still has no volume mixer; this is the smallest thing that
/// is one.
///
/// **This is not the wave tap.** `SystemAudioTap` listens and cannot break
/// anything: if it fails, a glyph stops moving. This one is `.mutedWhenTapped`,
/// which means the app's audio stops going to the speakers and starts arriving
/// here — we are IN the path, and every failure is somebody's music going
/// silent. Everything below that looks paranoid is that difference.
///
/// One aggregate device carries both halves: the process tap as an input and the
/// real output device as a sub-device. That keeps the two ends in a single clock
/// domain and a single IOProc, so there is no ring buffer between two devices
/// and no resampling to get wrong.
///
/// **Fail open, always.** `start()` refuses on any format it cannot map, and the
/// owner tears the tap down if no buffer arrives shortly after starting (see
/// `hasFired`) — measured behaviour: a tap can be created, wired and started
/// with every call returning `noErr` and then deliver nothing at all, at which
/// point the app is muted and we are not replacing the sound. Tearing down
/// unmutes it. A silent app is the one outcome that must not survive.
///
/// **Nothing the audio thread touches lives on this class.** It all lives on
/// `RenderState`, which the IOProc captures STRONGLY — see the note there. That
/// is why this type needs no `Sendable` conformance at all: it is created, used
/// and destroyed on the main actor, and the realtime thread never sees it.
final class AppVolumeTap {

    /// The app this tap belongs to. Immutable.
    let bundleID: String

    /// Everything the IOProc reads or writes. Held here so the main actor can
    /// read the counters, and captured by the render block so the audio thread
    /// can reach them without going anywhere near `self`.
    private let state: RenderState

    // Main actor only, start to finish. The audio thread never touches them,
    // which is now a structural fact rather than a promise: it cannot reach
    // them, because it does not hold a reference to this object.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(bundleID: String, multiplier: Float) {
        self.bundleID = bundleID
        self.state = RenderState(multiplier: multiplier)
    }

    deinit { stop() }

    var isRunning: Bool { procID != nil }

    /// Whether Core Audio has ever called us. The owner's watchdog reads this:
    /// zero buffers a moment after `AudioDeviceStart` returned `noErr` means the
    /// audio is going nowhere, and this app is muted while it does.
    var hasFired: Bool { callbackCount > 0 }

    /// How many buffers have been through. The owner samples it on a timer:
    /// the aggregate is clock-driven, so this advances whether or not the app is
    /// making noise, and a count that STOPS moving means the tap is dead rather
    /// than the music being quiet.
    var callbackCount: UInt64 { state.callbacks.load(ordering: .relaxed) }

    /// Whether the last cycle had an output buffer to write into.
    ///
    /// Not a paranoid extra: measured on a rebuild onto an aggregate output
    /// device, where callbacks arrived at the usual ninety a second with an
    /// output buffer list of ZERO buffers. A callback counter alone called that
    /// healthy while the app sat muted with its audio going nowhere.
    var deliversOutput: Bool { state.destinationBuffers.load(ordering: .relaxed) > 0 }

    /// Why the last `start()` refused, when we know something more useful than
    /// "macOS said no". The row shows it, and the whole reason this exists is
    /// the same one behind `WaveTapDiagnosis`: a failure reported with the wrong
    /// cause sends somebody to fix something that was never broken.
    private(set) var failureReason: String?

    /// The one refusal the tap can name, in the words its row shows.
    ///
    /// Left as it was when the model's own sentences were rewritten for the
    /// person reading them (`AppVolumeModel.levelNotApplied`, 2026-09-28): it
    /// already says what is wrong in that person's words, and the way out it
    /// implies — another output — is the right one. It does not suggest moving
    /// the slider, deliberately. That would retry, and be refused again, for as
    /// long as the output is a Multi-Output Device; choosing a single device
    /// retries on its own (`AppVolumeModel.outputDeviceChanged`).
    static let multiOutputRefusal = "Per-app volume doesn't work with a Multi-Output Device yet."

    /// The output device this tap was built against, as a UID.
    ///
    /// An aggregate names its sub-device once, at creation. When the default
    /// output moves, this tap goes on rendering to the device it was born with —
    /// and the app cannot be heard anywhere else, because `.mutedWhenTapped`
    /// took its own path away. Comparing this against the current default is how
    /// that gets noticed.
    private(set) var outputUID: String?

    /// Peak of the last cycle, for the UI to show something is flowing.
    var peak: Float { Float(bitPattern: state.peakBits.load(ordering: .relaxed)) }

    /// What the last cycle looked like. Diagnostics only.
    var shape: String { state.shape }

    /// Change the level without rebuilding anything. One relaxed store; the
    /// audio thread picks it up on its next cycle.
    func setMultiplier(_ value: Float) {
        state.multiplierBits.store(value.bitPattern, ordering: .relaxed)
    }

    /// - Returns: false if we could not take the audio over, in which case
    ///   nothing was changed and the app is still playing normally.
    /// The processes this tap currently covers. The owner compares it against a
    /// fresh enumeration: a browser opening a second playing tab is a new helper
    /// process, and a tap built before it exists will never carry its audio.
    private(set) var tappedPIDs: [pid_t] = []

    @MainActor
    @discardableResult
    func start(pids: [pid_t]) -> Bool {
        stop()
        failureReason = nil

        // One description, every process. A browser plays from as many helpers
        // as it has noisy tabs, and they have to arrive mixed on one tap — a tap
        // each would be N aggregate devices and N realtime threads for one row
        // with one slider on it.
        let processes = pids.compactMap(Self.processObject(pid:))
        guard !processes.isEmpty else {
            AppVolumeDiagnostics.log("\(bundleID): no Core Audio process for pids \(pids)")
            return false
        }
        tappedPIDs = pids.sorted()
        guard let outputUID = AudioDevices.currentOutputUID() else {
            AppVolumeDiagnostics.log("\(bundleID): no default output device")
            return false
        }
        self.outputUID = outputUID

        AppVolumeDiagnostics.log("\(bundleID): pids \(pids) → \(processes.count) process object(s) \(processes)")
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Airlock volume · \(bundleID)"
        description.isPrivate = true
        description.isExclusive = false
        // The whole point, and the one line that separates this from the wave
        // tap: the app stops feeding the device directly and feeds us instead.
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        let created = AudioHardwareCreateProcessTap(description, &tap)
        guard created == noErr, tap != kAudioObjectUnknown else {
            AppVolumeDiagnostics.log("\(bundleID): CreateProcessTap failed \(created)")
            return false
        }
        tapID = tap

        guard let aggregate = makeAggregate(tapUUID: description.uuid.uuidString,
                                            outputUID: outputUID) else {
            AppVolumeDiagnostics.log("\(bundleID): aggregate creation failed")
            stop()
            return false
        }
        aggregateID = aggregate

        var proc: AudioDeviceIOProcID?
        // `@Sendable` is load-bearing here for the reason spelled out in
        // `SystemAudioTap.start`: this method is `@MainActor`, a plain closure
        // would inherit that isolation, and Swift 6 SIGTRAPs on the first buffer
        // when Core Audio calls it from its own thread.
        //
        // **`state`, captured strongly — NOT `[weak self]`.** A weak capture
        // reads harmlessly and is what the wave tap does, but resolving one is a
        // call into the runtime that takes a side-table lock, and this block runs
        // on a realtime thread against a ~10ms deadline roughly ninety times a
        // second. A lock whose hold time belongs to some other thread is exactly
        // what must never appear here.
        //
        // Strong is also the safer half of the trade. `RenderState` is a few
        // atomics and no domain state, so keeping it alive costs nothing; the
        // block is released by `AudioDeviceDestroyIOProcID` in `stop()`, and it
        // holds no reference to the tap, so there is no cycle to break and
        // nothing to outlive.
        let state = self.state
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) {
            @Sendable _, input, _, output, _ in
            state.render(input, output)
        }
        guard status == noErr, let proc else {
            AppVolumeDiagnostics.log("\(bundleID): CreateIOProcID failed \(status)")
            stop()
            return false
        }
        procID = proc

        let started = AudioDeviceStart(aggregate, proc)
        guard started == noErr else {
            AppVolumeDiagnostics.log("\(bundleID): AudioDeviceStart failed \(started)")
            stop()
            return false
        }
        state.callbacks.store(0, ordering: .relaxed)
        AppVolumeDiagnostics.log("\(bundleID): tap running (aggregate=\(aggregate), out=\(outputUID))")
        return true
    }

    /// Safe to call from anywhere and more than once. Destroying the tap is what
    /// unmutes the app, so this is the recovery path as much as the teardown
    /// path — never make it conditional on things having gone well.
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
        outputUID = nil
    }

    // MARK: - Core Audio setup

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var pid = pid
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

    /// The real hardware behind an output device.
    ///
    /// Normally just the device itself. When the default output is an AGGREGATE
    /// — a Multi-Output Device, or anything built in Audio MIDI Setup — putting
    /// it inside our aggregate produces a device with no output buffers at all:
    /// measured `dst=0×0B`, callbacks arriving at the usual rate with every
    /// sample dropped. Core Audio does not nest aggregates.
    ///
    /// So it gets flattened: our aggregate takes the sub-devices the other one
    /// is made of. Recursive and depth-bounded, because an aggregate may contain
    /// an aggregate and a cycle here would hang the main actor.
    private static func realOutputs(behind uid: String, depth: Int = 0) -> [String] {
        guard depth < 4, let device = AudioDevices.deviceID(forUID: uid) else { return [uid] }

        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeAggregate else { return [uid] }

        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var list: CFArray?
        var listSize = UInt32(MemoryLayout<CFArray?>.size)
        guard AudioObjectGetPropertyData(device, &listAddress, 0, nil, &listSize, &list) == noErr,
              let uids = list as? [String], !uids.isEmpty else { return [uid] }

        return uids.flatMap { realOutputs(behind: $0, depth: depth + 1) }
    }

    /// Tap in, real device out, one clock. The wave tap's aggregate has an empty
    /// sub-device list because it only ever reads; this one has to put the audio
    /// back, so the output device is a member and the main sub-device.
    /// `@MainActor` because it logs, and logging is main-actor-only. That is the
    /// right home for it anyway: it is called from `start()` and from nowhere
    /// else, and it is setup, not audio.
    @MainActor
    private func makeAggregate(tapUUID: String, outputUID: String) -> AudioObjectID? {
        let outputs = Self.realOutputs(behind: outputUID)
        guard let main = outputs.first else { return nil }
        if outputs != [outputUID] {
            AppVolumeDiagnostics.log("\(bundleID): \(outputUID) is an aggregate → flattened to \(outputs)")
        }

        // **More than one real device behind the default: refuse, deliberately.**
        //
        // A Multi-Output Device is several devices at once, and `render` pairs
        // input buffer i with output buffer i — so the first device would get
        // the audio and every other one would be memset to silence, while the
        // app itself is muted at source. Losing sound on half your outputs is
        // worse than a level that does not apply.
        //
        // Fanning the tap out to every destination buffer is probably the right
        // answer, and it is NOT written here because it cannot be verified on a
        // machine with one output: the buffer layout for a stacked aggregate is
        // exactly the thing that would need to be seen rather than assumed, and
        // guessing at it has already cost this feature two silent-audio bugs.
        guard outputs.count == 1 else {
            failureReason = Self.multiOutputRefusal
            AppVolumeDiagnostics.log(
                "\(bundleID): \(outputs.count) real outputs behind \(outputUID) — refusing, fail open")
            return nil
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Airlock volume",
            kAudioAggregateDeviceUIDKey: "com.airlock.volume.\(tapUUID)",
            // Private, so it never appears in Sound preferences as a device
            // somebody could select. `AudioOutputDevice.isInternalUID` also
            // filters the `com.airlock.` prefix out of our own switcher.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // The REAL devices, never a nested aggregate — see `realOutputs`.
            kAudioAggregateDeviceMainSubDeviceKey: main,
            kAudioAggregateDeviceSubDeviceListKey: outputs.map { [kAudioSubDeviceUIDKey: $0] },
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }
}

/// Everything the realtime thread touches, and nothing else.
///
/// Split out so the IOProc can capture THIS strongly instead of capturing the
/// tap weakly. Resolving a weak reference calls into the runtime and takes a
/// side-table lock; doing that ninety times a second on a thread with a ~10ms
/// deadline is the kind of priority inversion that shows up months later as an
/// unexplained click in somebody's music, never as a failing test.
///
/// It conforms to `Sendable` outright rather than `@unchecked`, because there is
/// nothing to hand-wave: every stored property is a `let` `Atomic`. No domain
/// state, no model, no object ids, nothing the main actor also mutates. That is
/// also why keeping it alive for the life of the block is free.
final class RenderState: Sendable {
    let multiplierBits: Atomic<UInt32>
    let callbacks = Atomic<UInt64>(0)
    let peakBits = Atomic<UInt32>(0)
    /// Peak of what ARRIVED, before gain. Separate from `peakBits` because
    /// "silence out" has two very different causes — nothing came in, or we
    /// failed to write what did — and they need opposite fixes. One number
    /// cannot tell them apart, and this is the path where being wrong means
    /// somebody's music stops.
    let inputPeakBits = Atomic<UInt32>(0)
    /// Buffer geometry of the last cycle, for the same reason: a silent output
    /// with mismatched buffer counts is a pairing bug, not a quiet passage.
    let sourceBuffers = Atomic<UInt32>(0)
    let destinationBuffers = Atomic<UInt32>(0)
    let sourceBytes = Atomic<UInt32>(0)
    let destinationBytes = Atomic<UInt32>(0)

    init(multiplier: Float) {
        self.multiplierBits = Atomic<UInt32>(multiplier.bitPattern)
    }

    /// What the last cycle looked like. Main actor, diagnostics only.
    var shape: String {
        String(format: "in=%.4f out=%.4f src=%d\u{00D7}%dB dst=%d\u{00D7}%dB calls=%llu",
               Float(bitPattern: inputPeakBits.load(ordering: .relaxed)),
               Float(bitPattern: peakBits.load(ordering: .relaxed)),
               sourceBuffers.load(ordering: .relaxed),
               sourceBytes.load(ordering: .relaxed),
               destinationBuffers.load(ordering: .relaxed),
               destinationBytes.load(ordering: .relaxed),
               callbacks.load(ordering: .relaxed))
    }

    /// Runs on a realtime thread against a ~10ms deadline.
    ///
    /// No allocation, no locks, no file I/O, no main-actor hops — and unlike the
    /// note that used to head `SystemAudioTap.consume`, that is enforced by what
    /// is reachable from here rather than promised: `AppVolumeDiagnostics.log`
    /// is `@MainActor`, so a log line added below does not compile.
    ///
    /// vDSP rather than a sample loop because it is vectorised and takes no
    /// allocation to do it.
    func render(_ input: UnsafePointer<AudioBufferList>,
                        _ output: UnsafeMutablePointer<AudioBufferList>) {
        callbacks.wrappingAdd(1, ordering: .relaxed)

        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let destination = UnsafeMutableAudioBufferListPointer(output)
        var gain = Float(bitPattern: multiplierBits.load(ordering: .relaxed))
        var low: Float = -1
        var high: Float = 1
        var peak: Float = 0

        sourceBuffers.store(UInt32(source.count), ordering: .relaxed)
        destinationBuffers.store(UInt32(destination.count), ordering: .relaxed)
        sourceBytes.store(source.first?.mDataByteSize ?? 0, ordering: .relaxed)
        destinationBytes.store(destination.first?.mDataByteSize ?? 0, ordering: .relaxed)

        var inputPeak: Float = 0
        let paired = min(source.count, destination.count)
        for index in 0..<paired {
            guard let src = source[index].mData, let dst = destination[index].mData else { continue }
            let bytes = min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
            let count = vDSP_Length(bytes / MemoryLayout<Float>.size)
            guard count > 0 else { continue }
            let sp = src.bindMemory(to: Float.self, capacity: Int(count))
            let dp = dst.bindMemory(to: Float.self, capacity: Int(count))

            var localInput: Float = 0
            vDSP_maxmgv(sp, 1, &localInput, count)
            inputPeak = max(inputPeak, localInput)

            vDSP_vsmul(sp, 1, &gain, dp, 1, count)
            // Hard clamp. It never engages while `AppMix.maxGain` is unity —
            // it is here because the ceiling is a policy that can move, and a
            // buffer that wraps is a click in somebody's music.
            vDSP_vclip(dp, 1, &low, &high, dp, 1, count)
            var localPeak: Float = 0
            vDSP_maxmgv(dp, 1, &localPeak, count)
            peak = max(peak, localPeak)

            // Whatever the tap did not fill must be silenced rather than left
            // holding the previous cycle, which is a buzz at buffer rate.
            let outBytes = Int(destination[index].mDataByteSize)
            if outBytes > bytes { memset(dst.advanced(by: bytes), 0, outBytes - bytes) }
        }
        // Output channels with no input behind them: silence, not stale memory.
        if destination.count > paired {
            for index in paired..<destination.count where destination[index].mData != nil {
                memset(destination[index].mData!, 0, Int(destination[index].mDataByteSize))
            }
        }
        peakBits.store(peak.bitPattern, ordering: .relaxed)
        inputPeakBits.store(inputPeak.bitPattern, ordering: .relaxed)
    }

}

/// Owner-only log, for the same reason `WaveDiagnostics` exists and with the
/// same `@MainActor` guard: this runs inside a packaged, signed app on a
/// realtime thread, where there is no debugger and no stderr, and the isolation
/// is what stops the next person logging from inside `render`.
enum AppVolumeDiagnostics {
    /// Not private so that `OwnerLogsTests` checks this exact file.
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Airlock/appvolume.log")
    }

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
