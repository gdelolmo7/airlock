import Darwin
import Foundation
import Sentry
import XCTest
import AirlockCore
import AirlockTestSupport
@testable import AirlockApp

/// The rules for when crash reports start, stop and are asked about
/// (`CrashReporter`), with a stand-in for Sentry so nothing real is started.
@MainActor
final class CrashReporterTests: XCTestCase {
    private let dsn = "https://0123abcd@o12345.ingest.de.sentry.io/678"
    private var store: TestDefaults!
    private var scratch: TestScratch!
    private var engine: FakeEngine!

    override func setUp() async throws {
        store = TestDefaults("com.airlock.test.crashreports")
        scratch = TestScratch("crash")
        engine = FakeEngine()
    }

    override func tearDown() async throws {
        store.remove()
        scratch.remove()
    }

    private var marker: CleanExitMarker { CleanExitMarker(url: scratch.file("running")) }

    private func reporter(dsn: String?) -> CrashReporter {
        CrashReporter(dsn: dsn, defaults: store.defaults, engine: engine, marker: marker)
    }

    // MARK: - No DSN, no start

    func testWithoutADSNNothingStartsWhateverTheAnswer() {
        store.defaults.set(true, forKey: CrashReporter.consentKey)
        let crash = reporter(dsn: nil)
        XCTAssertFalse(crash.isAvailable)
        XCTAssertFalse(crash.isEnabled)
        crash.launch()
        crash.isEnabled = true
        XCTAssertTrue(engine.starts.isEmpty)
        XCTAssertFalse(crash.isRunning)
        // Leaves no trace either: no marker, no question.
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.url.path))
        XCTAssertFalse(crash.hasQuestionWaiting)
    }

    /// A "yes" from a build that cannot send is not kept: the copy that can
    /// send would otherwise read an answer nobody gave it.
    func testABuildWithoutADSNKeepsNoAnswer() {
        let crash = reporter(dsn: nil)
        crash.isEnabled = true
        XCTAssertNil(store.defaults.object(forKey: CrashReporter.consentKey))
    }

    /// No test, `swift run` or development package carries a DSN, so the
    /// shared reporter in this process is off and offers nothing, and
    /// Settings search does not lead to a switch that is not there.
    func testThisProcessHasNoDSN() {
        XCTAssertNil(CrashReporter.bundleDSN)
        XCTAssertFalse(CrashReporter.shared.isAvailable)
        XCTAssertFalse(SettingsAnchor.crashReports.isAvailable(guideOn: false))
        XCTAssertFalse(SettingsAnchor.search("crash", guideOn: false).contains(.crashReports))
    }

    // MARK: - Consent

    func testOffByDefaultSoNothingStarts() {
        let crash = reporter(dsn: dsn)
        XCTAssertTrue(crash.isAvailable)
        XCTAssertFalse(crash.isEnabled)
        crash.launch()
        XCTAssertTrue(engine.starts.isEmpty)
        XCTAssertFalse(crash.isRunning)
    }

    func testAYesFromBeforeStartsAtLaunchAndOnlyThen() {
        store.defaults.set(true, forKey: CrashReporter.consentKey)
        let crash = reporter(dsn: dsn)
        XCTAssertTrue(crash.isEnabled)
        XCTAssertTrue(engine.starts.isEmpty, "built is not launched")
        crash.launch()
        XCTAssertEqual(engine.starts, [dsn])
        XCTAssertTrue(crash.isRunning)
    }

    func testSayingYesStartsAtOnceAndIsKept() {
        let crash = reporter(dsn: dsn)
        crash.launch()
        crash.isEnabled = true
        XCTAssertEqual(engine.starts, [dsn])
        XCTAssertEqual(store.defaults.object(forKey: CrashReporter.consentKey) as? Bool, true)
        // Saying it twice starts nothing twice.
        crash.isEnabled = true
        XCTAssertEqual(engine.starts.count, 1)
    }

    func testTurningItOffStopsItAtOnce() {
        store.defaults.set(true, forKey: CrashReporter.consentKey)
        let crash = reporter(dsn: dsn)
        crash.launch()
        crash.isEnabled = false
        XCTAssertEqual(engine.stops, 1)
        XCTAssertFalse(crash.isRunning)
        XCTAssertEqual(store.defaults.object(forKey: CrashReporter.consentKey) as? Bool, false)
        // And back on again.
        crash.isEnabled = true
        XCTAssertEqual(engine.starts.count, 2)
        XCTAssertTrue(crash.isRunning)
    }

    /// The setup switch can be answered before the app has launched the
    /// reporter; the answer waits for launch rather than starting early.
    func testAYesBeforeLaunchWaitsForIt() {
        let crash = reporter(dsn: dsn)
        crash.isEnabled = true
        XCTAssertTrue(engine.starts.isEmpty)
        crash.launch()
        XCTAssertEqual(engine.starts, [dsn])
    }

    func testLaunchHappensOnce() {
        store.defaults.set(true, forKey: CrashReporter.consentKey)
        let crash = reporter(dsn: dsn)
        crash.launch()
        crash.launch()
        XCTAssertEqual(engine.starts.count, 1)
        // The second call did not find the first one's marker and take it
        // for a crash.
        XCTAssertFalse(store.defaults.bool(forKey: CrashReporter.waitingKey))
    }

    // MARK: - The question after an unexpected quit

    /// One run that never quit normally, then the next launch.
    private func launchAfterAnUnexpectedQuit() -> CrashReporter {
        reporter(dsn: dsn).launch()  // never noteCleanExit: it "crashed"
        let next = reporter(dsn: dsn)
        next.launch()
        return next
    }

    func testAnUnexpectedQuitLeavesAQuestionWaiting() {
        XCTAssertTrue(launchAfterAnUnexpectedQuit().hasQuestionWaiting)
    }

    func testANormalQuitLeavesNoQuestion() {
        let first = reporter(dsn: dsn)
        first.launch()
        first.noteCleanExit()
        let next = reporter(dsn: dsn)
        next.launch()
        XCTAssertFalse(next.hasQuestionWaiting)
    }

    func testAFirstEverLaunchIsNotAnUnexpectedQuit() {
        let crash = reporter(dsn: dsn)
        crash.launch()
        XCTAssertFalse(crash.hasQuestionWaiting)
    }

    func testNoQuestionWhenTheAnswerIsAlreadyYes() {
        store.defaults.set(true, forKey: CrashReporter.consentKey)
        XCTAssertFalse(launchAfterAnUnexpectedQuit().hasQuestionWaiting)
    }

    /// Shown once counts as asked, whatever the answer, and it is never put
    /// again, however many crashes follow.
    func testTheQuestionIsAskedOnce() {
        let crash = launchAfterAnUnexpectedQuit()
        crash.questionShown()
        XCTAssertFalse(crash.hasQuestionWaiting)
        XCTAssertFalse(launchAfterAnUnexpectedQuit().hasQuestionWaiting)
    }

    /// A launch that could not show it (setup or a new version's card had
    /// the panel) leaves it for the next one, crash or not.
    func testAnUnshownQuestionWaitsForALaterLaunch() {
        let crash = launchAfterAnUnexpectedQuit()
        crash.noteCleanExit()
        let later = reporter(dsn: dsn)
        later.launch()
        XCTAssertTrue(later.hasQuestionWaiting)
    }

    func testSayingYesAnywhereClearsTheQuestion() {
        let crash = launchAfterAnUnexpectedQuit()
        crash.isEnabled = true
        XCTAssertFalse(crash.hasQuestionWaiting)
        crash.isEnabled = false
        XCTAssertFalse(crash.hasQuestionWaiting, "a later no does not bring it back")
    }

    func testNoQuestionWithoutADSN() {
        reporter(dsn: nil).launch()
        let next = reporter(dsn: nil)
        next.launch()
        XCTAssertFalse(next.hasQuestionWaiting)
    }
}

@MainActor
private final class FakeEngine: CrashReportEngine {
    var starts: [String] = []
    var stops = 0
    func start(dsn: String) { starts.append(dsn) }
    func stop() { stops += 1 }
}

/// What Sentry is told, what a report looks like on its way out, and that
/// starting it does not cost the app its broken-pipe handling.
@MainActor
final class SentryCrashEngineTests: XCTestCase {
    private let scrubber = CrashReportScrubber(computerNames: ["Ana's MacBook Pro", "Anas-MacBook-Pro"],
                                               userNames: ["anagarcia", "Ana García"])
    private var scratch: TestScratch!
    private var store: TestDefaults!

    override func setUp() async throws {
        scratch = TestScratch("sentry")
        store = TestDefaults("com.airlock.test.sentryengine")
    }

    override func tearDown() async throws {
        scratch.remove()
        store.remove()
    }

    private func makeOptions() -> Options {
        SentryCrashEngine.options(dsn: "https://k@o1.ingest.de.sentry.io/2", cacheFolder: scratch.root,
                                  scrubber: scrubber,
                                  allowance: CrashReportAllowance(suiteName: store.name))
    }

    func testOnlyCrashesAndHangsAreOn() {
        let options = makeOptions()
        XCTAssertTrue(options.enableCrashHandler)
        XCTAssertTrue(options.enableAppHangTracking)
        XCTAssertEqual(options.appHangTimeoutInterval, 5)
        XCTAssertFalse(options.sendDefaultPii)
        XCTAssertEqual(options.maxBreadcrumbs, 0)
        XCTAssertFalse(options.enableAutoBreadcrumbTracking)
        XCTAssertFalse(options.enableNetworkBreadcrumbs)
        XCTAssertFalse(options.enableSwizzling)
        XCTAssertFalse(options.enableAutoPerformanceTracing)
        XCTAssertFalse(options.enableNetworkTracking)
        XCTAssertFalse(options.enableFileIOTracing)
        XCTAssertFalse(options.enableCaptureFailedRequests)
        XCTAssertNil(options.tracesSampleRate)
        XCTAssertFalse(options.enableAutoSessionTracking)
        XCTAssertFalse(options.enableWatchdogTerminationTracking)
        XCTAssertFalse(options.sendClientReports)
        XCTAssertFalse(options.enableMetricKit)
        XCTAssertFalse(options.enableUncaughtNSExceptionReporting)
        XCTAssertEqual(options.cacheDirectoryPath, scratch.root.path)
        XCTAssertNil(options.beforeBreadcrumb?(Breadcrumb()))
    }

    /// A report built with everything that can name a person in it, sent
    /// through the options' own `beforeSend`.
    func testAReportLeavesWithoutThePerson() throws {
        let options = makeOptions()
        let event = Event(level: .fatal)
        event.serverName = "Anas-MacBook-Pro"
        event.user = User(userId: "installation-id")
        event.breadcrumbs = [Breadcrumb()]
        event.message = SentryMessage(formatted: "could not open /Users/anagarcia/Secret/plan.txt")
        event.extra = ["owner": "Ana García", "hostname": "Anas-MacBook-Pro"]
        event.tags = ["where": "Ana's MacBook Pro"]
        event.context = [
            "app": ["app_version": "1.0.19", "app_build": "880", "device_app_hash": "4f2a"],
            "device": ["model": "Mac15,6", "locale": "es_ES"],
            "os": ["name": "macOS", "version": "26.5"],
            "culture": ["timezone": "Europe/Madrid"],
        ]
        let exception = Exception(value: "EXC_BAD_ACCESS reading /Users/anagarcia/x", type: "EXC_BAD_ACCESS")
        let frame = Frame()
        frame.package = "/Users/anagarcia/Applications/Airlock.app/Contents/MacOS/Airlock"
        frame.function = "NotchController.show()"
        frame.instructionAddress = "0x0000000100001234"
        exception.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        event.exceptions = [exception]
        let thread = SentryThread(threadId: 0)
        thread.name = "anagarcia's worker"
        event.threads = [thread]
        let image = DebugMeta()
        image.codeFile = "/Users/anagarcia/Applications/Airlock.app/Contents/MacOS/Airlock"
        event.debugMeta = [image]

        let sent = try XCTUnwrap(options.beforeSend?(event))

        XCTAssertNil(sent.serverName)
        // Nobody, and an empty place so Sentry does not look up the town.
        let sentUser = try XCTUnwrap(sent.user?.serialize())
        XCTAssertEqual(Array(sentUser.keys), ["geo"])
        XCTAssertEqual((sentUser["geo"] as? [String: Any])?.isEmpty, true)
        XCTAssertNil(sent.breadcrumbs)
        XCTAssertEqual(sent.message?.formatted, "could not open /Users/<user>/Secret/plan.txt")
        XCTAssertEqual(sent.extra?["owner"] as? String, "<user>")
        XCTAssertNil(sent.extra?["hostname"])
        XCTAssertEqual(sent.tags?["where"], "<computer>")
        XCTAssertEqual(Set(sent.context.map { Array($0.keys) } ?? []), ["app", "device", "os"])
        XCTAssertEqual(Set(sent.context?["app"].map { Array($0.keys) } ?? []), ["app_version", "app_build"])
        XCTAssertEqual(sent.context?["device"]?["model"] as? String, "Mac15,6")
        XCTAssertNil(sent.context?["device"]?["locale"])
        XCTAssertEqual(sent.exceptions?.first?.value, "EXC_BAD_ACCESS reading /Users/<user>/x")
        let sentFrame = try XCTUnwrap(sent.exceptions?.first?.stacktrace?.frames.first)
        XCTAssertEqual(sentFrame.package, "/Users/<user>/Applications/Airlock.app/Contents/MacOS/Airlock")
        // What a fix needs is untouched.
        XCTAssertEqual(sentFrame.function, "NotchController.show()")
        XCTAssertEqual(sentFrame.instructionAddress, "0x0000000100001234")
        XCTAssertEqual(sent.threads?.first?.name, "<user>'s worker")
        XCTAssertEqual(sent.debugMeta?.first?.codeFile,
                       "/Users/<user>/Applications/Airlock.app/Contents/MacOS/Airlock")
        XCTAssertEqual(sent.level, .fatal)
    }

    /// The sixth report of a day stays on the Mac.
    func testAMacSendsFiveReportsADayAtMost() {
        let options = makeOptions()
        for _ in 1...CrashReportAllowance.perDay {
            XCTAssertNotNil(options.beforeSend?(Event(level: .fatal)))
        }
        XCTAssertNil(options.beforeSend?(Event(level: .fatal)))
    }

    /// The real Sentry, started and closed in this process with a DSN that
    /// goes nowhere. It takes SIGPIPE with the rest of the fatal signals,
    /// which is the bug `BrokenPipeGuard.reclaim` exists for, and gives it
    /// back when closed.
    func testSentryTakesSIGPIPEAndClosingGivesItBack() throws {
        try withOurSIGPIPEHandling { ours in
            SentrySDK.start(options: SentryCrashEngine.options(
                dsn: "https://0123abcd@o0.ingest.invalid/1", cacheFolder: scratch.root,
                scrubber: scrubber, allowance: CrashReportAllowance(suiteName: store.name)))
            let during = currentHandler(SIGPIPE)
            SentrySDK.close()
            XCTAssertNotEqual(during, ours, "Sentry left SIGPIPE alone; reclaim may no longer be needed")
            XCTAssertEqual(currentHandler(SIGPIPE), ours)
        }
    }

    /// The engine puts the app's handler back at once, so a write into a
    /// closed pipe fails like any write instead of becoming a crash report
    /// and the end of the app. Stopping removes what Sentry kept on disk.
    func testTheEngineKeepsBrokenPipesSurvivable() throws {
        try withOurSIGPIPEHandling { ours in
            let folder = scratch.folder("reports")
            let engine = SentryCrashEngine(cacheFolder: folder,
                                           allowance: CrashReportAllowance(suiteName: store.name))
            let segvBefore = currentHandler(SIGSEGV)
            engine.start(dsn: "https://0123abcd@o0.ingest.invalid/1")
            defer { engine.stop() }

            XCTAssertNotEqual(currentHandler(SIGSEGV), segvBefore, "Sentry's crash handler is not running")
            XCTAssertEqual(currentHandler(SIGPIPE), ours)
            XCTAssertEqual(writeIntoAClosedPipe(), EPIPE)

            engine.stop()
            XCTAssertEqual(currentHandler(SIGSEGV), segvBefore)
            XCTAssertEqual(currentHandler(SIGPIPE), ours)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        }
    }

    /// Only one file talks to Sentry, so what it is told is in one place.
    func testOnlyTheEngineImportsSentry() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AirlockAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        let importers = try files.filter { file in
            try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n")
                .contains { $0.trimmingCharacters(in: .whitespaces) == "import Sentry" }
        }
        XCTAssertEqual(importers.map(\.lastPathComponent), ["SentryCrashEngine.swift"])
    }

    // MARK: - Helpers

    /// Runs `body` with the app's own SIGPIPE handler installed, and puts the
    /// process's original handling back afterwards.
    private func withOurSIGPIPEHandling(_ body: (Int) throws -> Void) throws {
        var saved = sigaction()
        sigaction(SIGPIPE, nil, &saved)
        defer {
            BrokenPipeGuard.install(log: nil)
            sigaction(SIGPIPE, &saved, nil)
        }
        BrokenPipeGuard.install(log: nil)
        try body(currentHandler(SIGPIPE))
    }

    private func currentHandler(_ signal: Int32) -> Int {
        var now = sigaction()
        sigaction(signal, nil, &now)
        return unsafeBitCast(now.__sigaction_u.__sa_handler, to: Int.self)
    }

    private func writeIntoAClosedPipe() -> Int32 {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return -1 }
        Darwin.close(ends[0])
        defer { Darwin.close(ends[1]) }
        var byte: UInt8 = 0x41
        errno = 0
        let wrote = Darwin.write(ends[1], &byte, 1)
        return wrote < 0 ? errno : 0
    }
}
