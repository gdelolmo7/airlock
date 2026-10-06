import AVFoundation
import AirlockObjC
import Speech
import XCTest
@testable import AirlockApp

/// A start that fails must leave nothing behind, and the hold after it must
/// work. Catching the raise that crashed 1.0.12 is only half the fix: the old
/// failure path covered `engine.start()` throwing and nothing else, so a raise
/// after the tap went in would have left it there — and a second tap on that
/// bus is itself a raise, on every hold, until relaunch. A failed start is
/// also tried once more, on a fresh engine, inside the same hold — once, and
/// never twice.
///
/// No microphone and no permission anywhere. Every engine here is in manual
/// rendering mode, which has an input node, a tap and a start but renders
/// offline, so nothing opens a device and nothing asks TCC. And nothing writes
/// dictation.log, which lives in the user's Library: the log is injected.
@MainActor
final class AudioCaptureFailureTests: XCTestCase {

    /// What `SpeechAnalyzer.bestAvailableAudioFormat` returns, measured.
    private var analyzerFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    }

    /// AVFAudio's own exception — the input node already has a tap, so
    /// `installTap` raises — and the hold still starts, on the fresh engine
    /// the failure put in. The raise is logged all the same, name and reason,
    /// because it is the only record of why the first engine failed.
    func testARaiseIsRetriedOnceOnAFreshEngineAndTheHoldGoesAhead() async throws {
        let (capture, engines, log) = makeCapture()
        let first = engines.made[0]
        first.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable _, _ in }
        defer { first.inputNode.removeTap(onBus: 0) }

        let stream = try capture.start(analyzerFormat: analyzerFormat)
        XCTAssertTrue(capture.isCapturing)
        XCTAssertEqual(engines.made.count, 2, "an engine that failed a start is not tried again")
        XCTAssertTrue(engines.made[1].isRunning, "the retry runs on the fresh engine")
        XCTAssertFalse(first.isRunning)

        let raised = try XCTUnwrap(log.lines.firstIndex {
            $0.hasPrefix("  installTap raised com.apple.coreaudio.avfaudio: ")
        }, "\(log.lines)")
        let reason = log.lines[raised].dropFirst("  installTap raised com.apple.coreaudio.avfaudio: ".count)
        XCTAssertFalse(reason.isEmpty, "the raise's reason must reach the log")
        let retried = try XCTUnwrap(log.lines.firstIndex(of: "  retrying once with a fresh engine"),
                                    "\(log.lines)")
        XCTAssertLessThan(raised, retried, "\(log.lines)")
        XCTAssertEqual(log.lines.filter { $0.contains("retrying") }.count, 1, "\(log.lines)")

        capture.stop()
        XCTAssertFalse(capture.isCapturing)
        let ended = await ends(stream)
        XCTAssertTrue(ended, "stop() must finish the stream, or the analyzer never finalizes")
    }

    /// The half the old failure path never undid: `prepare()` raises AFTER
    /// the tap is on. The retry goes ahead on a fresh engine, and the one that
    /// failed is left without our tap.
    func testARaiseAfterTheTapLeavesNoTapBehind() async throws {
        let (capture, engines, log) = makeCapture({ RaisingEngine() })
        let first = engines.made[0]

        let stream = try capture.start(analyzerFormat: analyzerFormat)
        XCTAssertTrue(capture.isCapturing)
        XCTAssertTrue(log.lines.contains { $0.contains("prepare raised") }, "\(log.lines)")

        // Were our tap still on, this second one would raise, and be caught.
        XCTAssertNoThrow(try ALExceptionCatcher.catchException {
            first.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable _, _ in }
        }, "the failed start left its tap installed")
        first.inputNode.removeTap(onBus: 0)

        capture.stop()
        let ended = await ends(stream)
        XCTAssertTrue(ended)
    }

    /// When the fresh engine fails as well, the hold reports the retry's
    /// failure — the first is in the log — and leaves nothing behind, so the
    /// hold after it starts first time.
    func testWhenTheRetryFailsTooItsFailureIsThrownAndTheNextHoldWorks() async throws {
        let (capture, engines, log) = makeCapture(raising("the first engine"), raising("the fresh engine"))

        XCTAssertThrowsError(try capture.start(analyzerFormat: analyzerFormat)) { error in
            guard let failure = error as? AudioCapture.Failure,
                  case .raised(let name, let reason) = failure else {
                return XCTFail("expected a caught raise, got \(error)")
            }
            XCTAssertEqual(name, "com.apple.coreaudio.avfaudio")
            XCTAssertEqual(reason, "the fresh engine", "the retry's failure is the one reported")
            XCTAssertTrue(failure.localizedDescription.hasPrefix("The microphone couldn't start — "))
        }
        XCTAssertFalse(capture.isCapturing)
        XCTAssertTrue(log.lines.contains("  prepare raised com.apple.coreaudio.avfaudio: the first engine"),
                      "\(log.lines)")
        XCTAssertEqual(engines.made.count, 3, "both failed engines replaced")
        for failed in engines.made.prefix(2) {
            XCTAssertNoThrow(try ALExceptionCatcher.catchException {
                failed.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable _, _ in }
            }, "a failed try left its tap installed")
            failed.inputNode.removeTap(onBus: 0)
        }

        // What `DictationModel` does next; it must be harmless.
        capture.stop()
        XCTAssertEqual(engines.made.count, 3)

        let stream = try capture.start(analyzerFormat: analyzerFormat)
        XCTAssertTrue(capture.isCapturing)
        XCTAssertTrue(engines.made[2].isRunning)
        XCTAssertEqual(engines.made.count, 3, "the next hold needed no retry")
        capture.stop()
        let ended = await ends(stream)
        XCTAssertTrue(ended)
    }

    /// The one failure the old path did handle — `start()` throwing — keeps
    /// its sentence, and is retried like any other.
    func testAStartThatThrowsIsStillEngineFailed() async throws {
        let (capture, engines, log) = makeCapture(throwing("the first engine"), throwing("the fresh engine"))
        let first = engines.made[0]

        XCTAssertThrowsError(try capture.start(analyzerFormat: analyzerFormat)) { error in
            guard case .engineFailed(let reason)? = error as? AudioCapture.Failure else {
                return XCTFail("expected engineFailed, got \(error)")
            }
            XCTAssertEqual(reason, "the fresh engine")
        }
        XCTAssertFalse(capture.isCapturing)
        let abandoned = try XCTUnwrap(log.lines.firstIndex {
            $0.hasPrefix("  start abandoned") && $0.contains("the first engine")
        }, "\(log.lines)")
        let retried = try XCTUnwrap(log.lines.firstIndex(of: "  retrying once with a fresh engine"),
                                    "\(log.lines)")
        XCTAssertLessThan(abandoned, retried, "\(log.lines)")
        XCTAssertNoThrow(try ALExceptionCatcher.catchException {
            first.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable _, _ in }
        }, "the failed start left its tap installed")
        first.inputNode.removeTap(onBus: 0)
        XCTAssertEqual(engines.made.count, 3)

        _ = try capture.start(analyzerFormat: analyzerFormat)
        XCTAssertTrue(capture.isCapturing)
        capture.stop()
    }

    /// Once means once. Two failures end the hold; the engine a third try
    /// would have used is left for the next hold, which gets a retry of its
    /// own.
    func testThereIsNeverAThirdAttempt() async throws {
        let (capture, engines, log) = makeCapture(
            throwing("the first engine"), throwing("the fresh engine"), throwing("a third engine"))
        func starts() -> [Int] { engines.made.map { ($0 as? ThrowingEngine)?.starts ?? 0 } }

        XCTAssertThrowsError(try capture.start(analyzerFormat: analyzerFormat))
        XCTAssertEqual(starts(), [1, 1, 0], "\(log.lines)")
        XCTAssertEqual(log.lines.filter { $0.contains("tap format") }.count, 2, "\(log.lines)")
        XCTAssertEqual(log.lines.filter { $0.contains("retrying") }.count, 1, "\(log.lines)")

        _ = try capture.start(analyzerFormat: analyzerFormat)
        XCTAssertTrue(capture.isCapturing)
        XCTAssertEqual(starts(), [1, 1, 1, 0], "\(log.lines)")
        XCTAssertEqual(log.lines.filter { $0.contains("retrying") }.count, 2, "\(log.lines)")
        capture.stop()
    }

    /// The engine stops itself when the hardware changes and keeps its old
    /// formats. An idle one is replaced there and then, so the next hold never
    /// meets a stale input node.
    func testAConfigurationChangeWhileIdleReplacesTheEngine() async throws {
        let (capture, engines, log) = makeCapture()
        _ = try capture.start(analyzerFormat: analyzerFormat)
        capture.stop()

        post(for: engines.made[0])
        let replaced = await eventually { engines.made.count == 2 }
        XCTAssertTrue(replaced, "\(log.lines)")

        _ = try capture.start(analyzerFormat: analyzerFormat)
        XCTAssertTrue(capture.isCapturing)
        capture.stop()
    }

    /// Only the current engine's changes count. A retired engine's are stale
    /// news, and anyone else's — the process can have other engines — are
    /// none of this type's business.
    func testOnlyTheCurrentEnginesChangesCount() async throws {
        let (capture, engines, log) = makeCapture()
        post(for: engines.made[0])
        let replaced = await eventually { engines.made.count == 2 }
        XCTAssertTrue(replaced, "\(log.lines)")

        post(for: engines.made[0])
        post(for: AVAudioEngine())
        // Nothing to wait FOR, so wait for something after them instead: the
        // current engine's change, handled once. Were either of the others
        // counted too, there would be more than three.
        post(for: engines.made[1])
        let replacedAgain = await eventually { engines.made.count == 3 }
        XCTAssertTrue(replacedAgain, "\(log.lines)")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(engines.made.count, 3, "\(log.lines)")
        withExtendedLifetime(capture) {}
    }

    /// Mid-hold, a change the engine survived is left alone — rebuilding on it
    /// would cost every routed hold its first words — while one that stopped
    /// the engine gets it replaced, once the hold is over and not before.
    func testAChangeMidHoldReplacesOnlyAStoppedEngineAndOnlyAfterTheHold() async throws {
        let (capture, engines, log) = makeCapture()
        let engine = engines.made[0]
        let stream = try capture.start(analyzerFormat: analyzerFormat)

        post(for: engine)
        let absorbed = await eventually { log.lines.contains { $0.contains("the engine kept running") } }
        XCTAssertTrue(absorbed, "\(log.lines)")
        XCTAssertEqual(engines.made.count, 1)

        engine.stop() // what the engine does to itself when the hardware changes
        post(for: engine)
        let noticed = await eventually { log.lines.contains { $0.contains("stopped the engine") } }
        XCTAssertTrue(noticed, "\(log.lines)")
        XCTAssertEqual(engines.made.count, 1, "never replaced mid-hold")
        XCTAssertTrue(capture.isCapturing)

        capture.stop()
        XCTAssertEqual(engines.made.count, 2)
        let ended = await ends(stream)
        XCTAssertTrue(ended)

        _ = try capture.start(analyzerFormat: analyzerFormat)
        XCTAssertTrue(capture.isCapturing)
        capture.stop()
    }

    /// The header's test for "input is not available", written so NaN fails
    /// it too.
    func testAFormatWithNoRateOrNoChannelsIsUnusable() {
        XCTAssertNil(AudioCapture.unusable(sampleRate: 48_000, channels: 1))
        XCTAssertNotNil(AudioCapture.unusable(sampleRate: 0, channels: 1))
        XCTAssertNotNil(AudioCapture.unusable(sampleRate: 48_000, channels: 0))
        XCTAssertNotNil(AudioCapture.unusable(sampleRate: -1, channels: 1))
        XCTAssertNotNil(AudioCapture.unusable(sampleRate: .nan, channels: 1))
    }

    /// However the start failed, the person holding the key reads the same
    /// kind of sentence — and never AVFAudio's assertion text.
    func testTheNewFailuresSayTheMicrophoneCouldNotStart() {
        let failures: [AudioCapture.Failure] = [
            .unusableFormat("0.0 Hz, 0 channels"),
            .raised(name: "com.apple.coreaudio.avfaudio", reason: "required condition is false: nullptr == Tap()"),
        ]
        for failure in failures {
            let sentence = failure.localizedDescription
            XCTAssertTrue(sentence.hasPrefix("The microphone couldn't start — "), sentence)
            XCTAssertFalse(sentence.contains("required condition"), sentence)
        }
    }

    // MARK: - Helpers

    /// `queued` are built in order, one per engine the capture asks for, and
    /// plain engines after them.
    private func makeCapture(_ queued: (() -> AVAudioEngine)...) -> (AudioCapture, Engines, Lines) {
        let engines = Engines()
        engines.queued = queued
        let log = Lines()
        let capture = AudioCapture(makeEngine: { engines.make() }, log: { log.lines.append($0) })
        return (capture, engines, log)
    }

    private func raising(_ reason: String) -> () -> AVAudioEngine {
        { let engine = RaisingEngine(); engine.reason = reason; return engine }
    }

    private func throwing(_ message: String) -> () -> AVAudioEngine {
        { let engine = ThrowingEngine(); engine.message = message; return engine }
    }

    private func post(for engine: AVAudioEngine) {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }

    /// Polls rather than sleeping a fixed time: the watch runs on the main
    /// actor, and only once this test lets go of it. The five seconds are a
    /// ceiling, not a wait — a pass returns at the first poll that sees it —
    /// so only a failure pays for them, and a machine busy with the rest of
    /// the suite is not mistaken for a broken watch.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// Whether the stream ends within five seconds — a ceiling, as in
    /// `eventually`. It has to end for the analyzer to finalize, so a stream
    /// left open is a hold that never finishes.
    private func ends(_ stream: AsyncStream<AnalyzerInput>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in stream {}; return true }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

/// Hands `AudioCapture` engines that cannot reach audio hardware, and keeps
/// every one, so a test can look at the engine a failure left behind.
private final class Engines {
    private(set) var made: [AVAudioEngine] = []
    /// Built instead of a plain engine, in order, while any are left.
    var queued: [() -> AVAudioEngine] = []

    func make() -> AVAudioEngine {
        let engine = queued.isEmpty ? AVAudioEngine() : queued.removeFirst()()
        do {
            try engine.enableManualRenderingMode(
                .offline,
                format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!,
                maximumFrameCount: 4096)
        } catch {
            // An engine on real hardware would check microphone permission the
            // moment its input node was touched. Stopping here is the lesser evil.
            preconditionFailure("manual rendering refused (\(error)); not handing out a hardware engine")
        }
        made.append(engine)
        return engine
    }
}

private final class Lines {
    var lines: [String] = []
}

/// `prepare()` raising the way AVFAudio does — after the tap is installed.
private final class RaisingEngine: AVAudioEngine {
    var reason = "required condition is false: raised by the test"

    override func prepare() {
        NSException(name: NSExceptionName("com.apple.coreaudio.avfaudio"),
                    reason: reason, userInfo: nil).raise()
    }
}

/// `start()` refusing the documented way, with an error, and counting how
/// often it was asked.
private final class ThrowingEngine: AVAudioEngine {
    var message = "refused by the test"
    private(set) var starts = 0

    override func start() throws {
        starts += 1
        throw NSError(domain: "com.apple.coreaudio.avfaudio", code: -10_875,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}
