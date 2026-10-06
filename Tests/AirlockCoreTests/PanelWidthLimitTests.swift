import XCTest
@testable import AirlockCore

/// The two machines the product is actually used on, in points:
/// 14" MacBook Pro 1512×982, 13" MacBook Air 1470×956 — and a 27" external
/// display at its default 2560×1440.
final class PanelWidthLimitTests: XCTestCase {
    private let requested: ClosedRange<CGFloat> = 460...760

    private func limit(screen: CGFloat) -> PanelWidthLimit {
        PanelWidthLimit(screenWidth: screen, requested: requested)
    }

    /// Twice over. 760 was offered and 756 was the whole window. Then 748 was
    /// the ceiling, which fitted the panel and not the island the kit draws
    /// 60pt wider around it, so the window edge still cut its ears and the
    /// bottom corners of its body.
    func testFourteenInchCannotDrawTheRequestedMaximum() {
        let mbp14 = limit(screen: 1512)
        XCTAssertEqual(mbp14.hostWindowWidth, 756)
        XCTAssertEqual(mbp14.maximum, 688)
        XCTAssertTrue(mbp14.isScreenLimited)
    }

    func testThirteenInchIsTighterStill() {
        let air13 = limit(screen: 1470)
        XCTAssertEqual(air13.hostWindowWidth, 735)
        XCTAssertEqual(air13.maximum, 667)
        XCTAssertTrue(air13.isScreenLimited)
    }

    /// A screen with room to spare is capped by the product, not by itself —
    /// 16" MacBook Pro, 1728pt wide.
    func testARoomyScreenKeepsTheRequestedMaximum() {
        let mbp16 = limit(screen: 1728)
        XCTAssertEqual(mbp16.maximum, 760)
        XCTAssertFalse(mbp16.isScreenLimited)
    }

    /// An external display could draw a panel far wider than the product
    /// offers. The product's 760 is the ceiling there, not the screen's 1212.
    func testALargeExternalDisplayIsCappedByTheProductNotTheScreen() {
        let external = limit(screen: 2560)
        XCTAssertEqual(external.hostWindowWidth, 1280)
        XCTAssertEqual(external.drawableWidth, 1212)
        XCTAssertEqual(external.maximum, 760)
        XCTAssertFalse(external.isScreenLimited)
    }

    /// What the ceiling is FOR, stated in the kit's terms rather than ours: at
    /// the widest panel the slider offers, the whole island and the margin fit
    /// inside the window. The numbers above can each be edited to agree with a
    /// wrong ceiling; this cannot.
    func testTheIslandAtTheCeilingFitsItsWindow() {
        for screen: CGFloat in [1470, 1512, 1728, 2560] {
            let widest = limit(screen: screen)
            let island = IslandChrome.islandWidth(panelWidth: widest.maximum)
            XCTAssertLessThanOrEqual(island + PanelWidthLimit.edgeMargin, widest.hostWindowWidth,
                                     "a \(widest.maximum)pt panel draws a \(island)pt island on a \(screen)pt screen")
        }
    }

    /// And no tighter than it has to be: where the screen sets the ceiling,
    /// the island meets the margin exactly. Width given up for nothing is
    /// width taken from the gutters.
    func testWhereTheScreenSetsTheCeilingTheIslandUsesTheWholeWindow() {
        for screen: CGFloat in [1470, 1512] {
            let widest = limit(screen: screen)
            XCTAssertEqual(IslandChrome.islandWidth(panelWidth: widest.maximum) + PanelWidthLimit.edgeMargin,
                           widest.hostWindowWidth, "\(screen)pt screen")
        }
    }

    /// A width chosen on a bigger screen is capped as it is READ. The stored
    /// preference is not this type's business, and that is the point: reconnect
    /// the wider display and 760 is honoured again.
    func testAStoredWidthAboveTheCeilingIsClampedOnRead() {
        XCTAssertEqual(limit(screen: 1512).clamped(760), 688)
        XCTAssertEqual(limit(screen: 1728).clamped(760), 760)
        XCTAssertEqual(limit(screen: 2560).clamped(760), 760)
    }

    /// Anyone who dragged the slider to the old ceiling has that number
    /// stored. It now reads as the new one, and it is still only a read.
    func testTheOldCeilingIsClampedToTheNewOne() {
        XCTAssertEqual(limit(screen: 1512).clamped(748), 688)
        XCTAssertEqual(limit(screen: 1470).clamped(727), 667)
    }

    /// 640 is the default. It has to be drawable on the narrowest Mac the
    /// product runs on, or everybody on a 13" starts out clamped.
    func testAWidthTheScreenCanDrawIsUntouched() {
        XCTAssertEqual(limit(screen: 1512).clamped(640), 640)
        XCTAssertEqual(limit(screen: 1470).clamped(640), 640)
    }

    func testClampingHoldsTheFloorToo() {
        XCTAssertEqual(limit(screen: 1512).clamped(120), 460)
    }

    /// A screen too small for even the minimum must still leave a usable
    /// slider. Bounds that crossed would trap at the point of use, and this is
    /// the one input nobody can check by eye.
    func testATinyScreenStillLeavesAValidRange() {
        let tiny = limit(screen: 600)
        XCTAssertEqual(tiny.maximum, 460)
        XCTAssertEqual(tiny.range, 460...460)
        XCTAssertEqual(tiny.clamped(640), 460)
    }

    /// The island's chrome is subtracted from the window now, so a window
    /// narrower than the chrome would go negative without the floor.
    func testNoScreenAtAllDoesNotProduceNegativeWidths() {
        let none = limit(screen: 0)
        XCTAssertEqual(none.hostWindowWidth, 0)
        XCTAssertEqual(none.drawableWidth, 0)
        XCTAssertEqual(none.range, 460...460)
    }
}
