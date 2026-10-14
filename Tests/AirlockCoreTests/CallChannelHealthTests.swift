import XCTest
@testable import AirlockCore

final class CallChannelHealthTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// A side that started at 0 and last had sound at `input` and speech at
    /// `speech`.
    private func side(input: TimeInterval?, speech: TimeInterval? = nil,
                      heard: Bool = true) -> CallChannelHealth.Side {
        .init(since: at(0), lastInput: input.map(at), lastSpeech: speech.map(at), heardAnything: heard)
    }

    func testYourSideIsMissingWhenNothingArrivesWhileTheyTalk() {
        var health = CallChannelHealth()
        health.update(yours: side(input: 10), theirs: side(input: 12.9, speech: 12.9),
                      youAreMuted: false, now: at(12.9))
        XCTAssertFalse(health.yoursMissing, "under three seconds is not missing yet")
        health.update(yours: side(input: 10), theirs: side(input: 13, speech: 13),
                      youAreMuted: false, now: at(13))
        XCTAssertTrue(health.yoursMissing)
        XCTAssertFalse(health.theirsMissing)
    }

    func testAQuietSideIsNotMissingWhenNobodyTalks() {
        var health = CallChannelHealth()
        health.update(yours: side(input: 10), theirs: side(input: 60, speech: 20),
                      youAreMuted: false, now: at(60))
        XCTAssertFalse(health.yoursMissing)
    }

    func testTheLineHoldsThroughAPauseAndGoesWhenSoundIsBack() {
        var health = CallChannelHealth()
        health.update(yours: side(input: 10), theirs: side(input: 14, speech: 14),
                      youAreMuted: false, now: at(14))
        XCTAssertTrue(health.yoursMissing)
        // They stop talking for a while: still missing, still said.
        health.update(yours: side(input: 10), theirs: side(input: 40, speech: 14),
                      youAreMuted: false, now: at(40))
        XCTAssertTrue(health.yoursMissing)
        // The microphone is back.
        health.update(yours: side(input: 41), theirs: side(input: 41, speech: 14),
                      youAreMuted: false, now: at(41))
        XCTAssertFalse(health.yoursMissing)
    }

    func testBeingMutedInTheCallIsNeverMissing() {
        var health = CallChannelHealth()
        health.update(yours: side(input: 10), theirs: side(input: 20, speech: 20),
                      youAreMuted: true, now: at(20))
        XCTAssertFalse(health.yoursMissing)
        health.update(yours: side(input: 10), theirs: side(input: 20, speech: 20),
                      youAreMuted: false, now: at(20))
        XCTAssertTrue(health.yoursMissing)
        health.update(yours: side(input: 10), theirs: side(input: 21, speech: 21),
                      youAreMuted: true, now: at(21))
        XCTAssertFalse(health.yoursMissing)
    }

    func testAMicrophoneThatNeverStartedIsMissingOnceTheyTalk() {
        var health = CallChannelHealth()
        health.update(yours: side(input: nil, heard: false), theirs: side(input: 5, speech: 5),
                      youAreMuted: false, now: at(5))
        XCTAssertTrue(health.yoursMissing)
    }

    /// Your side as the model measures it: the notes began at 0, the stream
    /// now running started at `stream`, the last buffer of any kind arrived
    /// at `buffer` and the last one above zero at `sound`.
    private func yours(buffer: TimeInterval?, sound: TimeInterval?,
                       stream: TimeInterval?) -> CallChannelHealth.Side {
        let input = CallChannelHealth.microphoneInput(
            lastBuffer: buffer.map(at), lastSound: sound.map(at), streamStartedAt: stream.map(at))
        return .init(since: at(0), lastInput: input, heardAnything: sound != nil)
    }

    /// A microphone with a noise gate sends exact zeros while you are quiet.
    /// It spoke at 5, so the zeros since are you listening, not a dead side.
    func testAGatedMicrophoneThatSpokeIsNotMissingWhileYouListen() {
        XCTAssertEqual(CallChannelHealth.microphoneInput(lastBuffer: at(20), lastSound: at(5),
                                                         streamStartedAt: at(0)), at(20))
        var health = CallChannelHealth()
        health.update(yours: yours(buffer: 20, sound: 5, stream: 0), theirs: side(input: 20, speech: 20),
                      youAreMuted: false, now: at(20))
        XCTAssertFalse(health.yoursMissing)
        // Its sound right as the stream started counts too.
        XCTAssertEqual(CallChannelHealth.microphoneInput(lastBuffer: at(20), lastSound: at(0),
                                                         streamStartedAt: at(0)), at(20))
    }

    /// Nothing but zeros from the start: a refused permission or a dead
    /// device, however steadily the buffers arrive.
    func testAMicrophoneThatNeverCarriedSoundIsMissingOnceTheyTalk() {
        XCTAssertNil(CallChannelHealth.microphoneInput(lastBuffer: at(20), lastSound: nil,
                                                       streamStartedAt: at(0)))
        var health = CallChannelHealth()
        health.update(yours: yours(buffer: 20, sound: nil, stream: 0), theirs: side(input: 20, speech: 20),
                      youAreMuted: false, now: at(20))
        XCTAssertTrue(health.yoursMissing)
    }

    /// The first stream carried sound; the microphone was started again at 40
    /// on a device that only sends zeros. The old stream's sound does not
    /// vouch for the new one.
    func testARestartOntoADeviceThatOnlySendsZerosIsMissingAgain() {
        var health = CallChannelHealth()
        health.update(yours: yours(buffer: 39, sound: 30, stream: 0), theirs: side(input: 39, speech: 39),
                      youAreMuted: false, now: at(39))
        XCTAssertFalse(health.yoursMissing)
        health.update(yours: yours(buffer: 50, sound: 30, stream: 40), theirs: side(input: 50, speech: 50),
                      youAreMuted: false, now: at(50))
        XCTAssertTrue(health.yoursMissing)
        // Sound on the new stream, and its zeros count again.
        health.update(yours: yours(buffer: 60, sound: 51, stream: 40), theirs: side(input: 60, speech: 60),
                      youAreMuted: false, now: at(60))
        XCTAssertFalse(health.yoursMissing)
    }

    /// No stream running (the last start failed): only real sound counts, as
    /// for a stream that never carried any.
    func testAFailedStartCountsOnlyRealSound() {
        XCTAssertEqual(CallChannelHealth.microphoneInput(lastBuffer: at(20), lastSound: at(5),
                                                         streamStartedAt: nil), at(5))
        var health = CallChannelHealth()
        health.update(yours: yours(buffer: 20, sound: 5, stream: nil), theirs: side(input: 20, speech: 20),
                      youAreMuted: false, now: at(20))
        XCTAssertTrue(health.yoursMissing)
    }

    func testTheirSideIsMissingWhenItStopsArrivingWhileYouTalk() {
        var health = CallChannelHealth()
        health.update(yours: side(input: 30, speech: 30), theirs: side(input: 26),
                      youAreMuted: false, now: at(30))
        XCTAssertTrue(health.theirsMissing)
        XCTAssertFalse(health.yoursMissing)
        health.update(yours: side(input: 31, speech: 31), theirs: side(input: 31),
                      youAreMuted: false, now: at(31))
        XCTAssertFalse(health.theirsMissing)
    }

    /// The call app often makes no sound until somebody speaks, so a tap that
    /// has not started yet is not "missing".
    func testTheirSideBeforeItsSoundStartedIsNotMissing() {
        var health = CallChannelHealth()
        health.update(yours: side(input: 30, speech: 30), theirs: .init(),
                      youAreMuted: false, now: at(30))
        XCTAssertFalse(health.theirsMissing)
        XCTAssertFalse(health.theirsNotAllowed)
    }

    func testOnlyZerosFromTheCallForFortyFiveSecondsIsThePermission() {
        var health = CallChannelHealth()
        health.update(yours: side(input: 44), theirs: side(input: 44.9, heard: false),
                      youAreMuted: false, now: at(44.9))
        XCTAssertFalse(health.theirsNotAllowed)
        health.update(yours: side(input: 45), theirs: side(input: 45, heard: false),
                      youAreMuted: false, now: at(45))
        XCTAssertTrue(health.theirsNotAllowed)
        health.update(yours: side(input: 46), theirs: side(input: 46, heard: true),
                      youAreMuted: false, now: at(46))
        XCTAssertFalse(health.theirsNotAllowed)
    }

    func testLevels() {
        XCTAssertEqual(CallChannelHealth.level([Float]()), 0)
        XCTAssertEqual(CallChannelHealth.level([Float](repeating: 0, count: 160)), 0)
        XCTAssertEqual(CallChannelHealth.level([Float](repeating: 0.5, count: 160)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(CallChannelHealth.level([Int16.max, -Int16.max]), 1, accuracy: 0.0001)
        XCTAssertEqual(CallChannelHealth.level([Int16](repeating: 0, count: 160)), 0)
        // A room's hum is not speech; a voice is.
        XCTAssertFalse(CallChannelHealth.isSpeech(level: 0.003))
        XCTAssertTrue(CallChannelHealth.isSpeech(level: 0.05))
    }
}

final class MicRestartTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testAFlowingMicrophoneIsLeftAlone() {
        var restart = MicRestart()
        XCTAssertFalse(restart.shouldRestart(now: at(1), startedAt: at(0), lastInput: nil, deviceChanged: false))
        XCTAssertFalse(restart.shouldRestart(now: at(60), startedAt: at(0), lastInput: at(59.9),
                                             deviceChanged: false))
    }

    func testAStalledMicrophoneIsStartedAgainAfterTwoSeconds() {
        var restart = MicRestart()
        XCTAssertFalse(restart.shouldRestart(now: at(61.9), startedAt: at(0), lastInput: at(60),
                                             deviceChanged: false))
        XCTAssertTrue(restart.shouldRestart(now: at(62), startedAt: at(0), lastInput: at(60),
                                            deviceChanged: false))
    }

    func testAChangedMicrophoneIsStartedAgainAtOnce() {
        var restart = MicRestart()
        XCTAssertTrue(restart.shouldRestart(now: at(10), startedAt: at(0), lastInput: at(9.9),
                                            deviceChanged: true))
    }

    func testStartsThatBringNoSoundBackWaitLongerEachTime() {
        var restart = MicRestart()
        // Stalled at 62: tried at once.
        XCTAssertTrue(restart.shouldRestart(now: at(62), startedAt: at(0), lastInput: at(60),
                                            deviceChanged: false))
        // The new stream (from 62) brings nothing: tried again two seconds on.
        XCTAssertTrue(restart.shouldRestart(now: at(64), startedAt: at(62), lastInput: at(60),
                                            deviceChanged: false))
        // Then four.
        XCTAssertFalse(restart.shouldRestart(now: at(67), startedAt: at(64), lastInput: at(60),
                                             deviceChanged: false))
        XCTAssertTrue(restart.shouldRestart(now: at(68), startedAt: at(64), lastInput: at(60),
                                            deviceChanged: false))
        // A start that failed outright waits its turn too.
        XCTAssertFalse(restart.shouldRestart(now: at(75), startedAt: nil, lastInput: at(60),
                                             deviceChanged: false))
        XCTAssertTrue(restart.shouldRestart(now: at(76), startedAt: nil, lastInput: at(60),
                                            deviceChanged: false))
    }

    func testSoundComingBackStartsTheWaitingOver() {
        var restart = MicRestart()
        XCTAssertTrue(restart.shouldRestart(now: at(62), startedAt: at(0), lastInput: at(60),
                                            deviceChanged: false))
        XCTAssertTrue(restart.shouldRestart(now: at(64), startedAt: at(62), lastInput: at(60),
                                            deviceChanged: false))
        // The stream from 64 flows.
        XCTAssertFalse(restart.shouldRestart(now: at(100), startedAt: at(64), lastInput: at(99.9),
                                             deviceChanged: false))
        // A later stall is tried at once again, not after the longer wait.
        XCTAssertTrue(restart.shouldRestart(now: at(200), startedAt: at(64), lastInput: at(198),
                                            deviceChanged: false))
    }
}
