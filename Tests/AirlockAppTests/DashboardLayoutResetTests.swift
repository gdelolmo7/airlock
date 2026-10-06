import XCTest
@testable import AirlockApp

/// The Dashboard's cards were laid out on purpose on 2026-10-01, and a layout
/// stored while they lived on Home would have hidden that from anyone who had
/// ever moved a card. These pin the one-time reset: it forgets those three
/// cards and nothing else, and it runs once.
@MainActor
final class DashboardLayoutResetTests: XCTestCase {
    func testForgetsOnlyTheDashboardCards() {
        // The owner's own stored layout on the day.
        let order = ["agents", "repository", "calendar", "media", "systemControls", "keymap",
                     "sound", "battery", "system", "tray", "clipboard"]
        let columns = ["keymap": "full", "system": "leading", "systemControls": "full"]

        let reset = WidgetArrangement.resetDashboard(order: order, columns: columns)

        XCTAssertEqual(reset.order, ["agents", "repository", "media", "systemControls", "keymap",
                                     "battery", "tray", "clipboard"])
        XCTAssertEqual(reset.columns, ["keymap": "full", "systemControls": "full"])
    }

    /// With their stored places gone, the three take their registry slots —
    /// calendar, then sound, then system — which is what puts Sound above
    /// This Mac in the trailing column.
    func testTheCardsFallBackToRegistryOrder() {
        let registry = ["agents", "calendar", "media", "sound", "system", "clipboard"]
        let stored = WidgetArrangement.resetDashboard(
            order: ["media", "system", "agents", "sound", "calendar", "clipboard"], columns: [:]).order
        XCTAssertEqual(WidgetArrangement.arranged(registry, stored: stored),
                       ["media", "calendar", "agents", "sound", "system", "clipboard"])
    }

    func testRunsOnceAndLeavesLaterMovesAlone() throws {
        let suite = "DashboardLayoutResetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(["system": "leading"], forKey: "widget.column")
        WidgetArrangement.applyDashboardLayoutOnce(defaults: defaults)
        XCTAssertEqual(defaults.dictionary(forKey: "widget.column") as? [String: String], [:])

        // Moved again by hand afterwards: the reset must not take it back.
        defaults.set(["system": "leading"], forKey: "widget.column")
        WidgetArrangement.applyDashboardLayoutOnce(defaults: defaults)
        XCTAssertEqual(defaults.dictionary(forKey: "widget.column") as? [String: String], ["system": "leading"])
    }

    /// A fresh install has nothing stored, and the reset must not invent an
    /// empty layout where there was none.
    func testWritesNothingWhereNothingWasStored() throws {
        let suite = "DashboardLayoutResetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        WidgetArrangement.applyDashboardLayoutOnce(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "widget.order"))
        XCTAssertNil(defaults.object(forKey: "widget.column"))
    }

    /// The second move of the day: Sound to Home beside the controls. The
    /// owner's stored `systemControls=full` has to go or the rail stays across
    /// the whole tab; `keymap=full` is theirs and stays.
    func testHomeSoundMoveForgetsTheControlsColumnOnly() throws {
        let suite = "DashboardLayoutResetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(["keymap": "full", "systemControls": "full"], forKey: "widget.column")
        WidgetArrangement.applyHomeSoundLayoutOnce(defaults: defaults)
        XCTAssertEqual(defaults.dictionary(forKey: "widget.column") as? [String: String], ["keymap": "full"])

        defaults.set(["keymap": "full", "systemControls": "full"], forKey: "widget.column")
        WidgetArrangement.applyHomeSoundLayoutOnce(defaults: defaults)
        XCTAssertEqual(defaults.dictionary(forKey: "widget.column") as? [String: String],
                       ["keymap": "full", "systemControls": "full"], "runs once")
    }

    func testLevelBarGoesWhereItIsPressed() {
        XCTAssertEqual(LevelBar.level(at: 50, width: 200), 0.25)
        XCTAssertEqual(LevelBar.level(at: -10, width: 200), 0)
        XCTAssertEqual(LevelBar.level(at: 260, width: 200), 1)
        XCTAssertNil(LevelBar.level(at: 10, width: 0))
    }
}
