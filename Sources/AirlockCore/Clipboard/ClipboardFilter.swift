import Foundation

/// The type filter above the clipboard list.
///
/// Five, as the design drew, once the clipboard learned to keep files at all.
///
/// It could not, at first: `Payload` was `.text` or `.image`, nothing read
/// `public.file-url`, and a file copied in Finder was recorded as a string of
/// its own path — which is why "Files" looked like a button with no data behind
/// it. The design's own empty state had said otherwise all along: "text, images,
/// files, and where each came from".
public enum ClipboardFilter: String, CaseIterable, Sendable, Identifiable, Codable {
    case all, text, links, images, files

    public var id: String { rawValue }

    /// Capitalised, as the design draws them — the one place in this panel's
    /// chrome that is, because they are buttons rather than labels.
    public var label: String { rawValue.capitalized }

    /// For the icon-only form, used when the panel is too narrow for words.
    public var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .links: return "link"
        case .images: return "photo"
        case .files: return "doc"
        }
    }

    /// What an empty list means under this filter — never "copy something and it
    /// lands here", which is only true when the history itself is empty.
    public var emptyMessage: String {
        switch self {
        case .all: return "Copy something and it lands here."
        case .text: return "No text copied yet."
        case .links: return "No links copied yet."
        case .images: return "No images copied yet."
        case .files: return "No files copied yet."
        }
    }

    /// What a search that found nothing says. Under a filter other than All it
    /// names the filter, because "Nothing matches" while Links is on is a miss
    /// that may only be the filter's — the thing you want can be one tap away
    /// under All.
    public func searchMissMessage(query: String) -> String {
        let quoted = "\u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}"
        switch self {
        case .all: return "Nothing matches \(quoted)"
        default: return "Nothing in \(label) matches \(quoted)"
        }
    }

    /// The button under a filtered search miss: switches to All, keeps the query.
    public static let searchEverythingButton = "Search everything"

    public func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: return true
        case .images: return item.isImage
        case .files: return item.isFile
        case .links: return item.textKind == .link
        // Code counts as text. The filter answers "what did I copy", and a
        // command is something you copied as text; splitting it out would make
        // the common case need two buttons.
        case .text: return !item.isImage && !item.isFile && item.textKind != .link
        }
    }
}

public extension ClipboardItem {
    /// The kind the row TINTS by and the filter MATCHES by, resolved once.
    ///
    /// Two call sites deriving this independently is how a row drawn as a link
    /// ends up missing from the links filter — the bug is invisible until
    /// someone filters, and then it looks like the filter is broken rather than
    /// the agreement.
    var textKind: ClipboardTextKind {
        // A filename is prose, never code — the design sets filenames in the UI
        // face, and `Screenshot 2026-08-12.png` would otherwise be judged on its
        // punctuation like anything else.
        (isImage || isFile) ? .prose : ClipboardTextKind.of(preview)
    }
}
