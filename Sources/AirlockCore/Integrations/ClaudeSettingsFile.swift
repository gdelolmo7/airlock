import Foundation

/// Shared read/write for `~/.claude/settings.json` — used by the hook and
/// status-line installers so backup/atomic-write behavior can't drift. The
/// write itself is `ConfigFileWriter`'s, shared with Codex for the same reason.
enum ClaudeSettingsFile {
    static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Through a symbolic link to the real file, atomically, keeping its
    /// permissions, with a one-time backup of the original — see
    /// `ConfigFileWriter`.
    static func write(_ root: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try ConfigFileWriter.replace(url, with: data)
    }
}

/// Manages the `statusLine` entry in Claude's settings.
///
/// The bridge borrows the status-line channel for rate-limit data. If the
/// user already has a custom status line, it is CHAINED (encoded into our
/// command as base64 and re-executed with the same stdin), so their display
/// is pixel-identical — and restored verbatim on uninstall.
public struct ClaudeStatusLineInstaller: Sendable {
    public let configURL: URL

    public init(configURL: URL? = nil) {
        self.configURL = configURL ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
    }

    /// Both identities — see `ClaudeHookInstaller.ourBinaryName`, which this
    /// is the status line's half of.
    ///
    /// **Not `command.contains("airlock")`.** That claimed anybody's status
    /// line whose path happened to contain the word — a script under
    /// `~/airlock-tools/`, say — and claiming one is worse here than in the
    /// hooks: `install` keeps the chain of a command it thinks is already ours
    /// rather than chaining it, so their status line would have been dropped
    /// rather than wrapped. The program has to be our binary by name, and the
    /// command has to be the one we write, with `--statusline`.
    static let marker = "airlock-hook"
    static let legacyMarker = "agentic-notch-hook"

    static func isOurCommand(_ command: String) -> Bool {
        guard command.contains("--statusline") else { return false }
        return command.split(whereSeparator: \.isWhitespace).contains { word in
            let bare = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            let name = (bare as NSString).lastPathComponent
            return name == marker || name == legacyMarker
        }
    }

    public func install(bridgeBinaryPath: String) throws {
        var root = try ClaudeSettingsFile.read(configURL)
        let existing = root["statusLine"] as? [String: Any]
        let existingCommand = existing?["command"] as? String

        var chainB64: String?
        if let existingCommand, Self.isOurCommand(existingCommand) {
            // Reinstall: keep whatever chain the previous install captured.
            chainB64 = Self.chainArgument(in: existingCommand)
        } else if let existingCommand, !existingCommand.isEmpty {
            chainB64 = Data(existingCommand.utf8).base64EncodedString()
        }

        var command = "'\(bridgeBinaryPath)' --statusline"
        if let chainB64 { command += " --chain-b64 \(chainB64)" }

        var entry: [String: Any] = ["type": "command", "command": command]
        if let padding = existing?["padding"] { entry["padding"] = padding }
        root["statusLine"] = entry
        try ClaudeSettingsFile.write(root, to: configURL)
    }

    /// Remove our bridge; restore the user's original command when we chained
    /// one, otherwise drop the key entirely.
    public func uninstall() throws {
        var root = try ClaudeSettingsFile.read(configURL)
        guard var entry = root["statusLine"] as? [String: Any],
              let command = entry["command"] as? String,
              Self.isOurCommand(command) else { return }

        if let chainB64 = Self.chainArgument(in: command),
           let data = Data(base64Encoded: chainB64),
           let original = String(data: data, encoding: .utf8) {
            entry["command"] = original
            root["statusLine"] = entry
        } else {
            root.removeValue(forKey: "statusLine")
        }
        try ClaudeSettingsFile.write(root, to: configURL)
    }

    public func isInstalled() -> Bool {
        guard let root = try? ClaudeSettingsFile.read(configURL),
              let entry = root["statusLine"] as? [String: Any],
              let command = entry["command"] as? String else { return false }
        return Self.isOurCommand(command)
    }

    static func chainArgument(in command: String) -> String? {
        let tokens = command.split(separator: " ")
        guard let index = tokens.firstIndex(of: "--chain-b64"), index + 1 < tokens.count else { return nil }
        return String(tokens[index + 1])
    }
}
