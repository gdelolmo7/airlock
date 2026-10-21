import AirlockCore
import AppKit
import XCTest
@testable import AirlockApp

/// Help, in the status item's menu: the one menu that is there whether or not
/// a window is open, so the only Help everybody can find.
@MainActor
final class HelpMenuTests: XCTestCase {
    func testHelpSitsRightAfterSetupGuide() throws {
        let menu = AppDelegate().makeStatusMenu()
        let titles = menu.items.map(\.title)
        let guide = try XCTUnwrap(titles.firstIndex(of: "Setup Guide…"))
        XCTAssertEqual(titles[guide + 1], "Help")
        XCTAssertNotNil(menu.items[guide + 1].submenu)
    }

    /// The website, the list of features, and a way to reach a person that
    /// works with or without a mail app. Every row answers to the delegate,
    /// or it would be drawn greyed out.
    func testHelpOffersTheSiteAndTheAddress() {
        let delegate = AppDelegate()
        let help = delegate.makeHelpMenu()
        let rows = help.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(rows.map(\.title), [
            "Airlock Website", "What Airlock Can Do",
            "Email hello@useairlock.app", "Copy Email Address",
        ])
        for row in rows {
            XCTAssertTrue(row.target === delegate, row.title)
            XCTAssertNotNil(row.action, row.title)
            XCTAssertTrue(delegate.responds(to: row.action), row.title)
            XCTAssertEqual(row.keyEquivalent, "", "\(row.title) claims a shortcut")
        }
    }

    /// Each call builds its own: one menu can hang under only one parent,
    /// and the menu bar and the status item each need one.
    func testEachMenuGetsItsOwnHelp() {
        let delegate = AppDelegate()
        XCTAssertFalse(delegate.makeHelpMenu() === delegate.makeHelpMenu())
    }
}

/// "Learn more" on the Settings pages: every page the website has about a
/// feature is one click from the Settings page that sets it up.
@MainActor
final class LearnMoreTests: XCTestCase {
    func testEveryFeaturePageIsOfferedFromTheSidebar() {
        let offered = SettingsPane.sidebarCases.flatMap(\.learnMore)
        XCTAssertEqual(Set(offered), Set(FeaturePage.allCases))
        XCTAssertEqual(offered.count, Set(offered).count, "one page offered from two places")
    }

    /// The site has no page about these, and a link to the home page would
    /// read as one about this page.
    func testPagesWithoutAFeaturePageShowNone() {
        for pane in [SettingsPane.general, .permissions, .license] {
            XCTAssertEqual(pane.learnMore, [], "\(pane)")
        }
    }
}
