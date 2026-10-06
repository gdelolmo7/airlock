import XCTest
@testable import AirlockCore

final class MediaSeekTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func seek(to target: TimeInterval = 90) -> MediaSeek {
        MediaSeek(target: target, requestedAt: t0)
    }

    // MARK: - What the drop says the playhead is doing

    func testAPausedPlayerStaysWhereItWasPut() {
        XCTAssertEqual(seek().expectedPosition(at: t0 + 10, isPlaying: false), 90)
    }

    func testAPlayingPlayerHasKeptRunningSinceTheDrop() {
        XCTAssertEqual(seek().expectedPosition(at: t0 + 10, isPlaying: true), 100)
    }

    /// A seek to the very start, judged against a reading taken a moment
    /// earlier, would otherwise expect a negative position.
    func testTheExpectationNeverGoesNegative() {
        XCTAssertEqual(seek(to: 0).expectedPosition(at: t0 - 5, isPlaying: true), 0)
    }

    // MARK: - The failure this type exists for

    /// The poll that was already in flight when the thumb was released. It
    /// carries the position from before the drag and, adopted, yanks the
    /// playhead back to it.
    func testAReadingFromBeforeTheSeekIsNotBelieved() {
        XCTAssertEqual(
            seek().verdict(reported: 12, reportedAt: t0 - 0.2, isPlaying: true, sameTrack: true),
            .hold)
    }

    /// Same reading, arriving after the request rather than before it: still
    /// nowhere near where the drop put the playhead.
    func testAStalePositionAfterTheSeekIsNotBelievedEither() {
        XCTAssertEqual(
            seek().verdict(reported: 12, reportedAt: t0 + 0.4, isPlaying: true, sameTrack: true),
            .hold)
    }

    // MARK: - Ordinary confirmation

    func testThePlayerArrivingWhereItWasSentConfirms() {
        XCTAssertEqual(
            seek().verdict(reported: 90.3, reportedAt: t0 + 0.3, isPlaying: true, sameTrack: true),
            .confirmed)
    }

    /// Confirmation is judged against the MOVING expectation, not the target:
    /// two seconds after a drop the player should be two seconds past it, and
    /// comparing against the bare target would refuse a perfectly good report.
    func testConfirmationFollowsThePlayheadRatherThanTheTarget() {
        XCTAssertEqual(
            seek().verdict(reported: 92, reportedAt: t0 + 2, isPlaying: true, sameTrack: true),
            .confirmed)
        XCTAssertEqual(
            seek().verdict(reported: 90.9, reportedAt: t0 + 2, isPlaying: true, sameTrack: true),
            .confirmed,
            "and the tolerance still covers the round trip: the position was "
            + "sampled inside the player before the Apple event came back, so a "
            + "report always lags its own timestamp a little")
        XCTAssertEqual(
            seek().verdict(reported: 90, reportedAt: t0 + 2, isPlaying: true, sameTrack: true),
            .hold,
            "two full seconds behind the playhead is not lag, it is the old "
            + "position — which is what a stale poll looks like once the "
            + "expectation has moved on")
    }

    func testAPausedPlayerConfirmsWithoutMoving() {
        XCTAssertEqual(
            seek().verdict(reported: 90, reportedAt: t0 + 3, isPlaying: false, sameTrack: true),
            .confirmed)
    }

    /// The edge, stated so a tolerance change has to come here first.
    func testTheToleranceIsInclusive() {
        let atEdge = 90 + MediaSeek.tolerance
        XCTAssertEqual(
            seek().verdict(reported: atEdge, reportedAt: t0, isPlaying: false, sameTrack: true),
            .confirmed)
        XCTAssertEqual(
            seek().verdict(reported: atEdge + 0.01, reportedAt: t0, isPlaying: false, sameTrack: true),
            .hold)
    }

    // MARK: - Letting go

    /// A player that never took the seek — an ad, a stream, a scripting
    /// interface that shrugged. Suppressing forever would freeze the bar at a
    /// position nothing is playing from.
    func testPatienceRunsOut() {
        let justBefore = t0 + MediaSeek.patience - 0.01
        XCTAssertEqual(
            seek().verdict(reported: 12, reportedAt: justBefore, isPlaying: true, sameTrack: true),
            .hold)
        XCTAssertEqual(
            seek().verdict(reported: 12, reportedAt: t0 + MediaSeek.patience,
                           isPlaying: true, sameTrack: true),
            .abandoned)
    }

    // MARK: - Letting go with nothing to go on

    /// The failure that made `patience` decorative: a PAUSED player that refused
    /// the seek. It posts no change notification and the drift poll skips it, so
    /// `verdict` is never called even once and the bar stays frozen at a
    /// position nothing is playing from. Silence has to be answerable too.
    func testPatienceRunsOutWithNoReportAtAll() {
        XCTAssertEqual(seek().verdictWithoutReport(at: t0 + MediaSeek.patience), .abandoned)
    }

    func testSilenceBeforeTheDeadlineIsStillWorthWaitingOut() {
        XCTAssertEqual(seek().verdictWithoutReport(at: t0), .hold)
        XCTAssertEqual(seek().verdictWithoutReport(at: t0 + MediaSeek.patience - 0.01), .hold)
    }

    /// Silence is never agreement, however long it lasts. A `.confirmed` from
    /// here would leave the optimistic position on screen as if the player had
    /// taken it, which is the frozen bar with a different name.
    func testSilenceCanNeverConfirm() {
        for offset in [-1, 0, 1, 4, 400] as [TimeInterval] {
            XCTAssertNotEqual(seek().verdictWithoutReport(at: t0 + offset), .confirmed, "\(offset)")
        }
    }

    /// The two arms agree on the instant, so a caller that sleeps out
    /// `patienceRemaining` and then asks `verdictWithoutReport` cannot wake one
    /// tick early and go back to sleep forever.
    func testTheDeadlineIsTheSameInstantAReportWouldBeJudgedAgainst() {
        XCTAssertEqual(seek().deadline, t0 + MediaSeek.patience)
        XCTAssertEqual(
            seek().verdict(reported: 12, reportedAt: seek().deadline,
                           isPlaying: true, sameTrack: true),
            .abandoned)
        XCTAssertEqual(seek().verdictWithoutReport(at: seek().deadline), .abandoned)
    }

    /// What the caller's timer sleeps on. Never negative — a `Task.sleep` on a
    /// deadline already past must fire at once rather than throw or wait out a
    /// wrapped-around duration.
    func testWhatIsLeftToWaitIsNeverNegative() {
        XCTAssertEqual(seek().patienceRemaining(at: t0), MediaSeek.patience)
        XCTAssertEqual(seek().patienceRemaining(at: t0 + 1), MediaSeek.patience - 1)
        XCTAssertEqual(seek().patienceRemaining(at: t0 + MediaSeek.patience), 0)
        XCTAssertEqual(seek().patienceRemaining(at: t0 + 3_600), 0)
    }

    /// Seeking past the end, or `next` arriving while we wait. Holding the old
    /// track's position onto a new one is a lie the bar must not tell, and it
    /// outranks patience — there is no longer anything to confirm.
    func testADifferentTrackEndsTheSuppressionImmediately() {
        XCTAssertEqual(
            seek().verdict(reported: 0, reportedAt: t0 + 0.1, isPlaying: true, sameTrack: false),
            .abandoned)
    }

    func testADifferentTrackOutranksEvenAReadingFromBeforeTheSeek() {
        XCTAssertEqual(
            seek().verdict(reported: 0, reportedAt: t0 - 1, isPlaying: true, sameTrack: false),
            .abandoned)
    }
}
