import AirlockTestSupport
import XCTest
@testable import AirlockCore

final class UsageSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_738_000_000)

    func testParsesDocumentedShape() throws {
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41,"resets_at":1738857600}}}"#
        let snapshot = try XCTUnwrap(UsageSnapshot.parse(statusLineJSON: Data(json.utf8), at: now))
        XCTAssertEqual(snapshot.fiveHour?.usedPercentage, 23.5)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_738_425_600))
        XCTAssertEqual(snapshot.sevenDay?.usedPercentage, 41) // integer percentage tolerated
    }

    func testWindowsIndependentlyAbsent() throws {
        let json = #"{"rate_limits":{"seven_day":{"used_percentage":2}}}"#
        let snapshot = try XCTUnwrap(UsageSnapshot.parse(statusLineJSON: Data(json.utf8), at: now))
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.sevenDay?.resetsAt)
    }

    func testNoRateLimitsMeansNilNotEmpty() {
        // API-key users have no rate_limits — never clobber a good cache.
        XCTAssertNil(UsageSnapshot.parse(statusLineJSON: Data(#"{"model":{"id":"x"}}"#.utf8), at: now))
        XCTAssertNil(UsageSnapshot.parse(statusLineJSON: Data("garbage".utf8), at: now))
    }

    func testCacheRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("an-usage-\(UUID().uuidString)/usage.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let snapshot = UsageSnapshot(
            fiveHour: RateLimitWindow(usedPercentage: 11, resetsAt: Date(timeIntervalSince1970: 1_738_425_600)),
            sevenDay: nil, capturedAt: now)
        try snapshot.save(to: url)
        XCTAssertEqual(UsageSnapshot.load(from: url), snapshot)
    }
}

final class StatusLineBridgeTests: XCTestCase {
    private func tempCache() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("an-slb-\(UUID().uuidString)/usage.json")
    }

    func testCachesAndChainsTransparently() throws {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let input = Data(#"{"rate_limits":{"five_hour":{"used_percentage":11,"resets_at":1738425600}},"model":{"display_name":"Opus"}}"#.utf8)

        // Chain to `cat`: a stand-in for the user's script — output must be
        // its stdout, fed the same stdin bytes.
        let chain = Data("cat".utf8).base64EncodedString()
        let output = StatusLineBridge.process(input: input, cacheURL: cache, chainCommandB64: chain)

        XCTAssertEqual(output, input, "chained command sees identical stdin and owns stdout")
        XCTAssertEqual(UsageSnapshot.load(from: cache)?.fiveHour?.usedPercentage, 11)
    }

    func testNoChainPrintsNothingAndBrokenChainFailsOpen() {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        XCTAssertTrue(StatusLineBridge.process(
            input: Data("{}".utf8), cacheURL: cache, chainCommandB64: nil).isEmpty)
        XCTAssertTrue(StatusLineBridge.process(
            input: Data("{}".utf8), cacheURL: cache, chainCommandB64: "not-base64!!").isEmpty)
        XCTAssertNil(UsageSnapshot.load(from: cache), "no rate_limits → cache untouched")
    }

    /// Nothing obliges a status line to read its input, and once one has
    /// exited, the bridge's write has no reader. That raised SIGPIPE, whose
    /// default is to kill the writer: the hook, mid-render — and here, the
    /// whole test run. The input is more than a pipe holds, so the write
    /// cannot finish before the command has gone. With a real payload of a
    /// few KB it is a race instead, one the hook nearly always wins.
    func testAChainThatNeverReadsItsInputCannotKillTheCaller() {
        let scratch = TestScratch()
        let input = Data(repeating: UInt8(ascii: " "), count: 1 << 20)
        let chain = Data("echo chained".utf8).base64EncodedString()

        let output = StatusLineBridge.process(
            input: input, cacheURL: scratch.file("usage.json"),
            namesURL: scratch.file("session-names.json"), chainCommandB64: chain)

        XCTAssertEqual(String(decoding: output, as: UTF8.self), "chained\n",
                       "a write nobody reads must not cost the line the command did print")
    }

    /// A command that neither reads nor exits blocks the write on a full pipe,
    /// so the deadline has to be running by then or nothing ends it. `exec`,
    /// so the deadline's SIGTERM lands on the command itself, not on a shell
    /// that would leave it holding the pipes.
    func testAChainThatNeitherReadsNorExitsIsStillCutOff() {
        let scratch = TestScratch()
        let input = Data(repeating: UInt8(ascii: " "), count: 1 << 20)
        let chain = Data("exec sleep 30".utf8).base64EncodedString()

        let started = Date()
        let output = StatusLineBridge.process(
            input: input, cacheURL: scratch.file("usage.json"),
            namesURL: scratch.file("session-names.json"), chainCommandB64: chain,
            timeout: 0.3)

        XCTAssertTrue(output.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "ended by the deadline, not by the command")
    }
}

final class SessionTitleTests: XCTestCase {
    func testBridgeRecordsSessionNames() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("an-names-\(UUID().uuidString)")
        let namesURL = dir.appendingPathComponent("session-names.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = Data(#"{"session_id":"abc","session_name":"Checkout flow rewrite"}"#.utf8)
        _ = StatusLineBridge.process(input: input, cacheURL: dir.appendingPathComponent("u.json"),
                                     namesURL: namesURL, chainCommandB64: nil)
        XCTAssertEqual(SessionNameCache.load(from: namesURL).names["abc"]?.name,
                       "Checkout flow rewrite")
    }

    func testTranscriptSummaryScan() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("an-tr-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"type":"summary","summary":"Old title","leafUuid":"a"}"#,
            #"{"type":"assistant","message":{"content":"…"}}"#,
            #"{"type":"summary","summary":"Checkout flow rewrite and tests","leafUuid":"b"}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptTitles.latestSummary(atPath: url.path),
                       "Checkout flow rewrite and tests")
        XCTAssertNil(TranscriptTitles.latestSummary(atPath: "/nonexistent"))
    }

    /// Verified on-disk: the desktop app records titles as custom-title
    /// records, not summary records — and they win as the latest word.
    func testCustomTitleRecordWins() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("an-ct-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"summary","summary":"early guess","leafUuid":"a"}"#,
            #"{"type":"user","message":{"content":"work work"}}"#,
            #"{"type":"custom-title","customTitle":"Checkout Flow rewrite and tests","sessionId":"x"}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptTitles.latestSummary(atPath: url.path),
                       "Checkout Flow rewrite and tests")
    }

    /// A transcript that opens but cannot be read has no title, like a missing
    /// one, rather than crashing the app. A write-only handle is the failure a
    /// test can stage without special permissions: it seeks, so the scan gets
    /// as far as the read, and then every read fails (EBADF).
    func testUnreadableTranscriptIsNoTitleNotACrash() throws {
        let scratch = TestScratch()
        let url = scratch.file("t.jsonl")
        try Data(#"{"type":"summary","summary":"Found when readable","leafUuid":"a"}"#.utf8).write(to: url)
        XCTAssertEqual(TranscriptTitles.latestSummary(atPath: url.path), "Found when readable",
                       "the file itself is fine; only the handle cannot read it")

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        XCTAssertNil(TranscriptTitles.latestSummary(reading: handle, byteBudget: 16 * 1024 * 1024))

        // Past the budget, the head-and-tail read: different seeks, same reads.
        try handle.truncate(atOffset: 2 * 1024 * 1024)
        XCTAssertNil(TranscriptTitles.latestSummary(reading: handle, byteBudget: 1024 * 1024))
    }

    func testExplicitTitleOutranksPromptAndSticks() {
        var state = SessionState()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        state.apply(AgentEvent(sessionID: "s", agent: .claudeCode, sequence: 1, timestamp: t0,
                               kind: .promptSubmitted(prompt: "looks better, but actualu values are")))
        XCTAssertNil(state.sessions["s"]?.titleExplicit)
        state.apply(AgentEvent(sessionID: "s", agent: .claudeCode, sequence: 2, timestamp: t0,
                               kind: .titleChanged(title: "Checkout flow rewrite")))
        XCTAssertEqual(state.sessions["s"]?.title, "Checkout flow rewrite")
        XCTAssertEqual(state.sessions["s"]?.titleExplicit, true)
        // Later prompts update the You-line but never the explicit title.
        state.apply(AgentEvent(sessionID: "s", agent: .claudeCode, sequence: 3, timestamp: t0,
                               kind: .promptSubmitted(prompt: "another message")))
        XCTAssertEqual(state.sessions["s"]?.title, "Checkout flow rewrite")
    }
}

final class ClaudeStatusLineInstallerTests: XCTestCase {
    private var configURL: URL!
    private var installer: ClaudeStatusLineInstaller!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("an-sli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        configURL = dir.appendingPathComponent("settings.json")
        installer = ClaudeStatusLineInstaller(configURL: configURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent())
    }

    private func statusLine() throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        return (root?["statusLine"] as? [String: Any]) ?? [:]
    }

    func testFreshInstallAndUninstallRemovesKey() throws {
        try installer.install(bridgeBinaryPath: "/x/airlock-hook")
        XCTAssertTrue(installer.isInstalled())
        XCTAssertEqual(try statusLine()["type"] as? String, "command")
        try installer.uninstall()
        XCTAssertEqual(try statusLine() as NSDictionary, [:], "no original to restore → key removed")
    }

    func testExistingCustomStatusLineIsChainedAndRestoredVerbatim() throws {
        let original = "~/.claude/statusline.sh --fancy 'with spaces'"
        let seed: [String: Any] = ["statusLine": ["type": "command", "command": original, "padding": 1],
                                   "model": "opus"]
        try JSONSerialization.data(withJSONObject: seed).write(to: configURL)

        try installer.install(bridgeBinaryPath: "/x/airlock-hook")
        var entry = try statusLine()
        let command = try XCTUnwrap(entry["command"] as? String)
        XCTAssertTrue(command.contains("--statusline"))
        XCTAssertTrue(command.contains("--chain-b64"))
        XCTAssertEqual(entry["padding"] as? Int, 1, "user's padding preserved")

        // Reinstall keeps the SAME original chain (no double-wrapping).
        try installer.install(bridgeBinaryPath: "/y/airlock-hook")
        entry = try statusLine()
        let recommand = try XCTUnwrap(entry["command"] as? String)
        XCTAssertTrue(recommand.hasPrefix("'/y/"))
        XCTAssertEqual(ClaudeStatusLineInstaller.chainArgument(in: recommand),
                       Data(original.utf8).base64EncodedString())

        try installer.uninstall()
        XCTAssertEqual(try statusLine()["command"] as? String, original, "restored byte-identical")
    }

    /// A status line of the user's own that merely has our name somewhere in
    /// its path. Reading it as ours was worse here than in the hooks: install
    /// keeps the chain of a command it thinks is already ours, so theirs would
    /// have been dropped rather than wrapped.
    func testAStatusLineNamedLikeOursIsNotOurs() throws {
        let theirs = "~/airlock-tools/statusline.sh --colour"
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": theirs]])
            .write(to: configURL)
        XCTAssertFalse(installer.isInstalled())

        try installer.install(bridgeBinaryPath: "/x/airlock-hook")
        XCTAssertTrue(installer.isInstalled())
        let command = try XCTUnwrap(try statusLine()["command"] as? String)
        XCTAssertEqual(ClaudeStatusLineInstaller.chainArgument(in: command),
                       Data(theirs.utf8).base64EncodedString(), "chained, not swallowed")

        try installer.uninstall()
        XCTAssertEqual(try statusLine()["command"] as? String, theirs)
    }

    /// Every shape we have ever written our own status line in is still read as
    /// ours.
    ///
    /// The matcher was tightened to stop it claiming other people's commands,
    /// and the usage bridge leans on it hardest: a status line of ours that
    /// failed this test would be chained a second time, wrapping our own
    /// command instead of the user's and losing whatever it had carried.
    func testOurOwnStatusLineIsRecognisedInEveryShapeWeHaveWritten() {
        let ours = [
            "'/Users/me/.airlock/bin/airlock-hook' --statusline",
            "'/Users/me/.airlock/bin/airlock-hook' --statusline --chain-b64 abc123",
            // A path with spaces, quoted the way the installer quotes it.
            "'/Users/me/Application Support/Airlock/airlock-hook' --statusline --chain-b64 abc123",
            // Before the rename, and before the quoting.
            "/Users/me/.agentic-notch/bin/agentic-notch-hook --statusline",
        ]
        for command in ours {
            XCTAssertTrue(ClaudeStatusLineInstaller.isOurCommand(command), command)
        }

        let theirs = [
            "~/airlock-tools/statusline.sh --colour",
            "/usr/local/bin/node ~/.claude/hooks/gsd-statusline.js",
            // Our binary, but the hook command rather than the status line.
            "'/Users/me/.airlock/bin/airlock-hook' --source claude-code --event Stop",
        ]
        for command in theirs {
            XCTAssertFalse(ClaudeStatusLineInstaller.isOurCommand(command), command)
        }
    }
}
