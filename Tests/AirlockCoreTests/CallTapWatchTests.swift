import AirlockCore
import XCTest

/// The call's own sound going dead while the Mac still plays a voice: first
/// the call tap is started again, then, if that did not help, the other
/// side is taken from the speakers. Going dead while the call app plays on
/// and the speakers hear nothing either: both taps are started again, and
/// again, for as long as it lasts. Silence on both with the call app
/// quiet is a quiet call, and must never do any of it.
final class CallTapWatchTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    /// Looks once a second from `from` to `to` seconds after the start,
    /// returning every action that was not `.none`, by second.
    private func run(_ watch: inout CallTapWatch, from: Int = 1, to: Int, since: Int = 0,
                     lastSound: (Int) -> Int?, speaking: (Int) -> Bool = { _ in true },
                     playing: (Int) -> Bool = { _ in false }) -> [Int: CallTapWatch.Action] {
        var actions: [Int: CallTapWatch.Action] = [:]
        for second in from...to {
            let action = watch.look(now: start + Double(second), callTapSince: start + Double(since),
                                    callTapLastSound: lastSound(second).map { start + Double($0) },
                                    speakersSpeaking: speaking(second), callAppPlaying: { playing(second) })
            if action != .none { actions[second] = action }
        }
        return actions
    }

    /// The FaceTime call: the call tap heard the first minute, then nothing,
    /// while the Mac went on playing the other side.
    func testACallTapThatGoesQuietIsStartedAgainThenReplaced() {
        var watch = CallTapWatch()
        let actions = run(&watch, to: 120, lastSound: { _ in 60 })
        XCTAssertEqual(actions[70], .restartCallTap, "\(actions)")
        // The restart gets its time; when it brings nothing, the speakers.
        XCTAssertEqual(actions[90], .useSpeakers, "\(actions)")
        XCTAssertEqual(actions.count, 2)
        XCTAssertTrue(watch.usingSpeakers)
    }

    /// A restart that worked: the call tap hears again, and the count starts
    /// over, so a later failure is a restart again before the speakers.
    func testARestartThatWorksStartsTheCountOver() {
        var watch = CallTapWatch()
        XCTAssertEqual(run(&watch, to: 75, lastSound: { _ in 60 })[70], .restartCallTap)
        // Heard again from the restart until 150, then quiet once more.
        let later = run(&watch, from: 76, to: 200, since: 70, lastSound: { min($0, 150) })
        XCTAssertEqual(later[160], .restartCallTap, "\(later)")
        XCTAssertEqual(later[180], .useSpeakers, "\(later)")
        XCTAssertEqual(later.count, 2, "\(later)")
    }

    /// Nobody talking anywhere: a quiet call, not a dead tap.
    func testSilenceOnBothSidesDoesNothing() {
        var watch = CallTapWatch()
        XCTAssertTrue(run(&watch, to: 600, lastSound: { _ in 5 }, speaking: { _ in false }).isEmpty)
    }

    /// A chime or a short sound on the Mac is not the other side talking.
    func testAShortSoundOnTheMacDoesNothing() {
        var watch = CallTapWatch()
        let actions = run(&watch, to: 600, lastSound: { _ in 5 }, speaking: { $0 % 60 < 3 })
        XCTAssertTrue(actions.isEmpty, "\(actions)")
    }

    /// The call tap still hearing the other side: nothing to do, however
    /// much the Mac plays.
    func testAWorkingCallTapIsLeftAlone() {
        var watch = CallTapWatch()
        for second in 1...300 {
            let action = watch.look(now: start + Double(second), callTapSince: start,
                                    callTapLastSound: start + Double(second - 1), speakersSpeaking: true,
                                    callAppPlaying: { true })
            XCTAssertEqual(action, .none)
        }
    }

    /// A call tap that never heard anything while the Mac played a voice is
    /// as dead as one that stopped.
    func testACallTapThatNeverHeardIsTreatedTheSame() {
        var watch = CallTapWatch()
        let actions = run(&watch, to: 60, lastSound: { _ in nil })
        XCTAssertEqual(actions[10], .restartCallTap, "\(actions)")
        XCTAssertEqual(actions[30], .useSpeakers, "\(actions)")
    }

    /// Once on the speakers, nothing more happens for the rest of the notes.
    func testOnTheSpeakersItStaysThere() {
        var watch = CallTapWatch()
        _ = run(&watch, to: 120, lastSound: { _ in 60 })
        XCTAssertTrue(run(&watch, from: 121, to: 600, lastSound: { _ in 60 }).isEmpty)
        XCTAssertTrue(watch.usingSpeakers)
    }

    /// The WhatsApp call: both taps went deaf to the call five minutes in,
    /// while WhatsApp played on. The speakers heard no voice, so only the
    /// call app playing gives it away: both taps are started again, again
    /// after `retryAfter`, then every `retryEvery`, never the speakers.
    func testBothTapsDeafWhileTheCallAppPlaysAreStartedAgainAndAgain() {
        var watch = CallTapWatch()
        let actions = run(&watch, to: 400, lastSound: { min($0, 300) }, speaking: { _ in false },
                          playing: { _ in true })
        XCTAssertEqual(actions, [310: .restartBoth, 330: .restartBoth, 390: .restartBoth], "\(actions)")
        XCTAssertFalse(watch.usingSpeakers)
        XCTAssertEqual(watch.restarts, 3)
    }

    /// A restart that brought the speakers back but not the call tap: the
    /// speakers now hear the other side, so they stand in, as soon as the
    /// first retry allows.
    func testSpeakersThatComeBackStandIn() {
        var watch = CallTapWatch()
        let actions = run(&watch, to: 120, lastSound: { _ in 60 }, speaking: { $0 >= 75 },
                          playing: { _ in true })
        XCTAssertEqual(actions, [70: .restartBoth, 90: .useSpeakers], "\(actions)")
        XCTAssertTrue(watch.usingSpeakers)
    }

    /// The speakers coming back only after the restarts slowed down still
    /// switch after `retryAfter`, not `retryEvery`.
    func testSpeakersThatComeBackLateStandInWithoutTheLongWait() {
        var watch = CallTapWatch()
        let actions = run(&watch, to: 200, lastSound: { _ in 60 }, speaking: { $0 >= 100 },
                          playing: { _ in true })
        XCTAssertEqual(actions, [70: .restartBoth, 90: .restartBoth, 110: .useSpeakers], "\(actions)")
    }

    /// Both taps started again and the call heard again: the count starts
    /// over, so the next loss begins with a single restart.
    func testARestartOfBothThatWorksStartsTheCountOver() {
        var watch = CallTapWatch()
        XCTAssertEqual(run(&watch, to: 75, lastSound: { _ in 60 }, speaking: { _ in false },
                           playing: { _ in true }), [70: .restartBoth])
        let later = run(&watch, from: 76, to: 200, since: 70, lastSound: { min($0, 150) },
                        speaking: { _ in false }, playing: { _ in true })
        XCTAssertEqual(later, [160: .restartBoth, 180: .restartBoth], "\(later)")
    }

    /// A call app that stopped playing (the call on hold, or over) with
    /// nothing on the speakers: a quiet call, left alone.
    func testACallAppThatStopsPlayingIsLeftAlone() {
        var watch = CallTapWatch()
        let actions = run(&watch, to: 600, lastSound: { _ in 60 }, speaking: { _ in false },
                          playing: { $0 < 65 })
        XCTAssertTrue(actions.isEmpty, "\(actions)")
    }

    /// The call app is asked only once the call tap has been quiet long
    /// enough, so a working call costs no look at the Mac's processes.
    func testTheCallAppIsAskedOnlyWhenTheCallTapIsQuiet() {
        var watch = CallTapWatch()
        var asked = 0
        for second in 1...120 {
            _ = watch.look(now: start + Double(second), callTapSince: start,
                           callTapLastSound: start + Double(second - 1), speakersSpeaking: false,
                           callAppPlaying: { asked += 1; return true })
        }
        XCTAssertEqual(asked, 0)
    }
}
