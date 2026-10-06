import XCTest
@testable import AirlockCore

final class CallDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let whatsApp = MicUser(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", playing: true)
    private let zoom = MicUser(bundleID: "us.zoom.xos", name: "zoom.us", playing: true)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testACallStartsOnceTheMicHasBeenHeldForTheSettleTime() {
        var d = CallDetector()
        XCTAssertNil(d.observe([whatsApp], at: at(0)))
        XCTAssertNil(d.observe([whatsApp], at: at(1)))
        let change = d.observe([whatsApp], at: at(2))
        let call = OngoingCall(bundleID: whatsApp.bundleID, appName: "WhatsApp", startedAt: at(0))
        XCTAssertEqual(change, .started(call))
        XCTAssertEqual(d.call, call, "the timer counts from the first sample, not from the settle")
    }

    func testListeningWithoutPlayingIsNotACall() {
        // Dictation, a voice memo, a recorder: the mic and nothing coming back.
        var d = CallDetector()
        let dictation = MicUser(bundleID: "com.example.Dictate", name: "Dictate", playing: false)
        for s in 0..<10 { XCTAssertNil(d.observe([dictation], at: at(TimeInterval(s)))) }
        XCTAssertNil(d.call)
    }

    func testABriefMicOpenNeverShowsACall() {
        var d = CallDetector()
        d.observe([whatsApp], at: at(0))
        d.observe([whatsApp], at: at(1))
        d.observe([], at: at(2))
        d.observe([whatsApp], at: at(3))
        XCTAssertNil(d.call, "the settle restarts once the mic lets go")
    }

    func testABeatWithoutTheMicDoesNotEndTheCall() {
        // AirPods going in mid-call drop the mic for a moment.
        var d = CallDetector()
        for s in 0...2 { d.observe([whatsApp], at: at(TimeInterval(s))) }
        XCTAssertNil(d.observe([], at: at(10)))
        XCTAssertNil(d.observe([], at: at(12)))
        XCTAssertNil(d.observe([whatsApp], at: at(13)))
        XCTAssertEqual(d.call?.startedAt, at(0), "same call, same timer")
    }

    func testTheCallEndsAfterTheGraceAndReportsWhenTheMicWent() {
        var d = CallDetector()
        for s in 0...2 { d.observe([whatsApp], at: at(TimeInterval(s))) }
        XCTAssertNil(d.observe([], at: at(60)))
        let change = d.observe([], at: at(63))
        guard case let .ended(call, endedAt)? = change else { return XCTFail("expected an end") }
        XCTAssertEqual(call.bundleID, whatsApp.bundleID)
        XCTAssertEqual(endedAt, at(60))
        XCTAssertNil(d.call)
    }

    func testTwoAppsOnTheMicResolveTheSameWayEveryTime() {
        var a = CallDetector(), b = CallDetector()
        for s in 0...2 {
            a.observe([zoom, whatsApp], at: at(TimeInterval(s)))
            b.observe([whatsApp, zoom], at: at(TimeInterval(s)))
        }
        XCTAssertEqual(a.call, b.call)
        XCTAssertNotNil(a.call)
    }

    func testTheCallStaysWithItsAppWhenAnotherJoins() {
        var d = CallDetector()
        for s in 0...2 { d.observe([zoom], at: at(TimeInterval(s))) }
        d.observe([zoom, whatsApp], at: at(5))
        XCTAssertEqual(d.call?.bundleID, zoom.bundleID)
    }

    func testFaceTimeDaemonsCountAsFaceTime() {
        XCTAssertEqual(CallDetector.callApp(forDaemon: "com.apple.avconferenced"), CallDetector.faceTime)
        XCTAssertEqual(CallDetector.callApp(forDaemon: "com.apple.TelephonyUtilities.callservicesd"),
                       CallDetector.faceTime)
        XCTAssertNil(CallDetector.callApp(forDaemon: "com.apple.Safari"))
    }

    func testTheTimerLabelStaysNarrow() {
        let call = OngoingCall(bundleID: "x", appName: "X", startedAt: t0)
        XCTAssertEqual(call.elapsedLabel(at: at(0)), "0:00")
        XCTAssertEqual(call.elapsedLabel(at: at(42)), "0:42")
        XCTAssertEqual(call.elapsedLabel(at: at(12 * 60 + 5)), "12:05")
        XCTAssertEqual(call.elapsedLabel(at: at(3600 + 2 * 60 + 14)), "1h02")
        XCTAssertEqual(call.elapsedLabel(at: at(-5)), "0:00", "a clock stepping back never goes negative")
    }

    // MARK: - On the island

    private func island(_ call: OngoingCall?, battery: Bool = false, meeting: Bool = false,
                        playing: Bool = false, attention: Int = 0) -> CompactIslandInput {
        CompactIslandInput(agentsEnabled: true, attentionCount: attention,
                           sessionCount: attention, hasMedia: playing, mediaPlaying: playing,
                           meetingSoon: meeting, now: at(30), batteryCritical: battery, call: call)
    }

    private var call: OngoingCall { OngoingCall(bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp", startedAt: t0) }

    func testACallOutranksTheMeetingCountdownAndTheWave() {
        XCTAssertEqual(CompactIsland.trailing(island(call, meeting: true, playing: true)), .call(call))
    }

    func testADyingBatteryAndAWaitingAgentStillOutrankACall() {
        XCTAssertEqual(CompactIsland.trailing(island(call, battery: true)), .batteryCritical(minutes: nil))
        XCTAssertEqual(CompactIsland.trailing(island(call, attention: 1)), .attentionDot)
    }

    func testACallBringsTheIslandUpOnItsOwn() {
        let alone = CompactIslandInput(now: at(30), call: call)
        XCTAssertTrue(CompactIsland.hasContent(alone))
        XCTAssertFalse(CompactIsland.hasContent(CompactIslandInput(now: at(30))))
    }

    func testTheCallIsSpokenWithItsApp() {
        XCTAssertEqual(CompactSlot.call(call).accessibilityLabel, "On a call in WhatsApp")
    }

    // MARK: - Resuming after a restart

    func testARestartMidCallKeepsTheOriginalStartTime() {
        // Airlock updated twenty minutes into a call and came back four seconds later.
        let original = OngoingCall(bundleID: whatsApp.bundleID, appName: "WhatsApp", startedAt: at(-1200))
        var d = CallDetector(resuming: CallSnapshot(call: original, seenAt: at(-4)), now: at(0))
        XCTAssertNil(d.observe([whatsApp], at: at(0)))
        XCTAssertNil(d.observe([whatsApp], at: at(1)))
        XCTAssertEqual(d.observe([whatsApp], at: at(2)), .resumed(original))
        XCTAssertEqual(d.call?.elapsedLabel(at: at(2)), "20:02")
    }

    func testASavedCallStillHasToBeFoundAgain() {
        // The call ended while Airlock was gone: nothing on the mic, no pill.
        let original = OngoingCall(bundleID: whatsApp.bundleID, appName: "WhatsApp", startedAt: at(-600))
        var d = CallDetector(resuming: CallSnapshot(call: original, seenAt: at(-2)), now: at(0))
        for s in 0..<5 { XCTAssertNil(d.observe([], at: at(TimeInterval(s)))) }
        XCTAssertNil(d.call)
    }

    func testASavedCallTooOldIsANewCall() {
        let original = OngoingCall(bundleID: whatsApp.bundleID, appName: "WhatsApp", startedAt: at(-3600))
        var d = CallDetector(resuming: CallSnapshot(call: original, seenAt: at(-300)), now: at(0))
        d.observe([whatsApp], at: at(0))
        let change = d.observe([whatsApp], at: at(2))
        XCTAssertEqual(change, .started(OngoingCall(bundleID: whatsApp.bundleID, appName: "WhatsApp", startedAt: at(0))))
    }

    func testAnotherAppOnTheMicIsNotTheSavedCall() {
        let original = OngoingCall(bundleID: whatsApp.bundleID, appName: "WhatsApp", startedAt: at(-600))
        var d = CallDetector(resuming: CallSnapshot(call: original, seenAt: at(-2)), now: at(0))
        d.observe([zoom], at: at(0))
        let change = d.observe([zoom], at: at(2))
        XCTAssertEqual(change, .started(OngoingCall(bundleID: zoom.bundleID, appName: "zoom.us", startedAt: at(0))))
    }

    func testTheSavedCallIsUsedOnceOnly() {
        // The resumed call ends; a second call in the same app starts at zero.
        let original = OngoingCall(bundleID: whatsApp.bundleID, appName: "WhatsApp", startedAt: at(-600))
        var d = CallDetector(resuming: CallSnapshot(call: original, seenAt: at(-2)), now: at(0))
        d.observe([whatsApp], at: at(0))
        d.observe([whatsApp], at: at(2))
        for s in 3...6 { d.observe([], at: at(TimeInterval(s))) }
        XCTAssertNil(d.call)
        d.observe([whatsApp], at: at(10))
        XCTAssertEqual(d.observe([whatsApp], at: at(12)),
                       .started(OngoingCall(bundleID: whatsApp.bundleID, appName: "WhatsApp", startedAt: at(10))))
    }

    // MARK: - Quiet moments (a browser stops its sound while nobody talks)

    func testAQuietMomentDoesNotEndTheCall() {
        var d = CallDetector()
        let quiet = MicUser(bundleID: whatsApp.bundleID, name: "WhatsApp", playing: false)
        for s in 0...2 { d.observe([whatsApp], at: at(TimeInterval(s))) }
        for s in 3...30 { XCTAssertNil(d.observe([quiet], at: at(TimeInterval(s)))) }
        XCTAssertEqual(d.call?.startedAt, at(0))
    }

    func testASavedCallResumesInAQuietMoment() {
        // The build-741 live failure: Meet was silent when Airlock came back.
        let chrome = MicUser(bundleID: "com.google.Chrome", name: "Google Chrome", playing: false)
        let original = OngoingCall(bundleID: chrome.bundleID, appName: "Google Chrome", startedAt: at(-58))
        var d = CallDetector(resuming: CallSnapshot(call: original, seenAt: at(-3)), now: at(0))
        XCTAssertTrue(d.isResumePending)
        XCTAssertNil(d.observe([chrome], at: at(0)))
        XCTAssertNil(d.observe([chrome], at: at(1)))
        XCTAssertEqual(d.observe([chrome], at: at(2)), .resumed(original))
    }

    func testListeningAfterTheSavedCallExpiredIsNotACall() {
        // A voice note in the same app a minute later: the saved call is gone,
        // and a mic with no sound back is not a call.
        let quiet = MicUser(bundleID: whatsApp.bundleID, name: "WhatsApp", playing: false)
        let original = OngoingCall(bundleID: whatsApp.bundleID, appName: "WhatsApp", startedAt: at(-600))
        var d = CallDetector(resuming: CallSnapshot(call: original, seenAt: at(-59)), now: at(0))
        for s in 0...20 { XCTAssertNil(d.observe([quiet], at: at(TimeInterval(s)))) }
        XCTAssertNil(d.call)
        XCTAssertFalse(d.isResumePending)
    }

    func testAQuietAppStillCannotStartACall() {
        var d = CallDetector()
        let quiet = MicUser(bundleID: whatsApp.bundleID, name: "WhatsApp", playing: false)
        for s in 0...10 { XCTAssertNil(d.observe([quiet], at: at(TimeInterval(s)))) }
        XCTAssertNil(d.call)
    }

    func testTheSnapshotRoundTrips() throws {
        var d = CallDetector()
        d.observe([whatsApp], at: at(0))
        d.observe([whatsApp], at: at(2))
        let snapshot = try XCTUnwrap(d.snapshot(at: at(30)))
        let decoded = try JSONDecoder().decode(CallSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, CallSnapshot(call: d.call!, seenAt: at(30)))
        XCTAssertNil(CallDetector().snapshot(at: at(0)), "no call, nothing to save")
    }
}
