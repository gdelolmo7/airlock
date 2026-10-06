import XCTest
@testable import AirlockCore

/// 185pt is the measured cutout on a 14" MacBook Pro.
final class GutterBudgetTests: XCTestCase {
    private func budget(panel: CGFloat, tightening: CGFloat = 0) -> GutterBudget {
        GutterBudget(panelWidth: panel, notchWidth: 185, tightening: tightening)
    }

    func testGuttersSplitWhatIsLeftOfThePanel() {
        XCTAssertEqual(budget(panel: 640).layoutGutter, 227.5)
        XCTAssertEqual(budget(panel: 640).clearGutter, 227.5)
    }

    /// The bug this type exists for: tightening inflates the gutter the layout
    /// believes in, but the reclaimed points are behind the camera. Advice
    /// measured against `layoutGutter` would call a spilling layout fine.
    func testTighteningInflatesLayoutGutterButNotClearGutter() {
        let tight = budget(panel: 640, tightening: 40)
        XCTAssertEqual(tight.layoutGutter, 247.5)
        XCTAssertEqual(tight.clearGutter, 227.5)
        XCTAssertEqual(tight.layoutGutter - tight.clearGutter, 20) // half the tightening, per side
    }

    func testFitsJudgesAgainstWhatIsVisible() {
        let tight = budget(panel: 640, tightening: 40)
        XCTAssertTrue(tight.fits(227.5))
        XCTAssertFalse(tight.fits(240), "240 sits inside the inflated gutter but behind the housing")
    }

    /// The regression that moved the default 580 -> 640: the settings gear
    /// pushed the trailing cluster to ~218pt against a 197.5pt gutter.
    func testTheGearRegression() {
        XCTAssertFalse(budget(panel: 580).fits(218))
        XCTAssertTrue(budget(panel: 640).fits(218))
        XCTAssertEqual(budget(panel: 580).widthNeeded(for: 218), 621)
    }

    /// A shortfall costs double, because widening feeds both gutters.
    func testWidthNeededCountsBothSides() {
        XCTAssertEqual(budget(panel: 500).widthNeeded(for: 200), 500 + (200 - 157.5) * 2)
    }

    func testWidthNeededLeavesAFittingPanelAlone() {
        XCTAssertEqual(budget(panel: 640).widthNeeded(for: 100), 640)
    }

    /// Tightening past the cutout must not invert the reserve.
    func testOverTighteningClampsAtZero() {
        let absurd = GutterBudget(panelWidth: 640, notchWidth: 185, tightening: 400)
        XCTAssertEqual(absurd.reservedCentre, 0)
        XCTAssertEqual(absurd.clearGutter, 227.5, "still measured from the real cutout")
    }

    func testNegativeTighteningIsTreatedAsNone() {
        XCTAssertEqual(budget(panel: 640, tightening: -20).reservedCentre, 185)
    }

    /// A notch-less display reserves nothing and the whole panel is gutter.
    func testNotchlessScreenHasNoReservedCentre() {
        let external = GutterBudget(panelWidth: 640, notchWidth: 0)
        XCTAssertEqual(external.reservedCentre, 0)
        XCTAssertEqual(external.clearGutter, 320)
        XCTAssertTrue(external.fits(300))
    }
}
