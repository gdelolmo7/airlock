import XCTest
@testable import AirlockApp

/// The rail's order and on/off set.
///
/// The ordering rule itself is `WidgetArrangement.arranged`, already tested —
/// what is new here is that the rail reuses it rather than growing a second
/// copy, and that the two rules which make a migration unnecessary survive that
/// reuse: an unknown id keeps its declaration slot, and a stale one is dropped.
@MainActor
final class SystemControlsArrangementTests: XCTestCase {

    private let all = SystemControlsModel.Control.allCases.map(\.rawValue)

    /// The reason removing `lock` did not scramble anybody's rail, and the reason
    /// adding a control will not either: an id the stored order never heard of
    /// keeps the slot the enum gives it instead of being appended.
    func testAnUnknownControlKeepsItsDeclarationSlot() {
        let stored = ["dark", "wifi"]                       // two of six, reordered
        let result = WidgetArrangement.arranged(all, stored: stored)
        XCTAssertEqual(Set(result), Set(all), "nothing may be dropped or duplicated")
        XCTAssertEqual(result.count, all.count)
        // The two stored ids occupy the slots wifi and dark had, in stored order.
        let wifiSlot = all.firstIndex(of: "wifi")!
        let darkSlot = all.firstIndex(of: "dark")!
        XCTAssertEqual(result[wifiSlot], "dark")
        XCTAssertEqual(result[darkSlot], "wifi")
    }

    /// A control removed from the build must not leave a hole or shift its
    /// neighbours — `lock` was removed from this enum one commit ago and is
    /// still in some users' stored order.
    func testAStaleStoredIdIsIgnored() {
        let result = WidgetArrangement.arranged(all, stored: ["lock", "dark", "wifi"])
        XCTAssertEqual(Set(result), Set(all))
        XCTAssertFalse(result.contains("lock"))
    }

    func testAnEmptyStoredOrderIsDeclarationOrder() {
        XCTAssertEqual(WidgetArrangement.arranged(all, stored: []), all)
    }

    /// Switching off is a set membership, so the order survives it — a control
    /// that comes back returns to where it was rather than to the end.
    func testSwitchingOffAndBackKeepsThePosition() {
        let model = SystemControlsModel()
        let before = model.shown
        guard let victim = before.dropFirst().first else { return XCTFail("need two controls") }
        model.setShown(victim, false)
        XCTAssertFalse(model.shown.contains(victim))
        XCTAssertTrue(model.hidden.contains(victim))
        model.setShown(victim, true)
        XCTAssertEqual(model.shown, before, "the control came back somewhere else")
    }

    /// Shown and hidden partition the whole set: a control cannot be in neither,
    /// which would be a button nobody can find or restore.
    func testShownAndHiddenPartitionEveryControl() {
        let model = SystemControlsModel()
        for control in SystemControlsModel.Control.allCases where control != .wifi {
            model.setShown(control, false)
        }
        XCTAssertEqual(Set(model.shown + model.hidden),
                       Set(SystemControlsModel.Control.allCases))
        XCTAssertTrue(Set(model.shown).isDisjoint(with: Set(model.hidden)))
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "systemControls.order")
        UserDefaults.standard.removeObject(forKey: "systemControls.off")
        super.tearDown()
    }
}
