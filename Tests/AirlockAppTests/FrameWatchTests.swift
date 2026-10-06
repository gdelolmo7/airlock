import AirlockCore
import AppKit
import XCTest
@testable import AirlockApp

/// The rules card C4's log line rests on: what counts as a black, clipped or
/// jumpy frame. Pure, so they are pinned here without a window; whether they
/// fire on the real island is checked with `--frame-loop` on the packaged app.
@MainActor
final class FrameWatchTests: XCTestCase {
    private let notch = CGSize(width: 185, height: 32)
    private let window = CGSize(width: 756, height: 982)

    private func reading(_ presentation: IslandPresentation, height: CGFloat = 400,
                         width: CGFloat = 630, below: Int = 5000) -> FrameWatch.Reading {
        FrameWatch.Reading(presentation: presentation, kitAgrees: true,
                           windowPresent: true, windowVisible: true, windowAlpha: 1,
                           shape: CGRect(x: (window.width - width) / 2, y: 0, width: width, height: height),
                           windowSize: window, notchSize: notch,
                           contentBelowBar: below, content: below + 500,
                           fadedLayers: [], overflow: 0, glassGround: false)
    }

    private func samples(_ points: [(TimeInterval, CGFloat, Bool)]) -> [FrameWatch.Sample] {
        points.map { FrameWatch.Sample(time: $0.0, height: $0.1, hasContent: $0.2) }
    }

    // MARK: Settled

    func testAHealthyPanelAndIslandPass() {
        XCTAssertEqual(FrameWatch.problems(reading(.expanded)), [])
        XCTAssertEqual(FrameWatch.problems(reading(.compact, height: 33, width: 300)), [])
        XCTAssertEqual(FrameWatch.problems(reading(.hidden)), [])
    }

    func testAPanelWithNothingBelowTheBarIsABlackBox() {
        XCTAssertEqual(FrameWatch.problems(reading(.expanded, below: 0)), [.blackBox])
    }

    /// On glass the material draws outside the process, so an empty-looking
    /// picture says nothing and the pixel rule stands down.
    func testGlassIsNotReadAsABlackBox() {
        var glass = reading(.expanded, below: 0)
        glass.glassGround = true
        XCTAssertEqual(FrameWatch.problems(glass), [])
    }

    func testSizeMustMatchThePresentation() {
        XCTAssertEqual(FrameWatch.problems(reading(.compact, height: 62, width: 288)), [.wrongSize])
        XCTAssertEqual(FrameWatch.problems(reading(.expanded, height: 40)), [.wrongSize])
    }

    /// Measured with a real pointer on the island: 292x62, the kit's hover
    /// shadow read as island. The size rule stands down under a pointer.
    func testAHoveredIslandsShadowIsNotItsSize() {
        var hovered = reading(.compact, height: 62, width: 292)
        hovered.hovering = true
        XCTAssertEqual(FrameWatch.problems(hovered), [])
    }

    func testContentCutOffIsClipped() {
        var overflowing = reading(.expanded)
        overflowing.overflow = 12
        XCTAssertEqual(FrameWatch.problems(overflowing), [.clipped])
        XCTAssertEqual(FrameWatch.problems(reading(.expanded, width: window.width)), [.clipped])
    }

    func testAMissingOrFadedWindowIsInvisible() {
        var faded = reading(.expanded)
        faded.windowAlpha = 0.5
        XCTAssertEqual(FrameWatch.problems(faded), [.invisible])
        var nothing = reading(.compact)
        nothing.shape = nil
        XCTAssertEqual(FrameWatch.problems(nothing), [.invisible])
    }

    func testALayerLeftFadedIsReported() {
        var stranded = reading(.expanded)
        stranded.fadedLayers = ["CALayer 600x200 0.00"]
        XCTAssertEqual(FrameWatch.problems(stranded), [.faded])
    }

    /// Every close on the installed app: the panel's content, at opacity 0,
    /// still in the tree under a 32pt island. Nothing of it can show.
    func testAClosingPanelsContentIsNotAStrand() {
        var closed = reading(.compact, height: 32, width: 260)
        closed.fadedLayers = ["NSViewBackingLayer 630x252 0.00"]
        XCTAssertEqual(FrameWatch.problems(closed), [])
    }

    func testTheKitDisagreeingIsReportedEvenWhenHidden() {
        var hidden = reading(.hidden)
        hidden.kitAgrees = false
        XCTAssertEqual(FrameWatch.problems(hidden), [.kitDisagrees])
    }

    // MARK: Frame by frame

    /// The measured healthy open, 33pt to 408pt over a third of a second.
    func testASpringIsNotAJump() {
        let open = samples([(0, 33, false), (0.04, 46, false), (0.08, 122, true), (0.12, 214, true),
                            (0.16, 303, true), (0.2, 357, true), (0.24, 400, true), (0.28, 410, true),
                            (0.32, 408, true)])
        XCTAssertEqual(FrameWatch.motionProblems(open, presentation: .expanded), [])
    }

    /// The snap C4 found on tab changes before the glide: 408pt to 176pt
    /// between two consecutive pictures.
    func testASnapIsAJump() {
        let snap = samples([(-0.016, 408, true), (0.043, 176, true), (0.1, 176, true), (0.15, 176, true)])
        XCTAssertEqual(FrameWatch.motionProblems(snap, presentation: .expanded), [.jump])
    }

    /// Two pictures far apart in time say nothing about the frames between.
    func testAGapIsNotAJump() {
        let gap = samples([(0, 408, true), (0.2, 176, true), (0.25, 176, true)])
        XCTAssertEqual(FrameWatch.motionProblems(gap, presentation: .expanded), [])
    }

    func testReduceMotionChangesSizeInOneStepOnPurpose() {
        let snap = samples([(-0.016, 408, true), (0.043, 176, true), (0.1, 176, true)])
        XCTAssertEqual(FrameWatch.motionProblems(snap, presentation: .expanded, reduceMotion: true), [])
    }

    /// On glass a picture without content reads as the top bar alone; that
    /// is the measurement, not the island, and it is left out.
    func testGlassHeightsWithoutContentAreLeftOut() {
        let glass = samples([(-0.016, 374, true), (0.033, 30, false), (0.1, 33, false),
                             (0.32, 146, true), (0.39, 144, true), (0.44, 142, true)])
        XCTAssertEqual(FrameWatch.motionProblems(glass, presentation: .expanded, glassGround: true), [])
        XCTAssertEqual(FrameWatch.motionProblems(glass, presentation: .expanded), [.jump])
    }

    func testAPanelThatArrivesEmptyIsLate() {
        let late = samples([(0, 33, false), (0.1, 300, false), (0.15, 408, false), (0.2, 408, false),
                            (0.25, 408, false), (0.3, 408, false), (0.35, 408, true)])
        XCTAssertEqual(FrameWatch.motionProblems(late, presentation: .expanded), [.lateContent])
    }

    /// A close from a short tab, measured: still for a beat, then the
    /// spring's fastest stretch covers two thirds of the way between two
    /// looks. It is still moving after that step, which a snap never is.
    func testAFastSpringFromRestIsNotAJump() {
        let close = samples([(0.071, 297, true), (0.178, 297, true), (0.239, 123, true), (0.299, 68, true),
                             (0.364, 46, false), (0.433, 38, false), (0.555, 33, false), (0.608, 33, false)])
        XCTAssertEqual(FrameWatch.motionProblems(close, presentation: .compact), [])
    }

    /// A snap that lands a few points short and settles is still a snap.
    func testASnapThatSettlesIsAJump() {
        let snap = samples([(-0.016, 408, true), (0.043, 182, true), (0.1, 177, true), (0.15, 176, true)])
        XCTAssertEqual(FrameWatch.motionProblems(snap, presentation: .expanded), [.jump])
    }
}
