import SwiftUI
import AirlockTestSupport
import XCTest
@testable import AirlockApp

/// The three type zones, which are the whole safety story of the text-size
/// setting: one scales, one must never scale, one scales part way.
@MainActor
final class TextScaleTests: XCTestCase {

    override func tearDown() async throws {
        Theme.setTextScale(1)
    }

    // MARK: - The panel scales

    func testChromeFollowsTheScale() {
        Theme.setTextScale(1.4)
        XCTAssertEqual(Theme.chrome(12, .semibold),
                       .system(size: 12 * 1.4, weight: .semibold, design: .default))
    }

    func testChromeIsUnchangedAtOne() {
        Theme.setTextScale(1)
        XCTAssertEqual(Theme.chrome(12), .system(size: 12, weight: .regular, design: .default))
    }

    /// Mono was a stored `let`, evaluated once — it could never have followed
    /// the setting, which would have left code spans the one thing that did not
    /// grow.
    func testMonoTiersFollowTheScaleToo() {
        Theme.setTextScale(1.4)
        XCTAssertEqual(Theme.code, .system(size: 12 * 1.4, weight: .medium, design: .monospaced))
        XCTAssertEqual(Theme.label, .system(size: 10 * 1.4, weight: .semibold, design: .monospaced))
    }

    // MARK: - The island must not

    /// The kit hard-clips the compact island to the physical notch height, so
    /// text that grew there would be cut off by the window rather than reflow.
    func testFixedIgnoresTheScaleEntirely() {
        Theme.setTextScale(Theme.maxTextScale)
        XCTAssertEqual(Theme.fixed(11, .bold), .system(size: 11, weight: .bold, design: .default))
    }

    // MARK: - The band scales part way

    /// The two gutters flank the camera housing on a measured width budget.
    func testGutterIsCapped() {
        Theme.setTextScale(Theme.maxTextScale)
        XCTAssertEqual(Theme.gutter(10), .system(size: 12.5, weight: .regular, design: .default),
                       "the gutter cap is 1.25, whatever the panel is set to")
    }

    func testGutterFollowsBelowTheCap() {
        Theme.setTextScale(1.1)
        XCTAssertEqual(Theme.gutter(10), .system(size: 11, weight: .regular, design: .default))
    }

    // MARK: - The range holds

    /// Clamped in the setter rather than at the slider, so a stale or
    /// hand-edited preference cannot produce a panel nobody can read.
    /// The ceiling exists because the layout was only checked to 1.4 — see
    /// `Theme.maxTextScale`. Clamping in the setter, not only at the slider,
    /// is what stops a stale preference from exceeding it.
    func testScaleIsClampedToItsRange() {
        Theme.setTextScale(9)
        XCTAssertEqual(Theme.textScale, Theme.maxTextScale)
        Theme.setTextScale(0.1)
        XCTAssertEqual(Theme.textScale, 1)
        Theme.setTextScale(-3)
        XCTAssertEqual(Theme.textScale, 1)
    }

    /// The slider's range and the clamp come from one constant. If they ever
    /// drift, the slider offers a size the layout was never checked at.
    func testTheSliderRangeMatchesTheClamp() {
        XCTAssertEqual(NotchAppearanceModel.textScaleRange.upperBound, Theme.maxTextScale)
        XCTAssertEqual(NotchAppearanceModel.textScaleRange.lowerBound, 1)
    }

    // MARK: - The cache must not outlive a scale change

    /// `InlineMarkdown` is memoised, and its result depends on the scale — so
    /// the scale is part of the key. Without that, changing the text size
    /// returns the previous scale's fonts for every line already on screen,
    /// which is a half-scaled panel that looks like the feature is broken.
    func testMarkdownCacheIsInvalidatedByAScaleChange() {
        Theme.setTextScale(1)
        let small = InlineMarkdown.render("run `swift build`", size: 12)
        Theme.setTextScale(Theme.maxTextScale)
        let large = InlineMarkdown.render("run `swift build`", size: 12)

        let smallCode = small.runs.compactMap(\.font).first
        let largeCode = large.runs.compactMap(\.font).first
        XCTAssertNotNil(smallCode)
        XCTAssertNotEqual(smallCode, largeCode,
                          "the cache returned the previous scale's font")
    }

    /// The model is the only writer, and a stored preference has to reach the
    /// static at construction — `didSet` does not fire during `init`, so
    /// without that the panel would come up unscaled for someone who had
    /// already chosen a size.
    func testAppearanceModelSeedsTheStaticAtInit() {
        let store = TestDefaults("com.airlock.test.textscale")
        let defaults = store.defaults
        defaults.set(1.3, forKey: "notch.textScale")
        Theme.setTextScale(1)

        _ = NotchAppearanceModel(defaults: defaults)
        XCTAssertEqual(Theme.textScale, 1.3, accuracy: 0.001)
    }
}
