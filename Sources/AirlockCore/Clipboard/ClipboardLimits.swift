import Foundation

/// Size bounds on what the clipboard history will keep.
///
/// The item cap bounds how MANY things are stored and says nothing about how
/// big they are, which leaves two real holes. Copy a 50 MB log file and the
/// whole thing is held in memory, hashed on the main actor, and re-serialised
/// into `clipboard.json` on every subsequent copy — so one large copy makes
/// every later copy slow, permanently. And two hundred retina screenshots is
/// gigabytes on disk that nothing ever reclaims.
///
/// Oversized items are **skipped, never truncated**. A truncated clipboard entry
/// is worse than an absent one: it looks complete in the list and pastes half a
/// file. Anything past these bounds is something you would re-copy from its
/// source rather than fish out of a history list.
public enum ClipboardLimits {
    /// Roughly forty thousand words. Past this it is a document, not a snippet.
    public static let maximumTextBytes = 256 * 1024

    /// Comfortably above any real screenshot, including 6K retina.
    public static let maximumImageBytes = 16 * 1024 * 1024

    /// Total disk the stored images may occupy. The per-item cap alone still
    /// permits two hundred large images, so this is what actually bounds the
    /// directory.
    public static let imageDirectoryBudget = 250 * 1024 * 1024

    public static func acceptsText(byteCount: Int) -> Bool {
        byteCount <= maximumTextBytes
    }

    public static func acceptsImage(byteCount: Int) -> Bool {
        byteCount <= maximumImageBytes
    }

    /// Human-readable, for the skip reason shown in Settings.
    public static func describe(bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

extension ClipboardHistory {
    /// Ids of the oldest image-bearing items to drop, to bring stored images
    /// under `budget`.
    ///
    /// Pinned items are never offered: pinning is the user saying "keep this",
    /// and a disk budget is a weaker claim than an explicit instruction. If the
    /// pins alone exceed the budget, nothing is dropped — the right failure is
    /// a large directory, not silently discarding what someone asked to keep.
    public func imageItemsToEvict(sizes: [String: Int],
                                  budget: Int = ClipboardLimits.imageDirectoryBudget) -> [UUID] {
        let imageItems = items.filter { $0.imageFile != nil }
        let total = imageItems.reduce(0) { $0 + (($1.imageFile).flatMap { sizes[$0] } ?? 0) }
        guard total > budget else { return [] }

        // Oldest first — `items` is newest-first, and pins float above both.
        var remaining = total
        var evicted: [UUID] = []
        for item in imageItems.reversed() where !item.pinned {
            guard remaining > budget else { break }
            remaining -= (item.imageFile).flatMap { sizes[$0] } ?? 0
            evicted.append(item.id)
        }
        return evicted
    }
}
