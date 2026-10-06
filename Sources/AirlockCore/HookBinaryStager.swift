import Foundation

/// Stages the hook binary at a stable path so installed hook commands survive
/// rebuilds, repo moves, and renames. Shared by the setup CLI and the app's
/// settings window — one implementation, one destination.
public enum HookBinaryStager {
    public static let binaryName = "airlock-hook"

    /// `~/.airlock/bin/agentic-notch-hook`.
    ///
    /// Deliberately NOT Application Support: that path contains a space, and
    /// agents run hook commands through `/bin/sh -c` (Claude, observed live)
    /// or possibly direct exec (Codex, undocumented). A space-free path works
    /// under both; an unquoted spaced path shell-splits and breaks every hook.
    public static func defaultStagedURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".airlock/bin/\(binaryName)")
    }

    /// Find the hook binary next to another executable (the setup CLI or the
    /// app itself — SwiftPM puts all products in one directory; a bundled app
    /// will embed the hook alongside its main executable).
    public static func locateSourceHook(near executable: URL?) -> URL? {
        guard let executable else { return nil }
        let sibling = executable.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent(binaryName)
        return FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil
    }

    /// Copy `source` to `destination` (replacing any previous copy) and make it
    /// executable. Returns the destination.
    @discardableResult
    public static func stage(from source: URL, to destination: URL = defaultStagedURL()) throws -> URL {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    // MARK: - Drift

    /// Whether the staged copy has fallen behind `source`.
    ///
    /// Size first because it settles almost every case for the cost of a stat;
    /// bytes only when the sizes agree, since two builds can be the same length
    /// and different code. Anything unreadable counts as outdated — restaging is
    /// cheap and a stale hook is not.
    public static func isOutdated(source: URL, destination: URL = defaultStagedURL()) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path) else { return true }
        let sourceSize = (try? manager.attributesOfItem(atPath: source.path)[.size]) as? Int
        let stagedSize = (try? manager.attributesOfItem(atPath: destination.path)[.size]) as? Int
        guard let sourceSize, let stagedSize else { return true }
        if sourceSize != stagedSize { return true }

        guard let current = try? Data(contentsOf: source),
              let staged = try? Data(contentsOf: destination) else { return true }
        return current != staged
    }

    /// Keep an already-installed hook in step with the running app.
    ///
    /// The staged binary is a *snapshot*, so it goes stale the moment the app
    /// updates and nothing says so. The symptom is the worst kind: Settings
    /// reports the hooks as installed and green while an old binary talks to a
    /// newer bridge. Observed here four days after install, found only because
    /// someone happened to read a file date.
    ///
    /// Deliberately does nothing when no staged copy exists. A missing file
    /// means the user never installed hooks, and silently creating one would be
    /// installing something they did not ask for.
    ///
    /// - Returns: true when it actually restaged.
    @discardableResult
    public static func refreshIfInstalled(near executable: URL?,
                                          destination: URL = defaultStagedURL()) throws -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else { return false }
        guard let source = locateSourceHook(near: executable) else { return false }
        guard isOutdated(source: source, destination: destination) else { return false }
        try stage(from: source, to: destination)
        return true
    }
}
