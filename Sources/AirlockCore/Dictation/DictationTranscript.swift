import Foundation

/// Assembles `SpeechTranscriber` results into one piece of text.
///
/// This exists because of one measured, non-obvious fact about the API: a
/// result's text is **cumulative over its own range, not a delta**. Volatile
/// results grow in place — "App", "Approve", "Approve the" — and then a final
/// result arrives covering *the same range* and replaces all of it, often with
/// different punctuation and casing than the last volatile guess.
///
/// Append every result as it arrives and you get "AppApproveApprove the". So
/// volatile text is held separately and replaced wholesale, and only finals are
/// ever appended.
public struct DictationTranscript: Equatable, Sendable {
    /// Segments the recogniser has committed to. Only this is delivered.
    public private(set) var finalized: String = ""
    /// The current in-flight guess. Replaced on every update, never appended,
    /// and never delivered — by the time you stop speaking it has been
    /// superseded by a final covering the same audio.
    public private(set) var volatile: String = ""

    public init() {}

    /// A live view for the "listening" indicator: what has been committed, plus
    /// the current guess.
    public var display: String {
        Self.joined(finalized, volatile)
    }

    /// What actually gets typed. Deliberately excludes `volatile`: anything
    /// still volatile at the end is superseded once the analyzer finalises, and
    /// including it would double the last few words.
    public var deliverable: String { finalized }

    public var isEmpty: Bool { finalized.isEmpty && volatile.isEmpty }

    public mutating func apply(text: String, isFinal: Bool) {
        let segment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            // An empty final still clears the volatile guess it supersedes.
            if !segment.isEmpty { finalized = Self.joined(finalized, segment) }
            volatile = ""
        } else {
            volatile = segment
        }
    }

    public mutating func reset() {
        finalized = ""
        volatile = ""
    }

    /// Join with a single space — unless the next segment opens with
    /// punctuation.
    ///
    /// A forced finalisation can cut mid-sentence, so the following segment
    /// genuinely can begin ", in the current directory". An unconditional space
    /// renders that as "the files , in the current directory".
    static func joined(_ base: String, _ next: String) -> String {
        guard !base.isEmpty else { return next }
        guard !next.isEmpty else { return base }
        guard let first = next.first else { return base }
        let attaches = first.isPunctuation || first.isMathSymbol || first == "'" || first == "\u{2019}"
        return attaches ? base + next : base + " " + next
    }
}
