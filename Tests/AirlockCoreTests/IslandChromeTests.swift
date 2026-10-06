import XCTest
@testable import AirlockCore

/// `IslandChrome` transcribes numbers the kit keeps private, so nothing can
/// compare it with the kit symbol for symbol. These check the arithmetic, then
/// that the kit's source still says what was transcribed: a re-vendored kit that
/// moves an inset fails here, by name, instead of clipping the island at the
/// widest setting, where nobody looks.
final class IslandChromeTests: XCTestCase {

    /// The default panel, as the kit lays it out: an inset and an ear each side.
    func testTheIslandIsSixtyWiderThanThePanel() {
        XCTAssertEqual(IslandChrome.islandWidth(panelWidth: 640), 700)
    }

    /// The black below the ears: the frame less an ear and the mask's half
    /// point each side.
    func testTheBodyIsTwentyNineWiderThanThePanel() {
        XCTAssertEqual(IslandChrome.bodyWidth(panelWidth: 640), 669)
    }

    func testThePanelForAnIslandUndoesTheIslandForAPanel() {
        for panel: CGFloat in [460, 640, 667, 688, 760] {
            XCTAssertEqual(IslandChrome.panelWidth(islandWidth: IslandChrome.islandWidth(panelWidth: panel)),
                           panel)
        }
    }

    // MARK: - The kit still says so

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AirlockCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Each fragment is a line a number was read from. The message names the
    /// number to re-read, because the fix belongs in `IslandChrome`, not in
    /// this list.
    func testTheKitStillDrawsTheChromeThatWasTranscribed() throws {
        let kit = try source("Sources/DynamicNotchKit/Views/NotchView.swift")
        let transcribed: [(fragment: String, number: String)] = [
            ("private let safeAreaInset: CGFloat = 15", "sideInset"),
            (".safeAreaInset(edge: .leading, spacing: 0) { Color.clear.frame(width: safeAreaInset) }", "sideInset"),
            (".safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: safeAreaInset) }", "sideInset"),
            ("(top: 15, bottom: 20)", "topCornerRadius"),
            (".padding(.horizontal, topCornerRadius)", "topCornerRadius"),
            (".padding(.horizontal, 0.5)", "maskInset"),
        ]
        for (fragment, number) in transcribed {
            XCTAssertTrue(kit.contains(fragment), """
                NotchView.swift no longer says `\(fragment)`. Re-read it and update \
                IslandChrome.\(number), or the width ceiling stops fitting the island.
                """)
        }
    }

    /// Two things the transcription leans on that the APP decides. The 15pt
    /// ears are the kit's fallback for `.auto`: a `.notch(...)` style brings its
    /// own radii. And only the notch style is transcribed, which holds because
    /// every display without a notch is handed a cutout to draw around.
    func testTheAppStillAsksForTheIslandThatWasTranscribed() throws {
        let controller = try source("Sources/AirlockApp/Notch/NotchController.swift")
        XCTAssertTrue(controller.contains("style: .auto,"), """
            NotchController no longer builds the kit with `style: .auto`. \
            IslandChrome.topCornerRadius is the kit's fallback radius for .auto, \
            and may now be the wrong one.
            """)
        XCTAssertTrue(controller.contains("notch.notchlessCutout = "), """
            NotchController no longer sets `notchlessCutout`, so the kit may draw \
            its floating style, whose chrome IslandChrome does not transcribe.
            """)
    }
}
