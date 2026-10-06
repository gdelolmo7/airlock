import Foundation

/// Claude.ai subscription rate-limit windows, as delivered on the status-line
/// channel (`rate_limits.five_hour` / `.seven_day`, Pro/Max only, present
/// after the first API response of a session). Account-wide, so one cached
/// snapshot serves every session.
public struct RateLimitWindow: Codable, Sendable, Equatable {
    /// 0–100.
    public var usedPercentage: Double
    public var resetsAt: Date?

    public init(usedPercentage: Double, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    /// Past its own reset, a reading is void rather than merely old: the window
    /// rolled, and the percentage describes a period that has ended. A 5-hour
    /// figure captured 8 hours ago is not stale data, it is data about nothing —
    /// seen live, the panel showing 0% while the real figure was 90%.
    ///
    /// Distinct from snapshot staleness, which is about when we last heard
    /// anything at all.
    public func hasRolled(at now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var fiveHour: RateLimitWindow?
    public var sevenDay: RateLimitWindow?
    public var capturedAt: Date

    public init(fiveHour: RateLimitWindow?, sevenDay: RateLimitWindow?, capturedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.capturedAt = capturedAt
    }

    /// Lenient parse of a status-line stdin payload. Returns nil when neither
    /// window is present (never clobber a good cache with an empty one).
    public static func parse(statusLineJSON: Data, at now: Date) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: statusLineJSON) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }

        func window(_ key: String) -> RateLimitWindow? {
            guard let dict = limits[key] as? [String: Any],
                  let used = dict["used_percentage"] as? Double ?? (dict["used_percentage"] as? Int).map(Double.init)
            else { return nil }
            let resets = (dict["resets_at"] as? Double ?? (dict["resets_at"] as? Int).map(Double.init))
                .map { Date(timeIntervalSince1970: $0) }
            return RateLimitWindow(usedPercentage: used, resetsAt: resets)
        }

        let five = window("five_hour")
        let seven = window("seven_day")
        guard five != nil || seven != nil else { return nil }
        return UsageSnapshot(fiveHour: five, sevenDay: seven, capturedAt: now)
    }

    // MARK: - Cache

    public static func defaultCacheURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["AIRLOCK_STATE_HOME"] {
            return URL(fileURLWithPath: override).appendingPathComponent("usage.json")
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Airlock/usage.json")
    }

    public static func load(from url: URL = defaultCacheURL()) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }

    public func save(to url: URL = Self.defaultCacheURL()) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        // See SessionTitles: 0600 to match the sibling caches, not because the
        // 0700 directory is insufficient today.
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }
}
