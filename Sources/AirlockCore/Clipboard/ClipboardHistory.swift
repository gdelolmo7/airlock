import Foundation

/// The clipboard history, as a pure value.
///
/// Same discipline as `SessionState`: every mutation goes through this type, it
/// does no I/O and holds no references, and the ordering invariant is enforced
/// here rather than trusted to callers. The model above it polls the pasteboard
/// and writes files; it does not decide what the list looks like.
public struct ClipboardHistory: Equatable, Sendable, Codable {
    /// Pinned first, then most recent. Held sorted rather than sorted on read —
    /// the list is rendered far more often than it is written.
    public private(set) var items: [ClipboardItem]

    public static let defaultCapacity = 200
    public static let capacityRange: ClosedRange<Int> = 20...1000

    public init(items: [ClipboardItem] = []) {
        self.items = items
        sort()
    }

    // MARK: - Mutation

    /// Result of taking a copy, so the caller knows whether the image file it
    /// just wrote is actually needed.
    public enum Insertion: Equatable, Sendable {
        case added(UUID)
        /// Content already present; the existing row moved to the top.
        case merged(UUID)
    }

    /// Re-copying something already in history promotes it instead of appending.
    /// The existing row keeps its id and its pin — losing a pin because you
    /// copied the thing again would be its own small betrayal.
    ///
    /// Text takes the newest copy's exact characters and source app: matching
    /// ignores spaces at either end, and pasting should give back what was
    /// copied last, not a version with a newline a terminal would run. An image
    /// keeps its own file, which the caller deletes the duplicate of.
    @discardableResult
    public mutating func insert(_ item: ClipboardItem, capacity: Int = defaultCapacity) -> Insertion {
        if let index = items.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            let id = items[index].id
            if items[index].text != nil, item.text != nil {
                items[index].payload = item.payload
                items[index].sourceBundleID = item.sourceBundleID
                items[index].sourceAppName = item.sourceAppName
            }
            promote(id: id, at: item.copiedAt)
            return .merged(id)
        }
        items.append(item)
        sort()
        trim(to: capacity)
        return .added(item.id)
    }

    /// Move an item back to the top, as if it had just been copied — because it
    /// has been.
    ///
    /// Picking a row out of the history puts it on the pasteboard, which makes
    /// it the most recent thing you copied. Leaving it where it was would mean
    /// the list disagreed with the clipboard it is a history of, and the item
    /// you use most would sink out of reach. Same path as re-copying it from the
    /// original app, and the same `copyCount` bump.
    public mutating func promote(id: UUID, at date: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].copiedAt = date
        items[index].copyCount += 1
        sort()
    }

    /// Folds together text rows that only differ by spaces at either end,
    /// for histories saved before `ClipboardItem.fingerprint(forText:)`
    /// ignored them. The row that sorts first survives (pinned, else newest),
    /// with the latest copy time and every copy counted. Text rows are
    /// re-fingerprinted on the way, so the next copy merges too.
    public mutating func mergeRepeatedText() {
        var survivors: [String: Int] = [:]
        var merged: [ClipboardItem] = []
        for item in items {
            guard let value = item.text else { merged.append(item); continue }
            let key = ClipboardItem.fingerprint(forText: value)
            if let index = survivors[key] {
                merged[index].copiedAt = max(merged[index].copiedAt, item.copiedAt)
                merged[index].copyCount += item.copyCount
                continue
            }
            survivors[key] = merged.count
            merged.append(ClipboardItem(id: item.id, payload: item.payload, fingerprint: key,
                                        copiedAt: item.copiedAt, pinned: item.pinned,
                                        copyCount: item.copyCount, sourceBundleID: item.sourceBundleID,
                                        sourceAppName: item.sourceAppName))
        }
        items = merged
        sort()
    }

    public mutating func setPinned(_ pinned: Bool, id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned = pinned
        sort()
    }

    public mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Pins are the whole point of pinning: a clear must not take them.
    public mutating func clearUnpinned() {
        items.removeAll { !$0.pinned }
    }

    public mutating func clearAll() {
        items.removeAll()
    }

    /// Applied when the setting changes, not only on insert — lowering the cap
    /// should take effect now rather than at the next copy.
    public mutating func trim(to capacity: Int) {
        guard capacity > 0 else { return clearUnpinned() }
        var kept = 0
        items.removeAll { item in
            if item.pinned { return false } // pinned rows never count against the cap
            kept += 1
            return kept > capacity
        }
    }

    /// Sorting is a private invariant, never a caller's job.
    private mutating func sort() {
        items.sort { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.copiedAt > rhs.copiedAt
        }
    }

    // MARK: - Reading

    public func item(id: UUID) -> ClipboardItem? {
        items.first { $0.id == id }
    }

    /// Case- and diacritic-insensitive substring match. Deliberately not fuzzy:
    /// clipboard search is used to *re-find something you just had*, where a
    /// literal match is what you expect and a fuzzy one surfaces noise.
    public func matching(_ query: String) -> [ClipboardItem] {
        let needle = Self.fold(query)
        guard !needle.isEmpty else { return items }
        return items.filter { Self.fold($0.searchableText).contains(needle) }
    }

    private static func fold(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Image files still pointed at by some row. Anything else in the images
    /// directory is orphaned — dropped rows leave bytes behind otherwise, and a
    /// screenshot history that only grows is a disk leak with a nice UI.
    public var referencedImageFiles: Set<String> {
        Set(items.compactMap(\.imageFile))
    }
}
