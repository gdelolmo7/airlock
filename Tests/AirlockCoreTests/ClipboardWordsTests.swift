import XCTest
@testable import AirlockCore

/// What the clipboard says about a search miss and a skipped copy.
final class ClipboardWordsTests: XCTestCase {

    func testASearchMissUnderAllSaysNothingAboutAFilter() {
        XCTAssertEqual(ClipboardFilter.all.searchMissMessage(query: "invoice"),
                       "Nothing matches \u{201C}invoice\u{201D}")
    }

    func testASearchMissUnderAFilterNamesTheFilter() {
        for filter in ClipboardFilter.allCases where filter != .all {
            let message = filter.searchMissMessage(query: " invoice ")
            XCTAssertTrue(message.contains(filter.label), message)
            XCTAssertTrue(message.contains("\u{201C}invoice\u{201D}"), "the query, trimmed: \(message)")
        }
    }

    /// The bug: Settings read "marked private (org.nspasteboard.ConcealedType)".
    func testNoSkipReasonShowsATypeIdentifierOrBundleID() {
        let reasons: [ClipboardSkipReason] = [
            .markedPrivate("org.nspasteboard.ConcealedType"),
            .ignoredType("com.agilebits.onepassword"),
            .ignoredApp("com.bitwarden.desktop"),
            .empty, .unsupported, .tooLarge(bytes: 61_400_000),
        ]
        for reason in reasons {
            let words = reason.words(appName: { _ in "Bitwarden" })
            for leak in ["org.", "com.", "nspasteboard", "agilebits"] {
                XCTAssertFalse(words.contains(leak), "\(reason) said \(words)")
            }
            XCTAssertFalse(words.isEmpty)
        }
    }

    func testAnIgnoredAppIsNamed() {
        let words = ClipboardSkipReason.ignoredApp("com.bitwarden.desktop")
            .words(appName: { _ in "Bitwarden" })
        XCTAssertTrue(words.contains("Bitwarden"), words)
    }

    /// Files are kept now, so "not text or an image" was wrong.
    func testUnsupportedMentionsFiles() {
        XCTAssertTrue(ClipboardSkipReason.unsupported.words(appName: { $0 }).contains("file"))
    }

    func testTheTooLargeNoticeSaysTheSizeAndThatTheClipboardStillHasIt() {
        let notice = ClipboardSkipReason.tooLargeNotice(bytes: 61_400_000)
        XCTAssertTrue(notice.contains(ClipboardLimits.describe(bytes: 61_400_000)), notice)
        XCTAssertTrue(notice.contains("still on the clipboard"), notice)
    }
}
