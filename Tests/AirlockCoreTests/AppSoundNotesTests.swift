import XCTest
@testable import AirlockCore

/// Notes taken by hand of an app playing sound, with no call on: a webinar
/// you only listen to, which never takes the microphone.
final class AppSoundNotesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_468_600)
    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }
    private var chrome: OngoingCall {
        OngoingCall(bundleID: "com.google.Chrome", appName: "Google Chrome", startedAt: now)
    }
    private var taken: OngoingCall {
        OngoingCall(bundleID: "com.google.Chrome", appName: "Google Chrome", startedAt: now, byHand: true)
    }
    private func zoom(at date: Date) -> OngoingCall {
        OngoingCall(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: date)
    }

    private func send(_ flow: inout MeetingNotesFlow, _ event: MeetingNotesFlow.Event,
                      enabled: Bool = true) -> [MeetingNotesFlow.Effect] {
        flow.apply(event, enabled: enabled, autoStart: false)
    }

    private func taking() -> MeetingNotesFlow {
        var flow = MeetingNotesFlow()
        _ = send(&flow, .takeNotesOfApp(chrome, at: now))
        return flow
    }

    // MARK: Which app

    private let chromePlayer = HandNotesSource.Player(bundleID: "com.google.Chrome", name: "Google Chrome")
    private let slack = HandNotesSource.Player(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")

    func testNothingPlayingIsTheRoom() {
        XCTAssertNil(HandNotesSource.app(playing: [], frontmost: "com.google.Chrome"))
    }

    func testTheAppInFrontWins() {
        XCTAssertEqual(HandNotesSource.app(playing: [chromePlayer, slack], frontmost: slack.bundleID), slack)
    }

    func testOtherwiseTheSameAnswerEveryTime() {
        XCTAssertEqual(HandNotesSource.app(playing: [slack, chromePlayer], frontmost: "com.apple.finder"),
                       chromePlayer)
        XCTAssertEqual(HandNotesSource.app(playing: [chromePlayer, slack], frontmost: nil), chromePlayer)
    }

    // MARK: The notes

    func testTheButtonStartsNotesOfTheApp() {
        var flow = MeetingNotesFlow()
        XCTAssertEqual(flow.handButton, .takeNotes)
        XCTAssertEqual(send(&flow, .takeNotesOfApp(chrome, at: now)), [.startNotes(taken, continuing: false)])
        XCTAssertEqual(flow.phase, .recording(taken, since: now))
        XCTAssertTrue(taken.isByHand)
        XCTAssertFalse(taken.isInPerson)
        XCTAssertEqual(flow.handButton, .stop)
    }

    func testNothingStartsWithCallNotesOffOrOnACall() {
        var off = MeetingNotesFlow()
        XCTAssertEqual(send(&off, .takeNotesOfApp(chrome, at: now), enabled: false), [])
        XCTAssertEqual(off.phase, .idle)

        var offered = MeetingNotesFlow()
        _ = send(&offered, .callStarted(zoom(at: now), at: now))
        XCTAssertEqual(send(&offered, .takeNotesOfApp(chrome, at: now)), [])
        XCTAssertEqual(offered.phase, .offering(zoom(at: now)))
    }

    /// The detector's calls pass the notes by: the webinar taking the
    /// microphone for a question, letting go of it, or another app's call.
    func testTheDetectorDoesNotEndThem() {
        var flow = taking()
        XCTAssertEqual(send(&flow, .callStarted(chrome, at: at(60))), [])
        XCTAssertEqual(send(&flow, .callEnded(at: at(90))), [])
        XCTAssertEqual(send(&flow, .callStarted(zoom(at: at(120)), at: at(120))), [])
        XCTAssertEqual(send(&flow, .tick(.init(now: at(130), lastSpeech: at(129)))), [])
        XCTAssertEqual(flow.phase, .recording(taken, since: now))
        XCTAssertFalse(flow.isWaitingForCallBack)
    }

    func testStopWritesThemHoweverShort() {
        var flow = taking()
        XCTAssertEqual(send(&flow, .stop), [.finishNotes])
        XCTAssertEqual(flow.phase, .writing(taken))
    }

    func testTheAppQuittingWritesThemAtOnce() {
        var flow = taking()
        XCTAssertEqual(send(&flow, .appQuit(bundleID: "us.zoom.xos", at: at(30))), [])
        XCTAssertEqual(send(&flow, .appQuit(bundleID: "com.google.Chrome", at: at(40))), [.finishNotes])
        XCTAssertEqual(flow.phase, .writing(taken))
    }

    func testSleepKeepsThem() {
        var flow = taking()
        XCTAssertEqual(send(&flow, .sleep(at: at(60))), [.finishNotes])
        XCTAssertTrue(flow.endedBySleep)
    }

    func testALongQuietWritesThem() {
        var flow = taking()
        let quiet = MeetingNotesFlow.silenceLimit
        XCTAssertEqual(send(&flow, .tick(.init(now: at(quiet - 1)))), [])
        XCTAssertEqual(send(&flow, .tick(.init(now: at(quiet)))), [.finishNotes])
        XCTAssertEqual(flow.phase, .writing(taken))
    }

    /// Notes by hand are not carried on by a call from the same app after:
    /// that call is asked about like any other.
    func testACallAfterwardsIsAskedAbout() {
        var flow = taking()
        _ = send(&flow, .stop)
        _ = send(&flow, .saved(folder: "f"))
        XCTAssertEqual(send(&flow, .callStarted(chrome, at: at(90))), [])
        XCTAssertEqual(flow.phase, .offering(chrome))
    }

    /// Calls kept before the flag existed still read back.
    func testOldSavedCallsDecode() throws {
        let old = #"{"bundleID":"us.zoom.xos","appName":"Zoom","startedAt":0}"#
        let call = try JSONDecoder().decode(OngoingCall.self, from: Data(old.utf8))
        XCTAssertFalse(call.byHand)
        let again = try JSONDecoder().decode(OngoingCall.self, from: JSONEncoder().encode(taken))
        XCTAssertEqual(again, taken)
    }
}
