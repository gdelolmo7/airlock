import XCTest
@testable import AirlockCore

final class TapLifecycleTests: XCTestCase {
    func testOpensWhenSomethingStartsPlaying() {
        var lifecycle = TapLifecycle()
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false), .start)
    }

    func testLeavesARunningTapAlone() {
        var lifecycle = TapLifecycle()
        for _ in 0..<50 {
            XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: true), .hold)
        }
    }

    func testDoesNothingWhileNothingIsPlaying() {
        var lifecycle = TapLifecycle()
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: false), .hold)
    }

    // MARK: - The two failures this type exists for

    /// TOO EAGER. `fetchState` is an Apple event; one that times out leaves the
    /// state nil for a cycle. Believing a single missed read tore the tap down
    /// and rebuilt it every eight to sixteen seconds — three aggregate devices a
    /// minute, each rebuild resetting the envelope, so the wave kept starting
    /// its life over instead of following the music.
    func testASingleMissedReadIsNotAPause() {
        var lifecycle = TapLifecycle()
        _ = lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true), .hold)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: true), .hold,
                       "playback came back — nothing should have happened")
    }

    /// TOO RELUCTANT is the other side, and worse: a tap on a paused player
    /// holds a real-time thread and an aggregate device for as long as the app
    /// runs.
    func testThreeMissedReadsInARowIsAPause() {
        var lifecycle = TapLifecycle()
        _ = lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true), .hold)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true), .hold)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true), .stop)
    }

    /// The count is CONSECUTIVE. Two misses, a real read, then two more must not
    /// add up to a stop — otherwise a flaky player closes the tap eventually,
    /// however well it is actually playing.
    func testTheCountResetsOnAnyRealRead() {
        var lifecycle = TapLifecycle()
        _ = lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false)
        _ = lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true)
        _ = lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: true), .hold)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true), .hold)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true), .hold,
                       "the earlier misses were forgiven")
    }

    // MARK: - Switching the feature off

    func testDisablingClosesAnOpenTapImmediately() {
        var lifecycle = TapLifecycle()
        _ = lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false)
        XCTAssertEqual(lifecycle.evaluate(enabled: false, isPlaying: true, isRunning: true), .stop,
                       "switched off is a decision, not a missed read")
    }

    func testDisabledWithNoTapIsQuiet() {
        var lifecycle = TapLifecycle()
        XCTAssertEqual(lifecycle.evaluate(enabled: false, isPlaying: false, isRunning: false), .hold)
        XCTAssertEqual(lifecycle.evaluate(enabled: false, isPlaying: true, isRunning: false), .hold)
    }

    /// Switching off mid-doubt must not leave a half-counted pause behind for
    /// the next time it is switched on.
    func testDisablingClearsThePendingCount() {
        var lifecycle = TapLifecycle()
        _ = lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false)
        _ = lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true)
        _ = lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true)
        _ = lifecycle.evaluate(enabled: false, isPlaying: false, isRunning: true)

        _ = lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true), .hold,
                       "a fresh three are needed, not one")
    }

    /// A tap that is not running cannot be stopped, however long playback has
    /// been absent — and the doubt count must not quietly accrue while idle.
    func testAnIdleModelNeverAccumulatesAStop() {
        var lifecycle = TapLifecycle()
        for _ in 0..<100 {
            XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: false), .hold)
        }
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false), .start)
    }
}
