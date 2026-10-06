import SwiftUI
import AirlockCore

/// Renders the inline markdown agents actually write — **bold**, *italic*,
/// `code`, [links](url) — into an AttributedString for the island's message
/// lines. Inline-only on purpose: block structure (tables, fences, headings)
/// is already removed upstream by `SessionState.displayLine` — a row can't
/// lay it out, so it is skipped rather than flattened into noise.
///
/// Code spans get the mono face, which is exactly our type rule: proportional
/// chrome everywhere, mono reserved for genuine code.
@MainActor
enum InlineMarkdown {
    /// Memoised, because every caller is inside a `body`.
    ///
    /// `SessionRowView` re-renders on hover — `showsFullExchange` is derived
    /// from `isHovered` — so moving the pointer down the agents tab re-parsed
    /// markdown for every row it passed, twice per row. Parsing is pure in
    /// (text, size), so the result is cacheable outright.
    ///
    /// Bounded and FIFO-evicted rather than unbounded: the inputs are agent
    /// messages, which are unbounded in number over a long session, and a cache
    /// that only grows is a leak with a nicer name. 256 covers every row on
    /// screen many times over.
    private static var memo: [Key: AttributedString] = [:]
    private static var order: [Key] = []
    private static let capacity = 256

    private struct Key: Hashable {
        let raw: String
        let size: CGFloat
        /// In the key because the rendered result depends on it — see `parse`.
        /// Without this, changing the text size would return the previous
        /// scale's fonts from the cache for every line already on screen.
        let scale: CGFloat
    }

    static func render(_ raw: String, size: CGFloat) -> AttributedString {
        let key = Key(raw: raw, size: size, scale: Theme.textScale)
        if let hit = memo[key] { return hit }
        let rendered = parse(raw, size: size)
        if order.count >= capacity, let oldest = order.first {
            order.removeFirst()
            memo.removeValue(forKey: oldest)
        }
        order.append(key)
        memo[key] = rendered
        return rendered
    }

    private static func parse(_ raw: String, size: CGFloat) -> AttributedString {
        let cleaned = raw
        guard var attributed = try? AttributedString(
            markdown: cleaned,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(cleaned)
        }

        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            // Scaled HERE rather than at the three call sites, because each of
            // them pairs this with a `Theme.chrome(N)` that already scales — so
            // leaving it raw made inline code shrink relative to its own
            // sentence as the setting went up.
            attributed[run.range].font = .system(size: (size - 0.5) * Theme.textScale,
                                                 weight: .medium, design: .monospaced)
            attributed[run.range].foregroundColor = Theme.codeText
        }
        // Links keep their text (the URL is noise in a row) but stay tinted.
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = Theme.running
            attributed[run.range].underlineStyle = nil
        }
        return attributed
    }
}
