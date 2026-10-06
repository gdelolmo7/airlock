import Darwin
import XCTest
@testable import AirlockCore

/// How Airlock rewrites an agent's own config file — see `ConfigFileWriter`.
/// The launch-time hook upgrade does this on every Mac with hooks installed, so
/// what it leaves behind, what it keeps and what it does to a link are the
/// user's business before they are ours.
final class ConfigFileWriterTests: XCTestCase {
    private var dir: URL!
    /// Folders a test locked and files it made immutable, undone on the way out
    /// so the temp directory can go.
    private var locked: [URL] = []
    private var frozen: [URL] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("an-cfw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in frozen { chflags(url.path, 0) }
        for url in locked { chmod(url.path, 0o755) }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    private struct Info: Equatable {
        let isLink: Bool
        let mode: mode_t
        let inode: ino_t
        let mtime: Int
    }

    private func info(_ url: URL) -> Info? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Info(isLink: (st.st_mode & S_IFMT) == S_IFLNK, mode: st.st_mode & 0o7777, inode: st.st_ino,
                    mtime: Int(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int(st.st_mtimespec.tv_nsec))
    }

    private func listing(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func folder(_ path: String) throws -> URL {
        let url = dir.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ url: URL, _ data: Data, mode: mode_t) throws {
        try data.write(to: url)
        chmod(url.path, mode)
    }

    /// Settings as a build from before PermissionRequest wrote them, with the
    /// user's own validator beside Airlock's entries.
    private func olderClaudeInstall() throws -> Data {
        var hooks: [String: Any] = [
            "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/my/own/validator"]]]],
        ]
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd", "Notification"] {
            let entry: [String: Any] = ["matcher": "", "hooks": [[
                "type": "command",
                "command": "'/Users/me/.airlock/bin/airlock-hook' --source claude-code --event \(event)",
                "timeout": event == "PreToolUse" ? 86_400 : 5,
            ]]]
            hooks[event] = ((hooks[event] as? [[String: Any]]) ?? []) + [entry]
        }
        return try JSONSerialization.data(withJSONObject: ["model": "opus", "hooks": hooks],
                                          options: [.prettyPrinted, .sortedKeys])
    }

    private func hooks(in url: URL) throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return (root?["hooks"] as? [String: Any]) ?? [:]
    }

    /// The launch step, with every installer pointed at the test's files.
    private func launch(claude: URL, codex: URL? = nil) -> [HookUpgrade.Outcome] {
        HookUpgrade.run([
            (agent: .claudeCode, installer: ClaudeHookInstaller(configURL: claude)),
            (agent: .codex, installer: CodexHookInstaller(configURL: codex ?? dir.appendingPathComponent("codex.toml"))),
        ])
    }

    // MARK: - Temp file and backup

    /// Owner-only from the moment it exists, whatever the umask says — and it
    /// never replaces anything already there.
    func testTempFileIsPrivateFromTheStartAndNeverClobbers() throws {
        let previous = umask(0o277)   // would make a plain create read-only
        defer { umask(previous) }
        let url = dir.appendingPathComponent("settings.json.airlock-test.tmp")
        try ConfigFileWriter.createPrivateFile(at: url, containing: Data("one".utf8))
        XCTAssertEqual(info(url)?.mode, 0o600)

        umask(0)                      // would make a plain create world-writable
        let second = dir.appendingPathComponent("second.tmp")
        try ConfigFileWriter.createPrivateFile(at: second, containing: Data())
        XCTAssertEqual(info(second)?.mode, 0o600)

        XCTAssertThrowsError(try ConfigFileWriter.createPrivateFile(at: url, containing: Data("two".utf8)))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one")
    }

    /// The backup is a copy of what was there before the first write — a real,
    /// owner-only file — taken once. The file keeps its own permissions.
    func testBackupIsAPrivateCopyTakenOnceAndPermissionsAreKept() throws {
        let url = dir.appendingPathComponent("settings.json")
        let backup = dir.appendingPathComponent("settings.json.airlock.bak")
        try file(url, Data("A".utf8), mode: 0o644)

        try ConfigFileWriter.replace(url, with: Data("B".utf8))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "B")
        XCTAssertEqual(info(url)?.mode, 0o644, "the file keeps its permissions")
        XCTAssertEqual(info(backup)?.isLink, false)
        XCTAssertEqual(info(backup)?.mode, 0o600)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "A")

        try ConfigFileWriter.replace(url, with: Data("C".utf8))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "A", "taken once, never refreshed")
        XCTAssertEqual(listing(dir), ["settings.json", "settings.json.airlock.bak"])

        // A file that was not there is created owner-only, with nothing to back up.
        let fresh = dir.appendingPathComponent("fresh.json")
        try ConfigFileWriter.replace(fresh, with: Data("{}".utf8))
        XCTAssertEqual(info(fresh)?.mode, 0o600)
        XCTAssertNil(info(dir.appendingPathComponent("fresh.json.airlock.bak")))
    }

    /// What a plain rename would drop, and the reason the swap carries it
    /// across by hand: an access control list or an extended attribute the user
    /// (or macOS) put on their settings file is still there afterwards.
    func testTheFileKeepsWhatWasAttachedToIt() throws {
        let url = dir.appendingPathComponent("settings.json")
        try file(url, Data("A".utf8), mode: 0o640)
        let tag = "com.airlock.test.tag"
        let value = Data("kept".utf8)
        try value.withUnsafeBytes { bytes in
            guard setxattr(url.path, tag, bytes.baseAddress, bytes.count, 0, 0) == 0 else {
                throw XCTSkip("this filesystem does not keep extended attributes")
            }
        }

        try ConfigFileWriter.replace(url, with: Data("B".utf8))

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "B")
        XCTAssertEqual(info(url)?.mode, 0o640)
        var read = [UInt8](repeating: 0, count: 16)
        let size = getxattr(url.path, tag, &read, read.count, 0, 0)
        XCTAssertEqual(size, value.count, "the extended attribute did not survive the write")
        XCTAssertEqual(Data(read.prefix(max(0, size))), value)
    }

    /// An older build copied a linked config's LINK as its backup, so the
    /// "backup" pointed at the live file. It is replaced by a real copy, and
    /// the file it pointed at is untouched by the swap.
    func testABackupLeftAsALinkBecomesARealCopy() throws {
        let url = dir.appendingPathComponent("settings.json")
        let backup = dir.appendingPathComponent("settings.json.airlock.bak")
        try file(url, Data("before".utf8), mode: 0o600)
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: url)

        try ConfigFileWriter.replace(url, with: Data("after".utf8))
        XCTAssertEqual(info(backup)?.isLink, false)
        XCTAssertEqual(info(backup)?.mode, 0o600)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "before")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "after")
    }

    // MARK: - A linked settings.json

    /// A dotfiles manager makes `~/.claude/settings.json` a link into the
    /// user's repository. Every write goes through it to the real file; the
    /// link is never touched, and nothing is left in either folder but the one
    /// backup.
    func testLinkedClaudeSettingsAreWrittenThroughAndTheLinkSurvives() throws {
        let dotfiles = try folder("dotfiles")
        let claude = try folder("home/.claude")
        let real = dotfiles.appendingPathComponent("claude-settings.json")
        let link = claude.appendingPathComponent("settings.json")
        let original = try olderClaudeInstall()
        try file(real, original, mode: 0o644)
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: "../../dotfiles/claude-settings.json")
        let linkBefore = try XCTUnwrap(info(link))
        func linkIsUntouched(_ step: String) {
            XCTAssertEqual(info(link), linkBefore, "\(step): the link itself is exactly as it was")
            XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                           "../../dotfiles/claude-settings.json", step)
            XCTAssertEqual(listing(claude), ["settings.json", "settings.json.airlock.bak"], "\(step): nothing else")
            XCTAssertEqual(listing(dotfiles), ["claude-settings.json"], "\(step): nothing added beside the real file")
            XCTAssertEqual(info(real)?.mode, 0o644, "\(step): permissions kept")
        }

        let installer = ClaudeHookInstaller(configURL: link)
        XCTAssertEqual(try installer.upgrade(), ["PermissionRequest"])
        XCTAssertNotNil(try hooks(in: real)["PermissionRequest"], "written to the real file")
        linkIsUntouched("upgrade")
        let backup = claude.appendingPathComponent("settings.json.airlock.bak")
        XCTAssertEqual(info(backup)?.isLink, false, "a copy, never a link")
        XCTAssertEqual(info(backup)?.mode, 0o600)
        XCTAssertEqual(try Data(contentsOf: backup), original)

        try installer.install(hookBinaryPath: "/x/airlock-hook")
        XCTAssertEqual(installer.status(), .installed)
        linkIsUntouched("install")

        let statusLine = ClaudeStatusLineInstaller(configURL: link)
        try statusLine.install(bridgeBinaryPath: "/x/airlock-hook")
        XCTAssertTrue(statusLine.isInstalled())
        try statusLine.uninstall()
        linkIsUntouched("status line")

        try installer.uninstall()
        XCTAssertEqual(installer.status(), .notInstalled)
        let left = try XCTUnwrap(try hooks(in: real)["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(left.first?["matcher"] as? String, "Bash", "the user's own hook stays")
        linkIsUntouched("uninstall")
        XCTAssertEqual(try Data(contentsOf: backup), original, "still the file as it first was")
    }

    /// A chain of links, a linked folder, a link to a file not written yet, and
    /// a loop — which is refused rather than written around.
    func testChainsLinkedFoldersNewFilesAndLoops() throws {
        // A chain: settings.json → middle.json → the real file.
        let chain = try folder("chain")
        let real = chain.appendingPathComponent("real.json")
        try file(real, try olderClaudeInstall(), mode: 0o600)
        try FileManager.default.createSymbolicLink(atPath: chain.appendingPathComponent("middle.json").path,
                                                   withDestinationPath: real.path)
        try FileManager.default.createSymbolicLink(atPath: chain.appendingPathComponent("settings.json").path,
                                                   withDestinationPath: "middle.json")
        XCTAssertEqual(try ClaudeHookInstaller(configURL: chain.appendingPathComponent("settings.json")).upgrade(),
                       ["PermissionRequest"])
        XCTAssertEqual(info(chain.appendingPathComponent("settings.json"))?.isLink, true)
        XCTAssertEqual(info(chain.appendingPathComponent("middle.json"))?.isLink, true)
        XCTAssertNotNil(try hooks(in: real)["PermissionRequest"])
        XCTAssertEqual(listing(chain), ["middle.json", "real.json", "settings.json", "settings.json.airlock.bak"])

        // The whole folder is the link: ~/.claude → dotfiles/claude.
        let kept = try folder("kept/claude")
        try file(kept.appendingPathComponent("settings.json"), try olderClaudeInstall(), mode: 0o600)
        let home = try folder("home2")
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude"), withDestinationURL: kept)
        let viaFolder = home.appendingPathComponent(".claude/settings.json")
        XCTAssertEqual(try ClaudeHookInstaller(configURL: viaFolder).upgrade(), ["PermissionRequest"])
        XCTAssertEqual(info(home.appendingPathComponent(".claude"))?.isLink, true)
        XCTAssertEqual(listing(kept), ["settings.json", "settings.json.airlock.bak"])

        // A link to a file that does not exist yet: install creates the file
        // the link names, and the link starts working.
        let fresh = try folder("fresh")
        let target = fresh.appendingPathComponent("not-yet.json")
        let dangling = fresh.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "not-yet.json")
        try ClaudeHookInstaller(configURL: dangling).install(hookBinaryPath: "/x/airlock-hook")
        XCTAssertEqual(info(dangling)?.isLink, true)
        XCTAssertEqual(info(target)?.mode, 0o600)
        XCTAssertNotNil(try hooks(in: target)["PermissionRequest"])

        // A loop has no file at the end of it: nothing to upgrade, and an
        // install is refused, leaving the folder as it was.
        let loop = try folder("loop")
        try FileManager.default.createSymbolicLink(atPath: loop.appendingPathComponent("a.json").path,
                                                   withDestinationPath: "b.json")
        try FileManager.default.createSymbolicLink(atPath: loop.appendingPathComponent("b.json").path,
                                                   withDestinationPath: "a.json")
        let looped = ClaudeHookInstaller(configURL: loop.appendingPathComponent("a.json"))
        XCTAssertEqual(try looped.upgrade(), [])
        XCTAssertThrowsError(try looped.install(hookBinaryPath: "/x/airlock-hook"))
        XCTAssertEqual(listing(loop), ["a.json", "b.json"])
    }

    // MARK: - Failures, and launching again and again

    /// A folder that cannot be written to: the write fails, the file is as it
    /// was, nothing is left behind, and launch goes on to the next agent —
    /// every time.
    func testAFailedWriteLeavesNothingAndLaunchCarriesOn() throws {
        let readOnly = try folder("read-only")
        let settings = readOnly.appendingPathComponent("settings.json")
        try file(settings, try olderClaudeInstall(), mode: 0o600)
        let before = try XCTUnwrap(info(settings))
        let bytes = try Data(contentsOf: settings)
        chmod(readOnly.path, 0o555)
        locked.append(readOnly)

        for attempt in 1...5 {
            let outcomes = launch(claude: settings)
            XCTAssertEqual(outcomes.map(\.agent), [.claudeCode, .codex], "launch \(attempt) reached every agent")
            XCTAssertNotNil(outcomes.first?.failure, "launch \(attempt)")
            XCTAssertEqual(outcomes.first?.added, [])
            XCTAssertNil(outcomes.last?.failure)
            XCTAssertEqual(listing(readOnly), ["settings.json"], "launch \(attempt) left nothing behind")
            XCTAssertEqual(info(settings), before)
            XCTAssertEqual(try Data(contentsOf: settings), bytes)
        }
    }

    /// The folder is writable but the swap itself fails (here, a file locked
    /// with `chflags uchg`): the temp file made for it is removed, no backup is
    /// taken of a write that never happened, and nothing piles up.
    func testAFailedSwapRemovesItsTempFileEveryTime() throws {
        let folder = try folder("locked-file")
        let settings = folder.appendingPathComponent("settings.json")
        try file(settings, try olderClaudeInstall(), mode: 0o600)
        let bytes = try Data(contentsOf: settings)
        chflags(settings.path, UInt32(UF_IMMUTABLE))
        frozen.append(settings)

        for attempt in 1...3 {
            let outcomes = launch(claude: settings)
            XCTAssertNotNil(outcomes.first?.failure, "launch \(attempt)")
            XCTAssertEqual(listing(folder), ["settings.json"], "launch \(attempt) left nothing behind")
            XCTAssertEqual(try Data(contentsOf: settings), bytes)
        }
    }

    /// Once the new event is there, later launches do not touch anything —
    /// not the file, not the backup, not the link — and add nothing.
    func testRepeatedLaunchesNeverAccumulateFiles() throws {
        let plain = try folder("plain")
        let settings = plain.appendingPathComponent("settings.json")
        try file(settings, try olderClaudeInstall(), mode: 0o600)

        let dotfiles = try folder("dots")
        let linkFolder = try folder("home3/.claude")
        let real = dotfiles.appendingPathComponent("settings.json")
        try file(real, try olderClaudeInstall(), mode: 0o644)
        let link = linkFolder.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(launch(claude: settings).first?.added, ["PermissionRequest"])
        XCTAssertEqual(launch(claude: link).first?.added, ["PermissionRequest"])
        let watched = [settings, plain.appendingPathComponent("settings.json.airlock.bak"),
                       real, link, linkFolder.appendingPathComponent("settings.json.airlock.bak")]
        let settled = watched.map(info)
        let folders = [plain, dotfiles, linkFolder].map(listing)
        XCTAssertEqual(folders, [["settings.json", "settings.json.airlock.bak"], ["settings.json"],
                                 ["settings.json", "settings.json.airlock.bak"]])

        for attempt in 2...6 {
            XCTAssertEqual(launch(claude: settings).map(\.added), [[], []], "launch \(attempt)")
            XCTAssertEqual(launch(claude: link).map(\.added), [[], []], "launch \(attempt)")
            XCTAssertEqual(watched.map(info), settled, "launch \(attempt) touched nothing")
            XCTAssertEqual([plain, dotfiles, linkFolder].map(listing), folders, "launch \(attempt) added nothing")
        }
    }

    // MARK: - Codex shares the writer

    /// `~/.codex/config.toml` goes through the same write: through a link,
    /// permissions kept, one private backup, nothing left behind — and a
    /// folder it cannot write to leaves nothing either.
    func testLinkedCodexConfigIsWrittenThroughToo() throws {
        let dotfiles = try folder("codex-dots")
        let codex = try folder("home4/.codex")
        let real = dotfiles.appendingPathComponent("config.toml")
        let original = "# mine\nmodel = \"o4\"\n"
        try file(real, Data(original.utf8), mode: 0o644)
        let link = codex.appendingPathComponent("config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let linkBefore = try XCTUnwrap(info(link))
        let installer = CodexHookInstaller(configURL: link)

        try installer.install(hookBinaryPath: "/x/airlock-hook")
        XCTAssertEqual(info(link), linkBefore)
        XCTAssertTrue(try String(contentsOf: real, encoding: .utf8).hasPrefix(original))
        XCTAssertTrue(try String(contentsOf: real, encoding: .utf8).contains(CodexHookInstaller.beginMarker))
        XCTAssertEqual(info(real)?.mode, 0o644)
        let backup = codex.appendingPathComponent("config.toml.airlock.bak")
        XCTAssertEqual(info(backup)?.isLink, false)
        XCTAssertEqual(info(backup)?.mode, 0o600)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
        XCTAssertEqual(listing(dotfiles), ["config.toml"])
        XCTAssertEqual(listing(codex), ["config.toml", "config.toml.airlock.bak"])

        try installer.uninstall()
        XCTAssertEqual(info(link), linkBefore)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), original)

        let readOnly = try folder("codex-read-only")
        let stuck = readOnly.appendingPathComponent("config.toml")
        try file(stuck, Data(original.utf8), mode: 0o600)
        chmod(readOnly.path, 0o555)
        locked.append(readOnly)
        XCTAssertThrowsError(try CodexHookInstaller(configURL: stuck).install(hookBinaryPath: "/x/airlock-hook"))
        XCTAssertEqual(listing(readOnly), ["config.toml"])
        XCTAssertEqual(try String(contentsOf: stuck, encoding: .utf8), original)
    }
}
