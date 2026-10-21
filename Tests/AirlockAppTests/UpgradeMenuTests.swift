import AppKit
import XCTest
@testable import AirlockApp

/// "Upgrade to Plus…" in the menu bar's menu: the one way to Plus that is
/// always there on Free, and not there on Plus or Pro.
@MainActor
final class UpgradeMenuTests: XCTestCase {
    /// Under the call rows, which keep their place right after "Settings…":
    /// with call notes off they are hidden, and it is the row after Settings.
    func testItComesRightAfterTheCallRows() throws {
        let titles = AppDelegate().makeStatusMenu().items.map(\.title)
        let settings = try XCTUnwrap(titles.firstIndex(of: "Settings…"))
        let upgrade = try XCTUnwrap(titles.firstIndex(of: "Upgrade to Plus…"))
        XCTAssertEqual(Array(titles[settings + 1 ..< upgrade]),
                       ["Call Notes…", "Take Notes", "Add Recording…"])
    }

    /// Shown on Free, hidden on any paid plan, settled each time the menu
    /// opens. Before launch has made the licence there is no plan to tell,
    /// so there is no row.
    func testItShowsOnlyOnFree() throws {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()
        let item = try XCTUnwrap(menu.items.first { $0.tag == AppDelegate.upgradeMenuTag })

        AppDelegate.showUpgrade(in: menu, onFree: true)
        XCTAssertFalse(item.isHidden)
        AppDelegate.showUpgrade(in: menu, onFree: false)
        XCTAssertTrue(item.isHidden)

        AppDelegate.showUpgrade(in: menu, onFree: true)
        delegate.menuNeedsUpdate(menu)
        XCTAssertTrue(item.isHidden)
    }

    /// Its tag is its own: nothing else in the menu answers to it.
    func testItsTagIsItsOwn() {
        let menu = AppDelegate().makeStatusMenu()
        XCTAssertEqual(menu.items.filter { $0.tag == AppDelegate.upgradeMenuTag }.count, 1)
    }
}
