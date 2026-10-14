import Foundation

/// Where the search reads calls from: the call folders and when each one's
/// record last changed. `MeetingStore` in the app, a dictionary in a test.
///
/// The only file access the search has, so ranking stays pure and is tested
/// on made-up calls without touching a disk.
public protocol CallFolders: Sendable {
    /// Every call folder by name, with when its record last changed.
    func stamps() -> [String: Date]
    /// The record in a folder, or nil when it is gone or unreadable.
    func record(in folder: String) -> MeetingRecord?
}

extension MeetingStore: CallFolders {
    public func stamps() -> [String: Date] {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        var stamps: [String: Date] = [:]
        for folder in folders where !folder.hasPrefix(".") {
            let path = root.appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent(MeetingFiles.recordName).path
            if let date = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                stamps[folder] = date
            }
        }
        return stamps
    }

    public func record(in folder: String) -> MeetingRecord? {
        keptRecord(in: root.appendingPathComponent(folder, isDirectory: true))
    }
}

/// A few turns of one call in a row, the unit a question is answered from.
public struct CallChunk: Equatable, Sendable {
    /// The call's folder name: what the notes window opens it by.
    public let folder: String
    /// The call's title, as the notes window shows it.
    public let title: String
    public let startedAt: Date
    /// When the first line in it was said, in seconds from the start.
    public let time: TimeInterval
    /// Who speaks in it, in order: "You", "Them", or the other person's
    /// name on a one-to-one call.
    public let speakers: [String]
    /// "Speaker: words" lines, one per change of speaker.
    public let text: String
    /// How often each search term occurs in it, title and people included.
    let counts: [String: Int]
    let length: Int
}

/// Every call, cut into chunks and ranked for a question with BM25, kept in
/// memory and nowhere else.
///
/// **There is no second copy of a transcript on disk.** The index is built
/// from the call folders the first time it is needed and lives as long as
/// the app does. Each search first asks the folders what changed, so a call
/// that grew is read again, and a call deleted in Finder is gone from the
/// next answer, leaving nothing behind.
public struct CallSearchIndex: Sendable {
    /// Characters of transcript per chunk, about. Six of them make a prompt
    /// of about 2,400 characters of excerpts, far inside the on-device
    /// model's window with the instructions and the answer.
    public static let chunkLimit = 400

    private var calls: [String: Call] = [:]
    /// Whether Apple's model reads a locale's language
    /// (`MeetingNotesSource`): a stretch it cannot read is answered from
    /// its other listening, or left out.
    private let canRead: @Sendable (String) -> Bool
    /// In how many chunks each term occurs, for the rarity half of BM25.
    private var frequency: [String: Int] = [:]
    private var chunkCount = 0
    private var averageLength: Double = 1

    private struct Call: Sendable {
        let stamp: Date
        let startedAt: Date
        let people: [String]
        let chunks: [CallChunk]
        /// Locales of stretches nothing could read (`MeetingNotesSource`).
        let unreadable: [String]
    }

    public init(canRead: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.canRead = canRead
    }

    /// What a refresh did, for the log: counts only.
    public struct Refresh: Equatable, Sendable {
        public var calls = 0
        public var read = 0
        public var dropped = 0
    }

    /// Reads the calls that are new or changed since the last refresh, and
    /// forgets the ones that are gone. Unchanged calls are not read.
    @discardableResult
    public mutating func refresh(from folders: some CallFolders) -> Refresh {
        let stamps = folders.stamps()
        var report = Refresh()
        for folder in calls.keys where stamps[folder] == nil {
            calls[folder] = nil
            report.dropped += 1
        }
        for (folder, stamp) in stamps where calls[folder]?.stamp != stamp {
            report.read += 1
            guard let record = folders.record(in: folder) else {
                if calls.removeValue(forKey: folder) != nil { report.dropped += 1 }
                continue
            }
            let source = MeetingNotesSource(record, canRead: canRead)
            calls[folder] = Call(stamp: stamp, startedAt: record.startedAt, people: Self.people(of: record),
                                 chunks: Self.chunks(of: record, folder: folder, said: source.readable),
                                 unreadable: source.unreadable)
        }
        if report.read > 0 || report.dropped > 0 { recount() }
        report.calls = calls.count
        return report
    }

    /// Everyone the calls were with, for `CallQuestion` to tell "what did
    /// Marta say" about a call from the news.
    public var people: [String] {
        var seen = Set<String>()
        return calls.values.flatMap(\.people).filter { seen.insert(CallText.fold($0)).inserted }
    }

    public var isEmpty: Bool { calls.isEmpty }

    // MARK: - Chunks

    /// A call cut into chunks of consecutive lines, each closed before it
    /// would pass `chunkLimit`. A line is the recogniser's sentence, so a
    /// chunk starts at a time somebody started speaking, which is where the
    /// notes window can open it. A single line longer than the limit is a
    /// chunk of its own rather than cut mid-sentence.
    ///
    /// `said` is what to cut, the transcript as read (`spokenSegments`)
    /// unless given: the index passes what Apple's model can read
    /// (`MeetingNotesSource.readable`).
    public static func chunks(of record: MeetingRecord, folder: String,
                              said: [MeetingSegment]? = nil) -> [CallChunk] {
        let title = MeetingFiles.title(of: record)
        let about = CallText.terms(([title] + people(of: record)).joined(separator: " "))
        var chunks: [CallChunk] = []
        var lines: [(speaker: String, text: String)] = []
        var start: TimeInterval = 0
        var size = 0

        func close() {
            guard !lines.isEmpty else { return }
            let text = lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
            var speakers: [String] = []
            for line in lines where !speakers.contains(line.speaker) { speakers.append(line.speaker) }
            let terms = CallText.terms(text) + about
            chunks.append(CallChunk(folder: folder, title: title, startedAt: record.startedAt,
                                    time: start, speakers: speakers, text: text,
                                    counts: terms.reduce(into: [:]) { $0[$1, default: 0] += 1 },
                                    length: terms.count))
            lines = []
            size = 0
        }

        for segment in said ?? record.spokenSegments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if size > 0, size + text.count > chunkLimit { close() }
            if lines.isEmpty { start = segment.start }
            let speaker = record.label(for: segment)
            if lines.last?.speaker == speaker {
                lines[lines.count - 1].text += " " + text
            } else {
                lines.append((speaker, text))
            }
            size += text.count + 1
        }
        close()
        return chunks
    }

    private static func people(of record: MeetingRecord) -> [String] {
        MeetingPeople(record: record).others
    }

    private mutating func recount() {
        frequency = [:]
        chunkCount = 0
        var total = 0
        for call in calls.values {
            for chunk in call.chunks {
                chunkCount += 1
                total += chunk.length
                for term in chunk.counts.keys { frequency[term, default: 0] += 1 }
            }
        }
        averageLength = chunkCount == 0 ? 1 : max(1, Double(total) / Double(chunkCount))
    }

    // MARK: - Ranking

    /// The chunks that best answer the query, best first, from calls inside
    /// its date range. Empty when nothing matches: no excerpt is better
    /// than a wrong one, because the answer is built only from these.
    ///
    /// A question with no words left after `CallQuery` ("¿qué quedamos
    /// ayer?") is about the latest call in the range as a whole. It is read
    /// for the words agreements are made in, and when those are not there,
    /// shown evenly from start to end, in the order it was said.
    public func search(_ query: CallQuery, limit: Int = 6) -> [CallChunk] {
        let inRange = calls.values.filter { call in
            guard let range = query.range, let first = call.chunks.first else { return true }
            return first.startedAt >= range.start && first.startedAt < range.end
        }
        guard limit > 0 else { return [] }
        if !query.terms.isEmpty {
            return Array(rank(inRange.flatMap(\.chunks), by: query.terms).prefix(limit))
        }
        guard let latest = inRange.compactMap(\.chunks.first).max(by: { $0.startedAt < $1.startedAt }),
              let chunks = calls[latest.folder]?.chunks else { return [] }
        let agreed = rank(chunks, by: Self.agreementWords).prefix(limit)
        let picked = agreed.isEmpty ? Self.spread(chunks, limit: limit) : Array(agreed)
        return picked.sorted { $0.time < $1.time }
    }

    /// The locale of a stretch nothing could read, in a call inside the
    /// query's range: why a search there may have come back empty. The
    /// newest such call's first.
    public func unreadable(for query: CallQuery) -> String? {
        calls.values
            .filter { call in
                guard let range = query.range else { return true }
                return call.startedAt >= range.start && call.startedAt < range.end
            }
            .sorted { $0.startedAt > $1.startedAt }
            .lazy.compactMap(\.unreadable.first).first
    }

    /// BM25 with the usual constants, dropping chunks that match nothing.
    /// Ties go to the newer call, then the earlier moment in it.
    func rank(_ chunks: [CallChunk], by terms: [String]) -> [CallChunk] {
        let k1 = 1.2, b = 0.75
        let unique = Array(Set(terms))
        let scored: [(chunk: CallChunk, score: Double)] = chunks.compactMap { chunk in
            var score = 0.0
            for term in unique {
                guard let count = chunk.counts[term], count > 0 else { continue }
                let documents = Double(frequency[term] ?? 1)
                let rarity = log(1 + (Double(chunkCount) - documents + 0.5) / (documents + 0.5))
                let tf = Double(count)
                score += rarity * tf * (k1 + 1)
                    / (tf + k1 * (1 - b + b * Double(chunk.length) / averageLength))
            }
            return score > 0 ? (chunk, score) : nil
        }
        return scored.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.chunk.startedAt != right.chunk.startedAt {
                return left.chunk.startedAt > right.chunk.startedAt
            }
            return left.chunk.time < right.chunk.time
        }.map(\.chunk)
    }

    /// Words an agreement is said in, for a question that names nothing
    /// but the agreeing.
    static let agreementWords: [String] = [
        "agreed", "agree", "decided", "decide", "deal", "plan", "deadline", "next",
        "send", "owner", "let", "will", "done",
        "acuerdo", "quedamos", "acordamos", "decidimos", "vale", "hecho", "plazo",
        "fecha", "envio", "mando", "siguiente", "entonces",
    ].map(CallText.stem)

    /// `limit` chunks evenly from first to last.
    static func spread(_ chunks: [CallChunk], limit: Int) -> [CallChunk] {
        guard chunks.count > limit else { return chunks }
        guard limit > 1 else { return [chunks[0]] }
        return (0..<limit).map { chunks[$0 * (chunks.count - 1) / (limit - 1)] }
    }
}

/// The index behind an actor, so the app's main thread never reads a call.
///
/// Built on the first question that needs it, not at launch: someone who
/// never asks about a call never has their calls read.
public actor CallSearch {
    private let folders: any CallFolders
    private var index: CallSearchIndex

    /// - Parameter canRead: whether Apple's model reads a locale's language.
    public init(folders: any CallFolders, canRead: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.folders = folders
        index = CallSearchIndex(canRead: canRead)
    }

    /// Everyone the calls were with.
    public func people() -> [String] {
        index.refresh(from: folders)
        return index.people
    }

    /// The best chunks for a question, and what the refresh before it did.
    public func search(_ query: CallQuery, limit: Int = 6) -> (chunks: [CallChunk], refresh: CallSearchIndex.Refresh) {
        let refresh = index.refresh(from: folders)
        return (index.search(query, limit: limit), refresh)
    }

    /// A language part of the calls in the query's range is in and nothing
    /// could read, by locale, as of the last search.
    public func unreadable(for query: CallQuery) -> String? {
        index.unreadable(for: query)
    }
}
