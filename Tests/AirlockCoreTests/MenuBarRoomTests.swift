import XCTest
@testable import AirlockCore

final class MenuBarRoomTests: XCTestCase {
    // The owner's 14-inch, measured 2026-10-30: cutout 663–848, the first
    // status item (the microphone light) at 891.
    private let cutoutMinX: CGFloat = 663
    private let cutoutMaxX: CGFloat = 848

    func testTheRoomIsTheGapToTheFirstStatusItem() {
        let room = MenuBarRoom.trailing(cutoutMinX: cutoutMinX, cutoutMaxX: cutoutMaxX,
                                        statusItemMinXs: [1200, 891, 1010])
        XCTAssertEqual(room, 43)
        XCTAssertEqual(MenuBarRoom.contentBudget(room: 43), 27)
    }

    func testNoStatusItemsMeansNoLimit() {
        XCTAssertNil(MenuBarRoom.trailing(cutoutMinX: cutoutMinX, cutoutMaxX: cutoutMaxX, statusItemMinXs: []))
    }

    func testItemsLeftOfTheCutoutDoNotCount() {
        let room = MenuBarRoom.trailing(cutoutMinX: cutoutMinX, cutoutMaxX: cutoutMaxX,
                                        statusItemMinXs: [120, 400, 950])
        XCTAssertEqual(room, 102)
    }

    func testAnItemTuckedUnderTheCutoutLeavesNoRoom() {
        let room = MenuBarRoom.trailing(cutoutMinX: cutoutMinX, cutoutMaxX: cutoutMaxX,
                                        statusItemMinXs: [840])
        XCTAssertEqual(room, 0)
        XCTAssertEqual(MenuBarRoom.contentBudget(room: 0), 0)
    }

    func testTheChromeMatchesTheKit() throws {
        // The kit's trailing inset is transcribed into `MenuBarRoom`; a
        // re-vendored kit that moves it fails here, by name.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let kit = try String(contentsOf: root.appendingPathComponent("Sources/DynamicNotchKit/Views/NotchView.swift"),
                             encoding: .utf8)
        let inset = Int(MenuBarRoom.kitTrailingInset)
        let fragment = ".safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: \(inset)) }"
        XCTAssertTrue(kit.contains(fragment), """
            NotchView.swift no longer says `\(fragment)`. Re-read it and update \
            MenuBarRoom.kitTrailingInset, or the call pill measures the wrong room.
            """)
    }
}

final class CallPillFitTests: XCTestCase {
    // Close to what the pill draws: a 5pt dot, the 11pt logo, "0:45" and "45s"
    // in 11pt semibold.
    private let withDot = CallPillFit.Widths(mark: 5, logo: 11, timer: 25, shortTimer: 19)
    private let noMark = CallPillFit.Widths(mark: nil, logo: 11, timer: 25, shortTimer: 19)

    func testEverythingWhenNothingWasMeasured() {
        XCTAssertEqual(CallPillFit.parts(withDot, budget: nil),
                       .init(mark: true, logo: true, timer: .full))
    }

    func testEverythingWhenItFits() {
        XCTAssertEqual(CallPillFit.width(of: .init(mark: true, logo: true, timer: .full), withDot), 47)
        XCTAssertEqual(CallPillFit.parts(withDot, budget: 47),
                       .init(mark: true, logo: true, timer: .full))
    }

    func testTheLogoGoesFirst() {
        XCTAssertEqual(CallPillFit.parts(withDot, budget: 40),
                       .init(mark: true, logo: false, timer: .full))
    }

    func testTheOwnersMenuBarKeepsTheDotAndTheMinutes() {
        // Room 43, budget 27: the case from the screenshot.
        XCTAssertEqual(CallPillFit.parts(withDot, budget: MenuBarRoom.contentBudget(room: 43)),
                       .init(mark: true, logo: false, timer: .short))
    }

    func testTheMarkOutlastsTheTimer() {
        XCTAssertEqual(CallPillFit.parts(withDot, budget: 10),
                       .init(mark: true, logo: false, timer: nil))
    }

    func testNothingWhenNothingFits() {
        XCTAssertEqual(CallPillFit.parts(withDot, budget: 2), .none)
    }

    func testWithoutAMarkTheLogoIsTheLastThingLeft() {
        XCTAssertEqual(CallPillFit.parts(noMark, budget: 20),
                       .init(mark: false, logo: false, timer: .short))
        XCTAssertEqual(CallPillFit.parts(noMark, budget: 12),
                       .init(mark: false, logo: true, timer: nil))
    }

    func testAWordWithNoShortFormSkipsThatStep() {
        let muted = CallPillFit.Widths(mark: 5, logo: 11, timer: 34, shortTimer: nil)
        XCTAssertEqual(CallPillFit.parts(muted, budget: 30),
                       .init(mark: true, logo: false, timer: nil))
    }
}
