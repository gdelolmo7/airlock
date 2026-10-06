import XCTest
@testable import AirlockCore

/// The list under the meters. What it must never do: show more than the meter
/// above it, lose load, show a line under 1%, reorder itself over noise, or put
/// the leftover above an app.
final class CPUBreakdownTests: XCTestCase {

    private let xcode = ProcessGroup(kind: .app, name: "Xcode")
    private let chrome = ProcessGroup(kind: .app, name: "Google Chrome")
    private let spotify = ProcessGroup(kind: .app, name: "Spotify")
    private let claude = ProcessGroup(kind: .app, name: "Claude")
    private let node = ProcessGroup(kind: .program, name: "node")

    private func names(_ breakdown: CPUBreakdown) -> [String] {
        breakdown.lines.map { breakdown.name(of: $0) }
    }

    private func shares(_ breakdown: CPUBreakdown) -> [Double] {
        breakdown.lines.map(\.share)
    }

    private func rankOnce(_ shares: [ProcessGroup: Double], headline: Double) -> CPUBreakdown {
        var ranker = CPUBreakdownRanker()
        return ranker.rank(shares: shares, headline: headline)
    }

    // MARK: - One unit: share of the whole Mac

    /// Three CPU-seconds in two seconds on fifteen cores is 10% of the Mac,
    /// not "150%".
    func testSharesArePercentOfEveryCoresWorthOfTheWindow() {
        let result = CPUBreakdown.shares(seconds: [xcode: 3, node: 1.5], window: 2, processors: 15)
        XCTAssertEqual(result[xcode] ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(result[node] ?? 0, 5, accuracy: 1e-9)
    }

    func testSharesDropWhatIsNotAFigure() {
        let result = CPUBreakdown.shares(seconds: [xcode: .nan, node: -1, chrome: 0, spotify: .infinity],
                                         window: 2, processors: 15)
        XCTAssertEqual(result, [:])
        XCTAssertEqual(CPUBreakdown.shares(seconds: [xcode: 3], window: 0, processors: 15), [:])
        XCTAssertEqual(CPUBreakdown.shares(seconds: [xcode: 3], window: 2, processors: 0), [:])
    }

    // MARK: - The leftover: load does not vanish

    func testTheLeftoverIsWhateverTheRowsDoNotAccountFor() {
        let breakdown = rankOnce([xcode: 30, chrome: 10, node: 0.4], headline: 50)
        XCTAssertEqual(names(breakdown), ["Xcode", "Google Chrome", CPUBreakdown.backgroundName])
        XCTAssertEqual(breakdown.lines.last?.share ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(shares(breakdown).reduce(0, +), 50, accuracy: 1e-9)
    }

    /// The leftover is not an app, and the list is read for the apps: it goes
    /// under them, however big it is.
    func testTheLeftoverGoesUnderTheAppsWhateverItsSize() {
        let breakdown = rankOnce([xcode: 30, chrome: 4], headline: 70)
        XCTAssertEqual(names(breakdown), ["Xcode", "Google Chrome", CPUBreakdown.backgroundName])
        XCTAssertEqual(breakdown.lines.last?.share ?? 0, 36, accuracy: 1e-9)
    }

    /// Bigger than every app, at every length a panel can offer: the apps from
    /// the top of the ranking, then the leftover. At one line an app would have
    /// to fold into a lone "Everything else", which is no list at all.
    func testALeftoverBiggerThanEveryAppIsLastAtEveryLength() {
        let breakdown = rankOnce([xcode: 20, chrome: 8, spotify: 5], headline: 80)
        let expected: [[String]] = [
            [],
            ["Xcode", CPUBreakdown.everythingElseName],
            ["Xcode", "Google Chrome", CPUBreakdown.everythingElseName],
            ["Xcode", "Google Chrome", "Spotify", CPUBreakdown.backgroundName],
        ]
        XCTAssertEqual(expected.count, CPUBreakdown.maximumLines)
        for length in 1...CPUBreakdown.maximumLines {
            let fitted = breakdown.fitted(maxLines: length)
            XCTAssertEqual(names(fitted), expected[length - 1], "\(length) lines")
            guard let last = fitted.lines.last else { continue }
            XCTAssertTrue(last.isLeftover, "\(length) lines")
            XCTAssertTrue(fitted.lines.dropLast().allSatisfy { !$0.isLeftover && $0.share < last.share },
                          "\(length) lines: every app above it is smaller")
        }
    }

    func testTheLeftoverIsHiddenBelowTheThresholdAndNeverNegative() {
        let under = rankOnce([xcode: 30], headline: 30.9)
        XCTAssertEqual(names(under), ["Xcode"])
        // Shares that add up to more than the headline: separate measurements,
        // milliseconds apart. Scaled down, with no negative leftover.
        let over = rankOnce([xcode: 30, chrome: 20], headline: 40)
        XCTAssertEqual(names(over), ["Xcode", "Google Chrome"])
        XCTAssertTrue(over.lines.allSatisfy { $0.share >= 0 })
        XCTAssertLessThanOrEqual(shares(over).reduce(0, +), 40 + 1e-9)
        XCTAssertEqual(over.lines[0].share, 24, accuracy: 1e-9)
    }

    /// The fourth app is inside the leftover, so the leftover is not only macOS
    /// any more and says so.
    func testAppsPastTheCapAreInTheLeftoverAndRenameIt() {
        let breakdown = rankOnce([xcode: 30, chrome: 10, claude: 8, spotify: 3], headline: 60)
        XCTAssertEqual(breakdown.lines.filter { !$0.isLeftover }.count, CPUBreakdown.maximumApps)
        XCTAssertFalse(names(breakdown).contains("Spotify"))
        XCTAssertEqual(breakdown.lines.first { $0.isLeftover }?.share ?? 0, 12, accuracy: 1e-9)
        XCTAssertEqual(breakdown.leftoverName, CPUBreakdown.everythingElseName)
    }

    func testWithEveryListableAppShownTheLeftoverIsMacOS() {
        let breakdown = rankOnce([xcode: 30, chrome: 0.5, spotify: 0.4], headline: 40)
        XCTAssertEqual(breakdown.leftoverName, CPUBreakdown.backgroundName)
    }

    /// A fourth app hovering at 1% would otherwise rename the line every few
    /// seconds. Once it has held an app it keeps the vaguer, always-true name
    /// until the panel closes.
    func testTheLeftoverKeepsItsVaguerNameUntilThePanelCloses() {
        var ranker = CPUBreakdownRanker()
        let crowded: [ProcessGroup: Double] = [xcode: 30, chrome: 10, claude: 8, spotify: 1.1]
        XCTAssertEqual(ranker.rank(shares: crowded, headline: 60).leftoverName, CPUBreakdown.everythingElseName)
        let quieter: [ProcessGroup: Double] = [xcode: 30, chrome: 10, claude: 8, spotify: 0.9]
        XCTAssertEqual(ranker.rank(shares: quieter, headline: 60).leftoverName, CPUBreakdown.everythingElseName)
        ranker.forget()
        XCTAssertEqual(ranker.rank(shares: quieter, headline: 60).leftoverName, CPUBreakdown.backgroundName)
    }

    // MARK: - The 1% threshold

    func testALineUnderOnePercentIsNotShown() {
        let breakdown = rankOnce([xcode: 0.99, chrome: 1.0], headline: 5)
        XCTAssertEqual(names(breakdown), ["Google Chrome", CPUBreakdown.backgroundName])
        XCTAssertFalse(names(breakdown).contains("Xcode"))
    }

    /// No rows and no filler text: an empty list, which the panel does not draw.
    func testAnIdleMacHasAnEmptyList() {
        XCTAssertTrue(rankOnce([xcode: 0.3, node: 0.2], headline: 0.8).isEmpty)
        XCTAssertTrue(rankOnce([:], headline: 0).isEmpty)
        XCTAssertTrue(rankOnce([xcode: 5], headline: .nan).isEmpty)
    }

    /// A quiet Mac whose load is all macOS's own says exactly that.
    func testLoadThatIsAllMacOSIsOneLine() {
        let breakdown = rankOnce([xcode: 0.3], headline: 4)
        XCTAssertEqual(names(breakdown), [CPUBreakdown.backgroundName])
    }

    // MARK: - Stable ordering

    func testTheFirstReadingIsOrderedBySizeThenName() {
        let breakdown = rankOnce([spotify: 5, chrome: 5, xcode: 9], headline: 19)
        XCTAssertEqual(names(breakdown), ["Xcode", "Google Chrome", "Spotify"])
    }

    func testRowsDoNotSwapOverLessThanAPoint() {
        var ranker = CPUBreakdownRanker()
        XCTAssertEqual(names(ranker.rank(shares: [xcode: 10.5, chrome: 10], headline: 20.5)),
                       ["Xcode", "Google Chrome"])
        XCTAssertEqual(names(ranker.rank(shares: [xcode: 10, chrome: 10.9], headline: 20.9)),
                       ["Xcode", "Google Chrome"])
        // A whole point is a real lead.
        XCTAssertEqual(names(ranker.rank(shares: [xcode: 10, chrome: 11], headline: 21)),
                       ["Google Chrome", "Xcode"])
        // And the new order is held the same way.
        XCTAssertEqual(names(ranker.rank(shares: [xcode: 10.8, chrome: 10.1], headline: 20.9)),
                       ["Google Chrome", "Xcode"])
    }

    /// The row cap is where jitter would hurt most: two apps taking turns at
    /// the third row. The fourth has to lead by a point to take it.
    func testAFourthAppHasToLeadByAPointToTakeTheLastRow() {
        var ranker = CPUBreakdownRanker()
        let first = ranker.rank(shares: [xcode: 20, chrome: 10, spotify: 5.5, node: 5], headline: 45)
        XCTAssertTrue(names(first).contains("Spotify"))
        XCTAssertFalse(names(first).contains("node"))
        let jitter = ranker.rank(shares: [xcode: 20, chrome: 10, spotify: 5.5, node: 6.2], headline: 45)
        XCTAssertTrue(names(jitter).contains("Spotify"))
        let lead = ranker.rank(shares: [xcode: 20, chrome: 10, spotify: 5.5, node: 6.6], headline: 45)
        XCTAssertTrue(names(lead).contains("node"))
        XCTAssertFalse(names(lead).contains("Spotify"))
    }

    /// A group that is not in this reading's shares is not a row — whatever it
    /// was last time.
    func testAnAppThatStoppedLeavesNoGhostRow() {
        var ranker = CPUBreakdownRanker()
        _ = ranker.rank(shares: [xcode: 30, chrome: 10], headline: 45)
        let after = ranker.rank(shares: [xcode: 30], headline: 35)
        XCTAssertFalse(names(after).contains("Google Chrome"))
    }

    /// Reading after reading the leftover grows past each app and shrinks back,
    /// and never moves: the apps keep their places above it at every length.
    func testTheLeftoverStaysLastWhileItsSizeCrossesTheApps() {
        var ranker = CPUBreakdownRanker()
        let apps: [ProcessGroup: Double] = [xcode: 30, chrome: 10]
        let expected: [[String]] = [
            [],
            ["Xcode", CPUBreakdown.everythingElseName],
            ["Xcode", "Google Chrome", CPUBreakdown.backgroundName],
            ["Xcode", "Google Chrome", CPUBreakdown.backgroundName],
        ]
        // A leftover of 5, then past Chrome's 10, past Xcode's 30, and back.
        for headline in [45.0, 55, 75, 100, 55, 42] {
            let breakdown = ranker.rank(shares: apps, headline: headline)
            XCTAssertEqual(breakdown.lines.last?.share ?? 0, headline - 40, accuracy: 1e-9)
            for length in 1...CPUBreakdown.maximumLines {
                XCTAssertEqual(names(breakdown.fitted(maxLines: length)), expected[length - 1],
                               "a leftover of \(headline - 40) in \(length) lines")
            }
        }
    }

    // MARK: - Fitting a panel short of room

    func testFewerLinesFoldTheLowestRankedAppsIntoTheLeftover() {
        let full = rankOnce([xcode: 30, chrome: 10, spotify: 5], headline: 50)
        XCTAssertEqual(full.lines.count, 4)
        XCTAssertEqual(full.fitted(maxLines: 4), full)

        let three = full.fitted(maxLines: 3)
        XCTAssertEqual(names(three), ["Xcode", "Google Chrome", CPUBreakdown.everythingElseName])
        XCTAssertEqual(three.lines.last?.share ?? 0, 10, accuracy: 1e-9)

        let two = full.fitted(maxLines: 2)
        XCTAssertEqual(names(two), ["Xcode", CPUBreakdown.everythingElseName])
        XCTAssertEqual(shares(two).reduce(0, +), 50, accuracy: 1e-9)
    }

    /// One line of "Everything else" under a meter showing the same figure says
    /// nothing, so no list at all.
    func testNoRoomForAnAppAndTheLeftoverIsNoList() {
        let full = rankOnce([xcode: 30, chrome: 10], headline: 50)
        XCTAssertTrue(full.fitted(maxLines: 1).isEmpty)
        XCTAssertTrue(full.fitted(maxLines: 0).isEmpty)
        // Unless the leftover is under the threshold: then one app is the list.
        let single = rankOnce([xcode: 40], headline: 40.5)
        XCTAssertEqual(names(single.fitted(maxLines: 1)), ["Xcode"])
    }

    /// A fitted list's rows are the top of the one ranking, so a short panel is
    /// as steady as a tall one: two apps within a point do not take turns at
    /// its last row either, and a whole point still takes it.
    func testAFittedListIsAsSteadyAsAFullOne() {
        var ranker = CPUBreakdownRanker()
        let first = ranker.rank(shares: [xcode: 30, chrome: 12, spotify: 11.5], headline: 57).fitted(maxLines: 3)
        XCTAssertEqual(names(first), ["Xcode", "Google Chrome", CPUBreakdown.everythingElseName])
        let jitter = ranker.rank(shares: [xcode: 30, chrome: 12, spotify: 12.8], headline: 57).fitted(maxLines: 3)
        XCTAssertEqual(names(jitter), ["Xcode", "Google Chrome", CPUBreakdown.everythingElseName])
        let lead = ranker.rank(shares: [xcode: 30, chrome: 12, spotify: 13.1], headline: 57).fitted(maxLines: 3)
        XCTAssertEqual(names(lead), ["Xcode", "Spotify", CPUBreakdown.everythingElseName])
    }

    // MARK: - Whole numbers that add up

    func testDisplayedFiguresNeverAddUpToMoreThanTheMeter() {
        let breakdown = rankOnce([xcode: 20.5, chrome: 20.5], headline: 41)
        XCTAssertEqual(breakdown.displayedPercents.reduce(0, +), 41)
        XCTAssertEqual(Set(breakdown.displayedPercents), [20, 21])
    }

    func testDisplayedFiguresRoundToNearestWhenTheyCan() {
        let breakdown = rankOnce([xcode: 30.4, chrome: 9.6], headline: 45.2)
        XCTAssertEqual(breakdown.displayedPercents, [30, 10, 5])
    }

    // MARK: - The invariants, over many shapes

    /// A seeded sweep of random readings. Whatever the shares, every list and
    /// every fitted list: no more than the meter, no line under 1%, no app
    /// above one that leads it by a point, no more than three apps, the apps
    /// the full list's from the top, and the leftover under them.
    func testInvariantsHoldForManyRandomReadings() {
        var seed: UInt64 = 0x5EED
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let groups = (0..<9).map { ProcessGroup(kind: .program, name: "p\($0)") }
        var ranker = CPUBreakdownRanker()
        for _ in 0..<400 {
            let headline = next() * 100
            var reading: [ProcessGroup: Double] = [:]
            for group in groups where next() < 0.7 { reading[group] = next() * next() * 40 }
            let breakdown = ranker.rank(shares: reading, headline: headline)
            for maxLines in 0...CPUBreakdown.maximumLines {
                let fitted = breakdown.fitted(maxLines: maxLines)
                XCTAssertLessThanOrEqual(fitted.lines.count, maxLines)
                XCTAssertLessThanOrEqual(fitted.lines.filter { !$0.isLeftover }.count, CPUBreakdown.maximumApps)
                XCTAssertLessThanOrEqual(fitted.lines.filter(\.isLeftover).count, 1)
                XCTAssertLessThanOrEqual(shares(fitted).reduce(0, +), headline + 1e-9)
                XCTAssertTrue(fitted.lines.allSatisfy { $0.share >= CPUBreakdown.threshold })
                XCTAssertLessThanOrEqual(fitted.displayedPercents.reduce(0, +),
                                         CPUBreakdown.displayedPercent(of: headline))
                XCTAssertTrue(fitted.displayedPercents.allSatisfy { $0 >= 1 })
                let apps = fitted.lines.filter { !$0.isLeftover }
                for (index, line) in apps.enumerated() {
                    for below in apps[(index + 1)...] {
                        XCTAssertLessThan(below.share, line.share + CPUBreakdown.hysteresis)
                    }
                }
                XCTAssertEqual(apps.map(\.id), breakdown.lines.filter { !$0.isLeftover }.prefix(apps.count).map(\.id))
                if let leftover = fitted.lines.firstIndex(where: \.isLeftover) {
                    XCTAssertEqual(leftover, fitted.lines.count - 1, "the leftover is the last line")
                }
            }
        }
    }
}
