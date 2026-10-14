import XCTest
@testable import AirlockApp

/// The trial-ended card's sentence. The look is the gallery's (L4, L4a, L4b,
/// A9); these pin what it promises, which a rewording can quietly drop.
@MainActor
final class LicenseBlockedViewTests: XCTestCase {
    /// The words keep their promises: what is kept, what comes back, and —
    /// only with agents on — where the agents ask meanwhile.
    func testTheWordsKeepTheirPromises() {
        let trial = LicenseBlockedView.explanation(surface: LicenseBlockedView.panel,
                                                   subscribedBefore: false, agentsAsk: false)
        XCTAssertTrue(trial.contains("Everything you've saved is still here"), trial)
        XCTAssertTrue(trial.contains("the panel, dictation and asking come straight back"), trial)
        XCTAssertFalse(trial.contains(LicenseBlockedView.agentsMeanwhile), trial)

        let agents = LicenseBlockedView.explanation(surface: LicenseBlockedView.panel,
                                                    subscribedBefore: false, agentsAsk: true)
        XCTAssertTrue(agents.hasSuffix(LicenseBlockedView.agentsMeanwhile), agents)

        let returning = LicenseBlockedView.explanation(surface: LicenseBlockedView.panel,
                                                       subscribedBefore: true, agentsAsk: false)
        XCTAssertTrue(returning.contains("nothing was deleted"), returning)
        XCTAssertFalse(returning.contains("trial"), "a past customer is not told about a trial")

        let tab = LicenseBlockedView.explanation(surface: AgentsWidget.lockedSurface,
                                                 subscribedBefore: false, agentsAsk: false)
        XCTAssertTrue(tab.contains("the Agents tab comes straight back"), tab)
    }
}
