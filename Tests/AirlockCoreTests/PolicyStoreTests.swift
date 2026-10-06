import XCTest
@testable import AirlockCore

final class PolicyStoreTests: XCTestCase {
    private var root: URL!
    private var store: PolicyStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("an-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = PolicyStore(globalFileURL: root.appendingPathComponent("global/policy.yaml"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLoadMissingFilesIsEmptyNotError() {
        let result = store.load(projectRoot: root.path)
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertTrue(result.policy.allow.isEmpty)
    }

    func testLoadMergesGlobalAndProject() throws {
        try FileManager.default.createDirectory(
            at: store.globalFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "allow:\n  - Read".write(to: store.globalFileURL, atomically: true, encoding: .utf8)

        let projectFile = store.projectFileURL(projectRoot: root.path)
        try FileManager.default.createDirectory(
            at: projectFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "deny:\n  - Bash(*deploy*)".write(to: projectFile, atomically: true, encoding: .utf8)

        let result = store.load(projectRoot: root.path)
        XCTAssertEqual(result.policy.allow.count, 1)
        XCTAssertEqual(result.policy.deny.count, 1)
    }

    func testBrokenFileSurfacesProblem() throws {
        try FileManager.default.createDirectory(
            at: store.globalFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "mystery: true".write(to: store.globalFileURL, atomically: true, encoding: .utf8)
        let result = store.load(projectRoot: nil)
        XCTAssertEqual(result.problems.count, 1)
    }

    func testAppendCreatesGlobalTemplateAndInserts() throws {
        try store.appendAllowRule("Bash(npm test)", projectRoot: nil)
        let policy = try PolicyParser.parse(String(contentsOf: store.globalFileURL, encoding: .utf8))
        XCTAssertTrue(policy.allow.map(\.text).contains("Bash(npm test)"))
        // Template content came along.
        XCTAssertTrue(policy.allow.map(\.text).contains("Read"))
    }

    func testAppendToProjectPreservesUserText() throws {
        let projectFile = store.projectFileURL(projectRoot: root.path)
        try FileManager.default.createDirectory(
            at: projectFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "# my precious comment\nversion: 1\n\nallow:\n  - Read\n"
        try original.write(to: projectFile, atomically: true, encoding: .utf8)

        try store.appendAllowRule("Bash(make build)", projectRoot: root.path)
        let text = try String(contentsOf: projectFile, encoding: .utf8)
        XCTAssertTrue(text.contains("# my precious comment"), "textual append must preserve comments")
        let policy = try PolicyParser.parse(text)
        XCTAssertEqual(policy.allow.map(\.text), ["Bash(make build)", "Read"])
    }

    func testAppendDedupes() throws {
        XCTAssertTrue(try store.appendAllowRule("Bash(npm test)", projectRoot: nil))
        XCTAssertFalse(try store.appendAllowRule("Bash(npm test)", projectRoot: nil))
        let text = try String(contentsOf: store.globalFileURL, encoding: .utf8)
        let occurrences = text.components(separatedBy: "Bash(npm test)").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testAppendWithoutAllowSectionAppendsOne() throws {
        try FileManager.default.createDirectory(
            at: store.globalFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "version: 1".write(to: store.globalFileURL, atomically: true, encoding: .utf8)
        try store.appendAllowRule("Read", projectRoot: nil)
        let policy = try PolicyParser.parse(String(contentsOf: store.globalFileURL, encoding: .utf8))
        XCTAssertEqual(policy.allow.map(\.text), ["Read"])
    }
}

extension PolicyStoreTests {
    /// An agent started in the policy directory itself read the global file
    /// TWICE and merged it with itself: every rule listed twice, every parse
    /// problem reported twice. A correctness fix for the engine, not only the
    /// pane.
    func testAProjectRootEqualToTheGlobalDirectoryDoesNotDoubleTheRules() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("selfmerge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".airlock"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent(".airlock/policy.yaml")
        try "allow:\n  - Read\n".write(to: file, atomically: true, encoding: .utf8)

        let store = PolicyStore(globalFileURL: file)
        let merged = store.load(projectRoot: dir.path)
        XCTAssertEqual(merged.policy.allow.count, 1, "the file was merged with itself")
        XCTAssertTrue(merged.problems.isEmpty)
    }

    /// The pane edits ONE named file, so it has to be able to read one.
    func testLoadingASingleFileDoesNotMerge() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("single-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".airlock"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let global = dir.appendingPathComponent("global.yaml")
        try "allow:\n  - Read\n".write(to: global, atomically: true, encoding: .utf8)
        let project = dir.appendingPathComponent(".airlock/policy.yaml")
        try "allow:\n  - Bash(git status)\n".write(to: project, atomically: true, encoding: .utf8)

        let store = PolicyStore(globalFileURL: global)
        XCTAssertEqual(store.load(projectRoot: dir.path).policy.allow.count, 2, "merged")
        XCTAssertEqual(store.load(fileAt: project).policy.allow.map(\.text), ["Bash(git status)"])
        XCTAssertEqual(store.load(fileAt: global).policy.allow.map(\.text), ["Read"])
    }
}
