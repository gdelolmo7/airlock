import XCTest
@testable import AirlockApp

/// Which side of the camera each tab sits on. The view draws whatever
/// `NotchTab.topBarSides` says, so this is where the layout is checked.
final class TopBarTabSidesTests: XCTestCase {
    /// Agents beside the gear on the right; every other tab in the strip on
    /// the left, in the order the registry gave them.
    func testAgentsSitsOnTheRightAndTheRestOnTheLeft() {
        let sides = NotchTab.topBarSides(NotchTab.allCases)
        XCTAssertEqual(sides.leading, [.home, .dashboard, .tray, .clipboard, .calls])
        XCTAssertEqual(sides.trailing, [.agents])
    }

    /// The strip still holds five at most, which is what fits beside the
    /// camera at the default width, now that Calls has a tab of its own.
    func testTheStripOnTheLeftNeverHoldsMoreThanFive() {
        XCTAssertLessThanOrEqual(NotchTab.topBarSides(NotchTab.allCases).leading.count, 5)
    }

    /// With the agents switched off the right has no tab at all, and with
    /// call notes off the strip is the one there was before Calls.
    func testATabNotOnShowIsOnNeitherSide() {
        let sides = NotchTab.topBarSides([.home, .dashboard, .tray, .clipboard])
        XCTAssertEqual(sides.leading, [.home, .dashboard, .tray, .clipboard])
        XCTAssertEqual(sides.trailing, [])

        let agentsOnly = NotchTab.topBarSides([.home, .agents])
        XCTAssertEqual(agentsOnly.leading, [.home])
        XCTAssertEqual(agentsOnly.trailing, [.agents])
    }

    /// The order the tabs cycle in, and the order they sit in from left to
    /// right: Calls after the Clipboard, Agents last.
    func testCallsComesAfterTheClipboardAndAgentsIsLast() {
        XCTAssertEqual(NotchTab.allCases, [.home, .dashboard, .tray, .clipboard, .calls, .agents])
        XCTAssertEqual(NotchTab.calls.symbol, "phone.fill")
        XCTAssertEqual(NotchTab.calls.label, "Calls")
    }
}
