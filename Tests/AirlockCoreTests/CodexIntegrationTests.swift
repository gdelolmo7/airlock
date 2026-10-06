import XCTest
@testable import AirlockCore

final class CodexIntegrationTests: XCTestCase {
    private let integration = CodexIntegration()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func decode(_ json: String) throws -> [AgentEvent] {
        try integration.decodeEvents(
            from: Data(json.utf8),
            context: HookContext(source: "codex", cwd: nil, terminal: nil, receivedAt: now))
    }

    // MARK: Registry

    func testRegistryResolvesCodex() {
        XCTAssertNotNil(AgentRegistry.shared.integration(source: "codex"))
        XCTAssertEqual(AgentRegistry.shared.integration(kind: .codex)?.source, "codex")
    }

    // MARK: Decoding (Claude-style schema, non-gating)

    func testSessionStartTagsCodexAgent() throws {
        let events = try decode(#"{"session_id":"cx-1","hook_event_name":"SessionStart","cwd":"/Users/me/api"}"#)
        XCTAssertEqual(events.first?.agent, .codex)
        guard case let .sessionStarted(project, _, _) = events.first?.kind else {
            return XCTFail("expected sessionStarted")
        }
        XCTAssertEqual(project, "api")
    }

    func testNeverBlocksAndEmitsNoDirective() {
        // Codex hooks are observational — nothing may ever wait on the notch.
        XCTAssertFalse(integration.isBlocking(eventName: "PreToolUse"))
        XCTAssertFalse(integration.isBlocking(eventName: "PermissionRequest"))
        XCTAssertNil(integration.directiveOutput(
            for: HookDirective(action: .allow), eventName: "PreToolUse"))
    }

    func testPreToolUseBecomesQuestionNotPermissionCard() throws {
        let events = try decode(#"{"session_id":"cx-1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm run build"}}"#)
        guard case let .questionAsked(prompt) = events.first?.kind else {
            return XCTFail("non-gating agents must not raise permission cards, got \(events)")
        }
        XCTAssertTrue(prompt.contains("Approve in terminal"))
        XCTAssertTrue(prompt.contains("npm run build"))
    }

    func testStopClearsTerminalQuestion() throws {
        let events = try decode(#"{"session_id":"cx-1","hook_event_name":"Stop"}"#)
        XCTAssertEqual(events.map(\.kind), [
            .questionAnswered(answer: ""),
            .turnEnded(assistantMessage: nil),
        ])
    }

    // MARK: Process matching

    func testMatchesProcess() {
        XCTAssertTrue(integration.matchesProcess(command: "codex"))
        XCTAssertTrue(integration.matchesProcess(command: "/opt/homebrew/bin/codex exec fix tests"))
        XCTAssertTrue(integration.matchesProcess(command: "codex-aarch64-apple-darwin exec"))
        XCTAssertTrue(integration.matchesProcess(command: "node /x/.bin/codex"))
        XCTAssertFalse(integration.matchesProcess(command: "vim codex.md"))
        XCTAssertFalse(integration.matchesProcess(command: "grep codex notes.txt"))
        XCTAssertFalse(integration.matchesProcess(command: "claude"))
    }
}

final class CodexHookInstallerTests: XCTestCase {
    private var configURL: URL!
    private var installer: CodexHookInstaller!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("an-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        configURL = dir.appendingPathComponent("config.toml")
        installer = CodexHookInstaller(configURL: configURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent())
    }

    func testInstallCreatesManagedBlock() throws {
        try installer.install(hookBinaryPath: "/x/airlock-hook")
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains(CodexHookInstaller.beginMarker))
        XCTAssertTrue(text.contains("[[hooks.SessionStart]]"))
        // `type = "command"` is required — codex refuses to boot without it
        // (found live in the shakedown).
        XCTAssertTrue(text.contains(#"hooks = [{ type = "command", command = "/x/airlock-hook --source codex --event Stop" }]"#))
        XCTAssertEqual(installer.status(), .installed)
    }

    func testInstallIsIdempotent() throws {
        try installer.install(hookBinaryPath: "/x/hook-v1")
        try installer.install(hookBinaryPath: "/x/hook-v2")
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: CodexHookInstaller.beginMarker).count, 2,
                       "exactly one managed block")
        XCTAssertFalse(text.contains("hook-v1"), "reinstall replaces the old block")
    }

    func testUserContentSurvivesInstallAndUninstall() throws {
        let original = "# my config\nmodel = \"o4\"\napproval_policy = \"on-request\"\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        try installer.install(hookBinaryPath: "/x/hook")
        var text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(original), "user content stays byte-identical, block appends")

        try installer.uninstall()
        text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(text, original)
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testConflictOnUnmanagedEntries() throws {
        try "[[hooks.Stop]]\nhooks = [{ command = \"/elsewhere/airlock-hook --source codex\" }]\n"
            .write(to: configURL, atomically: true, encoding: .utf8)
        guard case .conflict = installer.status() else {
            return XCTFail("unmanaged entries must surface as a conflict, not be clobbered")
        }
    }

    func testUninstallMissingFileIsNoop() {
        XCTAssertNoThrow(try installer.uninstall())
        XCTAssertEqual(installer.status(), .notInstalled)
    }
}
