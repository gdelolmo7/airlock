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

    // MARK: - Silence

    private let song = ["Spotify", "Song", "Artist"]
    private let nextSong = ["Spotify", "Next song", "Artist"]

    /// Opens on `song` and has the tap hear nothing for the full stretch,
    /// with the player still saying "playing" — Spotify gone silent.
    private func restingOnASilentSong() -> TapLifecycle {
        var lifecycle = TapLifecycle()
        _ = lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false, track: song)
        _ = lifecycle.listened(quietFor: TapLifecycle.silenceBeforeStopping, isPlaying: true, track: song)
        return lifecycle
    }

    /// The reason this exists: Spotify went silent while still saying it
    /// played, the three missed reads never came, and the tap listened to
    /// nothing until quit — sound input "still running" after a call.
    func testMinutesOfSilenceCloseTheTapWhateverThePlayerSays() {
        var lifecycle = TapLifecycle()
        _ = lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false, track: song)
        XCTAssertEqual(lifecycle.listened(quietFor: TapLifecycle.silenceBeforeStopping - 1,
                                          isPlaying: true, track: song), .hold)
        XCTAssertFalse(lifecycle.isResting)
        XCTAssertEqual(lifecycle.listened(quietFor: TapLifecycle.silenceBeforeStopping,
                                          isPlaying: true, track: song), .stop)
        XCTAssertTrue(lifecycle.isResting)
    }

    /// A paused player is read once, so it gets one miss and never three.
    func testAPausedPlayerThatIsReadOnceStillCloses() {
        var lifecycle = TapLifecycle()
        _ = lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false, track: song)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true, track: song), .hold)
        XCTAssertEqual(lifecycle.listened(quietFor: TapLifecycle.silenceBeforeStopping,
                                          isPlaying: false, track: song), .stop)
    }

    /// Music that can be heard is never closed for silence, however long.
    func testSoundNeverCloses() {
        var lifecycle = TapLifecycle()
        _ = lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false, track: song)
        for _ in 0..<10_000 {
            XCTAssertEqual(lifecycle.listened(quietFor: nil, isPlaying: true, track: song), .hold)
        }
        XCTAssertEqual(lifecycle.listened(quietFor: 3, isPlaying: true, track: song), .hold,
                       "a quiet passage or the gap between two tracks")
    }

    /// No loop: a player asked every few seconds that keeps saying the same
    /// thing must not open the tap straight back into the same silence.
    func testTheSameReportNeverOpensItAgain() {
        var lifecycle = restingOnASilentSong()
        for _ in 0..<100 {
            XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false, track: song), .hold)
        }
        XCTAssertTrue(lifecycle.isResting)
    }

    func testTheNextSongOpensItAgain() {
        var lifecycle = restingOnASilentSong()
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false, track: nextSong), .start)
        XCTAssertFalse(lifecycle.isResting)
    }

    func testPauseThenPlayOpensItAgain() {
        var lifecycle = restingOnASilentSong()
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: false, track: song), .hold)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false, track: song), .start)
    }

    /// Closed while paused: pressing play is the news.
    func testPlayAfterAPausedCloseOpensItAgain() {
        var lifecycle = TapLifecycle()
        _ = lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false, track: song)
        _ = lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true, track: song)
        _ = lifecycle.listened(quietFor: TapLifecycle.silenceBeforeStopping, isPlaying: false, track: song)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: false, track: song), .hold)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false, track: song), .start)
    }

    /// Spotify sent to an iPad changes track every few minutes and stays
    /// silent here. A tap opened again on that hint gets a short trial, not
    /// another three minutes, so it is closed most of the time.
    func testATapOpenedAgainThatHearsNothingClosesSooner() {
        var lifecycle = restingOnASilentSong()
        _ = lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false, track: nextSong)
        XCTAssertEqual(lifecycle.listened(quietFor: TapLifecycle.silenceBeforeStoppingAgain - 1,
                                          isPlaying: true, track: nextSong), .hold)
        XCTAssertEqual(lifecycle.listened(quietFor: TapLifecycle.silenceBeforeStoppingAgain,
                                          isPlaying: true, track: nextSong), .stop)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false, track: nextSong), .hold,
                       "and stays closed on the same report")
    }

    /// One that hears something is back to normal: the full stretch again.
    func testATapOpenedAgainThatHearsSoundGetsTheFullStretch() {
        var lifecycle = restingOnASilentSong()
        _ = lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false, track: nextSong)
        XCTAssertEqual(lifecycle.listened(quietFor: nil, isPlaying: true, track: nextSong), .hold)
        XCTAssertEqual(lifecycle.listened(quietFor: TapLifecycle.silenceBeforeStoppingAgain,
                                          isPlaying: true, track: nextSong), .hold)
        XCTAssertEqual(lifecycle.listened(quietFor: TapLifecycle.silenceBeforeStopping,
                                          isPlaying: true, track: nextSong), .stop)
    }

    /// The three-miss rule still works on a tap opened again.
    func testATapOpenedAgainStillClosesOnThreeMisses() {
        var lifecycle = restingOnASilentSong()
        _ = lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false, track: nextSong)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true, track: nextSong), .hold)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true, track: nextSong), .hold)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: false, isRunning: true, track: nextSong), .stop)
        XCTAssertFalse(lifecycle.isResting, "a pause, not a quiet close")
    }

    /// Switched off and on again, it starts from nothing: a plain playing read
    /// opens it, as it would on launch.
    func testSwitchingOffForgetsTheRest() {
        var lifecycle = restingOnASilentSong()
        XCTAssertEqual(lifecycle.evaluate(enabled: false, isPlaying: true, isRunning: false, track: song), .hold)
        XCTAssertFalse(lifecycle.isResting)
        XCTAssertEqual(lifecycle.evaluate(enabled: true, isPlaying: true, isRunning: false, track: song), .start)
    }
}
