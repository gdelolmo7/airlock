import XCTest
@testable import AirlockCore

/// A rules pane without match counts is a list of sentences that all look
/// equally true.
///
/// The count is what makes a dead rule visible, so the thing these pin hardest
/// is what does NOT count: a gate you answered by hand is evidence the rule did
/// not cover it, and counting those would make the deadest rule in the file
/// look like the busiest.
final class RuleProvenanceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func record(_ rule: String, _ outcome: GateOutcome, at: Date? = nil) -> GateRecord {
        GateRecord(toolName: "Bash", subject: nil, ruleText: rule,
                   outcome: outcome, decidedAt: at ?? t0)
    }

    private func index(_ records: [GateRecord]) -> [String: RuleProvenance] {
        RuleProvenance.index(GateLog(records: records))
    }

    // MARK: - What counts as a match

    func testOnlyAutomaticOutcomesCount() {
        let result = index([
            record("Bash(git status)", .autoAllowed),
            record("Bash(git status)", .autoAllowed),
            record("Bash(git status)", .autoDenied),
        ])
        XCTAssertEqual(result["Bash(git status)"]?.matches, 3)
    }

    /// THE one. A hand-answered gate means the rule did not cover it.
    func testHandAnsweredGatesAreNotMatches() {
        let result = index([
            record("Bash(npm test *)", .allowedOnce),
            record("Bash(npm test *)", .denied),
            record("Bash(npm test *)", .deferred),
        ])
        // No automatic decision and no Always click, so the rule has no record
        // at all — and the caller's fallback is what reads as "never matched".
        XCTAssertNil(result["Bash(npm test *)"],
                     "answering by hand is evidence the rule did nothing")
        XCTAssertTrue((result["Bash(npm test *)"] ?? .unrecorded).hasNeverMatched)
    }

    func testARuleWithNoRecordsIsUnrecorded() {
        XCTAssertNil(index([])["Bash(anything)"])
        XCTAssertTrue(RuleProvenance.unrecorded.hasNeverMatched)
        XCTAssertNil(RuleProvenance.unrecorded.authoredAt)
    }

    // MARK: - Authorship

    /// The only evidence that a human wrote a rule, since the file cannot say.
    func testAnAlwaysClickIsWhatAuthorsARule() {
        let result = index([record("Bash(git diff *)", .alwaysAllowed, at: t0)])
        XCTAssertEqual(result["Bash(git diff *)"]?.authoredAt, t0)
    }

    /// A rule is created once. Later Always clicks on the same text are it
    /// being re-confirmed, not re-authored, so the earliest date wins.
    func testTheEarliestAlwaysClickWins() {
        let later = t0.addingTimeInterval(86_400)
        let result = index([
            record("Bash(git diff *)", .alwaysAllowed, at: later),
            record("Bash(git diff *)", .alwaysAllowed, at: t0),
        ])
        XCTAssertEqual(result["Bash(git diff *)"]?.authoredAt, t0)
    }

    /// No click, so nobody here wrote it — it came with the starter file.
    func testATemplateRuleHasNoAuthor() {
        let result = index([record("Bash(git status)", .autoAllowed)])
        XCTAssertEqual(result["Bash(git status)"]?.matches, 1)
        XCTAssertNil(result["Bash(git status)"]?.authoredAt)
    }

    /// Authored and busy at the same time — the common case for a rule that has
    /// been earning its place since the day it was clicked.
    func testARuleCanBeBothAuthoredAndMatched() {
        let result = index([
            record("Bash(npm test *)", .alwaysAllowed, at: t0),
            record("Bash(npm test *)", .autoAllowed),
            record("Bash(npm test *)", .autoAllowed),
        ])
        XCTAssertEqual(result["Bash(npm test *)"]?.matches, 2)
        XCTAssertEqual(result["Bash(npm test *)"]?.authoredAt, t0)
    }

    func testRulesDoNotBleedIntoEachOther() {
        let result = index([
            record("Bash(git status)", .autoAllowed),
            record("Bash(rm *)", .autoDenied),
        ])
        XCTAssertEqual(result["Bash(git status)"]?.matches, 1)
        XCTAssertEqual(result["Bash(rm *)"]?.matches, 1)
    }
}
