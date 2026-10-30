import Foundation

/// A call's notes or transcript as Markdown made ready for the clipboard:
/// the same text as HTML, so it pastes formatted into Mail, Pages and Google
/// Docs, while the plain text stays Markdown for editors that want that.
///
/// Only the Markdown Airlock writes is understood: headings, bullets, to-dos,
/// a rule, paragraphs, and bold, italics and code inside a line. Anything else
/// is kept as text, never dropped.
public enum MarkdownCopy {
    /// `markdown` as an HTML fragment. A single line break inside a paragraph
    /// stays a line break, as in a transcript's "who and when" line over what
    /// they said.
    public static func html(from markdown: String) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        var list: [String] = []
        func flushParagraph() {
            if !paragraph.isEmpty { out.append("<p>" + paragraph.map(inline).joined(separator: "<br>") + "</p>") }
            paragraph = []
        }
        func flushList() {
            if !list.isEmpty { out.append("<ul>" + list.joined() + "</ul>") }
            list = []
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                flushList()
            } else if let (level, text) = heading(line) {
                flushParagraph()
                flushList()
                out.append("<h\(level)>\(inline(text))</h\(level)>")
            } else if line == "---" || line == "***" {
                flushParagraph()
                flushList()
                out.append("<hr>")
            } else if let item = item(line) {
                flushParagraph()
                list.append("<li>\(item)</li>")
            } else {
                flushList()
                paragraph.append(line)
            }
        }
        flushParagraph()
        flushList()
        return out.joined(separator: "\n")
    }

    /// `html(from:)` as a whole page, with a plain system font so it does not
    /// arrive in Times where the paste keeps the source's styles.
    public static func htmlPage(from markdown: String) -> String {
        """
        <html><head><meta charset="utf-8"><style>\
        body{font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px}\
        </style></head><body>
        \(html(from: markdown))
        </body></html>
        """
    }

    /// `text` with the marks that would change its meaning in Markdown
    /// escaped, for words that are someone's, not Airlock's: what was said.
    public static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\*_`".contains(character) { out.append("\\") }
            out.append(character)
        }
        // A line starting like a heading or a bullet would read as one.
        return out.components(separatedBy: "\n").map { line in
            let opensABlock = line.hasPrefix("#") || line.hasPrefix("- ") || line.hasPrefix("+ ")
                || line.trimmingCharacters(in: .whitespaces) == "---"
            return opensABlock ? "\\" + line : line
        }.joined(separator: "\n")
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    /// A bullet's contents, with a box in front for a to-do.
    private static func item(_ line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        let text = String(line.dropFirst(2))
        if text.hasPrefix("[ ] ") { return "☐ " + inline(String(text.dropFirst(4))) }
        if text.lowercased().hasPrefix("[x] ") { return "☑ " + inline(String(text.dropFirst(4))) }
        return inline(text)
    }

    /// One line's text, escaped for HTML, with its bold, italics and code.
    static func inline(_ text: String) -> String {
        let characters = Array(text)
        var out = ""
        var index = 0
        var open: Set<String> = []
        /// Where `mark` closes later on this line, so a lone star or
        /// underscore stays a character.
        func closes(_ mark: String, after start: Int) -> Bool {
            let marks = Array(mark)
            var at = start
            while at + marks.count <= characters.count {
                if characters[at] == "\\" { at += 2; continue }
                if Array(characters[at..<at + marks.count]) == marks { return true }
                at += 1
            }
            return false
        }
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                out += escape(characters[index + 1])
                index += 2
                continue
            }
            if character == "`", let end = characters[(index + 1)...].firstIndex(of: "`") {
                out += "<code>" + characters[(index + 1)..<end].map(escape).joined() + "</code>"
                index = end + 1
                continue
            }
            let double = index + 1 < characters.count && characters[index + 1] == character
            if character == "*" || character == "_" {
                let mark = double ? String([character, character]) : String(character)
                let tag = double ? "strong" : "em"
                if open.contains(mark) {
                    out += "</\(tag)>"
                    open.remove(mark)
                    index += mark.count
                    continue
                }
                // An underscore inside a word (snake_case) is not a mark.
                let wordBefore = index > 0 && (characters[index - 1].isLetter || characters[index - 1].isNumber)
                if !(character == "_" && wordBefore), closes(mark, after: index + mark.count) {
                    out += "<\(tag)>"
                    open.insert(mark)
                    index += mark.count
                    continue
                }
            }
            out += escape(character)
            index += 1
        }
        return out
    }

    private static func escape(_ character: Character) -> String {
        switch character {
        case "&": "&amp;"
        case "<": "&lt;"
        case ">": "&gt;"
        case "\"": "&quot;"
        default: String(character)
        }
    }
}
