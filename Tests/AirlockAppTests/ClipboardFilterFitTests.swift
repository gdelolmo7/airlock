import XCTest
import AppKit
@testable import AirlockApp
@testable import AirlockCore

/// Does the clipboard's filter row fit at the narrowest panel the app allows?
///
/// It did not, and nothing caught it: the row fits comfortably at the 640pt
/// default, and the 460pt floor is reachable two ways most people never hit —
/// dragging the width slider to its minimum, or having a small enough display
/// that `PanelWidthLimit` collapses the range to 460...460.
///
/// The failure was not width. The row needs 383pt of the 440 available, with
/// 56pt to spare. Both children of its HStack were flexible, so SwiftUI split
/// the space ~50/50 and gave the filters ~215pt against an intrinsic 244 —
/// three of five labels truncated at scale 1.0, four of five at 1.4. The fix is
/// `.fixedSize(horizontal:)`; these tests are what stop it regressing when a
/// sixth filter or a longer label arrives.
@MainActor
final class ClipboardFilterFitTests: XCTestCase {

    override func tearDown() {
        Theme.setTextScale(1)
        super.tearDown()
    }

    private var labels: [String] { ClipboardFilter.allCases.map(\.label) }

    /// The budget, at both ends of the text-scale range. `Theme.textScale` moves
    /// fonts and not containers, so the 440 does not grow with it — which is
    /// exactly why the maximum scale is the case that breaks first.
    func testTheRowAndAUsableSearchFieldFitAtThePanelFloor() {
        for scale in [1.0, Theme.maxTextScale] {
            Theme.setTextScale(scale)
            let filters = FilterRowMetrics.intrinsicWidth(labels: labels)
            let needed = filters + FilterRowMetrics.rowSpacing + FilterRowMetrics.searchFieldFloor
            XCTAssertLessThanOrEqual(
                needed, FilterRowMetrics.contentWidthAtPanelFloor,
                """
                At textScale \(scale) the filter row needs \(filters)pt, which leaves \
                \(FilterRowMetrics.contentWidthAtPanelFloor - filters - FilterRowMetrics.rowSpacing)pt \
                for the search field — under its \(FilterRowMetrics.searchFieldFloor)pt floor. \
                Shorten a label, drop a filter, or reduce the padding.
                """)
        }
    }

    /// The measured intrinsic, pinned. If someone adds a filter this fails here
    /// first, with a number, rather than in a screenshot at minimum width.
    func testIntrinsicWidthIsWhatWeMeasured() {
        Theme.setTextScale(1)
        XCTAssertEqual(FilterRowMetrics.intrinsicWidth(labels: labels), 244, accuracy: 2)
        Theme.setTextScale(Theme.maxTextScale)
        XCTAssertEqual(FilterRowMetrics.intrinsicWidth(labels: labels), 287, accuracy: 3)
    }

    /// The narrowest place this row can land: dragged into a column, at the
    /// panel floor, at maximum text scale. `ViewThatFits` drops to icons on
    /// their own line there, and that form has to fit or it clips.
    func testTheCompactFormFitsEvenInAColumnAtThePanelFloor() {
        Theme.setTextScale(Theme.maxTextScale)
        let compact = FilterRowMetrics.compactWidth(count: ClipboardFilter.allCases.count)
        XCTAssertLessThanOrEqual(compact, FilterRowMetrics.contentWidthInColumnAtFloor,
                                 """
                                 The icon row needs \(compact)pt and a column at the floor                                  gives \(FilterRowMetrics.contentWidthInColumnAtFloor)pt.                                  There is no narrower form to fall back to, so this one clips.
                                 """)
    }

    /// The labels are the width. A rename is a layout change, and this says so.
    func testALongerLabelWouldNotFit() {
        Theme.setTextScale(Theme.maxTextScale)
        let greedy = ["All", "Text", "Links", "Screenshots", "Documents"]
        let needed = FilterRowMetrics.intrinsicWidth(labels: greedy)
            + FilterRowMetrics.rowSpacing + FilterRowMetrics.searchFieldFloor
        XCTAssertGreaterThan(needed, FilterRowMetrics.contentWidthAtPanelFloor,
                             "if this now fits, the budget moved and the guard above is slack")
    }
}

/// The clipboard footer at the 460pt panel floor.
///
/// It overflowed in one conditional state and had done since before the filter
/// row existed: with the Accessibility warning inline it needed 509pt at
/// textScale 1.0 and 667pt at 1.4, against 440. SwiftUI picked the loser, and it
/// picked badly — the warning itself truncated, so the one state where a
/// switched-on feature silently does nothing announced itself half-written.
@MainActor
final class ClipboardFooterFitTests: XCTestCase {

    override func tearDown() {
        Theme.setTextScale(1)
        super.tearDown()
    }

    /// A pessimistic count label: four digits of history and three of pins.
    private let worstCount = "9999 items · 999 pinned"

    /// What must never truncate: the number and the button. The privacy sentence
    /// between them carries `layoutPriority(-1)` and a tooltip, so it is the one
    /// that gives.
    func testTheCountAndClearButtonFitAtThePanelFloor() {
        for scale in [1.0, Theme.maxTextScale] {
            Theme.setTextScale(scale)
            let fixed = FilterRowMetrics.footerFixedWidth(count: worstCount, clear: "Sure?")
            XCTAssertLessThan(fixed, FilterRowMetrics.contentWidthAtPanelFloor,
                              "at textScale \(scale) the footer's fixed half is \(fixed)pt")
        }
    }

    /// The warning has its own line now, so it is measured against the whole
    /// width rather than against whatever the counts left over.
    func testTheAccessibilityWarningFitsOnItsOwnLine() {
        for scale in [1.0, Theme.maxTextScale] {
            Theme.setTextScale(scale)
            let warning = FilterRowMetrics.warningWidth("Auto-paste needs Accessibility")
            XCTAssertLessThan(warning, FilterRowMetrics.contentWidthAtPanelFloor,
                              "at textScale \(scale) the warning is \(warning)pt")
        }
    }

    /// And it would NOT have fitted inline, which is why it moved — measured
    /// with the whole row, privacy sentence included, since that is the row that
    /// actually existed.
    ///
    /// Worth knowing how close it is even now: without the sentence, the fixed
    /// half plus the warning comes to exactly 440 at maximum scale. The line has
    /// no slack left in it, which is why the warning gets a line of its own
    /// rather than a shorter string.
    func testInliningTheWarningWouldOverflowAtBothScales() {
        for scale in [1.0, Theme.maxTextScale] {
            Theme.setTextScale(scale)
            let inline = FilterRowMetrics.footerFixedWidth(count: worstCount, clear: "Sure?")
                + FilterRowMetrics.privacyWidth(" · nothing from a password manager")
                + FilterRowMetrics.warningWidth("Auto-paste needs Accessibility")
                + 8
            XCTAssertGreaterThan(inline, FilterRowMetrics.contentWidthAtPanelFloor,
                                 "inline footer at textScale \(scale) is \(inline)pt")
        }
    }
}
