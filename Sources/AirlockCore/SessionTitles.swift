import Foundation

/// session_id → conversation name, fed by the status-line bridge
/// (`session_name`: the /rename value or the AI-generated title). Written by
/// the hook process, read by the app on its tick.
public struct SessionNameCache: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        public var at: Date
    }

    public var names: [String: Entry]

    public init(names: [String: Entry] = [:]) {
        self.names = names
    }

    public static func defaultURL() -> URL {
        UsageSnapshot.defaultCacheURL()
            .deletingLastPathComponent()
            .appendingPathComponent("session-names.json")
    }

    public static func load(from url: URL = defaultURL()) -> SessionNameCache {
        guard let data = try? Data(contentsOf: url) else { return SessionNameCache() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode(SessionNameCache.self, from: data)) ?? SessionNameCache()
    }

    /// Merge one observation and persist, keeping the most recent 200 entries.
    public static func record(sessionID: String, name: String, at now: Date, url: URL = defaultURL()) {
        var cache = load(from: url)
        cache.names[sessionID] = Entry(name: name, at: now)
        if cache.names.count > 200 {
            let keep = cache.names.sorted { $0.value.at > $1.value.at }.prefix(200)
            cache.names = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        // 0600, like every sibling cache. The 0700 directory above already stops
        // another user traversing in, so this is defence in depth rather than a
        // live exposure — but "the parent happens to be tight" is the kind of
        // reasoning that stops being true when somebody moves the file.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }
}

/// Reads the conversation title out of a Claude transcript. Two record
/// shapes exist in the wild (verified on-disk):
///   `{"type":"summary","summary":"…"}`            — CLI-generated titles
///   `{"type":"custom-title","customTitle":"…"}`   — desktop / renamed
/// Files ≤16MB are scanned fully (cheap, prefiltered); larger ones get a
/// bounded head+tail read so a runaway transcript costs nothing.
public enum TranscriptTitles {
    public static func latestSummary(atPath path: String, byteBudget: Int = 16 * 1024 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return latestSummary(reading: handle, byteBudget: byteBudget)
    }

    /// The scan, on a handle that is already open. Separate so a test can hand
    /// it one whose reads fail — no file on disk can be made to do that
    /// without special permissions.
    static func latestSummary(reading handle: FileHandle, byteBudget: Int) -> String? {
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        guard size > 0 else { return nil }

        // `read(upToCount:)` throws where `readData(ofLength:)` raised an
        // Objective-C exception, which Swift cannot catch: a read error took
        // the app down over a conversation title. A chunk that cannot be read
        // now contributes nothing, exactly like an empty one.
        func chunk(_ count: Int) -> Data {
            (try? handle.read(upToCount: count)) ?? Data()
        }

        var chunks: [Data] = []
        if size <= byteBudget {
            try? handle.seek(toOffset: 0)
            chunks.append(chunk(size))
        } else {
            let half = 1024 * 1024
            try? handle.seek(toOffset: 0)
            chunks.append(chunk(half))
            try? handle.seek(toOffset: UInt64(size - half))
            chunks.append(chunk(half))
        }

        let summaryMark = Data(#""type":"summary""#.utf8)
        let customMark = Data(#""type":"custom-title""#.utf8)
        var latest: String?
        for chunk in chunks {
            for line in chunk.split(separator: 0x0A) {
                guard line.count > 20, line.first == UInt8(ascii: "{"),
                      line.range(of: summaryMark) != nil || line.range(of: customMark) != nil
                else { continue }
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                else { continue }
                switch object["type"] as? String {
                case "summary":
                    if let summary = object["summary"] as? String, !summary.isEmpty { latest = summary }
                case "custom-title":
                    if let title = object["customTitle"] as? String, !title.isEmpty { latest = title }
                default:
                    break
                }
            }
        }
        return latest
    }
}
