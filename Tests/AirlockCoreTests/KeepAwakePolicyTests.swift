import XCTest
@testable import AirlockCore

final class KeepAwakePolicyTests: XCTestCase {
    private static let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    func testNeverStopsWithTheCutoffOff() {
        XCTAssertFalse(KeepAwakePolicy.shouldStop(cutoff: 0, percentage: 1, onBattery: true))
    }

    /// Plugged in is not going flat, whatever the level says.
    func testNeverStopsOnPower() {
        XCTAssertFalse(KeepAwakePolicy.shouldStop(cutoff: 20, percentage: 5, onBattery: false))
    }

    /// A Mac with no battery reports no percentage, and never stops.
    func testNeverStopsWithoutABattery() {
        XCTAssertFalse(KeepAwakePolicy.shouldStop(cutoff: 20, percentage: nil, onBattery: true))
    }

    /// "Below", so the level that was picked is still allowed.
    func testStopsBelowTheCutoffAndNotAtIt() {
        XCTAssertFalse(KeepAwakePolicy.shouldStop(cutoff: 20, percentage: 20, onBattery: true))
        XCTAssertTrue(KeepAwakePolicy.shouldStop(cutoff: 20, percentage: 19, onBattery: true))
    }

    func testARefusedStartSaysWhyAndWhatToDo() {
        XCTAssertNil(KeepAwakePolicy.refusal(cutoff: 20, percentage: 40, onBattery: true))
        let refusal = KeepAwakePolicy.refusal(cutoff: 20, percentage: 12, onBattery: true)
        XCTAssertTrue(refusal?.contains("20%") == true)
        XCTAssertTrue(refusal?.contains("Plug in") == true)
    }

    /// Unseen news stays however old it is; seen news goes after a few minutes.
    func testTheStoppedLineStaysUntilSeenThenGoes() {
        let now = Self.anchor
        XCTAssertTrue(KeepAwakePolicy.keepsStoppedNotice(firstSeenAt: nil, now: now))
        XCTAssertTrue(KeepAwakePolicy.keepsStoppedNotice(firstSeenAt: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(KeepAwakePolicy.keepsStoppedNotice(
            firstSeenAt: now.addingTimeInterval(-KeepAwakePolicy.stoppedNoticeAfterSeen), now: now))
        XCTAssertTrue(KeepAwakePolicy.keepsStoppedNotice(firstSeenAt: now.addingTimeInterval(60), now: now),
                      "a clock that went backwards keeps the line")
    }

    /// The feature is "keep awake"; the hyphenated form is not one of its names.
    func testTheSentencesUseTheFeaturesName() {
        XCTAssertFalse(KeepAwakePolicy.stoppedMessage(cutoff: 20).contains("Keep-awake"))
        XCTAssertFalse(KeepAwakePolicy.refusal(cutoff: 20, percentage: 12, onBattery: true)?
            .contains("keep-awake") ?? true)
    }

    func testTheChoicesStartWithNever() {
        XCTAssertEqual(KeepAwakePolicy.cutoffChoices.first, 0)
    }

    // MARK: - While an agent works (card Awake 1)

    func testBusyWhileWorkingAndForTheLingerAfter() {
        let now = Self.anchor
        XCTAssertTrue(KeepAwakePolicy.agentsBusy(working: true, lastWorkedAt: nil, now: now))
        XCTAssertFalse(KeepAwakePolicy.agentsBusy(working: false, lastWorkedAt: nil, now: now))
        XCTAssertTrue(KeepAwakePolicy.agentsBusy(working: false, lastWorkedAt: now.addingTimeInterval(-60),
                                                 now: now))
        XCTAssertFalse(KeepAwakePolicy.agentsBusy(working: false,
                                                  lastWorkedAt: now.addingTimeInterval(-KeepAwakePolicy.agentLinger),
                                                  now: now))
        // A clock stepping backwards ends the linger rather than stretching it.
        XCTAssertFalse(KeepAwakePolicy.agentsBusy(working: false, lastWorkedAt: now.addingTimeInterval(600),
                                                  now: now))
    }

    /// The card's defaults: plugged in yes, battery no.
    func testPluggedInByDefaultNotOnBattery() {
        XCTAssertTrue(KeepAwakePolicy.holdsForAgents(enabled: true, onBatteryToo: false, busy: true,
                                                     cutoff: 0, percentage: 80, onBattery: false))
        XCTAssertFalse(KeepAwakePolicy.holdsForAgents(enabled: true, onBatteryToo: false, busy: true,
                                                      cutoff: 0, percentage: 80, onBattery: true))
    }

    func testOnBatteryWhenAskedAndAboveTheCutoff() {
        XCTAssertTrue(KeepAwakePolicy.holdsForAgents(enabled: true, onBatteryToo: true, busy: true,
                                                     cutoff: 20, percentage: 40, onBattery: true))
        XCTAssertFalse(KeepAwakePolicy.holdsForAgents(enabled: true, onBatteryToo: true, busy: true,
                                                      cutoff: 20, percentage: 15, onBattery: true))
    }

    func testNeverWhenOffOrIdle() {
        XCTAssertFalse(KeepAwakePolicy.holdsForAgents(enabled: false, onBatteryToo: true, busy: true,
                                                      cutoff: 0, percentage: 80, onBattery: false))
        XCTAssertFalse(KeepAwakePolicy.holdsForAgents(enabled: true, onBatteryToo: true, busy: false,
                                                      cutoff: 0, percentage: 80, onBattery: false))
    }

    // MARK: - The island

    private func input(stoppedSecondsAgo: TimeInterval?, _ build: (inout CompactIslandInput) -> Void = { _ in })
        -> CompactIslandInput {
        var i = CompactIslandInput(now: Self.anchor,
                                   keepAwakeStoppedAt: stoppedSecondsAgo.map { Self.anchor.addingTimeInterval(-$0) },
                                   keepAwakeCutoff: 20)
        build(&i)
        return i
    }

    func testTheIslandSaysSoAndSummonsItself() {
        let i = input(stoppedSecondsAgo: 5)
        XCTAssertEqual(CompactIsland.trailing(i), .keepAwakeStopped(cutoff: 20))
        XCTAssertTrue(CompactIsland.hasContent(i))
    }

    func testTheNoticeEnds() {
        let i = input(stoppedSecondsAgo: CompactIsland.keepAwakeStopNotice)
        XCTAssertEqual(CompactIsland.trailing(i), .empty)
        XCTAssertFalse(CompactIsland.hasContent(i))
    }

    /// A clock stepping backwards must not hold a thirty-second notice forever.
    func testAStampInTheFutureShowsNothing() {
        XCTAssertEqual(CompactIsland.trailing(input(stoppedSecondsAgo: -60)), .empty)
    }

    /// The critical battery it is usually the cause of waits its turn.
    func testItOutranksTheCriticalBatteryButNotAGate() {
        XCTAssertEqual(CompactIsland.trailing(input(stoppedSecondsAgo: 5) { $0.batteryCritical = true }),
                       .keepAwakeStopped(cutoff: 20))
        XCTAssertEqual(CompactIsland.trailing(input(stoppedSecondsAgo: 5) { $0.attentionCount = 1 }),
                       .attentionDot)
    }
}
