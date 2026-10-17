import XCTest
@testable import AirlockCore

final class CallMuteLabelsTests: XCTestCase {
    func testMeetsButtonSaysWhatPressingItWouldDo() {
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Turn on microphone (⌘ + d)", in: .browser), true)
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Turn off microphone (⌘ + d)", in: .browser), false)
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Turn off microphone (ctrl + d)", in: .browser), false)
    }

    func testSpanishWithOrWithoutAccents() {
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Activar micrófono (⌘ + d)", in: .browser), true)
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Desactivar micrófono (⌘ + d)", in: .browser), false)
        XCTAssertEqual(CallMuteLabels.isMuted(label: "desactivar el microfono", in: .browser), false)
    }

    func testAVideosMuteButtonInABrowserIsNotTheCall() {
        XCTAssertNil(CallMuteLabels.isMuted(label: "Mute (m)", in: .browser))
        XCTAssertNil(CallMuteLabels.isMuted(label: "Unmute", in: .browser))
    }

    func testACallAppsPlainMuteButtonCounts() {
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Unmute", in: .app), true)
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Mute (⌘⇧A)", in: .app), false)
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Unmute audio", in: .app), true)
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Silenciar", in: .app), false)
    }

    func testATickedMuteSwitchMeansMuted() {
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Mute", checked: true, in: .app), true)
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Mute", checked: false, in: .app), false)
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Unmute", checked: false, in: .app), true,
                       "a flipping label is a button: its words win")
    }

    func testAHostsButtonsForOtherPeopleAreNotYours() {
        XCTAssertNil(CallMuteLabels.isMuted(label: "Mute all", in: .app))
        XCTAssertNil(CallMuteLabels.isMuted(label: "Mute Ana's microphone", in: .browser))
        XCTAssertNil(CallMuteLabels.isMuted(label: "Turn off camera (⌘ + e)", in: .browser))
    }

    func testMeetsMicButtonIsRecognisedInAnyLanguageForTheLog() {
        XCTAssertTrue(CallMuteLabels.looksLikeMeetMicButton("Mikrofon ausschalten (⌘ + D)"))
        XCTAssertTrue(CallMuteLabels.looksLikeMeetMicButton("Désactiver le micro (ctrl + d)"))
        XCTAssertFalse(CallMuteLabels.looksLikeMeetMicButton("Turn off camera (⌘ + e)"))
    }

    /// Zoom's web client names the button for you ("mute my microphone").
    func testMyMicrophoneWordingCountsInABrowser() {
        XCTAssertEqual(CallMuteLabels.isMuted(label: "unmute my microphone", in: .browser), true)
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Mute my microphone", in: .browser), false)
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Activar mi micrófono", in: .browser), true)
        XCTAssertEqual(CallMuteLabels.isMuted(label: "Silenciar mi micrófono", in: .browser), false)
    }

    func testCallServicePagesAreKnownByTheirAddress() {
        XCTAssertTrue(CallMuteLabels.isCallPage("https://app.zoom.us/wc/81234567890/join?fromPWA=1"))
        XCTAssertTrue(CallMuteLabels.isCallPage("https://us05web.zoom.us/wc/81234567890/start"))
        XCTAssertTrue(CallMuteLabels.isCallPage("https://app.zoom.com/wc/home"))
        XCTAssertTrue(CallMuteLabels.isCallPage("https://meet.google.com/abc-defg-hij"))
        XCTAssertTrue(CallMuteLabels.isCallPage("https://teams.microsoft.com/v2/"))
        XCTAssertTrue(CallMuteLabels.isCallPage("https://teams.cloud.microsoft/"))
        XCTAssertTrue(CallMuteLabels.isCallPage("acme.webex.com"))
    }

    func testOtherPagesAreNotCallPages() {
        XCTAssertFalse(CallMuteLabels.isCallPage("https://www.youtube.com/watch?v=x"))
        XCTAssertFalse(CallMuteLabels.isCallPage("https://notzoom.us/"))
        XCTAssertFalse(CallMuteLabels.isCallPage("https://discord.com/channels/1/2"))
        XCTAssertFalse(CallMuteLabels.isCallPage(""))
    }
}

final class MuteTimelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_468_600)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testNothingIsMutedUntilTheButtonSaysSo() {
        var timeline = MuteTimeline()
        timeline.observe(false, at: at(0))
        timeline.observe(nil, at: at(1))
        XCTAssertFalse(timeline.isMuted(at: at(0.5)))
        XCTAssertFalse(timeline.isMuted)
    }

    func testAMuteCountsFromThePreviousLook() {
        var timeline = MuteTimeline()
        timeline.observe(false, at: at(0))
        timeline.observe(false, at: at(0.3))
        timeline.observe(true, at: at(0.6))
        XCTAssertFalse(timeline.isMuted(at: at(0.29)))
        XCTAssertTrue(timeline.isMuted(at: at(0.3)), "pressed somewhere after the look at 0.3")
        XCTAssertTrue(timeline.isMuted(at: at(5)))
    }

    func testAnUnmuteCountsOnlyOnceSeen() {
        var timeline = MuteTimeline()
        timeline.observe(true, at: at(0))
        timeline.observe(true, at: at(0.3))
        timeline.observe(false, at: at(0.6))
        XCTAssertTrue(timeline.isMuted(at: at(0.59)))
        XCTAssertFalse(timeline.isMuted(at: at(0.6)))
        XCTAssertFalse(timeline.isMuted)
    }

    func testAnUnreadableLookKeepsWhatWasLastSeen() {
        var timeline = MuteTimeline()
        timeline.observe(true, at: at(0))
        timeline.observe(nil, at: at(10))
        XCTAssertTrue(timeline.isMuted(at: at(20)))
        timeline.observe(false, at: at(30))
        XCTAssertFalse(timeline.isMuted(at: at(31)))
    }

    func testAMuteAfterUnreadableLooksStartsAtTheLastLookNotTheLastReading() {
        var timeline = MuteTimeline()
        timeline.observe(false, at: at(0))
        timeline.observe(nil, at: at(10))
        timeline.observe(true, at: at(10.3))
        XCTAssertFalse(timeline.isMuted(at: at(5)), "long before: the call could hear you")
        XCTAssertTrue(timeline.isMuted(at: at(10.1)))
    }

    func testSeveralStretches() {
        var timeline = MuteTimeline()
        timeline.observe(true, at: at(0))
        timeline.observe(false, at: at(2))
        timeline.observe(false, at: at(3.7))
        timeline.observe(true, at: at(4))
        timeline.observe(false, at: at(6))
        XCTAssertEqual(timeline.stretches.count, 2)
        XCTAssertTrue(timeline.isMuted(at: at(1)))
        XCTAssertFalse(timeline.isMuted(at: at(3)))
        XCTAssertTrue(timeline.isMuted(at: at(5)))
        timeline.forget(before: at(3))
        XCTAssertEqual(timeline.stretches.count, 1)
    }
}
