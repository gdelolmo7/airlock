import XCTest
import AppKit
@testable import AirlockApp
@testable import AirlockCore

/// The destinations rail's routing and budget.
///
/// This is the only part of the feature `swift test` can see: the drop itself
/// runs through a real NSDraggingSession and an armed borderless window, which
/// no test process has. So the geometry that decides WHICH card a release lands
/// on is pure and lives here — a drop resolving to Trash when it was aimed at
/// AirDrop is the failure that matters, and it is silent.
@MainActor
final class TrayRailTests: XCTestCase {

    override func tearDown() {
        Theme.setTextScale(1)
        super.tearDown()
    }

    private let size = CGSize(width: TrayRailMetrics.width, height: 200)

    private func hit(_ y: CGFloat, hasDestinations: Bool = true) -> TrayRailDestination? {
        TrayRailLayout.destination(atRailLocal: CGPoint(x: 50, y: y),
                                   size: size, hasDestinations: hasDestinations)
    }

    // MARK: - Routing

    /// Laid out from the bottom: Trash last, Downloads above it, AirDrop takes
    /// what is left. The view stacks them the same way and the two MUST agree.
    func testTheThreeBandsAreWhereTheViewDrawsThem() {
        XCTAssertEqual(hit(size.height - 1), .trash)
        XCTAssertEqual(hit(size.height - TrayRailMetrics.rowHeight + 1), .trash)

        let downloadsMid = size.height - TrayRailMetrics.rowHeight
            - TrayRailMetrics.spacing - TrayRailMetrics.rowHeight / 2
        XCTAssertEqual(hit(downloadsMid), .downloads)

        XCTAssertEqual(hit(10), .airDrop)
    }

    /// A point in a gap is not a vote for the nearer card. Falling through to the
    /// shelf is harmless; guessing between Downloads and Trash is not.
    func testGapsBetweenCardsRouteNowhere() {
        let gap = size.height - TrayRailMetrics.rowHeight - TrayRailMetrics.spacing / 2
        XCTAssertNil(hit(gap))
    }

    /// An empty shelf has nothing to send anywhere, so the rail is the AirDrop
    /// box it has always been — and the whole column is that one target, which is
    /// what stops a drop finding a Trash card that is not drawn.
    func testAnEmptyShelfIsAllAirDrop() {
        XCTAssertEqual(hit(size.height - 1, hasDestinations: false), .airDrop)
        XCTAssertEqual(hit(10, hasDestinations: false), .airDrop)
    }

    func testPointsOutsideTheRailRouteNowhere() {
        XCTAssertNil(TrayRailLayout.destination(
            atRailLocal: CGPoint(x: -1, y: 10), size: size, hasDestinations: true))
        XCTAssertNil(TrayRailLayout.destination(
            atRailLocal: CGPoint(x: 50, y: size.height + 1), size: size, hasDestinations: true))
    }

    /// The panel-space entry point is the rail-local one with the origin taken
    /// off. If these disagree, an inbound drop lands on a different card than the
    /// one that lit up.
    func testPanelSpaceAgreesWithRailLocal() {
        let rail = CGRect(x: 300, y: 80, width: TrayRailMetrics.width, height: 200)
        for y in stride(from: 2.0, to: 198.0, by: 7) {
            XCTAssertEqual(
                TrayRailLayout.destination(atPanelPoint: CGPoint(x: 300 + 50, y: 80 + y),
                                           rail: rail, hasDestinations: true),
                hit(y),
                "disagreement at rail-local y=\(y)")
        }
    }

    // MARK: - Safety

    /// Only AirDrop may be reached by a drag that came from outside the app.
    /// Downloads and Trash act on files the shelf owns, so their unreachability
    /// is structural rather than a guard that could be got wrong.
    func testOnlyAirDropAcceptsInboundDrags() {
        XCTAssertTrue(TrayRailDestination.airDrop.acceptsInbound)
        XCTAssertFalse(TrayRailDestination.downloads.acceptsInbound)
        XCTAssertFalse(TrayRailDestination.trash.acceptsInbound)
    }

    /// Ownership is the gate that holds even if reachability does not. A shelf
    /// path passes; anything else is refused, including a file in a SUBFOLDER of
    /// the tray, which is not a shelf item.
    func testOwnershipAcceptsOnlyDirectChildrenOfTheTray() {
        let tray = URL(fileURLWithPath: "/Users/x/Airlock/tray")
        XCTAssertTrue(TrayShelfOwnership.owns(tray.appendingPathComponent("a.pdf"), tray: tray))
        XCTAssertFalse(TrayShelfOwnership.owns(
            URL(fileURLWithPath: "/Users/x/Desktop/taxes.pdf"), tray: tray))
        XCTAssertFalse(TrayShelfOwnership.owns(
            tray.appendingPathComponent("sub/a.pdf"), tray: tray))
    }

    func testOwnershipFilterDropsEverythingForeign() {
        let tray = URL(fileURLWithPath: "/Users/x/Airlock/tray")
        let mixed = [tray.appendingPathComponent("keep.png"),
                     URL(fileURLWithPath: "/Users/x/Documents/nope.png")]
        XCTAssertEqual(TrayShelfOwnership.filter(mixed, tray: tray), [mixed[0]])
    }

    // MARK: - The budget

    /// "Downloads" is 56pt at scale 1.0 and 75 at 1.4 against a 67pt budget, so
    /// the icon-only fallback is required rather than defensive. This is what
    /// says so if a label is ever renamed.
    func testTheLongestLabelOverflowsAtMaximumTextScale() {
        Theme.setTextScale(1)
        XCTAssertLessThan(TrayRailMetrics.labelWidth("Downloads"), TrayRailMetrics.labelBudget)
        Theme.setTextScale(Theme.maxTextScale)
        XCTAssertGreaterThan(TrayRailMetrics.labelWidth("Downloads"), TrayRailMetrics.labelBudget,
                             "if this now fits, the ViewThatFits ladder is untested")
    }

    /// The shelf's floor has to cover the rail, or the two lower cards draw
    /// outside their own rounded rect on a one-row shelf.
    func testTheShelfFloorCoversTheRailAtBothTextScales() {
        for scale in [1.0, Theme.maxTextScale] {
            Theme.setTextScale(scale)
            XCTAssertEqual(TrayRailMetrics.shelfContentMinimum + 16,
                           TrayRailMetrics.intrinsicHeight, accuracy: 0.01)
            XCTAssertGreaterThan(TrayRailMetrics.intrinsicHeight,
                                 TrayRailMetrics.rowHeight * 2 + TrayRailMetrics.spacing * 2)
        }
    }

    /// The rail keeps the 104pt the AirDrop box had, so the shelf beside it is
    /// unchanged at the 460pt floor — this is not a width change.
    func testTheRailDidNotGetWider() {
        XCTAssertEqual(TrayRailMetrics.width, 104)
        // 440 content at the floor, minus rail and gap, still leaves a usable shelf.
        XCTAssertGreaterThan(440 - TrayRailMetrics.width - 8, 300)
    }
}
