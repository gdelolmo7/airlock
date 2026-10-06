import XCTest
@testable import AirlockCore

final class PolicyRuleTests: XCTestCase {
    private func bash(_ command: String) -> PermissionRequest {
        PermissionRequest(id: "r", toolName: "Bash", summary: "Run",
                          command: command, target: command, createdAt: Date())
    }

    private func edit(_ path: String) -> PermissionRequest {
        PermissionRequest(id: "r", toolName: "Edit", summary: "Edit",
                          target: path, createdAt: Date())
    }

    func testToolOnlyRuleMatchesAnyUse() throws {
        let rule = try PolicyRule(parsing: "Read")
        let request = PermissionRequest(id: "r", toolName: "Read", summary: "Read file", createdAt: Date())
        XCTAssertTrue(rule.matches(request))
        XCTAssertFalse(rule.matches(bash("cat x")))
    }

    func testExactCommandMatch() throws {
        let rule = try PolicyRule(parsing: "Bash(git status)")
        XCTAssertTrue(rule.matches(bash("git status")))
        XCTAssertFalse(rule.matches(bash("git status --short")))
        XCTAssertFalse(rule.matches(bash("git stash")))
    }

    func testGlobMatch() throws {
        let rule = try PolicyRule(parsing: "Bash(git diff *)")
        XCTAssertTrue(rule.matches(bash("git diff HEAD~1")))
        XCTAssertFalse(rule.matches(bash("git diff"))) // needs an argument
    }

    func testWhitespaceNormalization() throws {
        let rule = try PolicyRule(parsing: "Bash(git   status)")
        XCTAssertTrue(rule.matches(bash("git status")))
        XCTAssertTrue(rule.matches(bash("  git \n status  ")))
    }

    func testInnerParensStayInPattern() throws {
        let rule = try PolicyRule(parsing: "Bash(echo (hi))")
        XCTAssertEqual(rule.pattern, "echo (hi)")
        XCTAssertTrue(rule.matches(bash("echo (hi)")))
    }

    func testFilePathRules() throws {
        let rule = try PolicyRule(parsing: "Edit(/tmp/*)")
        XCTAssertTrue(rule.matches(edit("/tmp/scratch.txt")))
        XCTAssertFalse(rule.matches(edit("/etc/hosts")))
    }

    func testParseErrors() {
        XCTAssertThrowsError(try PolicyRule(parsing: ""))
        XCTAssertThrowsError(try PolicyRule(parsing: "Bash(unclosed"))
        XCTAssertThrowsError(try PolicyRule(parsing: "Bash()"))
        XCTAssertThrowsError(try PolicyRule(parsing: "Two Words(x)"))
    }

    func testExactRuleTextForAlways() {
        XCTAssertEqual(PolicyRule.exactRuleText(for: bash("npm test")), "Bash(npm test)")
        XCTAssertEqual(
            PolicyRule.exactRuleText(for: PermissionRequest(id: "r", toolName: "Read", summary: "…", createdAt: Date())),
            "Read"
        )
        // Newlines collapse so the rule stays a single line.
        XCTAssertEqual(PolicyRule.exactRuleText(for: bash("echo a\necho b")), "Bash(echo a echo b)")
    }
}
