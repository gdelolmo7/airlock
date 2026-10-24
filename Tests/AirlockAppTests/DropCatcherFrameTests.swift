import AppKit
import XCTest
import AirlockCore
import DynamicNotchKit
@testable import AirlockApp

/// The one piece of coordinate maths that arming the catcher for a drag OFF the
/// shelf added — and the flip it depends on has already been got wrong once, in
/// the other direction, which is why `AirDropZoneKey` publishes through a
/// preference at all.
///
/// It matters because both failure modes are silent. Too far down and the box
/// stops receiving anything; too big and this window is back over the panel,
/// swallowing every drop meant for another app — which is the bug being fixed.
@MainActor
final class DropCatcherFrameTests: XCTestCase {
    private var screen: NSScreen {
        get throws { try XCTUnwrap(NSScreen.main) }
    }

    /// The published zone is in the panel's own top-left coordinates. AppKit
    /// measures from the screen's bottom-left, so the box's TOP edge sits
    /// `zone.minY` below the panel's top.
    func testTheArmedFrameIsTheBoxAndNothingElse() throws {
        let screen = try screen
        let panel = NotchDropCatcher.panelFrame(on: screen)
        let zone = CGRect(x: 300, y: 120, width: 104, height: 90)

        let armed = NotchDropCatcher.railFrame(zone, on: screen)

        XCTAssertEqual(armed.size, zone.size, "the box's size, not a rectangle around it")
        XCTAssertEqual(armed.minX, panel.minX + 300, accuracy: 0.01)
        XCTAssertEqual(armed.maxY, panel.maxY - 120, accuracy: 0.01,
                       "top edge measured down from the panel's top")
    }

    /// The whole point: whatever the box's frame, this window must not be the
    /// destination for anything outside it.
    func testTheArmedFrameNeverCoversThePanel() throws {
        let screen = try screen
        let panel = NotchDropCatcher.panelFrame(on: screen)

        for zone in [CGRect(x: 0, y: 0, width: 104, height: 60),
                     CGRect(x: 300, y: 200, width: 104, height: 120),
                     CGRect(x: panel.width - 104, y: 400, width: 104, height: 80)] {
            let armed = NotchDropCatcher.railFrame(zone, on: screen)
            XCTAssertTrue(panel.contains(armed), "\(zone) escaped the panel as \(armed)")
            XCTAssertLessThan(armed.width, panel.width / 2,
                              "anything near panel-width is the bug this replaced")
        }
    }

    // MARK: - At rest

    /// Over a camera housing: exactly the housing, as before monitors took
    /// drops. The cutout is the gap between the two auxiliary areas.
    func testAtRestOverANotchItIsTheHousing() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let physical = NotchMetrics(screenFrame: screen,
                                    auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 662, height: 32),
                                    auxiliaryTopRight: CGRect(x: 850, y: 950, width: 662, height: 32),
                                    safeAreaTop: 32)
        let island = NotchMetrics.island(physical: physical, menuBarHeight: 37)

        let resting = NotchDropCatcher.restingFrame(screenFrame: screen, island: island)

        XCTAssertEqual(resting, NSRect(x: 662, y: 950, width: 188, height: 32))
    }

    /// On a monitor: the stand-in the island is drawn around, centred at the
    /// top and exactly the menu bar's height, so the window sits inside the
    /// strip and over the island's own centre, never over a window below it.
    /// A second display's frame does not start at zero, which is the case
    /// that matters.
    func testAtRestOnAMonitorItIsTheStandIn() {
        let screen = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let physical = NotchMetrics(screenFrame: screen, auxiliaryTopLeft: nil,
                                    auxiliaryTopRight: nil, safeAreaTop: 0)
        let island = NotchMetrics.island(physical: physical, menuBarHeight: 25)

        let resting = NotchDropCatcher.restingFrame(screenFrame: screen, island: island)

        XCTAssertEqual(resting.width, VirtualCutout.width)
        XCTAssertEqual(resting.height, 25, "the menu bar strip, no taller")
        XCTAssertEqual(resting.midX, screen.midX, accuracy: 0.01)
        XCTAssertEqual(resting.maxY, screen.maxY, accuracy: 0.01, "top-flush")
    }

    // MARK: - While a file is in hand

    /// The strip is the panel's own column — no wider than the window that
    /// opens when the drag arrives, so the strip never promises a catch the
    /// panel then cannot give — and only the island's height, so everything
    /// below the menu bar still takes its drops.
    func testWithAFileInHandOverANotchItIsTheTopOfThePanelColumn() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let physical = NotchMetrics(screenFrame: screen,
                                    auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 662, height: 32),
                                    auxiliaryTopRight: CGRect(x: 850, y: 950, width: 662, height: 32),
                                    safeAreaTop: 32)
        let island = NotchMetrics.island(physical: physical, menuBarHeight: 37)
        let column = DynamicNotchOverlay.windowFrame(inScreenFrame: screen)

        let reach = NotchDropCatcher.reachFrame(screenFrame: screen, island: island)

        XCTAssertEqual(reach.minX, column.minX, accuracy: 0.01)
        XCTAssertEqual(reach.width, column.width, accuracy: 0.01)
        XCTAssertEqual(reach.height, island.notchHeight, accuracy: 0.01, "the island's height, no taller")
        XCTAssertEqual(reach.maxY, screen.maxY, accuracy: 0.01, "top-flush")
        XCTAssertGreaterThan(reach.width, 3 * island.notchWidth, "much easier to hit than the housing")
        XCTAssertTrue(reach.contains(NotchDropCatcher.restingFrame(screenFrame: screen, island: island)),
                      "everything the cutout caught, the strip still catches")
    }

    /// On a second display off to the left the strip is that display's, never
    /// the main one's: same column maths from its own frame.
    func testWithAFileInHandOnAMonitorItStaysOnThatMonitor() {
        let screen = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let physical = NotchMetrics(screenFrame: screen, auxiliaryTopLeft: nil,
                                    auxiliaryTopRight: nil, safeAreaTop: 0)
        let island = NotchMetrics.island(physical: physical, menuBarHeight: 25)

        let reach = NotchDropCatcher.reachFrame(screenFrame: screen, island: island)
        let resting = NotchDropCatcher.restingFrame(screenFrame: screen, island: island)

        XCTAssertTrue(screen.contains(reach), "\(reach) left the display")
        XCTAssertEqual(reach.midX, screen.midX, accuracy: 0.01)
        XCTAssertEqual(reach.height, 25, "the menu bar strip, no taller")
        XCTAssertEqual(reach.maxY, screen.maxY, accuracy: 0.01, "top-flush")
        XCTAssertTrue(reach.contains(resting))
    }

    // MARK: - While the island is the drop box

    /// Over the box and a margin round it: centred and top-flush like the
    /// island, wide enough for the island at the box's size, and well inside
    /// the column, so the windows either side of the box still take their
    /// drops. Its height is the kit's chrome round the box's content.
    func testAsTheDropBoxItIsTheBoxAndAMargin() {
        let box = DropPocketLayout(formats: 0, actions: 0).size
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let physical = NotchMetrics(screenFrame: screen,
                                    auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 662, height: 32),
                                    auxiliaryTopRight: CGRect(x: 850, y: 950, width: 662, height: 32),
                                    safeAreaTop: 32)
        let island = NotchMetrics.island(physical: physical, menuBarHeight: 37)
        let column = DynamicNotchOverlay.windowFrame(inScreenFrame: screen)

        let pocket = NotchDropCatcher.pocketFrame(screenFrame: screen, island: island, content: box)

        XCTAssertEqual(pocket.midX, screen.midX, accuracy: 0.01)
        XCTAssertEqual(pocket.maxY, screen.maxY, accuracy: 0.01, "top-flush")
        XCTAssertEqual(pocket.height,
                       island.notchHeight + box.height + NotchHost.bottomInset
                           + NotchDropCatcher.pocketMargin,
                       accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(pocket.width,
                                    IslandChrome.islandWidth(panelWidth: box.width),
                                    "the whole box catches, ears and all")
        XCTAssertLessThan(pocket.width, column.width * 0.85, "the strip's width again is the bug it avoids")
        XCTAssertTrue(column.contains(pocket))
        XCTAssertTrue(pocket.contains(NotchDropCatcher.restingFrame(screenFrame: screen, island: island)),
                      "everything the cutout caught, the box still catches")
    }

    /// On a second display off to the left, the box is that display's.
    func testAsTheDropBoxOnAMonitorItStaysOnThatMonitor() {
        let box = DropPocketLayout(formats: 5, actions: 4).size
        let screen = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let physical = NotchMetrics(screenFrame: screen, auxiliaryTopLeft: nil,
                                    auxiliaryTopRight: nil, safeAreaTop: 0)
        let island = NotchMetrics.island(physical: physical, menuBarHeight: 25)

        let pocket = NotchDropCatcher.pocketFrame(screenFrame: screen, island: island, content: box)

        XCTAssertTrue(screen.contains(pocket), "\(pocket) left the display")
        XCTAssertEqual(pocket.midX, screen.midX, accuracy: 0.01)
        XCTAssertEqual(pocket.maxY, screen.maxY, accuracy: 0.01, "top-flush")
    }

    /// The box's chips make it taller, and the catcher with it.
    func testTheChipsMakeTheCatcherTaller() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let physical = NotchMetrics(screenFrame: screen, auxiliaryTopLeft: nil,
                                    auxiliaryTopRight: nil, safeAreaTop: 0)
        let island = NotchMetrics.island(physical: physical, menuBarHeight: 25)
        let plain = NotchDropCatcher.pocketFrame(screenFrame: screen, island: island,
                                                 content: DropPocketLayout(formats: 0, actions: 0).size)
        let pictures = NotchDropCatcher.pocketFrame(screenFrame: screen, island: island,
                                                    content: DropPocketLayout(formats: 5, actions: 0).size)
        XCTAssertEqual(pictures.width, plain.width, accuracy: 0.01)
        XCTAssertGreaterThan(pictures.height, plain.height + PictureRowLayout.height)
    }

    // MARK: - Points into the panel

    /// Grown to the panel, the catcher's point only flips.
    func testAPointOnTheGrownCatcherOnlyFlips() {
        let panel = NSRect(x: 378, y: 0, width: 756, height: 982)
        let point = NotchDropCatcher.panelPoint(NSPoint(x: 100, y: 900), catcher: panel, panel: panel)
        XCTAssertEqual(point, CGPoint(x: 100, y: 82))
    }

    /// Resting over the box, the point goes through the screen: the box's
    /// window is smaller than the panel and centred in it.
    func testAPointOnTheBoxGoesThroughTheScreen() {
        let panel = NSRect(x: 378, y: 0, width: 756, height: 982)
        let catcher = NSRect(x: 520, y: 822, width: 472, height: 160)
        let point = NotchDropCatcher.panelPoint(NSPoint(x: 10, y: 150), catcher: catcher, panel: panel)
        XCTAssertEqual(point.x, 152, accuracy: 0.01)
        XCTAssertEqual(point.y, 10, accuracy: 0.01)
    }
}
