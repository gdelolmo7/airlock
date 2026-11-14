import Foundation

/// Changes the person makes to a notes page in the notes window, made to
/// the page's own Markdown: the file stays the one place the notes are,
/// readable and editable in any text editor.
///
/// Lines are counted as `MeetingPage.lines(of:)` splits them, and each
/// change names the lines of the block it is about (`MeetingPage.Placed.lines`).
/// A change to lines the page no longer has leaves it as it is.
public enum MeetingPageEdit {
    /// A to-do ticked, or unticked: "- [ ] " and "- [x] " swapped.
    public static func toggle(_ page: String, lines span: Range<Int>) -> String {
        var lines = MeetingPage.lines(of: page)
        guard let index = span.first, lines.indices.contains(index) else { return page }
        let line = lines[index]
        let lead = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(lead.count)
        guard let marker = rest.first, "-*•".contains(marker), rest.dropFirst().first == " " else { return page }
        let after = rest.dropFirst(2)
        let box: String
        if after.hasPrefix("[ ] ") { box = "[x] " }
        else if after.hasPrefix("[x] ") || after.hasPrefix("[X] ") { box = "[ ] " }
        else { return page }
        lines[index] = lead + "\(marker) " + box + after.dropFirst(4)
        return lines.joined(separator: "\n")
    }

    /// What the person edits of a line: its words as they read, without
    /// the Markdown around them (the bold lead, the "decided" tick), the
    /// owner or the time it was said, which the line keeps.
    public static func editable(_ block: MeetingPage.Block) -> String? {
        switch block {
        case .paragraph(let text): return text
        case .item(let text, _, _, _):
            var text = Substring(text)
            if text.hasPrefix(MeetingPage.decidedMark) { text = text.dropFirst(MeetingPage.decidedMark.count) }
            return text.replacingOccurrences(of: "**", with: "")
        case .heading, .unwritten, .rule: return nil
        }
    }

    /// The block on `span` reading `text` instead. A list line keeps its
    /// marker, its tick box, its owner and its time; a paragraph becomes
    /// one line. Empty text takes the block off the page.
    public static func replace(_ page: String, lines span: Range<Int>, with text: String) -> String {
        let text = oneLine(text)
        guard !text.isEmpty else { return delete(page, lines: span) }
        var lines = MeetingPage.lines(of: page)
        guard !span.isEmpty, span.lowerBound >= 0, span.upperBound <= lines.count else { return page }
        let first = lines[span.lowerBound]
        let lead = first.prefix { $0 == " " || $0 == "\t" }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        if span.count == 1, let item = MeetingPage.item(trimmed) {
            var head = String(trimmed.prefix(2))
            var rest = trimmed.dropFirst(2)
            for box in ["[ ] ", "[x] ", "[X] "] where rest.hasPrefix(box) {
                head += box
                rest = rest.dropFirst(box.count)
                break
            }
            // The text the parser read is the start of the rest; what follows
            // it is the owner and the time, kept as they are.
            let tail = rest.hasPrefix(item.text) ? String(rest.dropFirst(item.text.count)) : ""
            var words = text
            let point = MeetingPage.point(item.text)
            if point.lead != nil { words = MeetingPage.bolded(words) }
            if point.decided { words = MeetingPage.decidedMark + words }
            lines[span.lowerBound] = lead + head + words + tail
        } else {
            lines.replaceSubrange(span, with: [lead + text])
        }
        return lines.joined(separator: "\n")
    }

    /// The block on `span` taken off the page.
    public static func delete(_ page: String, lines span: Range<Int>) -> String {
        var lines = MeetingPage.lines(of: page)
        guard !span.isEmpty, span.lowerBound >= 0, span.upperBound <= lines.count else { return page }
        lines.removeSubrange(span)
        return lines.joined(separator: "\n")
    }

    /// A line the person typed, put on the page before line `at` (the
    /// page's end when past it): a to-do with a box to tick when `todo`,
    /// a plain list line otherwise. It has no time, so nothing to jump to.
    public static func add(_ page: String, at index: Int, text: String, todo: Bool) -> String {
        let text = oneLine(text)
        guard !text.isEmpty else { return page }
        var lines = MeetingPage.lines(of: page)
        let at = min(max(0, index), lines.count)
        let line = (todo ? "- [ ] " : "- ") + text
        // After a heading, a blank line first, as the writer leaves one.
        if at > 0, MeetingPage.heading(lines[at - 1].trimmingCharacters(in: .whitespaces)) != nil {
            lines.insert(contentsOf: ["", line], at: at)
        } else {
            lines.insert(line, at: at)
        }
        return lines.joined(separator: "\n")
    }

    /// Where a line added to a card goes: after its last line, or after its
    /// heading when it has none. Nil when the page lines are not known.
    public static func end(of section: MeetingPage.Section) -> Int? {
        if let last = section.lines.compactMap(\.lines).last { return last.upperBound }
        return section.headingLine.map { $0 + 1 }
    }

    /// The page with the title the person gave the call as its first heading.
    public static func retitled(_ page: String, as title: String) -> String {
        let title = oneLine(title)
        guard !title.isEmpty else { return page }
        var lines = MeetingPage.lines(of: page)
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           MeetingPage.heading(lines[first].trimmingCharacters(in: .whitespaces))?.level == 1 {
            lines[first] = "# " + title
        } else {
            lines.insert(contentsOf: ["# " + title, ""], at: 0)
        }
        return lines.joined(separator: "\n")
    }

    /// Whether the page is not what Airlock wrote: `written`, the page as
    /// written, with the names in `record` put in.
    public static func hasEdits(_ page: String, written: String?, record: MeetingRecord) -> Bool {
        guard let written else { return false }
        return page != MeetingNaming.apply(record, to: written)
    }

    /// The page named again from `old`'s names to `new`'s, the person's
    /// edits kept. A line still as Airlock wrote it is named afresh from
    /// the page as written, like a page nobody edited; a line the person
    /// changed or typed has each name it had swapped for the new one.
    public static func renamed(_ page: String, written: String, from old: MeetingRecord,
                               to new: MeetingRecord) -> String {
        let before = MeetingNaming.apply(old, to: written)
        let after = MeetingNaming.apply(new, to: written)
        if page == before { return after }
        let beforeLines = MeetingPage.lines(of: before), afterLines = MeetingPage.lines(of: after)
        var named: [String: String] = [:]
        if beforeLines.count == afterLines.count {
            for (line, renamed) in zip(beforeLines, afterLines) where named[line] == nil { named[line] = renamed }
        }
        let swaps = self.swaps(from: old, to: new)
        return MeetingPage.lines(of: page).map { line in
            if let renamed = named[line] { return renamed }
            var line = line
            for (from, to) in swaps { line = swap(from, with: to, in: line) }
            return MeetingNaming.apply(new, to: line)
        }.joined(separator: "\n")
    }

    /// Each name a voice had in `old` and what it is called in `new`: its
    /// new name, "You", or its label again when it is no longer named.
    /// "You" in `old` is a word too common to swap and is left alone.
    static func swaps(from old: MeetingRecord, to new: MeetingRecord) -> [(String, String)] {
        old.names.compactMap { given in
            guard !given.isYou, !given.name.isEmpty else { return nil }
            let now: String
            if let label = new.givenLabel(of: given.voice) {
                now = label
            } else if given.voice == MeetingRecord.otherSide {
                now = old.isInPerson ? MeetingRecord.someone : MeetingSpeaker.them.label
            } else {
                now = MeetingRecord.personLabel(given.voice)
            }
            return now == given.name ? nil : (given.name, now)
        }
    }

    /// `name` swapped for `other` wherever it is a whole word.
    static func swap(_ name: String, with other: String, in line: String) -> String {
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return line }
        let range = NSRange(line.startIndex..., in: line)
        return expression.stringByReplacingMatches(in: line, range: range,
                                                   withTemplate: NSRegularExpression.escapedTemplate(for: other))
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
