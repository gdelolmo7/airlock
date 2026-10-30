import AirlockCore
import AppKit
import XCTest
@testable import AirlockApp

/// Copy on a call's notes or transcript puts Markdown on the clipboard as
/// text, with HTML and RTF beside it so it pastes formatted.
@MainActor
final class CallCopyFormattedTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    func testMarkdownGoesOnAsTextHTMLAndRTF() throws {
        let markdown = "## To-dos\n\n- [ ] Send the deck\n\n**Ana** said hi"
        AirlockCopy.write(markdown, formatted: .init(markdown: markdown), to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), markdown)
        let html = try XCTUnwrap(pasteboard.string(forType: .html))
        XCTAssertTrue(html.contains("<h2>To-dos</h2>"))
        XCTAssertTrue(html.contains("<strong>Ana</strong>"))
        let rtf = try XCTUnwrap(pasteboard.data(forType: .rtf))
        let read = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: nil)
        XCTAssertTrue(read.string.contains("☐ Send the deck"))
        XCTAssertFalse(read.string.contains("**"))
    }

    func testAPlainCopyCarriesNoFormatting() {
        AirlockCopy.write("just text", formatted: nil, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "just text")
        XCTAssertNil(pasteboard.string(forType: .html))
    }

    func testTheTranscriptIsMarkdownWithWhoInBold() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        let record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                                   endedAt: start.addingTimeInterval(600),
                                   segments: [MeetingSegment(speaker: .them, start: 1, end: 4, text: "It costs *5*")],
                                   jots: [MeetingJot(at: 30, text: "check price")],
                                   pauses: [MeetingPause(start: 60, end: 120)])

        let markdown = CallNotesLibrary.markdownTranscript(of: record, calendar: calendar)
        let blocks = markdown.components(separatedBy: "\n\n")

        XCTAssertEqual(blocks.count, 3)
        XCTAssertTrue(blocks[0].hasPrefix("**"))
        XCTAssertTrue(blocks[0].hasSuffix("\nIt costs \\*5\\*"))
        XCTAssertTrue(blocks[1].hasPrefix("**Your note** · "))
        XCTAssertTrue(blocks[2].hasPrefix("_") && blocks[2].hasSuffix("_"))
    }
}
