import Foundation

/// A notes page read back into pieces a window can draw: headings,
/// paragraphs, list items, the stretches with no notes and the closing line.
///
/// Read from the file rather than kept beside it, so the window shows what
/// is on disk, the owner's own edits included. Only the Markdown that
/// `MeetingFiles.notesPage` writes is understood; anything else is kept as a
/// paragraph, never dropped.
public enum MeetingPage {
    public enum Block: Equatable, Sendable {
        case heading(String, level: Int)
        case paragraph(String)
        /// `checked` is nil for a plain item, false for "- [ ]", true for "- [x]".
        /// `at` is the time a line of notes was said, from its closing
        /// " · 12:03"; `owner` is who a to-do is for, from " — Ana" before
        /// that. Both nil on a line without them, so older pages read the same.
        case item(String, checked: Bool?, owner: String? = nil, at: TimeInterval? = nil)
        /// A stretch of the call the model wrote no notes for
        /// (`MeetingNotes.Stretch`), from its own line on the page.
        case unwritten(from: TimeInterval, to: TimeInterval)
        case rule
    }

    public static func blocks(of page: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in page.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if let heading = heading(line) {
                flush()
                blocks.append(.heading(heading.text, level: heading.level))
            } else if line == "---" || line == "***" {
                flush()
                blocks.append(.rule)
            } else if let item = item(line) {
                flush()
                blocks.append(.item(item.text, checked: item.checked, owner: item.owner, at: item.at))
            } else if let stretch = unwritten(line) {
                flush()
                blocks.append(.unwritten(from: stretch.start, to: stretch.end))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    /// The page without what the window already shows above it: the title
    /// and, when it is the very next thing, the date line.
    public static func body(of page: String, header: String) -> [Block] {
        var blocks = blocks(of: page)
        if case .heading(_, level: 1)? = blocks.first { blocks.removeFirst() }
        if case .paragraph(let text)? = blocks.first, text == header { blocks.removeFirst() }
        return blocks
    }

    /// A block and where it sits on the page.
    public struct Placed: Equatable, Sendable {
        public let block: Block
        /// The heading it sits under: the nearest one above it, or its own
        /// text for a heading. Nil above the first heading.
        public let section: String?
        /// Below the rule: the closing line about how the notes were made.
        public let closing: Bool

        public init(block: Block, section: String?, closing: Bool) {
            self.block = block
            self.section = section
            self.closing = closing
        }

        /// The person's own words, typed during the call ("Your notes"),
        /// rather than a line Airlock wrote. The heading itself is Airlock's.
        public var isYours: Bool {
            guard !closing, section == MeetingFiles.yourNotesHeading else { return false }
            if case .heading = block { return false }
            return true
        }
    }

    /// Each block with the heading it sits under and whether it is past the
    /// rule, read top to bottom.
    public static func placed(_ blocks: [Block]) -> [Placed] {
        var section: String?
        var closing = false
        return blocks.map { block in
            switch block {
            case .heading(let text, _): section = text
            case .rule: closing = true
            case .paragraph, .item, .unwritten: break
            }
            return Placed(block: block, section: section, closing: closing)
        }
    }

    /// A heading and the lines under it, which the window draws as one card.
    public struct Section: Equatable, Sendable {
        /// Nil for the lines above the first heading.
        public let heading: String?
        public let lines: [Placed]

        public init(heading: String?, lines: [Placed]) {
            self.heading = heading
            self.lines = lines
        }
    }

    /// The page in cards: what sits above the first heading, then one per
    /// heading with everything under it, and apart from them the lines past
    /// the rule, without the rule itself. A heading the owner added in a
    /// text editor gets a card like any other.
    public static func sections(_ placed: [Placed]) -> (sections: [Section], closing: [Placed]) {
        var sections: [Section] = []
        var heading: String?
        var lines: [Placed] = []
        var started = false
        var closing: [Placed] = []
        func flush() {
            if started || !lines.isEmpty { sections.append(Section(heading: heading, lines: lines)) }
        }
        for line in placed {
            if line.closing {
                if line.block != .rule { closing.append(line) }
                continue
            }
            if case .heading(let text, _) = line.block {
                flush()
                heading = text
                lines = []
                started = true
            } else {
                lines.append(line)
            }
        }
        flush()
        return (sections, closing)
    }

    private static func heading(_ line: String) -> (text: String, level: Int)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces), hashes)
    }

    private static func item(_ line: String) -> (text: String, checked: Bool?, owner: String?, at: TimeInterval?)? {
        guard let marker = line.first, "-*•".contains(marker), line.dropFirst().first == " " else { return nil }
        var text = String(line.dropFirst(2))
        var checked: Bool?
        for (box, value) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(box) {
            text = String(text.dropFirst(box.count))
            checked = value
            break
        }
        // " · 12:03" closes every line the notes writer makes. Only the last
        // " · " is looked at, and only a clock after it counts, so a dot in
        // the text itself is left alone.
        guard let dot = text.range(of: " · ", options: .backwards),
              let at = seconds(String(text[dot.upperBound...])) else {
            return (text, checked, nil, nil)
        }
        text = String(text[..<dot.lowerBound])
        // " — Ana" is only ever written on a to-do, before the time. The
        // writer softens any dash in the text itself, so the last one is the
        // owner's.
        var owner: String?
        if checked != nil, let dash = text.range(of: " — ", options: .backwards) {
            let name = text[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                owner = name
                text = String(text[..<dash.lowerBound])
            }
        }
        return (text, checked, owner, at)
    }

    /// The line `MeetingNotes.Stretch.sentence` writes, in its italics or
    /// without them. Any other wording is the owner's and stays a paragraph.
    private static func unwritten(_ line: String) -> MeetingNotes.Stretch? {
        var text = Substring(line)
        for mark in ["_", "*"] where text.count > 2 && text.hasPrefix(mark) && text.hasSuffix(mark) {
            text = text.dropFirst().dropLast()
            break
        }
        let lead = MeetingNotes.Stretch.lead, tail = MeetingNotes.Stretch.tail
        guard text.hasPrefix(lead), text.hasSuffix(tail) else { return nil }
        let times = text.dropFirst(lead.count).dropLast(tail.count).split(separator: "–")
        guard times.count == 2, let start = seconds(String(times[0])), let end = seconds(String(times[1])),
              start <= end else { return nil }
        return MeetingNotes.Stretch(start: start, end: end)
    }

    /// "4:05" or "1:02:09" as seconds, as `MeetingFiles.clock` writes them.
    static func seconds(_ clock: String) -> TimeInterval? {
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts[0].count <= 3,
              parts.dropFirst().allSatisfy({ $0.count == 2 }) else { return nil }
        var total = 0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part),
                  index == 0 || value < 60 else { return nil }
            total = total * 60 + value
        }
        return TimeInterval(total)
    }
}
