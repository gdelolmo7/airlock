import XCTest
@testable import AirlockCore

final class ClaudeHookInstallerTests: XCTestCase {
    private var configURL: URL!
    private var installer: ClaudeHookInstaller!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("an-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        configURL = dir.appendingPathComponent("settings.json")
        installer = ClaudeHookInstaller(configURL: configURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent())
    }

    private func readHooks() throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        return (root?["hooks"] as? [String: Any]) ?? [:]
    }

    func testInstallSubscribesAllEventsWithCorrectTimeouts() throws {
        try installer.install(hookBinaryPath: "/x/airlock-hook")
        let hooks = try readHooks()

        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                      "PostToolUse", "Stop", "SessionEnd", "Notification"] {
            XCTAssertNotNil(hooks[event], "missing \(event)")
        }

        func timeout(_ event: String) throws -> Int {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            let inner = try XCTUnwrap(entries.first?["hooks"] as? [[String: Any]])
            return try XCTUnwrap(inner.first?["timeout"] as? Int)
        }
        // Only the gates hold; everything else has a short leash — including
        // Notification, which is informational (a former bug kept it at 24h).
        XCTAssertEqual(try timeout("PreToolUse"), 86_400)
        XCTAssertEqual(try timeout("PermissionRequest"), 86_400, "Claude asking in its own window is a gate too")
        XCTAssertEqual(try timeout("Notification"), 5)
        XCTAssertEqual(try timeout("Stop"), 5)
        XCTAssertEqual(try command(hooks, "PermissionRequest"),
                       "'/x/airlock-hook' --source claude-code --event PermissionRequest")
        XCTAssertEqual(installer.status(), .installed)
    }

    /// The first managed command under `event`.
    private func command(_ hooks: [String: Any], _ event: String) throws -> String {
        let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "no \(event)")
        let managed = try XCTUnwrap(entries.first { entry in
            ((entry["hooks"] as? [[String: Any]])?.first?["command"] as? String)?.contains("airlock-hook") ?? false
        }, "nothing of ours under \(event)")
        let inner = try XCTUnwrap(managed["hooks"] as? [[String: Any]])
        return try XCTUnwrap(inner.first?["command"] as? String)
    }

    /// A hook of the user's own whose path merely CONTAINS our binary's name.
    ///
    /// It used to read as an install of ours, which is how `upgrade` would have
    /// wired their script into the events it added and `uninstall` would have
    /// deleted their entries.
    func testAHookNamedLikeOursIsNotOurs() throws {
        let theirs: [String: Any] = ["hooks": [
            "PreToolUse": [["matcher": "Bash", "hooks": [[
                "type": "command",
                "command": "~/bin/airlock-hook-logger.sh --source claude-code --event PreToolUse",
            ]]]],
            "Stop": [["matcher": "", "hooks": [[
                "type": "command", "command": "/opt/agentic-notch-hooks/notify.sh",
            ]]]],
        ]]
        let data = try JSONSerialization.data(withJSONObject: theirs)
        try data.write(to: configURL)

        XCTAssertEqual(installer.status(), .notInstalled, "none of this is ours")
        XCTAssertEqual(try installer.upgrade(), [], "and there is no install of ours to extend")
        try installer.uninstall()
        XCTAssertEqual(try Data(contentsOf: configURL), data,
                       "nothing of theirs removed — and nothing rewritten either")

        // Ours is still ours, spaces in the path and all.
        try installer.install(hookBinaryPath: "/Users/me/Application Support/Airlock/airlock-hook")
        XCTAssertEqual(installer.status(), .installed)
        let hooks = try readHooks()
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.count, 2, "their logger kept its place beside ours")
        XCTAssertEqual(try installer.upgrade(), [], "and the install reads as current")
    }

    // MARK: - Upgrade

    /// A settings file as the builds before PermissionRequest wrote it: seven
    /// events, the user's own validator ahead of ours, and a PermissionRequest
    /// hook the user wrote themselves.
    private func writeOlderInstall(binary: String = "/Users/me/Library/Application Support/Airlock/airlock-hook") throws {
        let quoted = ClaudeHookInstaller.shellQuoted(binary)
        var hooks: [String: Any] = [:]
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd", "Notification"] {
            hooks[event] = [[
                "matcher": "",
                "hooks": [["type": "command", "command": "\(quoted) --source claude-code --event \(event)",
                           "timeout": event == "PreToolUse" ? 86_400 : 5]],
            ]]
        }
        hooks["PreToolUse"] = [["matcher": "Bash", "hooks": [["type": "command", "command": "/my/own/validator"]]]]
            + (hooks["PreToolUse"] as! [[String: Any]])
        hooks["PermissionRequest"] = [["matcher": "Bash", "hooks": [["type": "command", "command": "/my/own/logger"]]]]
        try JSONSerialization.data(withJSONObject: ["model": "opus", "hooks": hooks]).write(to: configURL)
    }

    /// The reported bug's other half: an install from before PermissionRequest
    /// never heard it. Upgrading adds exactly that, beside the user's own hook
    /// for it, running the same binary as the install's other entries — and
    /// moves, rewrites or drops nothing else.
    func testUpgradeAddsWhatAnOlderInstallLacksAndNothingElse() throws {
        try writeOlderInstall()
        let before = try readHooks()

        XCTAssertEqual(try installer.upgrade(), ["PermissionRequest"])

        let after = try readHooks()
        for (event, entries) in before where event != "PermissionRequest" {
            XCTAssertEqual(after[event] as? NSArray, entries as? NSArray, "\(event) untouched")
        }
        let permission = try XCTUnwrap(after["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(permission.count, 2)
        XCTAssertEqual(permission.first?["matcher"] as? String, "Bash", "the user's own hook stays first")
        XCTAssertEqual(permission.last?["matcher"] as? String, "")
        let ours = try XCTUnwrap((permission.last?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(ours["command"] as? String,
                       "'/Users/me/Library/Application Support/Airlock/airlock-hook' --source claude-code --event PermissionRequest",
                       "same binary, quoted the same way, as the entries beside it")
        XCTAssertEqual(ours["timeout"] as? Int, 86_400)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        XCTAssertEqual(root?["model"] as? String, "opus")
    }

    /// Runs at every launch, so it must settle: once nothing is missing it
    /// writes nothing at all.
    func testUpgradeIsIdempotent() throws {
        try writeOlderInstall()
        try installer.upgrade()
        let settled = try Data(contentsOf: configURL)

        XCTAssertEqual(try installer.upgrade(), [])
        XCTAssertEqual(try Data(contentsOf: configURL), settled, "not rewritten")

        try installer.install(hookBinaryPath: "/x/airlock-hook")
        let installed = try Data(contentsOf: configURL)
        XCTAssertEqual(try installer.upgrade(), [], "a current install has everything")
        XCTAssertEqual(try Data(contentsOf: configURL), installed)
    }

    /// Upgrading is never installing — not on a Mac with no settings, not over
    /// somebody's own hooks, and not over a pre-rename install, which the
    /// app's migration rewrites whole instead (a new entry never names the old
    /// binary).
    func testUpgradeNeverInstalls() throws {
        XCTAssertEqual(try installer.upgrade(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path), "no file conjured")

        let theirs: [String: Any] = ["hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "/my/notifier"]]]]]]
        try JSONSerialization.data(withJSONObject: theirs).write(to: configURL)
        let untouched = try Data(contentsOf: configURL)
        XCTAssertEqual(try installer.upgrade(), [])
        XCTAssertEqual(try Data(contentsOf: configURL), untouched)

        let legacy: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "", "hooks": [[
            "type": "command", "command": "/Users/me/.agentic-notch/bin/agentic-notch-hook --source claude-code --event PreToolUse",
        ]]]]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: configURL)
        let old = try Data(contentsOf: configURL)
        XCTAssertEqual(try installer.upgrade(), [])
        XCTAssertEqual(try Data(contentsOf: configURL), old)

        // Codex's events have not grown, so its installer has nothing to add.
        let codex = CodexHookInstaller(configURL: configURL.deletingLastPathComponent().appendingPathComponent("config.toml"))
        XCTAssertEqual(try codex.upgrade(), [])
    }

    /// A value under a hook event that is not an array of entries is somebody
    /// else's — a hand-edited file, a newer schema, a mistake. It is left
    /// exactly as it is.
    ///
    /// It used to be read as an empty list and written back as our single
    /// entry, which took whatever was there with it — at every launch, once
    /// upgrading started running by itself.
    func testAnEventOfAnUnexpectedShapeIsLeftAlone() throws {
        let odd: [String: Any] = [
            "hooks": [
                // An object where Claude documents a list.
                "PostToolUse": ["matcher": "", "hooks": [["type": "command", "command": "/theirs.sh"]]],
                // A list with something in it that is not an entry.
                "Stop": [["matcher": "", "hooks": [["type": "command", "command": "/theirs.sh"]]], "surprise"],
                // And a real install, so the file counts as ours.
                "PreToolUse": [["matcher": "", "hooks": [[
                    "type": "command",
                    "command": "'/Users/me/.airlock/bin/airlock-hook' --source claude-code --event PreToolUse",
                    "timeout": 86_400,
                ]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: odd).write(to: configURL)

        XCTAssertFalse(try installer.upgrade().contains("PostToolUse"))
        var hooks = try readHooks()
        XCTAssertNotNil(hooks["PostToolUse"] as? [String: Any], "still their object")
        XCTAssertEqual((hooks["Stop"] as? [Any])?.count, 2, "still their list, surprise and all")

        // The same rule for an explicit install, and uninstall leaves them too.
        try installer.install(hookBinaryPath: "/x/airlock-hook")
        hooks = try readHooks()
        XCTAssertNotNil(hooks["PostToolUse"] as? [String: Any])
        XCTAssertEqual((hooks["Stop"] as? [Any])?.count, 2)
        XCTAssertNotNil(hooks["SessionStart"], "the events it could write, it wrote")

        try installer.uninstall()
        hooks = try readHooks()
        XCTAssertNotNil(hooks["PostToolUse"] as? [String: Any])
        XCTAssertEqual((hooks["Stop"] as? [Any])?.count, 2)
    }

    /// What upgrading added, uninstalling takes away — and only that.
    func testUninstallRemovesTheUpgradedEntry() throws {
        try writeOlderInstall()
        try installer.upgrade()
        try installer.uninstall()

        let hooks = try readHooks()
        let permission = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(permission.count, 1)
        XCTAssertEqual(permission.first?["matcher"] as? String, "Bash", "the user's own hook survives")
        XCTAssertNil(hooks["Stop"])
        XCTAssertEqual(installer.status(), .notInstalled)

        try installer.install(hookBinaryPath: "/x/airlock-hook")
        try installer.uninstall()
        XCTAssertEqual((try readHooks()["PermissionRequest"] as? [[String: Any]])?.count, 1)
    }

    func testUserEntriesAndSettingsSurviveInstallUninstall() throws {
        let original: [String: Any] = [
            "model": "opus",
            "hooks": [
                "PreToolUse": [[
                    "matcher": "Bash",
                    "hooks": [["type": "command", "command": "/my/own/validator"]],
                ]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: configURL)

        try installer.install(hookBinaryPath: "/x/airlock-hook")
        var hooks = try readHooks()
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.count, 2, "user entry + managed entry coexist")

        try installer.uninstall()
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        XCTAssertEqual(root?["model"] as? String, "opus", "unrelated settings preserved")
        hooks = (root?["hooks"] as? [String: Any]) ?? [:]
        let remaining = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?["matcher"] as? String, "Bash", "user hook untouched")
        XCTAssertNil(hooks["Stop"], "events that held only managed entries are removed")
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testReinstallReplacesNotDuplicates() throws {
        try installer.install(hookBinaryPath: "/x/airlock-hook")
        try installer.install(hookBinaryPath: "/y/airlock-hook")
        let hooks = try readHooks()
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        let inner = try XCTUnwrap(stop.first?["hooks"] as? [[String: Any]])
        XCTAssertTrue((inner.first?["command"] as? String)?.hasPrefix("'/y/") ?? false)
    }

    /// Found live: Claude runs hook commands via /bin/sh -c, so an unquoted
    /// path containing a space ("…/Application Support/…") shell-splits and
    /// silently breaks every hook. The command must parse back to the binary.
    func testSpacedHookPathSurvivesShellParsing() throws {
        let spaced = "/tmp/Application Support/airlock-hook"
        try installer.install(hookBinaryPath: spaced)
        let hooks = try readHooks()
        let entries = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let inner = try XCTUnwrap(entries.first?["hooks"] as? [[String: Any]])
        let command = try XCTUnwrap(inner.first?["command"] as? String)

        // sh -c would split the FIRST word as argv[0]; with quoting, the
        // quoted region is one word equal to the binary path.
        XCTAssertTrue(command.hasPrefix("'\(spaced)'"), "binary path must be single-quoted, got: \(command)")
        // And embedded single quotes cannot break out of the quoting.
        XCTAssertEqual(ClaudeHookInstaller.shellQuoted("it's"), #"'it'\''s'"#)
    }
}

final class HookBinaryStagerTests: XCTestCase {
    /// Regression guard for the live-found shell-split bug: the default staged
    /// location must never contain whitespace (Codex commands are unquoted).
    func testDefaultStagedPathHasNoWhitespace() {
        XCTAssertFalse(HookBinaryStager.defaultStagedURL().path.contains(where: \.isWhitespace))
    }

    func testStageCopiesReplacesAndMarksExecutable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("an-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("airlock-hook")
        let dest = dir.appendingPathComponent("bin/airlock-hook")

        try Data("v1".utf8).write(to: source)
        try HookBinaryStager.stage(from: source, to: dest)
        try Data("v2".utf8).write(to: source)
        try HookBinaryStager.stage(from: source, to: dest)

        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "v2", "restage replaces")
        let perms = try FileManager.default.attributesOfItem(atPath: dest.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o755)

        // locateSourceHook finds a sibling of an executable, or nothing.
        let neighbor = dir.appendingPathComponent("airlock-setup")
        try Data().write(to: neighbor)
        XCTAssertEqual(HookBinaryStager.locateSourceHook(near: neighbor), source)
        XCTAssertNil(HookBinaryStager.locateSourceHook(near: dir.appendingPathComponent("empty/nope")),
                     "no hook sibling → nil")
    }
}