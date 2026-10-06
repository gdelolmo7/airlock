import Foundation

/// Prepares finished transcript text for delivery as synthetic keystrokes.
public enum DictationText {
    /// `CGEventKeyboardSetUnicodeString` takes a UTF-16 buffer. Long strings are
    /// split rather than posted in one event: the API is documented to be for
    /// "a few" characters, and oversized payloads are silently truncated by some
    /// receivers rather than rejected. 20 scalars per event is well inside what
    /// every target handles.
    public static let defaultChunkLimit = 20

    /// What to type, or nil when there is nothing worth typing.
    ///
    /// Returning nil rather than "" matters: the caller uses it to tell "you
    /// said nothing" apart from "something went wrong", and those need different
    /// messages. Silence and a failed microphone look identical otherwise.
    public static func prepared(_ raw: String) -> String? {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Split into pieces safe to hand to `CGEvent`, never breaking a character.
    ///
    /// Splitting on a raw UTF-16 index would cut surrogate pairs in half, and
    /// half a surrogate is not a character — an emoji becomes two replacement
    /// glyphs. Walking scalars and counting their UTF-16 width keeps every unit
    /// whole, so `limit` is a ceiling rather than an exact size.
    public static func chunked(_ text: String, limit: Int = defaultChunkLimit) -> [String] {
        // A pair is 2 units wide; a limit of 1 could never place one and would
        // spin forever emitting empty chunks.
        let ceiling = max(2, limit)
        guard !text.isEmpty else { return [] }

        var chunks: [String] = []
        var current = String.UnicodeScalarView()
        var width = 0

        for scalar in text.unicodeScalars {
            let scalarWidth = UTF16.width(scalar)
            if width + scalarWidth > ceiling, !current.isEmpty {
                chunks.append(String(current))
                current = String.UnicodeScalarView()
                width = 0
            }
            current.append(scalar)
            width += scalarWidth
        }
        if !current.isEmpty { chunks.append(String(current)) }
        return chunks
    }
}
