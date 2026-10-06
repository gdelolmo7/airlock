import XCTest
@testable import AirlockCore

final class AgentsPresenceTests: XCTestCase {
    // MARK: - Derived, before anyone has been asked

    func testNoHooksMeansNoAgentSurfaces() {
        XCTAssertEqual(AgentsPresence.basis(choice: nil, hookStatuses: [.notInstalled, .notInstalled]),
                       .noHooksInstalled)
        XCTAssertFalse(AgentsPresence.resolve(choice: nil, hookStatuses: [.notInstalled]))
    }

    func testAnyInstalledHookTurnsThemOn() {
        XCTAssertEqual(AgentsPresence.basis(choice: nil, hookStatuses: [.notInstalled, .installed]),
                       .hooksInstalled)
        XCTAssertTrue(AgentsPresence.resolve(choice: nil, hookStatuses: [.notInstalled, .installed]))
    }

    /// A conflict is somebody who HAS been wiring an agent up, and the Agents
    /// pane is where the conflict gets explained — hiding it would hide the fix.
    func testConflictCountsAsWiredUp() {
        XCTAssertEqual(AgentsPresence.basis(choice: nil, hookStatuses: [.conflict("unmanaged entries")]),
                       .hooksInstalled)
        XCTAssertTrue(AgentsPresence.resolve(choice: nil, hookStatuses: [.conflict("x")]))
    }

    /// The registry could in principle be empty in a build with no integrations;
    /// that is "nobody is wired up", not a crash and not a default-on.
    func testNoAgentsAtAllIsOff() {
        XCTAssertFalse(AgentsPresence.resolve(choice: nil, hookStatuses: []))
    }

    // MARK: - An explicit choice outranks everything

    func testChoosingOffSurvivesAnInstalledHook() {
        XCTAssertEqual(AgentsPresence.basis(choice: false, hookStatuses: [.installed]),
                       .chosen(false))
        XCTAssertFalse(AgentsPresence.resolve(choice: false, hookStatuses: [.installed]))
    }

    /// The direction that matters most: somebody who wants the Agents tab
    /// BEFORE wiring hooks up must not have it taken away for being early.
    func testChoosingOnSurvivesNoHooksAtAll() {
        XCTAssertEqual(AgentsPresence.basis(choice: true, hookStatuses: [.notInstalled]),
                       .chosen(true))
        XCTAssertTrue(AgentsPresence.resolve(choice: true, hookStatuses: [.notInstalled]))
    }

    /// Uninstalling hooks must not silently flip a switch the user set — the
    /// difference between "never asked" and "answered no" is the whole point of
    /// the optional `choice`.
    func testAChoiceIsNotDerivedAndSoNeverMoves() {
        XCTAssertFalse(AgentsPresence.basis(choice: true, hookStatuses: []).isDerived)
        XCTAssertFalse(AgentsPresence.basis(choice: false, hookStatuses: [.installed]).isDerived)
        XCTAssertTrue(AgentsPresence.basis(choice: nil, hookStatuses: [.installed]).isDerived)
        XCTAssertTrue(AgentsPresence.basis(choice: nil, hookStatuses: [.notInstalled]).isDerived)
    }

    /// Installing hooks later is exactly the case the derived default exists
    /// for: an agent user who found the app as a notch companion first.
    func testInstallingHooksLaterTurnsThemOnByItself() {
        let before = AgentsPresence.resolve(choice: nil, hookStatuses: [.notInstalled, .notInstalled])
        let after = AgentsPresence.resolve(choice: nil, hookStatuses: [.installed, .notInstalled])
        XCTAssertFalse(before)
        XCTAssertTrue(after)
    }
}
