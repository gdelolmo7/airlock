import AVFoundation
import AirlockObjC
import Speech

/// Microphone → `AnalyzerInput`, for as long as a key is held.
///
/// Short and nasty. Four traps live here, all measured, and the compiler
/// catches none of them:
///
/// 1. The tap block is imported **unannotated**, so an unmarked closure written
///    inside this `@MainActor` type silently *inherits* main-actor isolation. It
///    compiles clean and then traps at runtime on the first buffer, because the
///    tap runs on a realtime audio thread. Hence `@Sendable` on the closure
///    below — see the note there.
/// 2. `AVAudioConverter` does **not** downmix. Given a multi-channel input it
///    picks one source channel via `channelMap`, and a measured 4-channel device
///    produced `channelMap == [-1]`: thousands of frames of pure silence,
///    reported as success. Aggregate devices are common on developer machines,
///    so the map is repaired before use.
/// 3. The device sample rate is not stable — 24 kHz on one run, 48 kHz on
///    another, on the same machine. It is read at start and never cached.
/// 4. AVFAudio **raises** where Swift expects a throw — a second tap on one
///    bus does, measured, and the engine's header warns that input which is
///    not available may too — and Swift's `catch` never sees an Objective-C
///    exception. One that escaped this main-actor code crashed 1.0.12 twice:
///    not here, but a fraction of a second later in a clipboard timer and in
///    the hold-key monitor, because the unwind skipped the runtime's
///    bookkeeping for the job it tore through. So every call that can raise
///    goes through `guarded`, one call per block, and a raise is a `Failure`
///    like any other.
@MainActor
final class AudioCapture {
    /// Non-fatal, but each needs a different sentence in the UI.
    enum Failure: LocalizedError {
        case noConverter(from: String, to: String)
        case engineFailed(String)
        /// No sample rate or no channels: the engine header's own sign that
        /// input is not available.
        case unusableFormat(String)
        /// Trap 4. `reason` is for the log — it reads like an assertion and
        /// tells the person holding the key nothing.
        case raised(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .noConverter(let from, let to):
                return "Can't convert microphone audio (\(from) → \(to))."
            case .engineFailed(let reason):
                return "The microphone couldn't start — \(reason)"
            case .unusableFormat(let format):
                return "The microphone couldn't start — the input device offers no audio (\(format))."
            case .raised:
                return "The microphone couldn't start — macOS's audio system refused. Try again."
            }
        }
    }

    /// Long-lived, because building one costs the start of a hold. A fresh
    /// engine added a median 60 ms before `prepare()` could even run (170 ms at
    /// p90; measured at background priority, so pessimistic), almost all of it
    /// the input node appearing — on top of the ~90 ms the app already takes
    /// from the key going down to the microphone running. That is the first
    /// word. It is not kept at any price, though: one that failed a start, or
    /// had the hardware change under it, is replaced — see `replaceEngine`.
    private var engine: AVAudioEngine
    /// The two engines before this one — see `replaceEngine` for why they are
    /// not simply let go.
    private var retiredEngines: [AVAudioEngine] = []
    private let makeEngine: () -> AVAudioEngine
    private let log: (String) -> Void
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var pipeline: Pipeline?
    private var isRunning = false
    /// The node our tap is on, and nil once it is off. Tracked apart from
    /// `isRunning` because a start can fail between installing the tap and
    /// running the engine, and a tap left behind makes every later
    /// `installTap` raise.
    private var tappedNode: AVAudioNode?
    /// The engine can no longer be trusted but this hold is still using it.
    /// It is replaced at the next `stop()` — never mid-hold.
    private var engineIsStale = false
    private var configurationWatch: Task<Void, Never>?

    /// Both parameters exist for the tests. An engine in manual rendering mode
    /// has an input node, a tap and a start but no hardware, so no microphone
    /// and no permission check; and the real log is a file in the user's
    /// Library, which a test run must never write.
    init(makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() },
         log: @escaping (String) -> Void = dictationLog) {
        self.makeEngine = makeEngine
        self.log = log
        engine = makeEngine()
        // Matched by identity rather than filtered with `object:`, which wants
        // a Sendable object; an engine is not one. The sequence is made out
        // here, not inside the task, because the observer registers when it is
        // created — so nothing posted before the task first runs is lost,
        // measured. A notification keeps its engine alive until it is read, so
        // the identity cannot have been reused by the time it is compared.
        let changes = NotificationCenter.default
            .notifications(named: .AVAudioEngineConfigurationChange)
            .map { ($0.object as AnyObject?).map(ObjectIdentifier.init) }
        configurationWatch = Task { [weak self] in
            for await changed in changes {
                guard let self else { return }
                // A retired engine's changes, or another engine's entirely.
                guard changed == ObjectIdentifier(self.engine) else { continue }
                self.configurationChanged()
            }
        }
    }

    deinit {
        configurationWatch?.cancel()
    }

    /// Whether the engine is actually up. `DictationModel` compares this against
    /// its own "listening" flag: the two disagreeing means a teardown stalled,
    /// which is a state no gesture can produce and the only honest signal that
    /// the feature needs rescuing rather than refusing.
    var isCapturing: Bool { isRunning }

    /// Loudest sample seen this session. The difference between "you said
    /// nothing" and "the microphone is dead" is otherwise invisible — both end
    /// as an empty transcript, and only one is the user's fault.
    var peakLevel: Float { pipeline?.peak ?? 0 }

    /// Level over the last moment rather than the whole session, so the meter
    /// tracks your voice instead of creeping to its maximum and staying there.
    var currentLevel: Float { pipeline?.takeRecentPeak() ?? 0 }

    /// Starts the engine and returns the stream the analyzer consumes. A start
    /// that fails is tried once more, on a fresh engine, before it throws.
    ///
    /// `analyzerFormat` comes from `SpeechAnalyzer.bestAvailableAudioFormat`
    /// (measured: 16 kHz mono Int16). The tap hands over Float32 at the device
    /// rate, so a converter is mandatory — feeding the raw buffer through
    /// produces nothing at all.
    func start(analyzerFormat: AVAudioFormat,
               deviceUID: String = "") throws -> AsyncStream<AnalyzerInput> {
        stop()
        do {
            return try attempt(analyzerFormat: analyzerFormat, deviceUID: deviceUID)
        } catch {
            // One more try, on the fresh engine the failure has already put
            // in, whatever the failure was. A long-lived engine can go stale
            // unannounced — the header promises the configuration-change
            // notification only "when rendering", which an idle engine is not —
            // and which failure a stale engine produces is not known, so every
            // kind gets the retry. It costs this hold one input node, a median
            // 60 ms (measured), against a hold that ends in "try again". Once
            // only: when a fresh engine fails too, the engine is not the
            // problem, and each further try is another input node spent before
            // the same error.
            log("  retrying once with a fresh engine")
            return try attempt(analyzerFormat: analyzerFormat, deviceUID: deviceUID)
        }
    }

    /// One try, on the current engine. A failure leaves nothing behind and a
    /// fresh engine in place — see `abandonStart`.
    private func attempt(analyzerFormat: AVAudioFormat,
                         deviceUID: String) throws -> AsyncStream<AnalyzerInput> {
        // Every AVFAudio call below goes through `guarded` — trap 4 — and on
        // locals, so a raise has nothing of ours to leave half-done.
        let engine = self.engine
        do {
            let input = try guarded("inputNode") { engine.inputNode }
            // BEFORE the format is read, never after. The sample rate follows
            // the device — measured 24 kHz on the built-in microphone and
            // 48 kHz on another, on this machine — so routing afterwards would
            // configure the converter for a device that is no longer supplying
            // the audio.
            //
            // A chosen device that is not plugged in is deliberately left
            // alone: the engine stays on the system default and the model
            // reports which device is missing. Silently recording from a
            // different microphone is the failure worth avoiding, because the
            // symptom is a transcript that is quietly poor for no visible
            // reason.
            if !deviceUID.isEmpty, let id = AudioDevices.deviceID(forUID: deviceUID),
               let unit = try guarded("audioUnit", { input.audioUnit }) {
                AudioDevices.route(unit, to: id)
            }
            let hardware = try guarded("inputFormat") { input.inputFormat(forBus: 0) }
            let tapFormat = try guarded("outputFormat") { input.outputFormat(forBus: 0) }
            // The hardware half is new, for the next time a start fails. The
            // 1.0.12 raise left no record of which call it was or why, and a
            // tap format that has drifted from the hardware's is the first
            // thing to rule out.
            log("  tap format \(tapFormat.sampleRate)Hz \(tapFormat.channelCount)ch "
                + "hardware \(hardware.sampleRate)Hz \(hardware.channelCount)ch "
                + "device=\(deviceUID.isEmpty ? "default" : deviceUID)")
            // Refused here, before AVFAudio gets the chance to raise over it.
            if let problem = Self.unusable(hardware) ?? Self.unusable(tapFormat) {
                throw Failure.unusableFormat(problem)
            }

            guard let converter = try guarded("AVAudioConverter", {
                AVAudioConverter(from: tapFormat, to: analyzerFormat)
            }) else {
                throw Failure.noConverter(from: "\(tapFormat)", to: "\(analyzerFormat)")
            }
            // Trap 2. A negative entry means "no source channel", which
            // converts to silence and reports success.
            if try guarded("channelMap", { converter.channelMap }).contains(where: { $0.intValue < 0 }) {
                let repaired = Array(repeating: NSNumber(value: 0),
                                     count: Int(analyzerFormat.channelCount))
                try guarded("channelMap =") { converter.channelMap = repaired }
            }

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            self.continuation = continuation

            let pipeline = Pipeline(converter: converter, format: analyzerFormat)
            self.pipeline = pipeline

            // `@Sendable` here is load-bearing, not decoration. Without it the
            // closure INHERITS this type's `@MainActor` isolation — silently,
            // because `AVAudioNodeTapBlock` is imported unannotated — and then
            // traps on the first spoken word:
            //
            //   _swift_task_checkIsolatedSwift → dispatch_assert_queue_fail
            //   closure #2 in AudioCapture.start(analyzerFormat:)
            //   AVAudioNodeTap::TapMessage::RealtimeMessenger_Perform()
            //
            // It compiled without a single diagnostic. Marking it `@Sendable`
            // severs the inherited isolation, which is also why every capture
            // below must be Sendable in its own right.
            let tap: AVAudioNodeTapBlock = { @Sendable buffer, _ in
                guard let converted = pipeline.process(buffer) else { return }
                continuation.yield(AnalyzerInput(buffer: converted))
            }
            try guarded("installTap") {
                input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat, block: tap)
            }
            tappedNode = input

            try guarded("prepare") { engine.prepare() }
            try guarded("start") { try engine.start() }
            isRunning = true
            return stream
        } catch {
            abandonStart(after: error)
            throw error as? Failure ?? Failure.engineFailed(error.localizedDescription)
        }
    }

    /// Idempotent, and it must be: every path out of `HoldGesture` calls it,
    /// including the ones that overlap.
    func stop() {
        guard isRunning || continuation != nil else { return }
        removeTap()
        if isRunning {
            let engine = self.engine
            do {
                try guarded("stop") { engine.stop() }
            } catch {
                engineIsStale = true
            }
            isRunning = false
        }
        // Closing the stream is what lets `finalizeAndFinishThroughEndOfInput`
        // return — see the ordering note in `SpeechSession.finish`.
        continuation?.finish()
        continuation = nil
        // `pipeline` deliberately survives: `peakLevel` is read after stopping,
        // to tell "you said nothing" from "no audio ever arrived".
        if engineIsStale { replaceEngine() }
    }

    /// Why a format cannot carry audio, or nil when it can.
    static func unusable(_ format: AVAudioFormat) -> String? {
        unusable(sampleRate: format.sampleRate, channels: format.channelCount)
    }

    static func unusable(sampleRate: Double, channels: AVAudioChannelCount) -> String? {
        // Phrased so that NaN is unusable too: every comparison with it is false.
        sampleRate > 0 && channels > 0 ? nil : "\(sampleRate) Hz, \(channels) channels"
    }

    // MARK: - Failure and replacement

    /// Runs ONE AVFAudio call that can raise, and turns a raise into
    /// `Failure.raised` — trap 4. Keep the block to that call on values that
    /// already exist: whatever else it held would be skipped by the raise, not
    /// undone.
    private func guarded<T>(_ call: String, _ body: () throws -> T) throws -> T {
        var outcome: Result<T, any Error>?
        do {
            try ALExceptionCatcher.catchException { outcome = Result(catching: body) }
        } catch {
            let info = (error as NSError).userInfo
            let name = info[ALExceptionNameKey] as? String ?? "NSException"
            let reason = info[ALExceptionReasonKey] as? String ?? ""
            log("  \(call) raised \(name): \(reason)")
            throw Failure.raised(name: name, reason: reason)
        }
        // Set whenever the catcher returns normally: the block ran to its end.
        return try outcome!.get()
    }

    /// Undoes a try that got partway, so the retry — and, if that fails too,
    /// the next hold — starts clean.
    ///
    /// The old failure path covered only `engine.start()` throwing. With a
    /// raise caught instead of fatal, one from `prepare()` would leave the tap
    /// installed and `isRunning` false, so `stop()` would never remove it — and
    /// every later `installTap` raises on a bus that already has one. The
    /// engine is replaced as well: one that failed a start is not trusted with
    /// the next.
    private func abandonStart(after error: any Error) {
        log("  start abandoned — \(error)")
        removeTap()
        let engine = self.engine
        try? guarded("stop") { engine.stop() }
        continuation?.finish()
        continuation = nil
        pipeline = nil
        isRunning = false
        replaceEngine()
    }

    private func removeTap() {
        guard let node = tappedNode else { return }
        tappedNode = nil
        do {
            try guarded("removeTap") { node.removeTap(onBus: 0) }
        } catch {
            // Nobody can say what state that left the node in.
            engineIsStale = true
        }
    }

    /// A new engine. Whatever starts next pays for its input node — the retry,
    /// or the next hold — as the first hold after launch always has.
    ///
    /// The old engine is kept until two more replacements have happened. The
    /// header forbids deallocating an engine from its configuration-change
    /// callback — it tears itself down synchronously on its own queue and can
    /// deadlock — and a notification still being delivered holds a reference,
    /// so letting go the moment it is swapped out could put the last release,
    /// and the teardown, on that queue anyway. Two, not one, because a start
    /// whose retry fails too replaces the engine twice in a row: kept for one,
    /// the engine that failed first would go the moment the second did.
    private func replaceEngine() {
        retiredEngines.append(engine)
        if retiredEngines.count > 2 { retiredEngines.removeFirst() }
        engine = makeEngine()
        engineIsStale = false
    }

    /// The engine stops itself when the hardware's rate or channel count
    /// changes, and its nodes keep the formats they had — which is how a
    /// long-lived engine goes stale, when its header insists that an input
    /// chain follow the hardware's rate.
    private func configurationChanged() {
        if !isRunning {
            log("audio configuration changed — replacing the idle engine")
            replaceEngine()
        } else if !engine.isRunning {
            log("audio configuration changed mid-hold and stopped the engine — replacing it after the hold")
            engineIsStale = true
        } else {
            // Still running, so it survived the change. This hold's own
            // routing, reported late, would look exactly like this — and
            // replacing on that would rebuild the engine on every routed hold,
            // and pay for it in first words.
            log("audio configuration changed mid-hold; the engine kept running")
        }
    }
}

/// Everything the realtime audio thread touches, behind one boundary.
///
/// `@unchecked Sendable` is justified here on its merits: a tap is delivered
/// serially on one thread, so the converter is never used concurrently, and the
/// only values read from outside are two `Float`s behind a lock. The type holds
/// no domain state — no model reference, no session — which is what keeps
/// CLAUDE.md's "concurrency by the compiler" rule meaningful everywhere it can
/// still be enforced.
///
/// It used to say "and deliberately nowhere else". That stopped being true one
/// day later, when `SystemAudioTap` landed with the same excuse and a far weaker
/// claim, and nobody noticed for months — which is the argument for enforcing
/// the rule with a test rather than a sentence. The criterion this type does
/// meet, and that one does not, is written down in W4 of
/// CLAUDE.md, Conventions.
private final class Pipeline: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var peakValue: Float = 0
    private var recentValue: Float = 0
    /// The buffer the input block is to hand over, and nil once it has.
    ///
    /// An instance field rather than a captured local because
    /// `AVAudioConverterInputBlock` is imported `@Sendable`, and capturing a
    /// mutable `var` plus a non-Sendable `AVAudioPCMBuffer` across that boundary
    /// is precisely the pattern that compiled clean and then crashed the app in
    /// the tap. It is safe here for a reason the compiler cannot see: `convert`
    /// invokes the block SYNCHRONOUSLY, on this thread, before returning —
    /// nothing escapes and nothing is concurrent. THAT is the reason this is
    /// safe — not the exclusivity claim the type comment used to make, which was
    /// false within a day of being written. Holding it on a type that is already
    /// `@unchecked Sendable` keeps the unsafety in one place and allocates
    /// nothing per buffer.
    private var pendingInput: AVAudioPCMBuffer?

    init(converter: AVAudioConverter, format: AVAudioFormat) {
        self.converter = converter
        self.format = format
    }

    var peak: Float {
        lock.lock(); defer { lock.unlock() }
        return peakValue
    }

    /// Reads and clears the running peak — a meter wants "how loud just now",
    /// while `peak` answers "was there ever any audio at all", and those are
    /// different questions.
    func takeRecentPeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        let value = recentValue
        recentValue = 0
        return value
    }

    /// Called on the audio thread, once per buffer.
    func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        observe(buffer)
        return convert(buffer)
    }

    private func observe(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        var loudest: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for frame in 0..<Int(buffer.frameLength) {
                loudest = max(loudest, abs(samples[frame]))
            }
        }
        lock.lock()
        peakValue = max(peakValue, loudest)
        recentValue = max(recentValue, loudest)
        lock.unlock()
    }

    /// The block form is mandatory: `convert(to:from:)` is documented as being
    /// only for conversions with no codec and no sample-rate change, and this is
    /// a sample-rate change every time.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        // Generous, and deliberately not exact. Measured output frame counts
        // jitter around the ratio (3194 then 3200 for identical inputs), so
        // sizing to the arithmetic alone truncates.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        pendingInput = buffer
        defer { pendingInput = nil }
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [self] _, outStatus in
            guard let input = pendingInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            pendingInput = nil
            outStatus.pointee = .haveData
            return input
        }

        // `.inputRanDry` is the NORMAL outcome for one-buffer-at-a-time feeding,
        // not an error — measured on every single conversion. Treating it as a
        // failure would drop all the audio.
        guard status == .haveData || status == .inputRanDry, output.frameLength > 0 else { return nil }
        return output
    }
}
