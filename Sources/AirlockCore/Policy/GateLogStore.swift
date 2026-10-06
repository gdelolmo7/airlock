import Foundation

/// Persists the gate history beside the session and clipboard caches.
///
/// `~/Library/Application Support/Airlock/gates.json`, 0600 — this is a
/// log of the commands your agents wanted to run, which is exactly as sensitive
/// as `sessions.json`. `AIRLOCK_STATE_HOME` overrides the directory, for
/// tests.
public struct GateLogStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = GateLogStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["AIRLOCK_STATE_HOME"] {
            return URL(fileURLWithPath: override).appendingPathComponent("gates.json")
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Airlock/gates.json")
    }

    /// Empty on missing or corrupt — a history, not a source of truth.
    public func load() -> GateLog {
        guard let data = try? Data(contentsOf: fileURL) else { return GateLog() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(GateLog.self, from: data)
        } catch {
            Log.policy.error(
                "ignoring corrupt gate log at \(fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return GateLog()
        }
    }

    public func save(_ log: GateLog) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(log)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: fileURL.path)
    }

    public func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
