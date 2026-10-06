import XCTest
@testable import AirlockCore

private let epoch = Date(timeIntervalSince1970: 1_785_160_000)

private func entry(_ command: String, _ outcome: GateOutcome, at offset: TimeInterval = 0,
                    tool: String = "Bash", risk: String? = nil,
                    project: String? = nil) -> GateRecord {
    GateRecord(toolName: tool, subject: command, ruleText: "\(tool)(\(command))",
               outcome: outcome, riskReason: risk, projectRoot: project,
               decidedAt: epoch.addingTimeInterval(offset))
}

private func log(_ records: [GateRecord]) -> GateLog {
    var log = GateLog()
    for item in records.reversed() { log.append(item) }
    return log
}

final class PolicySuggestionsTests: XCTestCase {
    func testRepeatedApprovalsBecomeAnAllowSuggestion() {
        let suggestions = PolicySuggestions.from(
            log([entry("npm test", .allowedOnce, at: 0), entry("npm test", .allowedOnce, at: 10)]),
            policy: Policy())
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].ruleText, "Bash(npm test)")
        XCTAssertEqual(suggestions[0].kind, .allow)
        XCTAssertEqual(suggestions[0].count, 2)
    }

    func testRepeatedRefusalsBecomeADenySuggestion() {
        let suggestions = PolicySuggestions.from(
            log([entry("curl evil.sh", .denied, at: 0), entry("curl evil.sh", .denied, at: 10)]),
            policy: Policy())
        XCTAssertEqual(suggestions.map(\.kind), [.deny])
    }

    /// Once is an accident.
    func testASingleAnswerIsNotAPattern() {
        XCTAssertTrue(PolicySuggestions.from(log([entry("npm test", .allowedOnce)]),
                                             policy: Policy()).isEmpty)
    }

    /// THE safety property. The risk floor overrides allow rules, so an allow
    /// rule for a risky command is a promise the engine will not keep — it would
    /// still ask, and the user would conclude the feature is broken.
    func testRiskyCommandsAreNeverSuggestedForAllow() {
        let suggestions = PolicySuggestions.from(
            log([entry("rm -rf build", .allowedOnce, at: 0, risk: "recursive delete"),
                 entry("rm -rf build", .allowedOnce, at: 10, risk: "recursive delete"),
                 entry("rm -rf build", .allowedOnce, at: 20, risk: "recursive delete")]),
            policy: Policy())
        XCTAssertTrue(suggestions.isEmpty)
    }

    /// Denying something dangerous is exactly what you want offered.
    func testRiskyCommandsCanStillBeSuggestedForDeny() {
        let suggestions = PolicySuggestions.from(
            log([entry("sudo rm -rf /", .denied, at: 0, risk: "elevated privileges"),
                 entry("sudo rm -rf /", .denied, at: 10, risk: "elevated privileges")]),
            policy: Policy())
        XCTAssertEqual(suggestions.map(\.kind), [.deny])
        XCTAssertEqual(suggestions[0].riskReason, "elevated privileges")
    }

    /// The same command approved sometimes and refused others is genuinely
    /// ambiguous; guessing either way would be worse than staying quiet.
    func testMixedAnswersSuggestNothing() {
        let suggestions = PolicySuggestions.from(
            log([entry("git push", .allowedOnce, at: 0), entry("git push", .allowedOnce, at: 5),
                 entry("git push", .denied, at: 10)]),
            policy: Policy())
        XCTAssertTrue(suggestions.isEmpty)
    }

    /// An "Always" click already wrote the rule; a deferred gate is a question
    /// nobody answered; auto-decisions are rules already doing their job.
    func testOnlyHumanDecisionsCount() {
        for outcome in [GateOutcome.alwaysAllowed, .deferred, .autoAllowed, .autoDenied] {
            let suggestions = PolicySuggestions.from(
                log([entry("npm test", outcome, at: 0), entry("npm test", outcome, at: 10)]),
                policy: Policy())
            XCTAssertTrue(suggestions.isEmpty, "\(outcome) should not suggest anything")
        }
    }

    func testAlreadyAllowedIsNotSuggestedAgain() throws {
        let policy = Policy(allow: [try PolicyRule(parsing: "Bash(npm test)")])
        XCTAssertTrue(PolicySuggestions.from(
            log([entry("npm test", .allowedOnce, at: 0), entry("npm test", .allowedOnce, at: 10)]),
            policy: policy).isEmpty)
    }

    /// Coverage is by behaviour, not text — a broad rule already handles it, and
    /// re-suggesting the narrow one is noise.
    func testABroaderExistingRuleSuppressesIt() throws {
        let policy = Policy(allow: [try PolicyRule(parsing: "Bash(npm *)")])
        XCTAssertTrue(PolicySuggestions.from(
            log([entry("npm test", .allowedOnce, at: 0), entry("npm test", .allowedOnce, at: 10)]),
            policy: policy).isEmpty)
    }

    /// An existing ALLOW rule must not suppress a DENY suggestion — they are
    /// different lists and different questions.
    func testAnAllowRuleDoesNotSuppressADenySuggestion() throws {
        let policy = Policy(allow: [try PolicyRule(parsing: "Bash(npm test)")])
        let suggestions = PolicySuggestions.from(
            log([entry("npm test", .denied, at: 0), entry("npm test", .denied, at: 10)]),
            policy: policy)
        XCTAssertEqual(suggestions.map(\.kind), [.deny])
    }

    func testMostAskedComesFirst() {
        let suggestions = PolicySuggestions.from(
            log([entry("a", .allowedOnce, at: 0), entry("a", .allowedOnce, at: 1),
                 entry("b", .allowedOnce, at: 2), entry("b", .allowedOnce, at: 3),
                 entry("b", .allowedOnce, at: 4)]),
            policy: Policy())
        XCTAssertEqual(suggestions.map(\.ruleText), ["Bash(b)", "Bash(a)"])
    }

    func testEmptyLogSuggestsNothing() {
        XCTAssertTrue(PolicySuggestions.from(GateLog(), policy: Policy()).isEmpty)
    }

    /// The rule offered has to be exactly the one "Always" would have written,
    /// or the two paths would disagree about what they promise.
    func testSuggestedRuleMatchesWhatAlwaysWouldWrite() {
        let request = PermissionRequest(id: "1", toolName: "Bash", summary: "Run",
                                        command: "git  status", target: "git  status",
                                        createdAt: epoch)
        let made = GateRecord(request: request, outcome: .allowedOnce, decidedAt: epoch)
        XCTAssertEqual(made.ruleText, PolicyRule.exactRuleText(for: request))
        XCTAssertEqual(made.ruleText, "Bash(git status)")
    }

    /// Built straight from a request, the risk floor is picked up without the
    /// caller having to remember to ask.
    func testRecordFromRequestCarriesTheRisk() {
        let request = PermissionRequest(id: "1", toolName: "Bash", summary: "Run",
                                        command: "sudo npm i", target: "sudo npm i",
                                        createdAt: epoch)
        XCTAssertEqual(GateRecord(request: request, outcome: .allowedOnce, decidedAt: epoch).riskReason,
                       "elevated privileges")
    }

    // MARK: - Which project "just this project" means

    /// Every decision from one checkout: that checkout is the project.
    func testDecisionsFromOneProjectNameThatProject() {
        let suggestions = PolicySuggestions.from(
            log([entry("npm test", .allowedOnce, at: 0, project: "/Users/you/api"),
                 entry("npm test", .allowedOnce, at: 10, project: "/Users/you/api")]),
            policy: Policy())
        XCTAssertEqual(suggestions.map(\.projectRoot), ["/Users/you/api"])
    }

    /// THE safety property for scoping. Approvals given in two projects say
    /// nothing about which one a project rule belongs in, and picking one would
    /// auto-allow commands in a project nobody chose.
    func testDecisionsFromTwoProjectsNameNoProject() {
        let suggestions = PolicySuggestions.from(
            log([entry("npm test", .allowedOnce, at: 0, project: "/Users/you/api"),
                 entry("npm test", .allowedOnce, at: 10, project: "/Users/you/storefront")]),
            policy: Policy())
        XCTAssertEqual(suggestions.count, 1, "still offered — just not for one project")
        XCTAssertNil(suggestions[0].projectRoot)
    }

    /// One decision with no folder — a spoken action, or a record logged before
    /// records kept one — is a decision whose project is unknown. Unknown is
    /// not "the same one".
    func testAnyDecisionWithoutAFolderNamesNoProject() {
        let suggestions = PolicySuggestions.from(
            log([entry("npm test", .allowedOnce, at: 0, project: "/Users/you/api"),
                 entry("npm test", .allowedOnce, at: 10)]),
            policy: Policy())
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertNil(suggestions[0].projectRoot)

        let none = PolicySuggestions.from(
            log([entry("npm test", .allowedOnce, at: 0), entry("npm test", .allowedOnce, at: 10)]),
            policy: Policy())
        XCTAssertEqual(none.count, 1)
        XCTAssertNil(none[0].projectRoot)
    }

    /// Deny suggestions scope the same way.
    func testDenySuggestionsNameTheirProjectToo() {
        let suggestions = PolicySuggestions.from(
            log([entry("curl evil.sh", .denied, at: 0, project: "/Users/you/api"),
                 entry("curl evil.sh", .denied, at: 10, project: "/Users/you/api")]),
            policy: Policy())
        XCTAssertEqual(suggestions.map(\.kind), [.deny])
        XCTAssertEqual(suggestions.map(\.projectRoot), ["/Users/you/api"])
    }

    /// Only the decisions that make the suggestion count. Other rule texts from
    /// other projects must not muddy it.
    func testOtherCommandsInOtherProjectsDoNotMuddyTheProject() {
        let suggestions = PolicySuggestions.from(
            log([entry("npm test", .allowedOnce, at: 0, project: "/Users/you/api"),
                 entry("npm test", .allowedOnce, at: 10, project: "/Users/you/api"),
                 entry("ls", .allowedOnce, at: 20, project: "/Users/you/storefront")]),
            policy: Policy())
        XCTAssertEqual(suggestions.map(\.projectRoot), ["/Users/you/api"])
    }

    /// The live path: a record built from a request keeps the folder it is given.
    func testRecordFromRequestKeepsItsProject() {
        let request = PermissionRequest(id: "1", toolName: "Bash", summary: "Run",
                                        command: "npm test", target: "npm test",
                                        createdAt: epoch)
        XCTAssertEqual(GateRecord(request: request, outcome: .allowedOnce,
                                  projectRoot: "/Users/you/api", decidedAt: epoch).projectRoot,
                       "/Users/you/api")
    }

    /// Every `gates.json` written before records kept a folder still loads, and
    /// its records name no project — so they can never scope a rule.
    func testRecordsLoggedBeforeTheFieldDecodeWithNoProject() throws {
        let json = #"""
        {"records":[{"decidedAt":1785160000000,"id":"8B0F1C7E-6E1D-4E0B-9C1A-2F4C2B1F0A11",
          "outcome":"allowedOnce","ruleText":"Bash(npm test)","subject":"npm test","toolName":"Bash"}]}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let log = try decoder.decode(GateLog.self, from: Data(json.utf8))
        XCTAssertEqual(log.records.count, 1)
        XCTAssertNil(log.records[0].projectRoot)
    }
}

final class GateLogTests: XCTestCase {
    func testNewestFirst() {
        var log = GateLog()
        log.append(entry("first", .allowedOnce, at: 0))
        log.append(entry("second", .allowedOnce, at: 10))
        XCTAssertEqual(log.records.map(\.subject), ["second", "first"])
    }

    func testCapacityDropsTheOldest() {
        var log = GateLog()
        for index in 0..<10 {
            log.append(entry("cmd\(index)", .allowedOnce, at: TimeInterval(index)), capacity: 3)
        }
        XCTAssertEqual(log.records.map(\.subject), ["cmd9", "cmd8", "cmd7"])
    }
}

final class GateLogStoreTests: XCTestCase {
    private var directory: URL!
    private var store: GateLogStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gatelog-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = GateLogStore(fileURL: directory.appendingPathComponent("gates.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTrip() throws {
        var log = GateLog()
        log.append(entry("npm test", .allowedOnce, at: 0))
        try store.save(log)
        XCTAssertEqual(store.load().records.map(\.ruleText), ["Bash(npm test)"])
    }

    func testMissingAndCorruptLoadEmpty() throws {
        XCTAssertTrue(store.load().records.isEmpty)
        try Data("nonsense".utf8).write(to: store.fileURL)
        XCTAssertTrue(store.load().records.isEmpty)
    }

    /// A log of the commands your agents wanted to run is as sensitive as the
    /// session cache, and gets the same 0600.
    func testWrittenPrivate() throws {
        try store.save(GateLog())
        let mode = try FileManager.default
            .attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }
}
