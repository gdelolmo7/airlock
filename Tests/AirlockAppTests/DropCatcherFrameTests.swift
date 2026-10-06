import AppKit
import XCTest
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
}
