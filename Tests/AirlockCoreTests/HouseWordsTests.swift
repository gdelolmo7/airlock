import XCTest

/// Card B1: the words in `docs/how-airlock-talks.md` stay out of anything a
/// person can read.
///
/// A scan of the source, like `SendableExemptionTests`, because the rule is
/// about what we write, and a sentence is written once and shown from many
/// places. It reads only string literals that sit where a person will see
/// them — inside `Text(`, `Label(`, `Button(`, a problem card, an alert, or a
/// property whose name says it is shown (`…Error`, `…Note`, `failure`…).
/// Interpolations are stripped first, so `\(tray.items.count)` is code, not
/// the word "tray"; a raw `localizedDescription` interpolated into one of
/// those sentences is caught on its own, before that.
///
/// It misses sentences built far from where they are drawn (a `return` in a
/// helper). It is a fence, not a proof; `docs/b1-before-after.md` is the
/// read-through.
final class HouseWordsTests: XCTestCase {
    /// Whole words, case-insensitive. Each maps to what to say instead, so the
    /// failure tells the next person the fix rather than the rule.
    static let banned: [(pattern: String, say: String)] = [
        ("island", "the notch"),
        ("tray", "the Shelf"),
        ("license", "licence (British spelling, like the website)"),
        ("token", "licence / licence key"),
        ("hooks?", "connect Claude Code / Codex"),
        ("gates?", "request"),
        ("status line", "Claude usage"),
        ("api key", "access key"),
        ("keep-awake", "keep awake"),
        ("wired? (it )?up", "connect"),
        ("binary", "say what is missing in plain words"),
        ("config", "settings file"),
        ("json", "say what it is for, not its format"),
    ]

    /// Where a literal is a sentence on screen.
    static let shownAt = [
        "Text(", "Label(", "Button(", "Section(", "Toggle(", "LabeledContent(",
        ".help(", "ProblemCard(", "PaneReference(", "messageText", "informativeText",
        "addButton(withTitle:", ".accessibilityLabel(", ".accessibilityHint(",
    ]

    /// `name = "…"` where the name says the value is shown.
    static let shownProperty = try! NSRegularExpression(
        pattern: #"\b\w*(Error|Note|Message|failure|Rejection|notice)\s*=\s*""#)

    func testNoBannedWordsInWhatAPersonReads() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AirlockCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/AirlockApp")

        let words = try Self.banned.map {
            (try NSRegularExpression(pattern: #"\b"# + $0.pattern + #"\b"#, options: .caseInsensitive), $0.say)
        }
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)

        var scanned = 0
        var hits: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            // The vendored kit is somebody else's words; the state gallery's
            // row titles are for us, and name the old states on purpose.
            guard !url.path.contains("/DynamicNotchKit/"),
                  !url.path.contains("/StateGallery/") else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(raw)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                let range = NSRange(line.startIndex..., in: line)
                let shown = Self.shownAt.contains { line.contains($0) }
                    || Self.shownProperty.firstMatch(in: line, range: range) != nil
                guard shown else { continue }

                for match in literal.matches(in: line, range: range) {
                    guard let r = Range(match.range(at: 1), in: line) else { continue }
                    let body = String(line[r])
                    scanned += 1
                    let place = "\(url.lastPathComponent):\(number + 1)"
                    if body.contains("localizedDescription") {
                        hits.append("\(place): macOS's own error text on screen — log it, show PlainProblem")
                    }
                    let prose = Self.strippingInterpolations(body)
                    let proseRange = NSRange(prose.startIndex..., in: prose)
                    for (word, say) in words where word.firstMatch(in: prose, range: proseRange) != nil {
                        hits.append("\(place): \"\(prose)\" — say \(say)")
                    }
                }
            }
        }

        XCTAssertGreaterThan(scanned, 200, "the scanner found almost nothing — it has stopped working")
        XCTAssertTrue(hits.isEmpty, """
            Words from the banned list in text a person reads \
            (docs/how-airlock-talks.md):
            \(hits.joined(separator: "\n"))
            """)
    }

    /// `"\(a.b) items"` → `" items"`, nesting included, so code inside an
    /// interpolation is never read as a word on screen.
    static func strippingInterpolations(_ s: String) -> String {
        var out = ""
        var depth = 0
        var chars = Array(s)[...]
        while let c = chars.popFirst() {
            if depth == 0, c == "\\", chars.first == "(" {
                chars.removeFirst()
                depth = 1
                continue
            }
            if depth > 0 {
                if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
                continue
            }
            out.append(c)
        }
        return out
    }

    func testInterpolationsAreNotWords() {
        XCTAssertEqual(Self.strippingInterpolations(#"\(tray.items.count) items"#), " items")
        XCTAssertEqual(Self.strippingInterpolations(#"a \(f(g(x))) b"#), "a  b")
    }
}
