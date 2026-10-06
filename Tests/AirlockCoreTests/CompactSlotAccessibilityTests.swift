import XCTest
@testable import AirlockCore

/// The island is a lamp, a dot and a bare number. Without these labels every one
/// of those states is silent, and a label that disagrees with the state is worse
/// than silence — which is exactly the bug the lamp had.
final class CompactSlotAccessibilityTests: XCTestCase {

    // MARK: - The lamp

    /// The regression this whole extension exists for: the view derived the
    /// label from `working` alone, so a blocked session with nothing else
    /// running announced itself as "Idle".
    func testBlockedAndNotWorkingIsNotAnnouncedAsIdle() {
        let label = CompactSlot.agentLamp(attention: true, working: false).accessibilityLabel
        XCTAssertEqual(label, "Agent needs an answer")
        XCTAssertNotEqual(label, "Idle")
    }

    func testAttentionOutranksWorking() {
        XCTAssertEqual(CompactSlot.agentLamp(attention: true, working: true).accessibilityLabel,
                       "Agent needs an answer")
    }

    func testWorkingWithoutAttention() {
        XCTAssertEqual(CompactSlot.agentLamp(attention: false, working: true).accessibilityLabel,
                       "Agent working")
    }

    func testIdleOnlyWhenNothingIsWaitingOrRunning() {
        XCTAssertEqual(CompactSlot.agentLamp(attention: false, working: false).accessibilityLabel,
                       "Agent idle")
    }

    /// Every lamp state says something. A nil here is a silent island.
    func testEveryLampStateIsLabelled() {
        for attention in [true, false] {
            for working in [true, false] {
                let slot = CompactSlot.agentLamp(attention: attention, working: working)
                XCTAssertNotNil(slot.accessibilityLabel, "attention=\(attention) working=\(working)")
            }
        }
    }

    // MARK: - The dot

    /// Redundant with the lamp most of the time, and load-bearing the rest: with
    /// a completion tick in the leading slot this dot is the only gate signal.
    func testAttentionDotIsLabelledEvenThoughItUsuallyRepeatsTheLamp() {
        XCTAssertEqual(CompactSlot.attentionDot.accessibilityLabel, "Needs an answer")
    }

    /// Guards the reasoning above: if this precedence ever changes so that the
    /// lamp always accompanies the dot, the dot could be hidden instead.
    func testCompletionTickCanCoexistWithAnAttentionDot() {
        // `now` has no default — Core owns no clock — and nothing here is
        // time-dependent, so any fixed instant states that plainly.
        let input = CompactIslandInput(agentsEnabled: true, attentionCount: 1,
                                       sessionCount: 1, anyRunning: false,
                                       completionTick: true,
                                       now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(CompactIsland.leading(input), .completionTick)
        XCTAssertEqual(CompactIsland.trailing(input), .attentionDot)
    }

    // MARK: - The rest

    func testMediaSlotsDoNotClaimPlaybackStateTheyDoNotKnow() {
        // `.artwork` means a track is loaded; only `.wave` means playing.
        XCTAssertEqual(CompactSlot.artwork.accessibilityLabel, "Media")
        XCTAssertEqual(CompactSlot.wave.accessibilityLabel, "Playing")
    }

    func testCompletionTickIsLabelled() {
        XCTAssertEqual(CompactSlot.completionTick.accessibilityLabel, "Session finished")
    }

    func testMeetingIconIsLabelled() {
        XCTAssertEqual(CompactSlot.meetingIcon.accessibilityLabel, "Meeting soon")
    }

    /// Deliberately nil — the view completes it with the minutes, which come
    /// from a clock Core does not have.
    func testMeetingCountdownIsLeftToTheView() {
        XCTAssertNil(CompactSlot.meetingCountdown.accessibilityLabel)
    }

    func testEmptyIsSilent() {
        XCTAssertNil(CompactSlot.empty.accessibilityLabel)
    }

    // MARK: - The route acknowledgement

    /// The label says the percentage the view deliberately does not draw. That
    /// asymmetry is the reason labels live in Core: what fits in 30 points over
    /// somebody's menu-bar extras and what is useful to hear are different
    /// questions, and only one of them is about width.
    func testTheRouteAckNamesTheDeviceAndTheLevelEvenThoughTheViewDrawsABar() {
        XCTAssertEqual(
            CompactSlot.outputRoute(name: "AirPods Pro", transport: .bluetooth,
                                    level: 0.4, muted: false).accessibilityLabel,
            "Output: AirPods Pro, 40%")
    }

    /// Mute is a state, not a level. "0%" would be a different claim, and a
    /// wrong one — the level comes back when you unmute.
    func testAMutedRouteSaysMutedRatherThanZero() {
        let label = CompactSlot.outputRoute(name: "MacBook Pro Speakers", transport: .builtIn,
                                        level: 0.3, muted: true)
            .accessibilityLabel
        XCTAssertEqual(label, "Output: MacBook Pro Speakers, muted")
        XCTAssertNotEqual(label, "Output: MacBook Pro Speakers, 0%")
    }

    /// HDMI and many external DACs have no software volume. The device still
    /// gets named; there is simply no number to say.
    func testARouteWithNoSoftwareVolumeStillNamesTheDevice() {
        XCTAssertEqual(
            CompactSlot.outputRoute(name: "LG UltraFine", transport: .displayPort,
                                    level: nil, muted: false).accessibilityLabel,
            "Output: LG UltraFine")
    }

    /// CoreAudio's current-device UID can name a device that is not in the
    /// enumerated list for a beat. Saying the route moved beats inventing a name.
    func testAnUnknownDeviceSaysTheRouteChangedRatherThanInventingOne() {
        XCTAssertEqual(CompactSlot.outputRoute(name: nil, transport: .unknown,
                                    level: 0.5, muted: false).accessibilityLabel,
                       "Output changed")
        XCTAssertEqual(CompactSlot.outputRoute(name: "", transport: .unknown,
                                    level: nil, muted: false).accessibilityLabel,
                       "Output changed")
    }

    // MARK: - Battery

    func testACriticalBatterySaysHowLongIsLeft() {
        XCTAssertEqual(CompactSlot.batteryCritical(minutes: 18).accessibilityLabel,
                       "Battery critical, 18 minutes left")
        XCTAssertEqual(CompactSlot.batteryCritical(minutes: 1).accessibilityLabel,
                       "Battery critical, 1 minute left")
    }

    /// IOKit does not always have an estimate. The glyph is still true.
    func testACriticalBatteryWithNoEstimateStillSaysCritical() {
        XCTAssertEqual(CompactSlot.batteryCritical(minutes: nil).accessibilityLabel,
                       "Battery critical")
    }

    // MARK: - The shelf

    func testTheShelfCountIsSpokenAsFilesNotABareNumeral() {
        XCTAssertEqual(CompactSlot.shelfCount(3).accessibilityLabel, "3 files on the shelf")
        XCTAssertEqual(CompactSlot.shelfCount(1).accessibilityLabel, "1 file on the shelf")
    }

    // MARK: - Keep-awake

    /// A report, not the rail button's instruction ("Keep this Mac awake"):
    /// the cup says what is happening, and read aloud as an instruction it
    /// would sound like a prompt to go and press something.
    func testKeepAwakeIsSpokenAsWhatIsHappening() {
        XCTAssertEqual(CompactSlot.keepingAwake.accessibilityLabel, "Keeping this Mac awake")
    }

    /// Nothing new may be silent. `.meetingCountdown` is the one deliberate nil
    /// and is exempted by name; anything else nil is an island state a screen
    /// reader cannot see at all.
    func testEveryNewSlotSpeaks() {
        let slots: [CompactSlot] = [
            .outputRoute(name: "AirPods", transport: .bluetooth, level: 0.4, muted: false),
            .outputRoute(name: nil, transport: .unknown, level: nil, muted: true),
            .batteryCritical(minutes: 9), .batteryCritical(minutes: nil),
            .shelfCount(1), .shelfCount(12),
            .keepingAwake, .keepAwakeStopped(cutoff: 20),
            .usageNotice(.nearLimit(.fiveHour, percent: 90)), .usageNotice(.reset(.sevenDay)),
        ]
        for slot in slots {
            XCTAssertNotNil(slot.accessibilityLabel, "\(slot)")
        }
    }
}
