import AppKit
import XCTest
@testable import AirlockApp

/// "Window Layouts" in the menu bar's menu: a submenu with every layout,
/// filled each time it opens.
@MainActor
final class WindowLayoutsMenuTests: XCTestCase {
    /// Right above Settings, so the call rows keep their place after it.
    func testItSitsRightAboveSettings() throws {
        let titles = AppDelegate().makeStatusMenu().items.map(\.title)
        let layouts = try XCTUnwrap(titles.firstIndex(of: "Window Layouts"))
        XCTAssertEqual(titles[layouts + 1], "Settings…")
    }

    /// Every layout, Centre and Put it back once each, then the way to Settings.
    func testTheSubmenuListsEveryLayout() throws {
        // Kept: the submenu's filler belongs to the app delegate.
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()
        let row = try XCTUnwrap(menu.items.first { $0.tag == AppDelegate.windowLayoutsMenuTag })
        let submenu = try XCTUnwrap(row.submenu)
        submenu.delegate?.menuNeedsUpdate?(submenu)
        let titles = submenu.items.filter { !$0.isSeparatorItem }.map(\.title)
        for action in WindowLayoutAction.allCases {
            XCTAssertEqual(titles.filter { $0 == action.name }.count, 1, action.name)
        }
        XCTAssertEqual(titles.last, "Window Layout Settings…")
        withExtendedLifetime(delegate) {}
    }
}
