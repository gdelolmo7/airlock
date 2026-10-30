import XCTest
@testable import AirlockCore

/// Copied notes and transcripts paste formatted: the Markdown Airlock writes,
/// turned into HTML for Mail, Pages and Google Docs.
final class MarkdownCopyTests: XCTestCase {
    func testHeadingsListsToDosAndARule() {
        let page = """
        # Notes: weekly sync

        ## To-dos

        - [ ] Send the deck — Ana · 12:03
        - [x] Book the room · 12:10

        ## Key points

        - Price stays the same

        ---

        _Written on this Mac by Airlock._
        """
        XCTAssertEqual(MarkdownCopy.html(from: page), """
        <h1>Notes: weekly sync</h1>
        <h2>To-dos</h2>
        <ul><li>☐ Send the deck — Ana · 12:03</li><li>☑ Book the room · 12:10</li></ul>
        <h2>Key points</h2>
        <ul><li>Price stays the same</li></ul>
        <hr>
        <p><em>Written on this Mac by Airlock.</em></p>
        """)
    }

    /// A transcript's "who and when" line keeps its own line over what was said.
    func testALineBreakInAParagraphStays() {
        XCTAssertEqual(MarkdownCopy.html(from: "**Person 1** · 12:03\nHello there"),
                       "<p><strong>Person 1</strong> · 12:03<br>Hello there</p>")
    }

    func testInlineMarksAndHTMLAreEscaped() {
        XCTAssertEqual(MarkdownCopy.inline("Use `a<b` & **mind** the *gap*"),
                       "Use <code>a&lt;b</code> &amp; <strong>mind</strong> the <em>gap</em>")
    }

    /// A lone star or a snake_case name is text, not the start of italics.
    func testUnmatchedMarksStayText() {
        XCTAssertEqual(MarkdownCopy.inline("5 * 3 and my_file_name"), "5 * 3 and my_file_name")
    }

    /// What someone said goes through `escaped`, and comes out of the HTML
    /// exactly as they said it.
    func testEscapedWordsReadBackAsSaid() {
        let said = "# not a heading, *really* and a_b\n- nor a bullet"
        let markdown = MarkdownCopy.escaped(said)
        XCTAssertEqual(MarkdownCopy.html(from: markdown),
                       "<p># not a heading, *really* and a_b<br>- nor a bullet</p>")
    }

    func testThePageNamesItsCharacterSet() {
        XCTAssertTrue(MarkdownCopy.htmlPage(from: "Hi").contains(#"<meta charset="utf-8">"#))
    }
}
