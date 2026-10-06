import XCTest
@testable import AirlockCore

private let epoch = Date(timeIntervalSince1970: 1_785_160_000)

private func bash(_ command: String) -> PermissionRequest {
    PermissionRequest(id: "1", toolName: "Bash", summary: "Run",
                      command: command, target: command, createdAt: epoch)
}

private func edit(_ path: String) -> PermissionRequest {
    PermissionRequest(id: "1", toolName: "Edit", summary: "Edit", target: path, createdAt: epoch)
}

final class RuleGeneralizerTests: XCTestCase {
    private func texts(_ request: PermissionRequest) -> [String] {
        RuleGeneralizer.candidates(for: request).map(\.text)
    }

    // MARK: - THE invariant

    /// A generalisation that fails to cover the very command you just approved
    /// is worse than the literal rule, because it looks like it worked and then
    /// asks you again. Nothing else here matters if this does not hold.
    func testEveryCandidateMatchesTheRequestItCameFrom() throws {
        let requests = [
            bash("git log --oneline -5"), bash("npm test"), bash("ls -la /tmp"),
            bash("swift build"), bash("npm run build --verbose"), bash("ls"),
            bash("echo hi && rm -rf /tmp/x"), bash("cat a.txt | grep b"),
            edit("/Users/g/proj/src/app.ts"), edit("/tmp/notes.md"),
            PermissionRequest(id: "1", toolName: "Read", summary: "Read", createdAt: epoch),
        ]
        for request in requests {
            for candidate in RuleGeneralizer.candidates(for: request) {
                let rule = try PolicyRule(parsing: candidate.text)
                XCTAssertTrue(rule.matches(request),
                              "\(candidate.text) does not match \(PolicyRule.subject(of: request) ?? "-")")
            }
        }
    }

    /// The `git diff` / `git diff *` pair in the starter template is there
    /// because fnmatch's `prefix *` needs a space and something after it. A
    /// ladder built without noticing that would offer rules that miss the exact
    /// command every time.
    func testTrailingWildcardStillNeedsArguments() throws {
        let rule = try PolicyRule(parsing: "Bash(git log *)")
        XCTAssertTrue(rule.matches(bash("git log --oneline")))
        XCTAssertFalse(rule.matches(bash("git log")))
        // Which is exactly why a prefix is never the whole command:
        XCTAssertFalse(texts(bash("git log")).contains("Bash(git log *)"))
    }

    // MARK: - Shell ladders

    func testSubcommandAndCommandLevels() {
        XCTAssertEqual(texts(bash("git log --oneline -5")),
                       ["Bash(git log --oneline -5)", "Bash(git log *)", "Bash(git *)"])
    }

    /// Flags describe this invocation, not a family of them, so the ladder stops
    /// before them.
    func testPrefixesStopAtTheFirstFlag() {
        XCTAssertEqual(texts(bash("ls -la /tmp")), ["Bash(ls -la /tmp)", "Bash(ls *)"])
    }

    func testTwoTokenCommandOffersOneLevel() {
        XCTAssertEqual(texts(bash("npm test")), ["Bash(npm test)", "Bash(npm *)"])
    }

    /// `ls` is already as general as `Bash(ls)` gets.
    func testSingleTokenHasNothingToWiden() {
        XCTAssertEqual(texts(bash("ls")), ["Bash(ls)"])
    }

    func testNarrowestFirst() {
        let candidates = RuleGeneralizer.candidates(for: bash("npm run build --verbose"))
        XCTAssertTrue(candidates[0].isExact)
        XCTAssertEqual(candidates.map(\.text).last, "Bash(npm *)")
    }

    // MARK: - Compound commands

    /// The subject is the whole line, so widening the first token of
    /// `echo hi && rm -rf /` would auto-approve anything appended to an echo.
    /// Only the literal rule is safe — and it will rarely match, which is the
    /// correct trade rather than a failure.
    func testCompoundCommandsAreNeverWidened() {
        for command in ["echo hi && ls", "cat a | grep b", "ls; rm x", "echo $(whoami)",
                        "ls > out.txt", "echo `date`"] {
            let candidates = RuleGeneralizer.candidates(for: bash(command))
            XCTAssertEqual(candidates.count, 1, "\(command) should offer only the exact rule")
            XCTAssertTrue(candidates[0].isExact)
        }
    }

    /// The dead rule from this repo's own policy file. It stays exact-only, and
    /// that is the right answer.
    func testTheRealDeadRuleStaysExactOnly() {
        let command = #"echo "=== hooks ===" && ls -la ~/.codex/hooks.json && cat ~/.codex/hooks.json"#
        XCTAssertEqual(RuleGeneralizer.candidates(for: bash(command)).count, 1)
    }

    // MARK: - File paths

    func testFilePathsWidenByDirectoryThenExtension() {
        XCTAssertEqual(texts(edit("/Users/g/proj/src/app.ts")),
                       ["Edit(/Users/g/proj/src/app.ts)",
                        "Edit(/Users/g/proj/src/*)",
                        "Edit(*.ts)"])
    }

    func testExtensionlessFileOffersOnlyItsDirectory() {
        XCTAssertEqual(texts(edit("/Users/g/proj/Makefile")),
                       ["Edit(/Users/g/proj/Makefile)", "Edit(/Users/g/proj/*)"])
    }

    /// Relative paths would produce nonsense globs.
    func testRelativePathsAreNotWidened() {
        XCTAssertEqual(texts(edit("src/app.ts")).count, 1)
    }

    // MARK: - Tool-only

    func testToolWithNoSubjectHasNothingToWiden() {
        let request = PermissionRequest(id: "1", toolName: "Read", summary: "Read", createdAt: epoch)
        XCTAssertEqual(texts(request), ["Read"])
        XCTAssertEqual(RuleGeneralizer.candidates(for: request)[0].summary, "Any use of Read")
    }

    /// The rule keeps the raw name — it is what the engine matches — and the
    /// promise under the Always button says it in words.
    func testAnMCPToolsRuleIsDescribedInWords() {
        let tool = "mcp__7adb9f71-433e-414a-a8a1-f17b52e5037f__trelloWriteCard"
        let request = PermissionRequest(id: "1", toolName: tool, summary: "x", createdAt: epoch)
        let exact = RuleGeneralizer.candidates(for: request)[0]
        XCTAssertEqual(exact.text, tool)
        XCTAssertEqual(exact.summary, "Any use of Trello: write card")
    }

    // MARK: - Recommendation

    /// One click writes the first genuine generalisation — the whole point.
    func testRecommendationIsTheFirstWidening() {
        XCTAssertEqual(RuleGeneralizer.recommended(for: bash("git log --oneline -5")).text,
                       "Bash(git log *)")
    }

    /// But never invents breadth to feel useful.
    func testRecommendationFallsBackToExact() {
        XCTAssertTrue(RuleGeneralizer.recommended(for: bash("ls")).isExact)
        XCTAssertTrue(RuleGeneralizer.recommended(for: bash("echo a && ls")).isExact)
    }

    func testRecommendationAlwaysMatchesTheRequest() throws {
        for command in ["git log -5", "npm test", "ls", "echo a && b", "swift build -c release"] {
            let request = bash(command)
            let rule = try PolicyRule(parsing: RuleGeneralizer.recommended(for: request).text)
            XCTAssertTrue(rule.matches(request), command)
        }
    }

    /// Every candidate has to parse, or the file it lands in stops loading and
    /// takes every other rule down with it.
    func testEveryCandidateParses() {
        for command in ["git log --oneline -5", "npm run build", "ls -la", "echo a && b"] {
            for candidate in RuleGeneralizer.candidates(for: bash(command)) {
                XCTAssertNoThrow(try PolicyRule(parsing: candidate.text), candidate.text)
            }
        }
    }
}

/// Suggestions carry the same ladder, so Settings and the Always button cannot
/// disagree about what a rule for a given gate should be.
final class SuggestionGeneralizationTests: XCTestCase {
    private func log(_ command: String, times: Int) -> GateLog {
        var log = GateLog()
        let request = bash(command)
        for index in 0..<times {
            log.append(GateRecord(request: request, outcome: .allowedOnce,
                                  decidedAt: epoch.addingTimeInterval(TimeInterval(index))))
        }
        return log
    }

    func testSuggestionOffersTheLadder() throws {
        let suggestion = try XCTUnwrap(PolicySuggestions.from(log("git log --oneline -5", times: 2),
                                                              policy: Policy()).first)
        XCTAssertEqual(suggestion.candidates.map(\.text),
                       ["Bash(git log --oneline -5)", "Bash(git log *)", "Bash(git *)"])
    }

    /// The default is the widening, matching what one Always click writes.
    func testRecommendedMatchesTheAlwaysButton() throws {
        let suggestion = try XCTUnwrap(PolicySuggestions.from(log("git log --oneline -5", times: 2),
                                                              policy: Policy()).first)
        XCTAssertEqual(suggestion.recommended.text,
                       RuleGeneralizer.recommended(for: bash("git log --oneline -5")).text)
    }

    /// Nothing safe to widen means no picker and no invented breadth. Note the
    /// command is deliberately harmless — `echo a && rm -rf b` trips the risk
    /// floor and is never offered for allow at all, which is the safety rule
    /// doing its job rather than a gap in the ladder.
    func testCompoundSuggestionOffersOnlyTheLiteral() throws {
        let suggestion = try XCTUnwrap(PolicySuggestions.from(log("echo a && ls b", times: 2),
                                                              policy: Policy()).first)
        XCTAssertEqual(suggestion.candidates.count, 1)
        XCTAssertTrue(suggestion.recommended.isExact)
    }

    /// And the floor still wins over the whole feature: a risky compound is not
    /// suggested, laddered or otherwise.
    func testRiskyCompoundIsNotSuggestedAtAll() {
        XCTAssertTrue(PolicySuggestions.from(log("echo a && rm -rf b", times: 2),
                                             policy: Policy()).isEmpty)
    }

    /// Every rung must still cover the gates it was derived from, or accepting a
    /// suggestion would write a rule that changes nothing.
    func testEveryRungCoversTheOriginalGate() throws {
        let request = bash("npm run build --verbose")
        let suggestion = try XCTUnwrap(PolicySuggestions.from(log("npm run build --verbose", times: 2),
                                                              policy: Policy()).first)
        for candidate in suggestion.candidates {
            XCTAssertTrue(try PolicyRule(parsing: candidate.text).matches(request), candidate.text)
        }
    }
}
