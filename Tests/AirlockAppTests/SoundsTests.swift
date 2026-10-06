import XCTest
import AirlockCore
@testable import AirlockApp

/// The sound wiring (card D2): each sounding moment reaches the player once,
/// with its file, at the levels that play it, and never on top of another.
/// Neither a real preference nor the speaker is touched.
@MainActor
final class SoundsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @MainActor private final class Rig {
        var level = SoundLevel.important
        var choice = Sounds.airlockChoice
        var now: Date
        var played: [String] = []
        var waiting: [(TimeInterval, @MainActor () -> Void)] = []
        init(now: Date) { self.now = now }
    }

    private func make(_ rig: Rig, _ moments: Moments) -> Sounds {
        Sounds(listeningTo: moments, level: { rig.level }, needsYouChoice: { rig.choice },
               clock: { rig.now }, length: { $0 == "AirlockNeedsYou" ? 1 : 0.5 },
               play: { rig.played.append($0) }, later: { rig.waiting.append(($0, $1)) })
    }

    func testOnlyImportantPlaysTheCallAndTheChime() {
        let moments = Moments(), rig = Rig(now: t0)
        let sounds = make(rig, moments)
        moments.announce(.gateArrived, now: t0)
        rig.now = t0.addingTimeInterval(2)
        moments.announce(.approved, now: rig.now)
        moments.announce(.guideEnded, now: rig.now)
        moments.announce(.agentFinished, now: rig.now)
        XCTAssertEqual(rig.played, ["AirlockNeedsYou", "AirlockDone"])
        _ = sounds
    }

    func testAllPlaysTheOtherTwo() {
        let moments = Moments(), rig = Rig(now: t0)
        rig.level = .all
        let sounds = make(rig, moments)
        moments.announce(.approved, now: t0)
        rig.now = t0.addingTimeInterval(1)
        moments.announce(.guideEnded, now: rig.now)
        XCTAssertEqual(rig.played, ["AirlockApproved", "AirlockWentWrong"])
        _ = sounds
    }

    func testOffIsSilent() {
        let moments = Moments(), rig = Rig(now: t0)
        rig.level = .off
        let sounds = make(rig, moments)
        for moment in Moment.allCases { moments.announce(moment, now: t0) }
        XCTAssertEqual(rig.played, [])
        XCTAssertTrue(rig.waiting.isEmpty)
        _ = sounds
    }

    /// Somebody who picked a Mac sound for the gate keeps it.
    func testTheGateCanStillBeAMacSound() {
        let moments = Moments(), rig = Rig(now: t0)
        rig.choice = "Submarine"
        let sounds = make(rig, moments)
        moments.announce(.gateArrived, now: t0)
        XCTAssertEqual(rig.played, ["Submarine"])
        XCTAssertEqual(Sounds.name(for: .done, needsYouChoice: "Submarine"), "AirlockDone")
        _ = sounds
    }

    /// A gate arriving as an agent finishes: the chime, then the call once
    /// the chime is over — and a replaced one never plays.
    func testTheCallWaitsForTheChime() {
        let moments = Moments(), rig = Rig(now: t0)
        rig.level = .all
        let sounds = make(rig, moments)
        moments.announce(.approved, now: t0)
        rig.now = t0.addingTimeInterval(0.1)
        moments.announce(.agentFinished, now: rig.now)
        rig.now = t0.addingTimeInterval(0.2)
        moments.announce(.gateArrived, now: rig.now)
        XCTAssertEqual(rig.played, ["AirlockApproved"])
        XCTAssertEqual(rig.waiting.map(\.0).map { ($0 * 10).rounded() / 10 }, [0.4, 0.3])
        for (_, action) in rig.waiting { action() }
        XCTAssertEqual(rig.played, ["AirlockApproved", "AirlockNeedsYou"])
        _ = sounds
    }

    func testEveryResourceFileIsInTheRepo() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Sounds")
        for sound in AirlockSound.allCases {
            let file = folder.appendingPathComponent(sound.resourceName + ".wav")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
        }
    }
}
