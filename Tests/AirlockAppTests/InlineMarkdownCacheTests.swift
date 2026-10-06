import SwiftUI
import XCTest
@testable import AirlockApp

/// The cache must be invisible: same input, same output, and it must not grow
/// without bound over a long session of agent messages.
@MainActor
final class InlineMarkdownCacheTests: XCTestCase {

    func testCachedResultMatchesAFreshParse() {
        let source = "ran `swift build` and it **worked**"
        let first = InlineMarkdown.render(source, size: 11)
        let second = InlineMarkdown.render(source, size: 11)
        XCTAssertEqual(first, second)
        XCTAssertEqual(String(first.characters), "ran swift build and it worked")
    }

    /// Size is part of the key: the same text at two sizes is two results, and
    /// caching on text alone would silently render the wrong one.
    func testSizeIsPartOfTheKey() {
        let source = "`code`"
        let small = InlineMarkdown.render(source, size: 10)
        let large = InlineMarkdown.render(source, size: 16)
        let smallFont = small.runs.compactMap(\.font).first
        let largeFont = large.runs.compactMap(\.font).first
        XCTAssertNotNil(smallFont)
        XCTAssertNotEqual(smallFont, largeFont, "a code span must carry its own size")
    }

    /// Agent messages are unbounded over a session, so an unbounded cache is a
    /// leak. Push well past the cap and confirm the results are still right —
    /// eviction must not be able to return somebody else's string.
    func testStaysCorrectPastTheEvictionLimit() {
        for index in 0..<600 {
            let rendered = InlineMarkdown.render("message **\(index)**", size: 11)
            XCTAssertEqual(String(rendered.characters), "message \(index)")
        }
        // The very first entry is long evicted; re-rendering it must still be
        // correct rather than stale or absent.
        XCTAssertEqual(String(InlineMarkdown.render("message **0**", size: 11).characters),
                       "message 0")
    }

    func testPlainTextSurvivesUnchanged() {
        XCTAssertEqual(String(InlineMarkdown.render("no markup here", size: 11).characters),
                       "no markup here")
    }
}
