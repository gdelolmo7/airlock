import XCTest
@testable import AirlockCore

/// The "Learn more" links and the Help menu.
///
/// A wrong link here fails quietly: the click works, the browser opens, and
/// the person lands on the website's 404 instead of the page about the thing
/// they were looking at. Two ways to get there, which these tests close:
///
/// 1. **A guessed page name.** "clipboard" reads as right and is a 404; the
///    page is `clipboard-history`. The list below is the website's `features`
///    folder as published on 2026-10-19, each one checked live.
/// 2. **The file's name instead of the address.** The site serves its pages
///    without `.html`, and `/features/` alone has no page at all.
///
/// What these cannot catch is the website renaming a page later. That has to
/// be changed here by whoever renames it.
final class FeaturePageTests: XCTestCase {
    private let published = [
        "call-notes", "clipboard-history", "coding-agents", "dictation", "drop-shelf",
        "keep-awake", "media-and-sound", "this-mac", "today",
    ]

    func testOnePagePerPublishedFeature() {
        XCTAssertEqual(FeaturePage.allCases.map(\.rawValue).sorted(), published)
    }

    func testEveryLinkIsTheSiteAddressOfItsPage() {
        for page in FeaturePage.allCases {
            let url = page.url
            XCTAssertEqual(url.scheme, "https", "\(page)")
            XCTAssertEqual(url.host, "useairlock.app", "\(page)")
            XCTAssertEqual(url.path, "/features/\(page.rawValue)", "\(page)")
            XCTAssertNil(url.query, "\(page)")
            XCTAssertFalse(url.absoluteString.hasSuffix(".html"), "\(page)")
        }
    }

    /// A menu offering several must not offer two that read the same.
    func testTitlesAreDistinctAndPlain() {
        let titles = FeaturePage.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        for title in titles {
            XCTAssertFalse(title.isEmpty)
            XCTAssertEqual(title.first.map { String($0) }, title.first.map { String($0).uppercased() }, title)
        }
    }

    func testHelpGoesToTheSiteAndToAPerson() {
        XCTAssertEqual(HelpLinks.website.absoluteString, "https://useairlock.app/")
        // The home page's "What it does" tiles; there is no page at /features/.
        XCTAssertEqual(HelpLinks.allFeatures.host, "useairlock.app")
        XCTAssertEqual(HelpLinks.allFeatures.path, "/")
        XCTAssertEqual(HelpLinks.allFeatures.fragment, "features")
        XCTAssertEqual(HelpLinks.emailURL.scheme, "mailto")
        XCTAssertEqual(HelpLinks.emailURL.absoluteString, "mailto:" + HelpLinks.email)
        XCTAssertEqual(HelpLinks.email, "hello@useairlock.app")
    }
}
