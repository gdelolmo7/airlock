import Foundation

/// Manages Codex hook entries in `~/.codex/config.toml`.
///
/// Codex registers lifecycle hooks as TOML array-of-tables
/// (`[[hooks.<Event>]]` with `hooks = [{ command = "…" }]`). We own exactly one
/// marker-delimited block appended at the end of the file — array-of-tables
/// headers are position-independent, so this is valid TOML regardless of what
/// the user has above. Install replaces our block, uninstall removes only it,
/// and everything the user wrote stays byte-identical.
public struct CodexHookInstaller: HookInstaller {
    /// Low-noise default set (Codex has no SessionEnd/Notification events;
    /// session end is handled by process liveness).
    static let events = ["SessionStart", "UserPromptSubmit", "Stop"]

    static let beginMarker = "# >>> airlock hooks (managed block — do not edit)"
    static let endMarker = "# <<< airlock hooks"
    /// The pre-rename block. Kept so an existing install is still recognised as
    /// ours and gets replaced, rather than read as an unmanaged conflict that
    /// can neither be uninstalled nor installed over.
    static let legacyBeginMarker = "# >>> agentic-notch hooks (managed block — do not edit)"
    static let legacyEndMarker = "# <<< agentic-notch hooks"

    public let configURL: URL

    public init(configURL: URL? = nil) {
        self.configURL = configURL ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/config.toml")
    }

    public var configPath: String { configURL.path }

    public func install(hookBinaryPath: String) throws {
        var text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        text = Self.removingManagedBlock(from: text)

        var block = [Self.beginMarker]
        for event in Self.events {
            block.append("[[hooks.\(event)]]")
            // `type = "command"` is REQUIRED — codex 0.140.0 refuses to start
            // on a config whose hook entries lack it (found live; the config
            // reference elides it). Command stays unquoted on purpose: Codex's
            // exec semantics (sh vs direct) are undocumented and quoting breaks
            // direct exec; the staged binary lives at a space-free path
            // (~/.airlock/bin), safe under either interpretation.
            block.append("hooks = [{ type = \"command\", command = \"\(hookBinaryPath) --source codex --event \(event)\" }]")
        }
        block.append(Self.endMarker)

        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty { text += "\n" }
        text += block.joined(separator: "\n") + "\n"
        try write(text)
    }

    public func status() -> HookInstallStatus {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .notInstalled
        }
        if text.contains(Self.beginMarker) || text.contains(Self.legacyBeginMarker) { return .installed }
        if text.contains("airlock-hook") || text.contains("agentic-notch-hook") {
            return .conflict("unmanaged Airlock entries in \(configPath)")
        }
        return .notInstalled
    }

    public func uninstall() throws {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return }
        let cleaned = Self.removingManagedBlock(from: text)
        guard cleaned != text else { return }
        try write(cleaned)
    }

    // MARK: - Helpers

    /// Remove our marker-delimited block (inclusive), plus the blank line the
    /// install added before it.
    static func removingManagedBlock(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        // Either identity's block, so an upgrade replaces rather than duplicates.
        guard let begin = lines.firstIndex(where: {
            $0.hasPrefix(beginMarker) || $0.hasPrefix(legacyBeginMarker)
        }) else { return text }
        let end = lines[begin...].firstIndex(where: {
            $0.hasPrefix(endMarker) || $0.hasPrefix(legacyEndMarker)
        }) ?? (lines.count - 1)
        lines.removeSubrange(begin...min(end, lines.count - 1))
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// The same write as Claude's settings — through a link, atomic, keeping
    /// permissions, one backup — see `ConfigFileWriter`.
    private func write(_ text: String) throws {
        try ConfigFileWriter.replace(configURL, with: Data(text.utf8))
    }
}
