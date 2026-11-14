import Foundation

/// One dictation, as the History list keeps it.
///
/// Written when the microphone opens, before a word is known, and marked
/// finished once the text has been typed or copied. A record still unfinished
/// at the next launch is a dictation that was cut off on its way (a crash, a
/// force quit, a power cut): its recording is transcribed again and the entry
/// shows as recovered. That ordering is the whole of "none is ever lost".
public struct DictationEntry: Codable, Equatable, Identifiable, Sendable {
    /// What happened to the words.
    public enum Delivery: String, Codable, Sendable {
        /// Typed where the cursor was.
        case typed
        /// Put on the clipboard: nowhere to type, or typing failed.
        case copied
        /// Never reached anywhere: still recording, cut off, or nothing heard.
        case none
    }

    public var id: UUID
    public var date: Date
    /// The app in front when the dictation started, by its shown name.
    public var app: String?
    /// The words exactly as the recogniser heard them.
    public var heard: String
    /// What was typed: the word list and the tidy step applied.
    public var text: String
    /// What `text` said before each Try again, oldest first.
    public var earlier: [String]
    public var finished: Bool
    /// Brought back at launch from a recording that was cut off.
    public var recovered: Bool
    public var delivery: Delivery
    /// Whether a recording sits beside the record, for Try again.
    public var hasRecording: Bool

    public init(id: UUID = UUID(), date: Date, app: String? = nil, heard: String = "",
                text: String = "", earlier: [String] = [], finished: Bool = false,
                recovered: Bool = false, delivery: Delivery = .none, hasRecording: Bool = false) {
        self.id = id
        self.date = date
        self.app = app
        self.heard = heard
        self.text = text
        self.earlier = earlier
        self.finished = finished
        self.recovered = recovered
        self.delivery = delivery
        self.hasRecording = hasRecording
    }

    /// Older records may lack fields added later; every one of them has a
    /// sensible absent value, so a record is never dropped for its age.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        heard = try c.decodeIfPresent(String.self, forKey: .heard) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        earlier = try c.decodeIfPresent([String].self, forKey: .earlier) ?? []
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? true
        recovered = try c.decodeIfPresent(Bool.self, forKey: .recovered) ?? false
        delivery = try c.decodeIfPresent(Delivery.self, forKey: .delivery) ?? .none
        hasRecording = try c.decodeIfPresent(Bool.self, forKey: .hasRecording) ?? false
    }
}

/// The rules of the History list: how long things are kept, what a search
/// matches, and what Try again does to an entry. Pure, so all of it is tested;
/// the files live in the app (`DictationHistoryStore`).
public enum DictationHistory {
    /// Text is kept for the last 200 dictations or 30 days, whichever is fewer.
    public static let keepsAtMost = 200
    public static let keepsTextFor: TimeInterval = 30 * 24 * 3600
    /// Recordings are kept a week, on this Mac only.
    public static let keepsRecordingsFor: TimeInterval = 7 * 24 * 3600

    /// What to throw away.
    public struct Pruning: Equatable, Sendable {
        /// Entries to remove whole, recording and all.
        public var entries: Set<UUID>
        /// Entries to keep whose recording is now too old.
        public var recordings: Set<UUID>

        public init(entries: Set<UUID> = [], recordings: Set<UUID> = []) {
            self.entries = entries
            self.recordings = recordings
        }

        public var isEmpty: Bool { entries.isEmpty && recordings.isEmpty }
    }

    /// Unfinished entries are never pruned: they wait for recovery, which
    /// finishes them, and only then do they count.
    public static func pruning(_ entries: [DictationEntry], now: Date) -> Pruning {
        var result = Pruning()
        let finished = newestFirst(entries.filter(\.finished))
        for (index, entry) in finished.enumerated() {
            let age = now.timeIntervalSince(entry.date)
            if index >= keepsAtMost || age > keepsTextFor {
                result.entries.insert(entry.id)
            } else if entry.hasRecording, age > keepsRecordingsFor {
                result.recordings.insert(entry.id)
            }
        }
        return result
    }

    public static func newestFirst(_ entries: [DictationEntry]) -> [DictationEntry] {
        entries.sorted { $0.date > $1.date }
    }

    /// Entries cut off before they finished, oldest first, so recovered
    /// dictations come back in the order they were spoken.
    public static func toRecover(_ entries: [DictationEntry]) -> [DictationEntry] {
        entries.filter { !$0.finished }.sorted { $0.date < $1.date }
    }

    /// Every word of the query must appear in the entry: in what was typed,
    /// what was heard, an earlier version or the app's name. Case and accents
    /// are ignored, so "jose" finds "José".
    public static func search(_ entries: [DictationEntry], for query: String) -> [DictationEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = fold(([entry.text, entry.heard, entry.app ?? ""] + entry.earlier)
                .joined(separator: "\n"))
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Try again's result: the new words replace the entry's, and the old
    /// text is kept one click away. Nothing heard the second time leaves the
    /// entry as it was, so trying again can never lose a dictation.
    public static func retried(_ entry: DictationEntry, heard: String, text: String) -> DictationEntry {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return entry }
        var next = entry
        if text != entry.text, !entry.text.isEmpty {
            next.earlier = entry.earlier.filter { $0 != entry.text } + [entry.text]
        }
        next.heard = heard
        next.text = text
        return next
    }

    /// Puts an earlier version back, keeping the one it replaces.
    public static func restored(_ entry: DictationEntry, earlier version: String) -> DictationEntry {
        guard let index = entry.earlier.firstIndex(of: version) else { return entry }
        var next = entry
        next.earlier.remove(at: index)
        if !entry.text.isEmpty { next.earlier.append(entry.text) }
        next.text = version
        return next
    }

    /// The text the paste-again shortcut types: the newest entry with words.
    public static func last(_ entries: [DictationEntry]) -> DictationEntry? {
        newestFirst(entries).first { $0.finished && !$0.text.isEmpty }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

extension FocusTarget {
    /// Whether the focused element, or a focused descendant, is a password
    /// field. Dictation keeps no text and no recording of one.
    public static func containsPasswordField(_ snapshot: Snapshot, depth: Int = maximumDepth) -> Bool {
        if snapshot.role == "AXSecureTextField" { return true }
        guard depth > 0 else { return false }
        return snapshot.children.contains { $0.isFocused && containsPasswordField($0, depth: depth - 1) }
    }
}
