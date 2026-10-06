import XCTest
@testable import AirlockCore

final class PolicyParserTests: XCTestCase {
    func testFullFile() throws {
        let policy = try PolicyParser.parse("""
        # comment
        version: 1
        ask_timeout: 120

        allow:
          - Read
          - Bash(git status)   # inline comment
          - "Bash(git diff *)"

        deny:
          - Bash(*rm -rf /*)
        """)
        XCTAssertEqual(policy.version, 1)
        XCTAssertEqual(policy.askTimeout, 120)
        XCTAssertEqual(policy.allow.map(\.text), ["Read", "Bash(git status)", "Bash(git diff *)"])
        XCTAssertEqual(policy.deny.map(\.text), ["Bash(*rm -rf /*)"])
    }

    func testEmptyListsAndCommentsOnly() throws {
        let policy = try PolicyParser.parse("""
        version: 1
        deny:
          # - Bash(*production*)
        """)
        XCTAssertTrue(policy.deny.isEmpty)
        XCTAssertNil(policy.askTimeout)
    }

    func testTemplateParses() throws {
        _ = try PolicyParser.parse(PolicyStore.globalTemplate)
        _ = try PolicyParser.parse(PolicyStore.projectTemplate)
    }

    func testHashInsidePatternSurvives() throws {
        let policy = try PolicyParser.parse("allow:\n  - Bash(grep*#*)")
        XCTAssertEqual(policy.allow.first?.pattern, "grep*#*")
    }

    func testLoudFailures() {
        XCTAssertThrowsError(try PolicyParser.parse("\tallow:"))          // tabs
        XCTAssertThrowsError(try PolicyParser.parse("mystery: 3"))         // unknown key
        XCTAssertThrowsError(try PolicyParser.parse("allow: Read"))        // inline list
        XCTAssertThrowsError(try PolicyParser.parse("- Read"))             // item outside list
        XCTAssertThrowsError(try PolicyParser.parse("version:"))           // missing value
        XCTAssertThrowsError(try PolicyParser.parse("ask_timeout: soon"))  // non-numeric
        XCTAssertThrowsError(try PolicyParser.parse("ask_timeout: -5"))    // negative
        XCTAssertThrowsError(try PolicyParser.parse("allow:\n  - Bash(")) // bad rule
        XCTAssertThrowsError(try PolicyParser.parse("just some text"))     // no key
    }

    func testMergeProjectOverGlobal() throws {
        let global = try PolicyParser.parse("ask_timeout: 300\nallow:\n  - Read")
        let project = try PolicyParser.parse("ask_timeout: 60\ndeny:\n  - Bash(*deploy*)")
        let merged = global.merging(project: project)
        XCTAssertEqual(merged.askTimeout, 60)
        XCTAssertEqual(merged.allow.count, 1)
        XCTAssertEqual(merged.deny.count, 1)
    }
}

extension PolicyParserTests {
    /// The message names the actual mistake.
    ///
    /// `try? PolicyRule(parsing:)` threw away which of four `ParseError` cases
    /// fired, so every malformed rule read "use `Tool` or `Tool(pattern)`" —
    /// true, and not the sentence somebody needs when they have left a bracket
    /// open on line 14 and the whole file is being ignored because of it.
    func testTheMessageNamesTheActualMistake() {
        func message(_ yaml: String) -> String {
            do { _ = try PolicyParser.parse(yaml); return "no error" }
            catch { return String(describing: error) }
        }
        XCTAssertTrue(message("allow:\n  - Bash(git push\n").contains("missing a closing bracket"),
                      message("allow:\n  - Bash(git push\n"))
        XCTAssertTrue(message("allow:\n  - Bash()\n").contains("brackets are empty"),
                      message("allow:\n  - Bash()\n"))
    }

    /// The line number survives, because "which line" is the other half of a
    /// message somebody has to act on.
    func testTheLineNumberSurvives() {
        do {
            _ = try PolicyParser.parse("version: 1\nallow:\n  - Read\n  - Bash(git push\n")
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(String(describing: error).contains("line 4"), String(describing: error))
        }
    }
}
