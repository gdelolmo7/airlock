import XCTest
@testable import AirlockCore

/// The heads-up near Claude's limit (card Agents 1): once per window, the
/// reset only after a warning, one notice at a time.
final class UsageAlertTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let fiveHourEnd = now.addingTimeInterval(2 * 3600)
    private static let weekEnd = now.addingTimeInterval(3 * 24 * 3600)

    private func snapshot(fiveHour: Double? = nil, sevenDay: Double? = nil) -> UsageSnapshot {
        UsageSnapshot(fiveHour: fiveHour.map { RateLimitWindow(usedPercentage: $0, resetsAt: Self.fiveHourEnd) },
                      sevenDay: sevenDay.map { RateLimitWindow(usedPercentage: $0, resetsAt: Self.weekEnd) },
                      capturedAt: Self.now)
    }

    private func evaluate(_ snapshot: UsageSnapshot?, _ memory: UsageAlert.Memory = .init(),
                          level: Int = 90, reset: Bool = false, at now: Date = now)
        -> (notice: UsageAlert.Notice?, memory: UsageAlert.Memory) {
        UsageAlert.evaluate(snapshot, memory: memory, level: level, announcesReset: reset, now: now)
    }

    func testWarnsAtTheLevelAndNotBelowIt() {
        XCTAssertNil(evaluate(snapshot(fiveHour: 89.9)).notice)
        XCTAssertEqual(evaluate(snapshot(fiveHour: 90)).notice, .nearLimit(.fiveHour, percent: 90))
    }

    /// The figure climbing inside the same window is not news again.
    func testOncePerWindow() {
        let first = evaluate(snapshot(fiveHour: 91))
        XCTAssertNotNil(first.notice)
        XCTAssertNil(evaluate(snapshot(fiveHour: 97), first.memory).notice)
    }

    /// Once the window ends, the next crossing is a new warning.
    func testTheNextWindowWarnsAgain() {
        let first = evaluate(snapshot(fiveHour: 91))
        let later = Self.fiveHourEnd.addingTimeInterval(60)
        let next = UsageSnapshot(fiveHour: RateLimitWindow(usedPercentage: 92,
                                                           resetsAt: later.addingTimeInterval(5 * 3600)),
                                 sevenDay: nil, capturedAt: later)
        XCTAssertEqual(evaluate(next, first.memory, at: later).notice, .nearLimit(.fiveHour, percent: 92))
    }

    func testNeverWithTheLevelOff() {
        XCTAssertNil(evaluate(snapshot(fiveHour: 100, sevenDay: 100), level: 0).notice)
    }

    /// A reading from a window that already ended describes nothing.
    func testARolledReadingNeverWarns() {
        XCTAssertNil(evaluate(snapshot(fiveHour: 99), at: Self.fiveHourEnd.addingTimeInterval(1)).notice)
    }

    /// Two due at once: the week first, the 5-hour one on the next ask.
    func testOneAtATimeTheWeekFirst() {
        let both = snapshot(fiveHour: 95, sevenDay: 92)
        let first = evaluate(both)
        XCTAssertEqual(first.notice, .nearLimit(.sevenDay, percent: 92))
        let second = evaluate(both, first.memory)
        XCTAssertEqual(second.notice, .nearLimit(.fiveHour, percent: 95))
        XCTAssertNil(evaluate(both, second.memory).notice)
    }

    func testTheResetIsSaidOnlyWhenAskedFor() {
        let warned = evaluate(snapshot(fiveHour: 91)).memory
        let after = Self.fiveHourEnd.addingTimeInterval(1)
        XCTAssertEqual(evaluate(nil, warned, reset: true, at: after).notice, .reset(.fiveHour))
        let quiet = evaluate(nil, warned, reset: false, at: after)
        XCTAssertNil(quiet.notice)
        // Forgotten, so switching it on later never announces an old reset.
        XCTAssertNil(evaluate(nil, quiet.memory, reset: true, at: after).notice)
    }

    func testTheResetIsSaidOnce() {
        let warned = evaluate(snapshot(fiveHour: 91)).memory
        let after = Self.fiveHourEnd.addingTimeInterval(1)
        let said = evaluate(nil, warned, reset: true, at: after)
        XCTAssertNotNil(said.notice)
        XCTAssertNil(evaluate(nil, said.memory, reset: true, at: after).notice)
    }

    /// A window that was never warned about resets without a word.
    func testNoResetWithoutAWarning() {
        XCTAssertNil(evaluate(snapshot(fiveHour: 40), reset: true,
                              at: Self.fiveHourEnd.addingTimeInterval(1)).notice)
    }

    /// No reset time in the reading: the window's nominal length stands in.
    func testAReadingWithoutAResetTimeStillCountsOnce() {
        let bare = UsageSnapshot(fiveHour: RateLimitWindow(usedPercentage: 93, resetsAt: nil),
                                 sevenDay: nil, capturedAt: Self.now)
        let first = evaluate(bare)
        XCTAssertNotNil(first.notice)
        XCTAssertNil(evaluate(bare, first.memory, at: Self.now.addingTimeInterval(4 * 3600)).notice)
        XCTAssertNotNil(evaluate(bare, first.memory, at: Self.now.addingTimeInterval(5 * 3600 + 1)).notice)
    }

    func testTheSentences() {
        XCTAssertEqual(UsageAlert.Notice.nearLimit(.fiveHour, percent: 90).sentence,
                       "Claude's 5-hour limit is 90% used")
        XCTAssertEqual(UsageAlert.Notice.reset(.sevenDay).sentence, "Claude's weekly limit has reset")
    }

    func testTheMemorySurvivesARelaunch() throws {
        let memory = evaluate(snapshot(fiveHour: 91)).memory
        let data = try JSONEncoder().encode(memory)
        XCTAssertEqual(try JSONDecoder().decode(UsageAlert.Memory.self, from: data), memory)
    }

    func testTheChoicesStartWithNeverAndOfferTheDefault() {
        XCTAssertEqual(UsageAlert.levelChoices.first, 0)
        XCTAssertTrue(UsageAlert.levelChoices.contains(UsageAlert.defaultLevel))
    }

    // MARK: - The island

    private func island(noticeSecondsAgo: TimeInterval,
                        _ build: (inout CompactIslandInput) -> Void = { _ in }) -> CompactIslandInput {
        var i = CompactIslandInput(now: Self.now,
                                   usageNotice: .nearLimit(.fiveHour, percent: 90),
                                   usageNoticeAt: Self.now.addingTimeInterval(-noticeSecondsAgo))
        build(&i)
        return i
    }

    func testTheIslandShowsItAndComesUpForIt() {
        let i = island(noticeSecondsAgo: 3)
        XCTAssertEqual(CompactIsland.trailing(i), .usageNotice(.nearLimit(.fiveHour, percent: 90)))
        XCTAssertTrue(CompactIsland.hasContent(i))
    }

    func testTheNoticeEnds() {
        let i = island(noticeSecondsAgo: CompactIsland.usageNoticeDuration)
        XCTAssertEqual(CompactIsland.trailing(i), .empty)
        XCTAssertFalse(CompactIsland.hasContent(i))
        XCTAssertEqual(CompactIsland.trailing(island(noticeSecondsAgo: -60)), .empty)
    }

    /// Above everything that lasts longer, below a gate and a running guide.
    func testWhereItRanks() {
        let notice = CompactSlot.usageNotice(.nearLimit(.fiveHour, percent: 90))
        XCTAssertEqual(CompactIsland.trailing(island(noticeSecondsAgo: 3) {
            $0.batteryCritical = true; $0.meetingSoon = true; $0.mediaPlaying = true; $0.keepingAwake = true
        }), notice)
        XCTAssertEqual(CompactIsland.trailing(island(noticeSecondsAgo: 3) { $0.attentionCount = 1 }),
                       .attentionDot)
    }

    func testItSpeaksThePercentage() {
        XCTAssertEqual(CompactSlot.usageNotice(.nearLimit(.sevenDay, percent: 95)).accessibilityLabel,
                       "Claude's weekly limit is 95% used")
    }

    /// The island draws how full, not "5h" — shorthand nothing explains.
    func testTheIslandDrawsThePercentageNotTheWindow() {
        XCTAssertEqual(UsageAlert.Notice.nearLimit(.fiveHour, percent: 90).compactLabel, "90%")
        XCTAssertNil(UsageAlert.Notice.reset(.sevenDay).compactLabel)
    }
}
