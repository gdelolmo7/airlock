import Foundation

/// Persists sessions across app launches.
///
/// `~/Library/Application Support/Airlock/sessions.json` (0600 — session
/// data includes commands). Override the directory with
/// `AIRLOCK_STATE_HOME` (tests/demos only).
///
/// Restore flow: `load()` → `SessionState.preparedForRestore` → the liveness
/// engine reconciles against reality — restored sessions whose agent process
/// is gone are declared dead within seconds, no special-case code.
public struct SessionRegistry: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = SessionRegistry.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["AIRLOCK_STATE_HOME"] {
            return URL(fileURLWithPath: override).appendingPathComponent("sessions.json")
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Airlock/sessions.json")
    }

    /// nil on missing or unreadable cache — the app starts fresh. A corrupt
    /// file is logged, never fatal: this is a cache, not a source of truth.
    public func load() -> SessionState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(SessionState.self, from: data)
        } catch {
            Log.session.error(
                "ignoring corrupt session cache at \(fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Atomic write, 0600. `excluding` filters transient sessions (demo seeds).
    public func save(_ state: SessionState, excluding: Set<String> = []) throws {
        let filtered = SessionState(sessions: state.sessions.filter { !excluding.contains($0.key) })

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(filtered)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
