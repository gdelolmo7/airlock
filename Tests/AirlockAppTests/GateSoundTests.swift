import AppKit
import XCTest
@testable import AirlockApp

/// The sound itself cannot be asserted — playing returns before
/// anything is audible, and there is no output device in a test process. What
/// can be asserted is everything that decides WHETHER it plays, which is the
/// part with opinions in it.
@MainActor
final class GateSoundTests: XCTestCase {

    /// Airlock's own Needs you first (card D2). Whether a gate makes a sound
    /// at all is the Sounds level now, tested in `SoundsTests` and Core's
    /// `AirlockSoundTests` without a real preference.
    func testAirlocksOwnSoundComesFirst() {
        XCTAssertEqual(AgentsWidgetModel.gateSoundChoices.first, Sounds.airlockChoice)
        XCTAssertEqual(Sounds.name(for: .needsYou, needsYouChoice: Sounds.airlockChoice), "AirlockNeedsYou")
    }

    /// Every offered name must actually resolve to a sound on this system —
    /// a picker entry that silently does nothing is worse than a shorter list,
    /// because the user concludes the feature is broken rather than the name.
    func testEveryOfferedSoundExists() {
        for name in AgentsWidgetModel.gateSoundChoices where name != Sounds.airlockChoice {
            XCTAssertNotNil(NSSound(named: name), "\(name) is not a system sound")
            XCTAssertNotNil(Sounds.url(for: name), "\(name) has no file to play")
        }
    }

    /// macOS's error sounds say the wrong thing about a gate: it is a question
    /// waiting on you, not a failure.
    func testNoErrorSoundsAreOffered() {
        for banned in ["Basso", "Funk", "Sosumi"] {
            XCTAssertFalse(AgentsWidgetModel.gateSoundChoices.contains(banned),
                           "\(banned) reads as an error")
        }
    }

    /// The stored name is what plays, so an unknown one — a preference written
    /// by an older build, or by hand — must not crash. `NSSound(named:)` returns
    /// nil and `play()` is simply never reached.
    func testAnUnknownSoundNameIsHarmless() {
        let model = AgentsWidgetModel()
        model.gateSoundName = "NotARealSound-\(UUID().uuidString)"
        model.playGateSound()  // must not trap
        UserDefaults.standard.removeObject(forKey: "agents.gateSoundName")
    }
}
