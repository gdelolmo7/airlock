import XCTest
@testable import AirlockCore

/// Which moment plays which of the four sounds, at which level, and what
/// happens when two land together (card D2).
final class AirlockSoundTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testTheMomentsThatMakeASound() {
        let sounding = Dictionary(uniqueKeysWithValues: Moment.allCases.compactMap { moment in
            moment.sound.map { (moment, $0) }
        })
        XCTAssertEqual(sounding, [
            .gateArrived: .needsYou,
            .agentFinished: .done, .guideDone: .done,
            .approved: .approved,
            .agentFailed: .wentWrong, .guideEnded: .wentWrong,
        ])
    }

    /// Things you just did or just saw make no sound at any level.
    func testEverydayMomentsAreSilent() {
        for moment in [Moment.copied, .tabChanged, .islandOpened, .fileDropped, .denied, .guideStep] {
            XCTAssertNil(moment.sound, "\(moment)")
        }
    }

    func testEachLevelPlaysItsSounds() {
        XCTAssertEqual(AirlockSound.allCases.filter(SoundLevel.off.plays), [])
        XCTAssertEqual(AirlockSound.allCases.filter(SoundLevel.important.plays), [.needsYou, .done])
        XCTAssertEqual(AirlockSound.allCases.filter(SoundLevel.all.plays), AirlockSound.allCases)
    }

    func testTheFilesHaveTheirNames() {
        XCTAssertEqual(AirlockSound.allCases.map(\.resourceName),
                       ["AirlockNeedsYou", "AirlockDone", "AirlockApproved", "AirlockWentWrong"])
    }

    // MARK: Which level

    func testNobodyAskedGetsOnlyImportant() {
        XCTAssertEqual(SoundLevel.resolve(stored: nil, legacyGateSound: nil), .important)
        XCTAssertEqual(SoundLevel.default, .important)
    }

    /// The old gate sound was off unless switched on. Switched on keeps a
    /// sound; switched off, by hand, keeps silence.
    func testTheOldGateSwitchCarriesOver() {
        XCTAssertEqual(SoundLevel.resolve(stored: nil, legacyGateSound: true), .important)
        XCTAssertEqual(SoundLevel.resolve(stored: nil, legacyGateSound: false), .off)
    }

    func testTheNewSettingWins() {
        XCTAssertEqual(SoundLevel.resolve(stored: "all", legacyGateSound: false), .all)
        XCTAssertEqual(SoundLevel.resolve(stored: "off", legacyGateSound: true), .off)
    }

    func testAnUnknownStoredLevelFallsBack() {
        XCTAssertEqual(SoundLevel.resolve(stored: "loud", legacyGateSound: nil), .important)
        XCTAssertEqual(SoundLevel.resolve(stored: "loud", legacyGateSound: false), .off)
    }

    // MARK: Never two at once

    func testApartTheyBothPlay() {
        var overlap = SoundOverlap()
        XCTAssertEqual(overlap.admit(.done, length: 0.6, at: t0), .now)
        XCTAssertEqual(overlap.admit(.needsYou, length: 1, at: t0.addingTimeInterval(0.6)), .now)
    }

    /// An agent finishing under the call is dropped: the call is the one with
    /// somebody waiting behind it.
    func testALesserSoundUnderAGreaterIsDropped() {
        var overlap = SoundOverlap()
        XCTAssertEqual(overlap.admit(.needsYou, length: 1, at: t0), .now)
        XCTAssertEqual(overlap.admit(.done, length: 0.6, at: t0.addingTimeInterval(0.3)), .skip)
        XCTAssertEqual(overlap.admit(.needsYou, length: 1, at: t0.addingTimeInterval(0.5)), .skip)
    }

    /// A gate arriving as an agent finishes: the chime, then the call.
    func testAGreaterSoundWaitsForTheLesserToEnd() {
        var overlap = SoundOverlap()
        XCTAssertEqual(overlap.admit(.done, length: 0.6, at: t0), .now)
        XCTAssertEqual(overlap.admit(.needsYou, length: 1, at: t0.addingTimeInterval(0.2)),
                       .at(t0.addingTimeInterval(0.6)))
        // Busy until the call ends.
        XCTAssertEqual(overlap.admit(.done, length: 0.6, at: t0.addingTimeInterval(1.2)), .skip)
        XCTAssertEqual(overlap.admit(.done, length: 0.6, at: t0.addingTimeInterval(1.6)), .now)
    }

    /// Only one waits: a still more important one takes its slot.
    func testAWaitingSoundIsReplacedByAGreaterOne() {
        var overlap = SoundOverlap()
        XCTAssertEqual(overlap.admit(.approved, length: 0.5, at: t0), .now)
        XCTAssertEqual(overlap.admit(.done, length: 0.6, at: t0.addingTimeInterval(0.1)),
                       .at(t0.addingTimeInterval(0.5)))
        XCTAssertEqual(overlap.admit(.needsYou, length: 1, at: t0.addingTimeInterval(0.2)),
                       .at(t0.addingTimeInterval(0.5)))
        XCTAssertEqual(overlap.admit(.wentWrong, length: 0.6, at: t0.addingTimeInterval(0.3)), .skip)
    }

    func testAClockThatWentBackwardsDoesNotSilence() {
        var overlap = SoundOverlap()
        XCTAssertEqual(overlap.admit(.needsYou, length: 1, at: t0), .now)
        XCTAssertEqual(overlap.admit(.done, length: 0.6, at: t0.addingTimeInterval(-3600)), .now)
    }
}
