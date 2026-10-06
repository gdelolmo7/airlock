import Foundation

/// Manages Claude Code hook entries in `~/.claude/settings.json`.
///
/// Idempotent and reversible: install replaces only our own managed entries
/// (identified by the binary name in the command), and uninstall leaves every
/// user-authored hook untouched. Writes are atomic (temp file + rename) and a
/// one-time backup is kept.
public struct ClaudeHookInstaller: HookInstaller {
    /// The events Claude waits on for a notch decision (24h Claude-side
    /// timeout): PreToolUse before a call runs, and PermissionRequest when
    /// Claude is about to ask in its own window. Everything else is
    /// fire-and-forget with a short leash.
    private static let blockingEvents = ["PreToolUse", "PermissionRequest"]

    /// Every event an install subscribes to. One added here reaches existing
    /// installs through `upgrade`, not only new ones.
    private static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PostToolUse", "Stop", "SessionEnd", "Notification",
    ]

    /// Our hook commands, under either identity.
    ///
    /// `legacyMarker` is not dead weight: an install written before the Airlock
    /// rename says `agentic-notch-hook`, and a matcher that only knew the new
    /// name would read those entries as somebody else's — reporting "not
    /// installed", refusing to uninstall them, and adding a second set alongside
    /// the first. Recognise both; only ever write the new one.
    private static let marker = "airlock-hook"
    private static let legacyMarker = "agentic-notch-hook"

    /// The name our binary is run under by this command, or nil when the
    /// command is not ours at all.
    ///
    /// **It used to be `command.contains("airlock-hook")`.** A hook of the
    /// user's own at `~/bin/airlock-hook-logger.sh` satisfies that, and what
    /// follows is not cosmetic: `upgrade` would have taken their script as the
    /// install to extend and wired THEIR command into the events it added, and
    /// `uninstall` would have deleted their entries as ours.
    ///
    /// So the program has to be ours by name — the last component of a whole
    /// word, which is quoting-proof, since a quoted path with spaces still ends
    /// in `…/airlock-hook'` — and the command has to run it the way we run it,
    /// with `--source`. Both identities count; only the new one is ever
    /// written.
    static func ourBinaryName(in command: String) -> String? {
        guard command.contains(" --source ") else { return nil }
        for word in command.split(whereSeparator: \.isWhitespace) {
            let bare = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            let name = (bare as NSString).lastPathComponent
            if name == marker || name == legacyMarker { return name }
        }
        return nil
    }

    static func isOurCommand(_ command: String) -> Bool { ourBinaryName(in: command) != nil }

    public let configURL: URL

    public init(configURL: URL? = nil) {
        self.configURL = configURL ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
    }

    public var configPath: String { configURL.path }

    public func install(hookBinaryPath: String) throws {
        var root = try readSettings()
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // Claude runs this via /bin/sh -c — quote the binary path so it
        // survives spaces (found live: unquoted "…/Application Support/…"
        // shell-split and broke).
        let invocation = "\(Self.shellQuoted(hookBinaryPath)) --source claude-code"
        for event in Self.events {
            guard var entries = Self.entries(in: hooks, event: event) else { continue }
            entries.removeAll(where: Self.isManaged)
            entries.append(Self.entry(for: event, invocation: invocation))
            hooks[event] = entries
        }

        root["hooks"] = hooks
        try writeSettings(root)
    }

    /// Subscribes an existing install to the events it predates, and touches
    /// nothing else.
    ///
    /// An install is written once, so an event added later — PermissionRequest
    /// was the first — would never be heard on a Mac that installed before it:
    /// nobody reinstalls something that works. `install` is not the answer
    /// either, since it rewrites every managed entry and moves each one behind
    /// the user's own. This only adds what is missing, running the same
    /// binary, quoted the same way, as the install's own entries.
    ///
    /// Upgrading is never installing: with no install to extend, nothing is
    /// written. Nor with only pre-rename entries — the app's migration rewrites
    /// those whole, new events included, before this runs, and a new entry
    /// must never name the old binary. A second run finds nothing missing and
    /// does not write. Returns the events it added.
    @discardableResult
    public func upgrade() throws -> [String] {
        var root = try readSettings()
        guard var hooks = root["hooks"] as? [String: Any],
              let invocation = Self.installedInvocation(in: hooks) else { return [] }

        var added: [String] = []
        for event in Self.events {
            guard var entries = Self.entries(in: hooks, event: event),
                  !entries.contains(where: Self.isManaged) else { continue }
            entries.append(Self.entry(for: event, invocation: invocation))
            hooks[event] = entries
            added.append(event)
        }
        guard !added.isEmpty else { return [] }

        root["hooks"] = hooks
        try writeSettings(root)
        return added
    }

    public func status() -> HookInstallStatus {
        guard let root = try? readSettings(),
              let hooks = root["hooks"] as? [String: Any] else { return .notInstalled }
        let present = hooks.values.contains { value in
            (value as? [[String: Any]])?.contains(where: Self.isManaged) ?? false
        }
        return present ? .installed : .notInstalled
    }

    public func uninstall() throws {
        var root = try readSettings()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        var removed = false
        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            let before = entries.count
            entries.removeAll(where: Self.isManaged)
            guard entries.count != before else { continue }
            removed = true
            if entries.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = entries }
        }
        // Nothing of ours in it: not a file to rewrite. It used to be written
        // back anyway — reformatted, and backed up — for somebody who had asked
        // us to remove hooks we had never installed.
        guard removed else { return }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeSettings(root)
    }

    // MARK: - Helpers

    /// POSIX single-quote quoting: safe under `/bin/sh -c` for any path.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The entries under `event`, or nil when what is there is not the shape
    /// Claude documents — an array of entry objects.
    ///
    /// **Nil means leave it alone.** This used to read
    /// `as? [[String: Any]] ?? []`, so anything else — an object, a string, a
    /// list with one odd item in it — became an empty list and was written
    /// back as our single entry, taking whatever the user had with it. That was
    /// survivable while it only happened when somebody clicked Install. It now
    /// runs at every launch, on every Mac with hooks, over a file nobody asked
    /// us to tidy up.
    private static func entries(in hooks: [String: Any], event: String) -> [[String: Any]]? {
        guard let value = hooks[event] else { return [] }   // nothing there: ours to add
        return value as? [[String: Any]]
    }

    /// One managed entry: every tool (`matcher` empty), our command, and the
    /// timeout its event needs.
    private static func entry(for event: String, invocation: String) -> [String: Any] {
        let timeout = blockingEvents.contains(event) ? Int(HookDirective.blockingWait) : 5
        return [
            "matcher": "",
            "hooks": [[
                "type": "command",
                "command": "\(invocation) --event \(event)",
                "timeout": timeout,
            ]],
        ]
    }

    /// What an existing install runs, up to the event: `'…/airlock-hook'
    /// --source claude-code`, exactly as written — or nil when no entry names
    /// the current binary.
    private static func installedInvocation(in hooks: [String: Any]) -> String? {
        let separator = " --event "
        for event in events {
            for entry in (hooks[event] as? [[String: Any]]) ?? [] {
                for hook in (entry["hooks"] as? [[String: Any]]) ?? [] {
                    guard let command = hook["command"] as? String,
                          ourBinaryName(in: command) == marker,
                          let range = command.range(of: separator, options: .backwards) else { continue }
                    return String(command[..<range.lowerBound])
                }
            }
        }
        return nil
    }

    private static func isManaged(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String).map(Self.isOurCommand) ?? false }
    }

    private func readSettings() throws -> [String: Any] {
        try ClaudeSettingsFile.read(configURL)
    }

    private func writeSettings(_ root: [String: Any]) throws {
        try ClaudeSettingsFile.write(root, to: configURL)
    }
}
