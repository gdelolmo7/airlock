import XCTest
@testable import AirlockCore

/// The room the System section's list of apps is offered. Heights are the
/// list's own at text size 1: an 8pt gap, a 13pt caption, then 19pt a line
/// (a 16pt row and 3pt between rows), so one line is 40pt and four are 97pt.
///
/// The owner's setup is the case that was broken: System in the trailing
/// column under the calendar, beside a leading column that can be taller.
final class PanelStackLayoutTests: XCTestCase {
    private typealias Region = PanelStackLayout.Region

    private let budget: CGFloat = 500

    private func listHeight(lines: Int) -> CGFloat {
        lines == 0 ? 0 : 8 + 13 + CGFloat(lines) * 19
    }

    /// What the list does with a room: the most lines that fit, up to four.
    private func lines(fitting room: CGFloat) -> Int {
        (0...4).last { listHeight(lines: $0) <= room } ?? 0
    }

    /// A stack reported the way the panel reports one: the list's own height,
    /// claimed by the column it sits in; each column, list included; and the
    /// whole stack. `outside` is everything in the stack that is not in the
    /// paired columns — the full-width band and the gaps — without the list;
    /// `leading` and `trailing` are the columns without the list.
    private func measured(tab: String = "home", outside: CGFloat, leading: CGFloat = 0,
                          trailing: CGFloat = 0, list: CGFloat, in region: Region) -> PanelStackLayout {
        let leadingColumn = leading + (region == .leading ? list : 0)
        let trailingColumn = trailing + (region == .trailing ? list : 0)
        let stack = outside + (region == .fullWidth ? list : 0) + max(leadingColumn, trailingColumn)

        var claimed = PanelStackLayout.yielding(list)
        claimed.claimYielding(for: region)
        var layout = PanelStackLayout.stack(stack, tab: tab)
        layout.merge(claimed)
        if leadingColumn > 0 { layout.merge(.column(.leading, height: leadingColumn)) }
        if trailingColumn > 0 { layout.merge(.column(.trailing, height: trailingColumn)) }
        return layout
    }

    private func room(_ layout: PanelStackLayout, in region: Region, tab: String = "home") -> CGFloat {
        layout.yieldingRoom(in: region, budget: budget, tab: tab)
    }

    // MARK: - The full-width band

    /// Every row there goes onto the stack, so the list gets the budget less
    /// everything else — which is what the whole stack used to be given.
    func testFullWidthBandIsTheBudgetLessEverythingElse() {
        let roomy = measured(outside: 380, list: listHeight(lines: 4), in: .fullWidth)
        XCTAssertEqual(room(roomy, in: .fullWidth), 120)
        XCTAssertEqual(lines(fitting: room(roomy, in: .fullWidth)), 4)

        let tight = measured(outside: 450, list: listHeight(lines: 4), in: .fullWidth)
        XCTAssertEqual(room(tight, in: .fullWidth), 50)
        XCTAssertEqual(lines(fitting: room(tight, in: .fullWidth)), 1)

        let over = measured(outside: 520, list: listHeight(lines: 4), in: .fullWidth)
        XCTAssertEqual(room(over, in: .fullWidth), 0, "never negative")
    }

    /// A column on its own spans the panel, and its rows go onto the stack
    /// exactly as the band's do.
    func testALoneColumnIsTheFullWidthRule() {
        let lone = measured(outside: 68, trailing: 360, list: listHeight(lines: 4), in: .trailing)
        let band = measured(outside: 68 + 360, list: listHeight(lines: 4), in: .fullWidth)
        XCTAssertEqual(room(lone, in: .trailing), room(band, in: .fullWidth))
        XCTAssertEqual(room(lone, in: .trailing), 72)
    }

    // MARK: - A column

    /// When the list's column is the taller one, its rows lengthen the stack,
    /// and it gives way at the budget.
    func testListInTheTallerColumnGivesWayAtTheBudget() {
        let roomy = measured(outside: 68, leading: 200, trailing: 300,
                             list: listHeight(lines: 4), in: .trailing)
        XCTAssertEqual(room(roomy, in: .trailing), 500 - 68 - 300)
        XCTAssertEqual(lines(fitting: room(roomy, in: .trailing)), 4)

        let tight = measured(outside: 68, leading: 200, trailing: 380,
                             list: listHeight(lines: 4), in: .trailing)
        XCTAssertEqual(room(tight, in: .trailing), 52)
        XCTAssertEqual(lines(fitting: room(tight, in: .trailing)), 1,
                       "the stack stops at the budget: 68 + 380 + 40 is 488, and a second line is 507")
    }

    /// The owner's case with the other column inside the budget but taller
    /// than System's. The list's rows are free up to the other column, and
    /// allowed past it up to the budget. The estimate this replaced counted
    /// the other column against them: with the list at its one "Measuring…"
    /// line it offered 500 − (68 + 420 − 21) = 33pt, under a line, and the list
    /// never appeared.
    func testListInTheShorterColumnKeepsTheSlackBesideIt() {
        let measuring = measured(outside: 68, leading: 420, trailing: 60, list: 21, in: .trailing)
        XCTAssertEqual(room(measuring, in: .trailing), 500 - 68 - 60)
        XCTAssertEqual(lines(fitting: room(measuring, in: .trailing)), 4)
    }

    /// The other column alone is past the budget, so the tab scrolls whatever
    /// the list does. The list is not what made it scroll, and may grow as far
    /// as the other column reaches — but not past it, where its rows would
    /// lengthen a scroll that is already there.
    func testOtherColumnOverTheBudgetLeavesTheListItsHeight() {
        let beside = measured(outside: 68, leading: 600, trailing: 60,
                              list: listHeight(lines: 4), in: .trailing)
        XCTAssertEqual(room(beside, in: .trailing), 540)
        XCTAssertEqual(lines(fitting: room(beside, in: .trailing)), 4)

        let level = measured(outside: 68, leading: 600, trailing: 550,
                             list: listHeight(lines: 4), in: .trailing)
        XCTAssertEqual(room(level, in: .trailing), 50)
        XCTAssertEqual(lines(fitting: room(level, in: .trailing)), 1,
                       "550 + 40 stays inside the other column's 600; 550 + 59 would not")
    }

    /// Mirrored: the rule is the column's, not the trailing side's.
    func testTheLeadingColumnIsTheSameRule() {
        let leading = measured(outside: 68, leading: 60, trailing: 600,
                               list: listHeight(lines: 4), in: .leading)
        XCTAssertEqual(room(leading, in: .leading), 540)
    }

    // MARK: - No feedback

    /// A list that went, measured while it was gone. The old estimate kept it
    /// gone: with no rows to subtract, the room stayed under a row forever.
    /// Here the room is what it was while the list was drawn, so the rows come
    /// back the moment there is something to show.
    func testAHiddenListComesBackWhenItsRowsCostNothing() {
        let gone = measured(outside: 68, leading: 600, trailing: 60, list: 0, in: .trailing)
        XCTAssertEqual(lines(fitting: room(gone, in: .trailing)), 4)

        let goneFromTheBand = measured(outside: 450, list: 0, in: .fullWidth)
        XCTAssertEqual(lines(fitting: room(goneFromTheBand, in: .fullWidth)), 1)
    }

    /// The property all of the above rests on: the room is worked out from
    /// heights that are not the list's, so whatever the list did last layout,
    /// the next is offered the same room and draws the same list. Heights that
    /// are not whole points, so the cancelling is tested in floating point too.
    func testTheRoomIsTheSameWhateverTheListDid() {
        let drawn: [CGFloat] = [0, 21, listHeight(lines: 1), listHeight(lines: 2),
                                listHeight(lines: 3), listHeight(lines: 4)]
        for region in [Region.fullWidth, .leading, .trailing] {
            for (leading, trailing) in [(431.7, 58.9), (58.9, 431.7), (613.3, 58.9), (58.9, 613.3)] {
                let rooms = drawn.map { list in
                    room(measured(outside: 61.3, leading: leading, trailing: trailing, list: list, in: region),
                         in: region)
                }
                XCTAssertEqual(Set(rooms).count, 1, "\(region), columns \(leading) and \(trailing): \(rooms)")
            }
        }
    }

    // MARK: - Measured when

    /// The first layout after a tab switch still holds the last tab's
    /// measurement. It is no limit at all: the new tab draws its natural list,
    /// and its own measurement takes rows away if they do not fit.
    func testAMeasurementOfAnotherTabIsNoLimit() {
        let agents = measured(tab: "agents", outside: 900, list: 0, in: .fullWidth)
        for region in [Region.fullWidth, .leading, .trailing] {
            XCTAssertEqual(room(agents, in: region, tab: "home"), .infinity, "\(region)")
        }
        let home = measured(tab: "home", outside: 68, leading: 600, trailing: 60, list: 0, in: .trailing)
        XCTAssertEqual(room(home, in: .trailing, tab: "home"), 540)
    }

    /// Nothing measured yet, or a stack with nothing in it (the widgets step
    /// aside while dictating): no limit either.
    func testNothingMeasuredIsNoLimit() {
        XCTAssertEqual(PanelStackLayout().yieldingRoom(in: .trailing, budget: budget, tab: "home"), .infinity)
        let empty = PanelStackLayout.stack(0, tab: "home")
        XCTAssertEqual(empty.yieldingRoom(in: .fullWidth, budget: budget, tab: "home"), .infinity)
    }

    // MARK: - Reporting

    /// The list cannot see where it sits, so it reports as full width and the
    /// column around it claims it. Two blocks add rather than one hiding the
    /// other; heights, each reported by one view, keep the one measured.
    func testReportsMergeAndAColumnClaimsItsList() {
        var inColumn = PanelStackLayout.yielding(59)
        inColumn.merge(.column(.trailing, height: 180))
        inColumn.claimYielding(for: .trailing)
        XCTAssertEqual(inColumn.yieldingTrailing, 59)
        XCTAssertEqual(inColumn.yieldingFullWidth, 0)
        XCTAssertEqual(inColumn.trailingColumn, 180, "a claim moves the list, not the column")

        var inBand = PanelStackLayout.yielding(59)
        inBand.claimYielding(for: .fullWidth)
        XCTAssertEqual(inBand.yieldingFullWidth, 59)

        var stack = PanelStackLayout.stack(420, tab: "home")
        stack.merge(inColumn)
        stack.merge(.column(.leading, height: 300))
        stack.merge(.yielding(21))
        XCTAssertEqual(stack.tab, "home")
        XCTAssertEqual(stack.stack, 420)
        XCTAssertEqual(stack.leadingColumn, 300)
        XCTAssertEqual(stack.trailingColumn, 180)
        XCTAssertEqual(stack.yieldingTrailing, 59)
        XCTAssertEqual(stack.yieldingFullWidth, 21)
    }
}
