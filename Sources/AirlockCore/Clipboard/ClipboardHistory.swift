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

    /// Copies a smaller plan does not show, newest first. Put away when the
    /// plan dropped, never deleted for it: they come back on a plan that shows
    /// them, and are let go `outOfSightDays` after the first were put away.
    /// Nothing reads them but `fit`, so they are in no list and no search.
    public private(set) var outOfSight: [ClipboardItem]
    /// When everything out of sight is let go.
    public private(set) var outOfSightUntil: Date?
    /// The most the plan showed when this was last fitted; nil had no limit.
    /// A plan that shows fewer than this is a plan that dropped, and only a
    /// drop puts copies out of sight. Free's own copies past its limit go,
    /// as they do on every plan at its limit.
    public private(set) var planShowed: Int?

    public static let defaultCapacity = 200
    public static let capacityRange: ClosedRange<Int> = 20...1000
    public static let outOfSightDays = 30
    public static let outOfSightFor = TimeInterval(outOfSightDays) * 86_400

    public init(items: [ClipboardItem] = []) {
        self.items = items
        self.outOfSight = []
        sort()
    }

    // MARK: - Saved

    private enum CodingKeys: String, CodingKey {
        case items, outOfSight, outOfSightUntil, planShowed
    }

    /// A history saved before plans had only `items`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([ClipboardItem].self, forKey: .items)
        outOfSight = try container.decodeIfPresent([ClipboardItem].self, forKey: .outOfSight) ?? []
        outOfSightUntil = try container.decodeIfPresent(Date.self, forKey: .outOfSightUntil)
        planShowed = try container.decodeIfPresent(Int.self, forKey: .planShowed)
        sort()
    }

    /// The same history without the rows `drop` picks, out of sight or not.
    /// For a row that can no longer work, such as an image whose file is gone.
    public func dropping(where drop: (ClipboardItem) -> Bool) -> ClipboardHistory {
        var kept = self
        kept.items.removeAll(where: drop)
        kept.outOfSight.removeAll(where: drop)
        if kept.outOfSight.isEmpty { kept.outOfSightUntil = nil }
        return kept
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
        // Copied again while out of sight: it is wanted, so it comes back,
        // with its own id and its copies counted.
        if let index = outOfSight.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            var back = outOfSight.remove(at: index)
            if back.text != nil, item.text != nil {
                back.payload = item.payload
                back.sourceBundleID = item.sourceBundleID
                back.sourceAppName = item.sourceAppName
            }
            if outOfSight.isEmpty { outOfSightUntil = nil }
            items.append(back)
            promote(id: back.id, at: item.copiedAt)
            trim(to: capacity)
            return .merged(back.id)
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
        outOfSight.removeAll { $0.id == id }
        if outOfSight.isEmpty { outOfSightUntil = nil }
    }

    /// Pins are the whole point of pinning: a clear must not take them. What
    /// is out of sight goes too: a clear is asked of the whole history.
    public mutating func clearUnpinned() {
        items.removeAll { !$0.pinned }
        outOfSight = []
        outOfSightUntil = nil
    }

    public mutating func clearAll() {
        items.removeAll()
        outOfSight = []
        outOfSightUntil = nil
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

    /// Fits the history to the plan, asked every time it changes and every
    /// time anything is copied: `planShows` is `PlanLimits.clipboardShows`
    /// now, `capacity` the person's own setting.
    ///
    /// **A plan change never deletes a copy.** A plan that shows fewer than
    /// the last one puts the oldest past its limit out of sight, for
    /// `outOfSightDays`; a plan with no limit brings them back. Pinned copies
    /// stay where they are on every plan, as they never count against a limit.
    /// Only the person's own setting deletes, as it always has.
    ///
    /// Returns how many copies Free's limit let go just now: past the plan's
    /// limit and inside the person's own setting, so the same copies would
    /// still be here on a plan without one. Copies put out of sight are not
    /// counted; they are not gone.
    @discardableResult
    public mutating func fit(planShows: Int?, capacity: Int, now: Date) -> Int {
        let showed = planShowed
        planShowed = planShows

        if let until = outOfSightUntil, now >= until {
            outOfSight = []
            outOfSightUntil = nil
        }
        if planShows == nil, !outOfSight.isEmpty {
            let shown = Set(items.map(\.fingerprint))
            items += outOfSight.filter { !shown.contains($0.fingerprint) }
            outOfSight = []
            outOfSightUntil = nil
            sort()
        }
        trim(to: capacity)
        guard let shows = planShows else { return 0 }

        var kept = 0
        var past: [ClipboardItem] = []
        items.removeAll { item in
            if item.pinned { return false }
            kept += 1
            guard kept > shows else { return false }
            past.append(item)
            return true
        }
        let dropped = showed.map { shows < $0 } ?? true
        guard !past.isEmpty else { return 0 }
        guard dropped || outOfSightUntil != nil else { return past.count }
        outOfSight = past + outOfSight
        outOfSightUntil = outOfSightUntil ?? now.addingTimeInterval(Self.outOfSightFor)
        // Never more kept than the person's own setting allows.
        let room = max(0, capacity - items.filter { !$0.pinned }.count)
        if outOfSight.count > room { outOfSight.removeLast(outOfSight.count - room) }
        if outOfSight.isEmpty { outOfSightUntil = nil }
        return 0
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
    ///
    /// Copies out of sight keep theirs, or they would come back blank.
    public var referencedImageFiles: Set<String> {
        Set((items + outOfSight).compactMap(\.imageFile))
    }
}
