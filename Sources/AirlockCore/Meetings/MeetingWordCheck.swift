import Foundation

/// "Check these words" on a notes page, answered.
///
/// The notes list a word the transcript may have heard wrong ("Mapa, heard
/// as “napa”"). "Use Mapa" puts it in place of every way it was heard, in
/// the notes and in the transcript, and takes the line off the list; "Leave
/// it" only takes the line off. Pure: the store reads and writes the files.
public enum MeetingWordCheck {
    /// `text` with each of `heard`, as a whole word, read as `best`. Case and
    /// accents don't count in finding it ("Napa", "napá"); `best` goes in as
    /// it is spelled. One pass, the longest form first where two start
    /// together, so a two-word form is not half replaced by a shorter one
    /// and nothing put in is replaced again. Where `best` itself is written
    /// it stays, even when a form heard is part of it ("Mapa" in "Mapa
    /// Empresarial").
    public static func replace(_ heard: [String], with best: String, in text: String) -> String {
        let forms = heard.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != best }
        guard !forms.isEmpty else { return text }
        // Longest first; on a tie a form heard before the guess, so "mapa"
        // still becomes "Mapa".
        let looked = (forms.map { (form: $0, keep: false) } + [(form: best, keep: true)])
            .filter { !$0.form.isEmpty }
            .sorted { ($0.form.count, $0.keep ? 0 : 1) > ($1.form.count, $1.keep ? 0 : 1) }
        var result = ""
        var rest = text[...]
        while true {
            var first: (range: Range<String.Index>, keep: Bool)?
            for (form, keep) in looked {
                guard let range = wholeWord(form, in: text, from: rest.startIndex) else { continue }
                if first == nil || range.lowerBound < first!.range.lowerBound { first = (range, keep) }
            }
            guard let first else { break }
            result += text[rest.startIndex..<first.range.lowerBound]
            result += first.keep ? String(text[first.range]) : best
            rest = text[first.range.upperBound...]
        }
        return result + rest
    }

    /// The first place from `start` where `form` is a whole word of `text`.
    private static func wholeWord(_ form: String, in text: String, from start: String.Index) -> Range<String.Index>? {
        var from = start
        while from < text.endIndex,
              let found = text[from...].range(of: form, options: [.caseInsensitive, .diacriticInsensitive]) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            if isWordEdge(before), isWordEdge(after) { return found }
            from = text.index(after: found.lowerBound)
        }
        return nil
    }

    /// `page` with `best`'s line gone from "Check these words", and the
    /// heading too once it has no line left. With `use`, every one of
    /// `heard` in the rest of the page reads `best`, except in the person's
    /// own notes, which stay as they typed them.
    public static func answer(_ page: String, best: String, heard: [String], use: Bool) -> String {
        let lines = page.components(separatedBy: "\n")
        var kept: [String] = []
        var section: String?
        var wordsAt: Int?
        var wordsLeft = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let heading = heading(trimmed) {
                closeWords(&kept, at: wordsAt, left: wordsLeft)
                wordsAt = nil
                section = heading
                if heading == MeetingFiles.wordsHeading {
                    wordsAt = kept.count
                    wordsLeft = 0
                }
                kept.append(use ? replace(heard, with: best, in: line) : line)
                continue
            }
            if trimmed == "---" || trimmed == "***" {
                closeWords(&kept, at: wordsAt, left: wordsLeft)
                wordsAt = nil
                section = nil
            }
            if section == MeetingFiles.wordsHeading, wordsAt != nil {
                if let word = word(in: trimmed) {
                    if same(word.best, best) { continue }
                    wordsLeft += 1
                }
                kept.append(line)
                continue
            }
            let yours = section == MeetingFiles.yourNotesHeading
            kept.append(use && !yours ? replace(heard, with: best, in: line) : line)
        }
        closeWords(&kept, at: wordsAt, left: wordsLeft)
        return kept.joined(separator: "\n")
    }

    /// `record` with every one of `heard` read as `best` in what was said,
    /// the shadow's lines too. The person's typed lines are theirs and are
    /// left alone. Returns how many lines changed.
    @discardableResult
    public static func use(_ best: String, for heard: [String], in record: inout MeetingRecord) -> Int {
        var changed = 0
        let segments = record.segments.map { segment -> MeetingSegment in
            var segment = segment
            let text = replace(heard, with: best, in: segment.text)
            if text != segment.text {
                segment.text = text
                changed += 1
            }
            return segment
        }
        let shadow = record.shadow.map { line -> MeetingShadowLine in
            var line = line
            line.segment.text = replace(heard, with: best, in: line.segment.text)
            return line
        }
        if changed > 0 { record.replaceSegments(with: segments) }
        if shadow != record.shadow { record.replaceShadow(with: shadow) }
        return changed
    }

    /// Whether "Use" should also add `best` to the words in Settings: a
    /// figure ("40 €", "2027") is right for this call only.
    public static func belongsInKnownWords(_ best: String) -> Bool {
        !best.contains(where: \.isNumber) && !MeetingKnownWords.key(best).isEmpty
    }

    // MARK: - Lines

    /// A line of the list read back, its time left out.
    private static func word(in line: String) -> (best: String, heard: [String])? {
        guard case .item(let text, _, _, _)? = MeetingPage.blocks(of: line).first else { return nil }
        return MeetingPage.word(text)
    }

    private static func heading(_ line: String) -> String? {
        guard case .heading(let text, _)? = MeetingPage.blocks(of: line).first,
              line.hasPrefix("#") else { return nil }
        return text
    }

    /// Takes the words heading off, with the blank lines under it, when no
    /// word is left below it.
    private static func closeWords(_ kept: inout [String], at index: Int?, left: Int) {
        guard let index, left == 0, index < kept.count else { return }
        let rest = kept[(index + 1)...]
        guard rest.allSatisfy({ word(in: $0.trimmingCharacters(in: .whitespaces)) == nil }) else { return }
        // Only blank lines (and nothing the person added) go with it.
        guard rest.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
        kept.removeSubrange(index...)
    }

    private static func same(_ one: String, _ other: String) -> Bool {
        MeetingKnownWords.key(one) == MeetingKnownWords.key(other)
    }

    private static func isWordEdge(_ character: Character?) -> Bool {
        guard let character else { return true }
        return !(character.isLetter || character.isNumber)
    }
}
