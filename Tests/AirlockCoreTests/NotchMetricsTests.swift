import XCTest
@testable import AirlockCore

/// Numbers below are measured off a real 14" MacBook Pro (1512×982pt):
/// auxiliaryTopLeftArea = (0, 950, 663, 32), auxiliaryTopRightArea = (848, 950, 664, 32).
final class NotchMetricsTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let auxLeft = CGRect(x: 0, y: 950, width: 663, height: 32)
    private let auxRight = CGRect(x: 848, y: 950, width: 664, height: 32)

    private func metrics(safeAreaTop: CGFloat) -> NotchMetrics {
        NotchMetrics(screenFrame: screen, auxiliaryTopLeft: auxLeft, auxiliaryTopRight: auxRight,
                     safeAreaTop: safeAreaTop)
    }

    func testNotchSizeComesFromAuxiliaryAreas() {
        let m = metrics(safeAreaTop: 32)
        XCTAssertEqual(m.notchHeight, 32)
        XCTAssertEqual(m.notchWidth, 185) // 1512 - 663 - 664
        XCTAssertTrue(m.hasNotch)
    }

    /// The whole point: the menu bar hiding must not shrink the camera housing.
    func testNotchHeightSurvivesHiddenMenuBar() {
        XCTAssertEqual(metrics(safeAreaTop: 0).notchHeight, 32)
        XCTAssertEqual(metrics(safeAreaTop: 0).notchWidth, 185)
    }

    /// Clearance is one notch height in BOTH menu-bar states. This is the
    /// invariant every earlier fix broke by picking a constant — and it now
    /// holds because the host measures the cutout rather than the menu bar, so
    /// `safeAreaTop` has no say in it at all.
    func testClearanceIsOneNotchHeightWhateverTheMenuBarDoes() {
        for safeAreaTop in [CGFloat(32), 0, 12, 40] {
            XCTAssertEqual(metrics(safeAreaTop: safeAreaTop).foreignTopInset, 32)
            XCTAssertEqual(metrics(safeAreaTop: safeAreaTop).totalClearance, 32)
        }
    }

    func testNotchlessScreenHasNoClearance() {
        let external = NotchMetrics(screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                    auxiliaryTopLeft: nil, auxiliaryTopRight: nil, safeAreaTop: 0)
        XCTAssertFalse(external.hasNotch)
        XCTAssertEqual(external.notchHeight, 0)
        XCTAssertEqual(external.totalClearance, 0)
    }

    /// The vendored kit fits its window to the content, so the ceiling is the
    /// display rather than the old fixed half-screen box.
    func testHostPanelHeightIsTheWholeScreen() {
        XCTAssertEqual(metrics(safeAreaTop: 32).hostPanelHeight, 982)
    }

    func testContentBudgetLeavesRoomForBothHostInsets() {
        // 982 - 32 (host top) - 15 (host bottom) - 8 (margin)
        XCTAssertEqual(metrics(safeAreaTop: 32).contentBudget(hostBottomInset: 15, margin: 8), 927)
    }

    /// The budget must not move when the menu bar does.
    func testBudgetIsStableAcrossMenuBarStates() {
        let visible = metrics(safeAreaTop: 32), hidden = metrics(safeAreaTop: 0)
        XCTAssertEqual(visible.contentBudget(hostBottomInset: 15, margin: 8),
                       hidden.contentBudget(hostBottomInset: 15, margin: 8))
        XCTAssertEqual(visible.contentBudget(hostBottomInset: 15, margin: 8), 927)
    }

    /// The gutter layout cancels the host's top inset and draws from the screen
    /// top, so it gets that inset back as usable budget.
    func testFullBleedBudgetReclaimsTheHostTopInset() {
        let m = metrics(safeAreaTop: 32)
        XCTAssertEqual(m.fullBleedContentBudget(hostBottomInset: 15, margin: 8), 959) // 982 - 15 - 8
        XCTAssertEqual(m.fullBleedContentBudget(hostBottomInset: 15, margin: 8)
                       - m.contentBudget(hostBottomInset: 15, margin: 8), m.foreignTopInset)
    }

    /// And unlike `contentBudget`, it must not move when the menu bar hides —
    /// the top bar owns that band either way.
    func testFullBleedBudgetIsMenuBarIndependent() {
        XCTAssertEqual(metrics(safeAreaTop: 32).fullBleedContentBudget(hostBottomInset: 15, margin: 8),
                       metrics(safeAreaTop: 0).fullBleedContentBudget(hostBottomInset: 15, margin: 8))
    }

    /// A panel shorter than the host's own insets must clamp at zero, not go
    /// negative and invert the layout.
    func testContentBudgetNeverNegative() {
        let tiny = NotchMetrics(screenFrame: CGRect(x: 0, y: 0, width: 800, height: 30),
                                auxiliaryTopLeft: auxLeft, auxiliaryTopRight: auxRight, safeAreaTop: 32)
        XCTAssertEqual(tiny.contentBudget(hostBottomInset: 15, margin: 8), 0)
    }
}

/// A five-hour figure captured eight hours ago describes a window that has
/// since rolled — the live failure that put 0% on screen against a real 90%.
final class RateLimitWindowRolloverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_160_000)

    func testRolledOnceResetHasPassed() {
        let window = RateLimitWindow(usedPercentage: 0, resetsAt: now.addingTimeInterval(-3600))
        XCTAssertTrue(window.hasRolled(at: now))
    }

    func testNotRolledBeforeReset() {
        let window = RateLimitWindow(usedPercentage: 90, resetsAt: now.addingTimeInterval(3600))
        XCTAssertFalse(window.hasRolled(at: now))
    }

    /// Exactly at the reset the window has turned over, so treat it as rolled
    /// rather than reporting the outgoing period's number.
    func testRollsAtTheBoundary() {
        XCTAssertTrue(RateLimitWindow(usedPercentage: 50, resetsAt: now).hasRolled(at: now))
    }

    /// No reset time means no basis to call it void — staleness covers that case.
    func testUnknownResetIsNeverRolled() {
        XCTAssertFalse(RateLimitWindow(usedPercentage: 50, resetsAt: nil).hasRolled(at: now))
    }
}

/// The stand-in cutout the island is drawn around on a monitor with the lid
/// shut, and the guarantee that it is never mistaken for a real one.
final class VirtualCutoutTests: XCTestCase {
    private let laptop = NotchMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                      auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663, height: 32),
                                      auxiliaryTopRight: CGRect(x: 848, y: 950, width: 664, height: 32),
                                      safeAreaTop: 32)
    private let monitor = NotchMetrics(screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                       auxiliaryTopLeft: nil, auxiliaryTopRight: nil, safeAreaTop: 0)

    /// A real notch comes back untouched whatever the menu bar reads — the
    /// MacBook must not change.
    func testARealNotchPassesThroughUntouched() {
        for strip in [CGFloat(32), 0, 24] {
            XCTAssertEqual(NotchMetrics.island(physical: laptop, menuBarHeight: strip), laptop)
        }
    }

    /// Laptop-sized, not the kit's 300pt bar, and exactly as tall as the menu
    /// bar, so it sits inside it.
    func testAMonitorGetsALaptopSizedStandInTheHeightOfItsMenuBar() {
        let island = NotchMetrics.island(physical: monitor, menuBarHeight: 24)
        XCTAssertEqual(island.notchWidth, 185)
        XCTAssertEqual(island.notchHeight, 24)
        XCTAssertEqual(island.screenFrame, monitor.screenFrame)
        XCTAssertTrue(island.isStandIn)
    }

    /// With the menu bar hidden there is no strip to measure. A panel opened
    /// over a full-screen app is the same shape as one opened over the desktop.
    func testAHiddenMenuBarFallsBackToTheUsualHeight() {
        XCTAssertEqual(NotchMetrics.island(physical: monitor, menuBarHeight: 0).notchHeight,
                       VirtualCutout.fallbackHeight)
        XCTAssertEqual(VirtualCutout.size(menuBarHeight: 0), VirtualCutout.size(menuBarHeight: 24))
    }

    /// Never a notch: the drop catcher needs real hardware to sit over, and
    /// `hasNotch` is what it asks.
    func testAStandInIsNeverANotch() {
        XCTAssertFalse(NotchMetrics.island(physical: monitor, menuBarHeight: 24).hasNotch)
        XCTAssertFalse(monitor.isStandIn)
        XCTAssertFalse(laptop.isStandIn)
        XCTAssertTrue(laptop.hasNotch)
    }

    /// The kit adds a top inset of the cutout's height and the layout cancels
    /// `foreignTopInset`, so for a stand-in they have to be the same number.
    func testTheLayoutCancelsExactlyTheStandInsHeight() {
        XCTAssertEqual(NotchMetrics.island(physical: monitor, menuBarHeight: 24).foreignTopInset,
                       VirtualCutout.size(menuBarHeight: 24).height)
    }

    /// Only while the menu bar shows, notch or not (owner, 2026-10-04).
    func testWhereTheIslandMayRest() {
        XCTAssertTrue(VirtualCutout.canRest(menuBarHeight: 32))
        XCTAssertTrue(VirtualCutout.canRest(menuBarHeight: 24))
        XCTAssertFalse(VirtualCutout.canRest(menuBarHeight: 0),
                       "the menu bar hidden — full screen or auto-hide — on a notch or a monitor")
    }

    // MARK: - Top-edge reveal

    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testTheTopEdgeBringsItBack() {
        XCTAssertTrue(TopEdgeReveal.isRevealed(was: false, pointer: CGPoint(x: 300, y: 982), screen: builtIn))
        XCTAssertTrue(TopEdgeReveal.isRevealed(was: false, pointer: CGPoint(x: 1512, y: 981), screen: builtIn))
        XCTAssertFalse(TopEdgeReveal.isRevealed(was: false, pointer: CGPoint(x: 300, y: 970), screen: builtIn),
                       "near the top is not the top: a film's controls live up there")
    }

    func testItStaysWhileThePointerStaysInTheStrip() {
        XCTAssertTrue(TopEdgeReveal.isRevealed(was: true, pointer: CGPoint(x: 756, y: 950), screen: builtIn))
        XCTAssertFalse(TopEdgeReveal.isRevealed(was: true, pointer: CGPoint(x: 756, y: 930), screen: builtIn))
    }

    func testAnotherDisplaysTopEdgeDoesNotCount() {
        let above = CGPoint(x: 300, y: 1200)
        let beside = CGPoint(x: 1600, y: 982)
        for pointer in [above, beside] {
            XCTAssertFalse(TopEdgeReveal.isRevealed(was: false, pointer: pointer, screen: builtIn))
            XCTAssertFalse(TopEdgeReveal.isRevealed(was: true, pointer: pointer, screen: builtIn))
        }
    }
}
