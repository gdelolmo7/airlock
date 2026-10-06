import Foundation

/// A row's quick-select key.
public enum ClipboardShortcut: Equatable, Hashable, Sendable {
    /// ⌥1…⌥9 — pinned rows, in the order you pinned them.
    case pinned(Int)
    /// ⌘1…⌘9 — the most recent unpinned rows. Maccy's `⌘n`.
    case recent(Int)

    public var label: String {
        switch self {
        case .pinned(let n): return "⌥\(n)"
        case .recent(let n): return "⌘\(n)"
        }
    }
}

/// Assigns quick-select keys to the rows on screen.
///
/// Pure, and worth testing, because the numbering has to agree exactly with
/// what the badges say — a shortcut that fires the wrong row silently pastes
/// the wrong thing, which is the worst failure this feature has.
///
/// **Positional, not permanent.** Maccy gives each pinned item "a random but
/// permanent" shortcut. Permanence is better for muscle memory, but random is
/// worse for everything else: an unpredictable key has to be read off the screen
/// before every use, which costs exactly what clicking costs. Numbering by
/// position means ⌥1 is always the top pin, and the badge confirms it.
///
/// Assignment runs over the **visible** rows, so it follows a search. If you
/// filter to three results, ⌘1 is the first of those three — the alternative is
/// badges that lie about what the keys will do.
public enum ClipboardShortcuts {
    /// Nine per group. Ten would need ⌘0, which reads as "tenth" to nobody.
    public static let perGroup = 9

    public static func assign(_ items: [ClipboardItem]) -> [UUID: ClipboardShortcut] {
        var result: [UUID: ClipboardShortcut] = [:]
        var pinned = 0
        var recent = 0
        for item in items {
            if item.pinned {
                guard pinned < perGroup else { continue }
                pinned += 1
                result[item.id] = .pinned(pinned)
            } else {
                guard recent < perGroup else { continue }
                recent += 1
                result[item.id] = .recent(recent)
            }
        }
        return result
    }

    /// The row a keystroke should act on, or nil when nothing is bound to it.
    public static func item(for shortcut: ClipboardShortcut,
                            in items: [ClipboardItem]) -> ClipboardItem? {
        switch shortcut {
        case .pinned(let n):
            return nth(n, of: items.filter(\.pinned))
        case .recent(let n):
            return nth(n, of: items.filter { !$0.pinned })
        }
    }

    private static func nth(_ n: Int, of items: [ClipboardItem]) -> ClipboardItem? {
        guard (1...perGroup).contains(n), items.count >= n else { return nil }
        return items[n - 1]
    }
}
