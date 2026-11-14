import XCTest
@testable import AirlockCore

final class AddOnTests: XCTestCase {
    // MARK: - The list

    func testTheSixAddOnsInOrder() {
        XCTAssertEqual(AddOn.allCases,
                       [.shelf, .clipboard, .meetingNotes, .codingAgents, .windowLayouts, .dictation])
    }

    func testEveryAddOnHasANameAndALine() {
        for addOn in AddOn.allCases {
            XCTAssertFalse(addOn.displayName.isEmpty, "\(addOn)")
            XCTAssertFalse(addOn.summary.isEmpty, "\(addOn)")
        }
    }

    /// Home and Dashboard are the base app; no add-on may claim them, or
    /// switching it off would take away something the base promises.
    func testTabsBroughtAndNeverTheBaseOnes() {
        XCTAssertEqual(AddOn.shelf.tabID, "tray")
        XCTAssertEqual(AddOn.clipboard.tabID, "clipboard")
        XCTAssertEqual(AddOn.meetingNotes.tabID, "calls")
        XCTAssertEqual(AddOn.codingAgents.tabID, "agents")
        XCTAssertNil(AddOn.windowLayouts.tabID)
        XCTAssertNil(AddOn.dictation.tabID)
        let tabs = AddOn.allCases.compactMap(\.tabID)
        XCTAssertFalse(tabs.contains("home"))
        XCTAssertFalse(tabs.contains("dashboard"))
        XCTAssertEqual(Set(tabs).count, tabs.count, "two add-ons cannot share a tab")
    }

    /// Each card says where the add-on shows up and what macOS will be asked
    /// for, so nothing it does after "Add" comes as a surprise.
    func testEveryCardSaysWhereItGoesAndWhatItAsks() {
        for addOn in AddOn.allCases {
            XCTAssertFalse(addOn.notchPlace.isEmpty, "\(addOn)")
            XCTAssertTrue(addOn.asks.hasPrefix("Asks for"), "\(addOn)")
        }
        // One that brings a tab says so, by the tab's name.
        XCTAssertTrue(AddOn.shelf.notchPlace.contains("Shelf"))
        XCTAssertTrue(AddOn.meetingNotes.notchPlace.contains("Calls"))
        XCTAssertTrue(AddOn.dictation.notchPlace.hasPrefix("No tab"))
        XCTAssertTrue(AddOn.windowLayouts.notchPlace.hasPrefix("No tab"))
        // The ones that need a permission name it.
        XCTAssertTrue(AddOn.meetingNotes.asks.contains("microphone"))
        XCTAssertTrue(AddOn.dictation.asks.contains("microphone"))
        XCTAssertTrue(AddOn.windowLayouts.asks.contains("Accessibility"))
        XCTAssertEqual(AddOn.shelf.asks, "Asks for nothing")
    }

    func testOnlyMeetingNotesCarriesAPlanBadge() {
        XCTAssertEqual(AddOn.meetingNotes.planBadge, "Plus for full notes")
        for addOn in AddOn.allCases where addOn != .meetingNotes {
            XCTAssertNil(addOn.planBadge, "\(addOn)")
        }
    }

    // MARK: - The seed's rule

    private func evidence(ran: Bool = false, finished: Bool = false, started: Bool = false,
                          stored: Bool = false, launched: Bool = false) -> AddOnSeed.Evidence {
        AddOnSeed.Evidence(alreadyRan: ran, setupFinished: finished, setupStarted: started,
                           anySwitchStored: stored, launchedBefore: launched)
    }

    func testNothingStoredIsAFreshInstall() {
        XCTAssertEqual(AddOnSeed.decide(evidence()), .freshInstall)
    }

    func testAnyTraceOfUseIsAnExistingInstall() {
        XCTAssertEqual(AddOnSeed.decide(evidence(finished: true)), .existingInstall)
        XCTAssertEqual(AddOnSeed.decide(evidence(started: true)), .existingInstall)
        XCTAssertEqual(AddOnSeed.decide(evidence(stored: true)), .existingInstall)
        XCTAssertEqual(AddOnSeed.decide(evidence(launched: true)), .existingInstall)
    }

    func testTheSentinelOutranksEverything() {
        XCTAssertEqual(AddOnSeed.decide(evidence(ran: true)), .alreadyRan)
        XCTAssertEqual(AddOnSeed.decide(evidence(ran: true, finished: true, stored: true)), .alreadyRan)
    }

    // MARK: - Against real defaults

    private let switches = ["tray.enabled", "widget.clipboard.enabled", "meetings.enabled",
                            "widget.agents.enabled", "windowLayouts.enabled", "dictation.enabled"]
    private let finishedKey = "onboarding.completed"
    private let startedKey = "onboarding.resumeStep"
    private let markerKey = "whatsNew.lastSeenVersion"
    private let baseKey = "widget.system.enabled"

    private func scratchDefaults() -> (UserDefaults, String) {
        let suite = "airlock.addon-seed-tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func run(_ defaults: UserDefaults) -> AddOnSeed.Decision {
        AddOnSeed.run(in: defaults, switchKeys: switches, setupFinishedKey: finishedKey,
                      setupStartedKey: startedKey, launchMarkerKeys: [markerKey],
                      baseOnKeys: [baseKey])
    }

    /// Every add-on starts on by its own model's default, so a fresh install
    /// writes none of their keys; only the base app's This Mac is switched on.
    func testAFreshInstallLeavesEveryAddOnOnAndSwitchesThisMacOn() {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(run(defaults), .freshInstall)
        for key in switches {
            XCTAssertNil(defaults.object(forKey: key), "\(key) must keep its model's default (on)")
        }
        XCTAssertEqual(defaults.object(forKey: baseKey) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: AddOnSeed.sentinelKey) as? Bool, true)
    }

    func testAnExistingInstallIsMarkedAndOtherwiseUntouched() {
        for setUp in [{ (d: UserDefaults) in d.set(true, forKey: self.finishedKey) },
                      { (d: UserDefaults) in d.set("agents", forKey: self.startedKey) },
                      { (d: UserDefaults) in d.set(true, forKey: "widget.clipboard.enabled") },
                      { (d: UserDefaults) in d.set(false, forKey: "dictation.enabled") },
                      { (d: UserDefaults) in d.set("1.2.0", forKey: self.markerKey) }] {
            let (defaults, suite) = scratchDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            setUp(defaults)
            let before = defaults.persistentDomain(forName: suite) ?? [:]

            XCTAssertEqual(run(defaults), .existingInstall)
            var after = defaults.persistentDomain(forName: suite) ?? [:]
            XCTAssertEqual(after.removeValue(forKey: AddOnSeed.sentinelKey) as? Bool, true)
            XCTAssertEqual(after as NSDictionary, before as NSDictionary,
                           "nothing but the sentinel may change on an existing install")
        }
    }

    /// The second launch of a fresh install, after its owner switched This
    /// Mac off and the key went away, must not switch it on again.
    func testRunsOnce() {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(run(defaults), .freshInstall)
        defaults.removeObject(forKey: baseKey)
        XCTAssertEqual(run(defaults), .alreadyRan)
        XCTAssertNil(defaults.object(forKey: baseKey))
    }
}
