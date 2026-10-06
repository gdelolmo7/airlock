import XCTest
@testable import AirlockCore

/// The surgery has to preserve everything it did not mean to touch, and must
/// never remove a line it was not asked for — deleting the wrong line here
/// loosens the thing that gates command execution.
final class PolicyDocumentTests: XCTestCase {
    private let sample = """
    # agentic-notch policy
    version: 1

    ask_timeout: 300

    allow:
      # Read-only tools.
      - Read
      - Bash(git status)

    deny:
      # Hard bans.
      - Bash(*production*)
      # - Bash(*rm -rf /*)

    """

    // MARK: - Insert

    func testInsertLandsUnderTheHeader() {
        var document = PolicyDocument(sample)
        XCTAssertTrue(document.insert("Bash(ls *)", into: .allow))
        let lines = document.text.components(separatedBy: "\n")
        let header = lines.firstIndex(of: "allow:")!
        XCTAssertEqual(lines[header + 1], "  - Bash(ls *)")
    }

    /// The reason this type exists: a parse-and-reserialise round trip would
    /// take every one of these with it.
    func testCommentsAndBlankLinesSurvive() {
        var document = PolicyDocument(sample)
        document.insert("Glob", into: .allow)
        document.remove("Read", from: .allow)
        XCTAssertTrue(document.text.contains("# agentic-notch policy"))
        XCTAssertTrue(document.text.contains("  # Read-only tools."))
        XCTAssertTrue(document.text.contains("  # Hard bans."))
        XCTAssertTrue(document.text.contains("  # - Bash(*rm -rf /*)"))
        XCTAssertTrue(document.text.contains("ask_timeout: 300"))
    }

    func testInsertIntoTheRightSection() {
        var document = PolicyDocument(sample)
        document.insert("Bash(curl *)", into: .deny)
        let policy = try! PolicyParser.parse(document.text)
        XCTAssertTrue(policy.deny.contains { $0.text == "Bash(curl *)" })
        XCTAssertFalse(policy.allow.contains { $0.text == "Bash(curl *)" })
    }

    func testDuplicateIsRefused() {
        var document = PolicyDocument(sample)
        XCTAssertFalse(document.insert("Read", into: .allow))
        XCTAssertEqual(document.text, sample)
    }

    /// Whitespace inside a pattern is normalised by `PolicyRule`, so these are
    /// the same rule to the engine and must be the same rule here.
    func testDuplicateDetectionIsCanonical() {
        var document = PolicyDocument(sample)
        XCTAssertFalse(document.insert("Bash(git   status)", into: .allow))
    }

    func testUnparseableRuleIsRefused() {
        var document = PolicyDocument(sample)
        XCTAssertFalse(document.insert("Bash(unclosed", into: .allow))
        XCTAssertFalse(document.insert("", into: .allow))
        XCTAssertEqual(document.text, sample)
    }

    func testMissingSectionIsCreated() {
        var document = PolicyDocument("version: 1\n")
        XCTAssertTrue(document.insert("Read", into: .deny))
        let policy = try! PolicyParser.parse(document.text)
        XCTAssertEqual(policy.deny.map(\.text), ["Read"])
    }

    /// Whatever we write has to survive the strict parser that gates execution.
    func testResultStaysParseable() throws {
        var document = PolicyDocument(sample)
        document.insert("Bash(npm test)", into: .allow)
        document.insert("Bash(*secrets*)", into: .deny)
        document.remove("Read", from: .allow)
        let policy = try PolicyParser.parse(document.text)
        XCTAssertEqual(policy.allow.map(\.text), ["Bash(npm test)", "Bash(git status)"])
        XCTAssertEqual(policy.deny.map(\.text), ["Bash(*secrets*)", "Bash(*production*)"])
    }

    // MARK: - Remove

    func testRemoveTakesExactlyOneLine() {
        var document = PolicyDocument(sample)
        let before = document.text.components(separatedBy: "\n").count
        XCTAssertTrue(document.remove("Read", from: .allow))
        XCTAssertEqual(document.text.components(separatedBy: "\n").count, before - 1)
        XCTAssertFalse(document.text.contains("  - Read"))
        XCTAssertTrue(document.text.contains("  - Bash(git status)"))
    }

    func testRemoveIsScopedToItsSection() {
        var document = PolicyDocument("""
        allow:
          - Read
        deny:
          - Read
        """)
        XCTAssertTrue(document.remove("Read", from: .deny))
        let policy = try! PolicyParser.parse(document.text)
        XCTAssertEqual(policy.allow.map(\.text), ["Read"])
        XCTAssertTrue(policy.deny.isEmpty)
    }

    /// A commented-out rule is documentation. It must not be matched, and it
    /// must not be deleted.
    func testCommentedRuleIsNotARule() {
        var document = PolicyDocument(sample)
        XCTAssertFalse(document.contains("Bash(*rm -rf /*)", in: .deny))
        XCTAssertFalse(document.remove("Bash(*rm -rf /*)", from: .deny))
        XCTAssertTrue(document.text.contains("  # - Bash(*rm -rf /*)"))
    }

    /// The settings list shows canonical rule text, so that is what comes back
    /// when you press delete — it has to match a differently-spaced file.
    func testRemoveMatchesCanonically() {
        var document = PolicyDocument("allow:\n  - Bash(git   status)\n")
        XCTAssertTrue(document.remove("Bash(git status)", from: .allow))
        XCTAssertFalse(document.text.contains("git"))
    }

    /// A trailing comment on a rule line does not stop it being that rule.
    func testRuleWithTrailingCommentIsFound() {
        var document = PolicyDocument("allow:\n  - Read  # safe\n")
        XCTAssertTrue(document.contains("Read", in: .allow))
        XCTAssertTrue(document.remove("Read", from: .allow))
    }

    func testRemovingSomethingAbsentIsANoOp() {
        var document = PolicyDocument(sample)
        XCTAssertFalse(document.remove("Bash(nope)", from: .allow))
        XCTAssertFalse(document.remove("Read", from: .deny))
        XCTAssertEqual(document.text, sample)
    }

    func testRemovingFromAMissingSectionIsANoOp() {
        var document = PolicyDocument("version: 1\n")
        XCTAssertFalse(document.remove("Read", from: .allow))
    }

    /// `allow:` sits above `deny:` in the template, so the body scan has to stop
    /// at the next top-level key rather than running to the end of the file.
    func testSectionBodyStopsAtTheNextKey() {
        var document = PolicyDocument(sample)
        XCTAssertFalse(document.contains("Bash(*production*)", in: .allow))
        XCTAssertTrue(document.contains("Bash(*production*)", in: .deny))
        XCTAssertFalse(document.remove("Bash(*production*)", from: .allow))
        XCTAssertTrue(document.text.contains("  - Bash(*production*)"))
    }
}

final class PolicyStoreEditingTests: XCTestCase {
    private var directory: URL!
    private var store: PolicyStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("policy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = PolicyStore(globalFileURL: directory.appendingPathComponent("policy.yaml"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAddCreatesTheFileFromTheTemplate() throws {
        XCTAssertTrue(try store.add("Bash(npm test)", kind: .allow))
        let text = try String(contentsOf: store.globalFileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("# agentic-notch policy"))
        XCTAssertTrue(store.load(projectRoot: nil).policy.allow.contains { $0.text == "Bash(npm test)" })
    }

    func testAddThenRemoveRoundTrips() throws {
        try store.add("Bash(npm test)", kind: .deny)
        XCTAssertTrue(store.load(projectRoot: nil).policy.deny.contains { $0.text == "Bash(npm test)" })
        XCTAssertTrue(try store.remove("Bash(npm test)", kind: .deny))
        XCTAssertFalse(store.load(projectRoot: nil).policy.deny.contains { $0.text == "Bash(npm test)" })
    }

    func testTemplateRulesCanBeRemoved() throws {
        try store.writeGlobalTemplateIfMissing()
        XCTAssertTrue(store.load(projectRoot: nil).policy.allow.contains { $0.text == "Read" })
        XCTAssertTrue(try store.remove("Read", kind: .allow))
        let result = store.load(projectRoot: nil)
        XCTAssertFalse(result.policy.allow.contains { $0.text == "Read" })
        XCTAssertTrue(result.problems.isEmpty)
        // Its neighbours and the comments above it are untouched.
        XCTAssertTrue(result.policy.allow.contains { $0.text == "Glob" })
    }

    func testRemovingFromAMissingFileIsANoOp() throws {
        XCTAssertFalse(try store.remove("Read", kind: .allow))
    }

    /// The "Always allow" click still works, and now shares one implementation
    /// with the settings UI rather than a parallel one.
    func testAppendAllowRuleStillBehaves() throws {
        XCTAssertTrue(try store.appendAllowRule("Bash(swift build)", projectRoot: nil))
        XCTAssertFalse(try store.appendAllowRule("Bash(swift build)", projectRoot: nil))
        // And a rule the starter template already ships is likewise a no-op.
        XCTAssertFalse(try store.appendAllowRule("Bash(git status)", projectRoot: nil))
    }
}
