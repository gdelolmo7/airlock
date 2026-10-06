import XCTest
@testable import AirlockCore

final class AudioOutputMenuTests: XCTestCase {
    private func device(_ name: String) -> AudioOutputDevice {
        AudioOutputDevice(uid: "uid-\(name)", name: name)
    }

    private var all: [AudioOutputDevice] {
        ["MacBook", "Studio Display", "AirPods Pro", "Beats Fit", "DAC", "TV"].map(device)
    }

    func testCurrentDeviceComesFirst() {
        let layout = AudioOutputMenu.layout(devices: all, currentUID: "uid-AirPods Pro", limit: 4)
        XCTAssertEqual(layout.shown.first?.name, "AirPods Pro")
    }

    func testEverythingFitsWhenUnderTheLimit() {
        let devices = Array(all.prefix(3))
        let layout = AudioOutputMenu.layout(devices: devices, currentUID: "uid-MacBook", limit: 4)
        XCTAssertEqual(layout.shown.count, 3)
        XCTAssertEqual(layout.hidden, 0)
    }

    func testOverflowIsCountedNotDropped() {
        let layout = AudioOutputMenu.layout(devices: all, currentUID: "uid-MacBook", limit: 3)
        XCTAssertEqual(layout.shown.count, 3)
        XCTAssertEqual(layout.hidden, 3, "six devices, three shown")
    }

    /// The overflow has to BE the devices, not how many there are. A count is
    /// all a row can print from a number, and a printed count is a device that
    /// can only be reached from System Settings.
    func testTheOverflowCarriesTheDevicesItCounts() {
        let layout = AudioOutputMenu.layout(devices: all, currentUID: "uid-MacBook", limit: 3)
        XCTAssertEqual(layout.overflow.map(\.name), ["Beats Fit", "DAC", "TV"])
        XCTAssertEqual(layout.hidden, layout.overflow.count)
    }

    /// Between the row and the overflow, every device is selectable — whichever
    /// one is current, and even when the current one is not there at all.
    func testNoDeviceIsLostBetweenTheRowAndTheOverflow() {
        for current in ["uid-MacBook", "uid-TV", "uid-Unplugged"] {
            let layout = AudioOutputMenu.layout(devices: all, currentUID: current, limit: 3)
            XCTAssertEqual(Set((layout.shown + layout.overflow).map(\.uid)),
                           Set(all.map(\.uid)), current)
        }
    }

    /// The promotion rule again, from the other side: the device you are
    /// listening on is in the row, so it is never in the list behind "+3".
    func testTheCurrentDeviceIsNeverInTheOverflow() {
        let layout = AudioOutputMenu.layout(devices: all, currentUID: "uid-TV", limit: 1)
        XCTAssertFalse(layout.overflow.contains { $0.uid == "uid-TV" })
    }

    /// THE rule. A cap that hides the device you are listening on makes the row
    /// read as "switched to nothing" — nothing selected, and no way to tell why.
    func testTheCurrentDeviceIsNeverTheOneHidden() {
        // Last in system order, and the limit only has room for one.
        let layout = AudioOutputMenu.layout(devices: all, currentUID: "uid-TV", limit: 1)
        XCTAssertEqual(layout.shown.map(\.name), ["TV"])
        XCTAssertEqual(layout.hidden, 5)
    }

    func testOrderIsOtherwiseLeftAlone() {
        let layout = AudioOutputMenu.layout(devices: all, currentUID: "uid-Beats Fit", limit: 6)
        XCTAssertEqual(layout.shown.map(\.name),
                       ["Beats Fit", "MacBook", "Studio Display", "AirPods Pro", "DAC", "TV"],
                       "promoting the current one must not reshuffle the rest")
    }

    // MARK: - Devices that are not places to listen

    /// Reported from a laptop connected to nothing: `CADefaultDeviceAggregate-…`
    /// offered as a choice beside the built-in speakers, under a name no user
    /// could interpret. macOS builds these for its own routing and leaves them
    /// in the device list.
    func testMacOSInternalAggregatesAreNotOffered() {
        XCTAssertTrue(AudioOutputDevice.isInternalUID("CADefaultDeviceAggregate-1234-5"))
        XCTAssertTrue(AudioOutputDevice.isInternalUID("CADefaultDeviceAggregate"))
    }

    /// Ours counts too — the reactive wave wraps its process tap in a private
    /// aggregate for as long as music is playing, which is precisely when
    /// someone is most likely to open this row.
    func testOurOwnTapAggregateIsNotOffered() {
        XCTAssertTrue(AudioOutputDevice.isInternalUID("com.airlock.wave.ABC-123"))
        XCTAssertTrue(AudioOutputDevice.isInternalUID("com.agenticnotch.wave.OLD-1"))
    }

    /// A user-built aggregate from Audio MIDI Setup is a real destination and
    /// must survive — the filter is for private ones, not for aggregates.
    func testRealDevicesAreLeftAlone() {
        for uid in ["BuiltInSpeakerDevice", "AppleUSBAudioEngine:Mi:Monitor",
                    "AggregateDevice-UserMade", "BlackHole2ch_UID"] {
            XCTAssertFalse(AudioOutputDevice.isInternalUID(uid), uid)
        }
    }

    // MARK: - The awkward moments

    /// Unplug an interface and CoreAudio can name a default that is already
    /// gone. That is a beat of inconsistency, not an error — it must not invent
    /// a chip for a device that is not there.
    func testACurrentDeviceThatIsNoLongerPresentIsNotInvented() {
        let layout = AudioOutputMenu.layout(devices: all, currentUID: "uid-Unplugged", limit: 3)
        XCTAssertEqual(layout.shown.count, 3)
        XCTAssertFalse(layout.shown.contains { $0.uid == "uid-Unplugged" })
        XCTAssertEqual(layout.shown.first?.name, "MacBook", "falls back to system order")
    }

    func testNoCurrentDeviceIsFine() {
        let layout = AudioOutputMenu.layout(devices: all, currentUID: nil, limit: 2)
        XCTAssertEqual(layout.shown.map(\.name), ["MacBook", "Studio Display"])
        XCTAssertEqual(layout.hidden, 4)
    }

    func testNoDevicesAtAll() {
        let layout = AudioOutputMenu.layout(devices: [], currentUID: nil, limit: 3)
        XCTAssertTrue(layout.shown.isEmpty)
        XCTAssertEqual(layout.hidden, 0)
    }

    func testAZeroLimitHidesEverythingRatherThanCrashing() {
        let layout = AudioOutputMenu.layout(devices: all, currentUID: "uid-MacBook", limit: 0)
        XCTAssertTrue(layout.shown.isEmpty)
        XCTAssertEqual(layout.hidden, 6)
        XCTAssertEqual(layout.overflow.count, 6, "a row with no room is still a row with devices")
    }
}

/// The one rule behind the mute button that can be checked without a device.
final class OutputMuteTests: XCTestCase {
    /// The common case, and the reason this is nearly always a no-op: the mute
    /// property leaves the level alone, so unmuting already lands where it was.
    func testALevelThatCameBackByItselfIsLeftAlone() {
        XCTAssertNil(OutputMute.levelToRestore(reported: 0.62, remembered: 0.62))
        XCTAssertNil(OutputMute.levelToRestore(reported: 0.62, remembered: 0.2),
                     "the device wins — it is the one that knows")
    }

    /// The devices that zero their volume while muted. Without this the button
    /// unmutes into silence, which reads as a click that did nothing.
    func testADeviceThatUnmutesIntoSilenceIsPutBack() {
        XCTAssertEqual(OutputMute.levelToRestore(reported: 0, remembered: 0.62), 0.62)
    }

    /// A slider dragged to the bottom before muting is silence somebody chose.
    /// Unmuting must not invent a level for it — the mute key does not either.
    func testSilenceIsNotRestoredIntoAudibility() {
        XCTAssertNil(OutputMute.levelToRestore(reported: 0, remembered: 0))
        XCTAssertNil(OutputMute.levelToRestore(reported: 0, remembered: nil),
                     "nothing was captured, so there is nothing to claim")
    }

    /// No software volume at all — an HDMI display or many an external DAC.
    /// There is no slider in that case and there must be no write either.
    func testADeviceWithNoVolumeIsNeverWrittenTo() {
        XCTAssertNil(OutputMute.levelToRestore(reported: nil, remembered: 0.62))
    }

    // MARK: - What it reads as

    /// Mute FIRST. The percentage is what the slider shows and there is no
    /// sound at it — but it is still worth saying, because it is where unmuting
    /// lands and it is the thing a drag is moving.
    func testTheSpokenLevelLeadsWithTheMute() {
        XCTAssertEqual(OutputMute.spokenLevel(volume: 0.62, isMuted: true),
                       "muted, 62 percent")
        XCTAssertEqual(OutputMute.spokenLevel(volume: 0.62, isMuted: false), "62 percent")
    }

    /// The slider is LIVE while muted — pointedly not disabled, so the level to
    /// come back to can be set — so the value is the position it is at, not a
    /// position it used to be at. "was 70 percent" while somebody drags to 70
    /// is the wrong tense for the only number they are being told.
    func testAMutedLevelIsReadInThePresentBecauseItIsStillBeingSet() {
        for percent in stride(from: 10, through: 90, by: 10) {
            XCTAssertEqual(OutputMute.spokenLevel(volume: Float(percent) / 100, isMuted: true),
                           "muted, \(percent) percent")
        }
        XCTAssertFalse(OutputMute.spokenLevel(volume: 0.7, isMuted: true).contains("was"))
    }

    /// Zero is not muted. The button one control away offers "Mute Output"
    /// whenever the mute property is off, so a spoken value saying "muted"
    /// there is two adjacent elements contradicting each other. Zero percent
    /// already says there is no sound.
    func testALevelOfZeroIsNotCalledMutedWhileTheDeviceIsNot() {
        XCTAssertEqual(OutputMute.spokenLevel(volume: 0, isMuted: false), "0 percent")
        XCTAssertEqual(OutputMute.spokenLevel(volume: 0, isMuted: true), "muted",
                       "nothing behind the mute worth adding")
    }

    /// The glyph's rule and the word are deliberately different tests: a
    /// crossed-out speaker is true of either silence, "muted" only of the mute
    /// property. Silent-but-not-muted is the case that has to differ.
    func testTheGlyphRuleAndTheWordDisagreeOnPurposeAtZero() {
        XCTAssertTrue(OutputMute.isSilent(volume: 0, isMuted: false), "the glyph still crosses out")
        XCTAssertFalse(OutputMute.spokenLevel(volume: 0, isMuted: false).contains("muted"))
    }

    /// One definition of silence, shared by the glyph, the tint and the spoken
    /// value — the alternative is three thresholds that drift apart.
    func testSilenceIsTheMutePropertyOrTheLevel() {
        XCTAssertTrue(OutputMute.isSilent(volume: 0.62, isMuted: true))
        XCTAssertTrue(OutputMute.isSilent(volume: 0, isMuted: false))
        XCTAssertFalse(OutputMute.isSilent(volume: 0.62, isMuted: false))
        // No software volume at all — an HDMI display, many a DAC. The mute
        // property is the only thing left to go on.
        XCTAssertTrue(OutputMute.isSilent(volume: nil, isMuted: true))
        XCTAssertFalse(OutputMute.isSilent(volume: nil, isMuted: false))
    }

    /// Both ends of the glyph rule read this, so it has to mean silence rather
    /// than merely quiet.
    func testTheSilenceThresholdIsBelowAnythingAudible() {
        XCTAssertLessThan(OutputMute.silenceThreshold, 0.01 + .ulpOfOne)
        XCTAssertNil(OutputMute.levelToRestore(reported: OutputMute.silenceThreshold,
                                               remembered: 0.62),
                     "at the threshold there is already sound")
    }
}
