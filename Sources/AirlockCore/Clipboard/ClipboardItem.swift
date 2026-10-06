import CryptoKit
import Foundation

/// One thing you copied.
///
/// Image bytes are *not* held here — only the name of a file beside the history
/// JSON. A few hundred screenshots inlined as base64 would turn every save into
/// a multi-megabyte rewrite of the whole history, and this is a cache that gets
/// written on every copy.
public struct ClipboardItem: Identifiable, Equatable, Sendable, Codable {
    public enum Payload: Equatable, Sendable, Codable {
        case text(String)
        /// File name inside the images directory, plus pixel size for the row.
        case image(file: String, width: Int, height: Int)
        /// A file COPIED IN FINDER, held as its path and nothing else.
        ///
        /// Not the bytes, for the reason images are not held either — but also
        /// not a copy of the file: this is a reference to where it already
        /// lives, so pasting it puts the same URL back and the original is never
        /// duplicated or moved. A row whose file has since been deleted or moved
        /// is a row that can no longer paste, which is the honest outcome for a
        /// reference.
        case file(path: String)
    }

    public let id: UUID
    /// Changes only when a re-copy of the same text merges into this row: the
    /// row then holds the newest copy's exact text (see `ClipboardHistory.insert`).
    public internal(set) var payload: Payload
    /// Stable content identity. Re-copying the same thing moves the existing row
    /// to the top rather than adding a second one, which is the behaviour that
    /// makes a clipboard history usable instead of a log.
    public let fingerprint: String
    public var copiedAt: Date
    public var pinned: Bool
    /// How many times this exact content has been copied. Cheap to keep, and the
    /// only basis for a most-used sort later.
    public var copyCount: Int
    public internal(set) var sourceBundleID: String?
    public internal(set) var sourceAppName: String?

    public init(id: UUID = UUID(), payload: Payload, fingerprint: String, copiedAt: Date,
                pinned: Bool = false, copyCount: Int = 1,
                sourceBundleID: String? = nil, sourceAppName: String? = nil) {
        self.id = id
        self.payload = payload
        self.fingerprint = fingerprint
        self.copiedAt = copiedAt
        self.pinned = pinned
        self.copyCount = copyCount
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
    }

    /// The fingerprint for copied text: the same words with different spaces
    /// or line breaks at either end are the same copy.
    ///
    /// Selecting a sentence picks up a trailing space one time and not the
    /// next, and a line copied from a terminal or an editor often brings its
    /// newline. Hashing the exact bytes made those two rows that read
    /// identically. Spaces inside the text still count, since there they
    /// change what it says. A copy that is nothing but whitespace keeps its
    /// exact bytes, or every blank copy would collapse into one row.
    public static func fingerprint(forText value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (trimmed.isEmpty ? value : trimmed).precomposedStringWithCanonicalMapping
        return "t:" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// How much of a copied text `preview` reads: far more than a row or a
    /// tooltip can show, and few enough that reading it costs nothing.
    public static let previewSource = 2_000

    public var isImage: Bool {
        if case .image = payload { return true }
        return false
    }

    public var isFile: Bool {
        if case .file = payload { return true }
        return false
    }

    public var filePath: String? {
        if case .file(let path) = payload { return path }
        return nil
    }

    public var text: String? {
        if case .text(let value) = payload { return value }
        return nil
    }

    public var imageFile: String? {
        if case .image(let file, _, _) = payload { return file }
        return nil
    }

    /// One line for the row. Collapses whitespace because copied code and copied
    /// prose both arrive full of newlines, and a row that grows to fit them
    /// turns the list into a wall.
    ///
    /// Only the first `previewSource` characters are read. The row shows one
    /// line, and the filter, the row tint and the tooltip all go through this
    /// property — several times per redraw — so a single 115,000-character copy
    /// in the owner's history froze the panel for about half a second on every
    /// filter switch (2026-10-04).
    public var preview: String {
        switch payload {
        case .text(let value):
            let head = value.prefix(Self.previewSource)
            let collapsed = head
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .joined(separator: " ")
            if collapsed.isEmpty { return "(whitespace)" }
            return head.endIndex < value.endIndex ? collapsed + "…" : collapsed
        case .image(_, let width, let height):
            return "Image — \(width)×\(height)"
        case .file(let path):
            // The name, not the path. The design sets filenames in the UI face
            // beside prose, and a full path in a 28pt row is all middle.
            return (path as NSString).lastPathComponent
        }
    }

    /// What a search query is matched against. Images have no text, so they
    /// match on their source app and the word "image" — otherwise typing
    /// anything at all would hide every screenshot you took.
    public var searchableText: String {
        switch payload {
        case .text(let value):
            return [value, sourceAppName].compactMap { $0 }.joined(separator: " ")
        case .image:
            return ["image", sourceAppName].compactMap { $0 }.joined(separator: " ")
        case .file(let path):
            // The whole path, not the name the row shows. "downloads" and
            // "tailandia" are how people look for a file they copied, and
            // neither is in the filename.
            return ["file", path, sourceAppName].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// Rough character count, for the row's trailing detail.
    public var sizeLabel: String {
        switch payload {
        case .text(let value):
            let count = value.count
            return count == 1 ? "1 char" : "\(count) chars"
        case .image(_, let width, let height):
            return "\(width)×\(height)"
        case .file(let path):
            let ext = (path as NSString).pathExtension
            return ext.isEmpty ? "file" : ext.lowercased()
        }
    }
}
