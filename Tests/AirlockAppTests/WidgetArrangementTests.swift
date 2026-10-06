import SwiftUI
import XCTest
@testable import AirlockApp

/// The panel's layout used to be the array literal in `AppDelegate`.
///
/// These pin the two rules that let a user order exist without a migration
/// every time a widget is added: an unknown id keeps its registry position, and
/// a stale id cannot reorder anything around it.
@MainActor
final class WidgetArrangementTests: XCTestCase {
    private let registry = ["agents", "media", "sound", "calendar", "clipboard"]

    func testNoStoredOrderIsRegistryOrder() {
        XCTAssertEqual(WidgetArrangement.arranged(registry, stored: []), registry)
    }

    func testAFullStoredOrderIsHonouredExactly() {
        let stored = ["calendar", "media", "agents", "clipboard", "sound"]
        XCTAssertEqual(WidgetArrangement.arranged(registry, stored: stored), stored)
    }

    /// THE rule that avoids migrations. A widget the stored order has never
    /// heard of keeps the slot the registry gave it, rather than being appended
    /// to the bottom of somebody's panel.
    func testAnUnlistedWidgetKeepsItsRegistryPosition() {
        // The user has only ever reordered the first two.
        let stored = ["media", "agents"]
        let result = WidgetArrangement.arranged(registry, stored: stored)
        XCTAssertEqual(result, ["media", "agents", "sound", "calendar", "clipboard"])
    }

    /// A widget removed from the build must not leave a hole, and must not be
    /// able to shift anything around it from beyond the grave.
    func testStoredIdsThatNoLongerExistAreIgnored() {
        let stored = ["ghost", "calendar", "media", "vanished"]
        let result = WidgetArrangement.arranged(registry, stored: stored)
        // The two live ids fill the two slots they already occupied — media's
        // and calendar's — in the order the user asked for. `agents`, `sound`
        // and `clipboard` were never reordered, so they keep their own slots
        // and the dead ids move nothing at all.
        XCTAssertEqual(result, ["agents", "calendar", "sound", "media", "clipboard"])
    }

    func testTheResultIsAlwaysAPermutationOfTheRegistry() {
        for stored in [[], ["sound"], ["clipboard", "agents"], registry.reversed()] {
            let result = WidgetArrangement.arranged(registry, stored: Array(stored))
            XCTAssertEqual(Set(result), Set(registry), "lost or invented a widget")
            XCTAssertEqual(result.count, registry.count, "duplicated a widget")
        }
    }

    // MARK: - What may not move

    /// A gate that could be dragged below the fold is a gate that can be lost —
    /// the same reason `demandsAttention` overrides the enabled switch.
    func testAWidgetDemandingAttentionCannotBeMoved() {
        XCTAssertFalse(WidgetArrangement.isMovable(PinnedStub(demandsAttention: true)))
    }

    /// Gutter widgets are chrome on every tab and have no stack slot, so there
    /// is no position to give them.
    func testGutterWidgetsCannotBeMoved() {
        XCTAssertFalse(WidgetArrangement.isMovable(PinnedStub(placement: .gutter)))
    }

    func testAnOrdinaryWidgetCanBeMoved() {
        XCTAssertTrue(WidgetArrangement.isMovable(PinnedStub()))
    }
}

private struct PinnedStub: NotchWidget {
    var demandsAttention: Bool = false
    var placement: WidgetPlacement = .stack

    var id: String { "stub" }
    var displayName: String { "Stub" }
    var tier: WidgetTier { .ambient }
    var isToggleable: Bool { true }
    var isEnabled: Bool {
        get { true }
        nonmutating set { }
    }

    func panelSection() -> AnyView? { nil }
}
