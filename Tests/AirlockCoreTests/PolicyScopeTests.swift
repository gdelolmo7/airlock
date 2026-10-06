import XCTest
@testable import AirlockCore

final class PolicyScopeTests: XCTestCase {
    private let globalFile = URL(fileURLWithPath: "/Users/x/.airlock/policy.yaml")

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - What can be a scope

    func testARealDirectoryBecomesAScope() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(PolicyScope.project(dir.path, globalFile: globalFile)?.projectRoot,
                       dir.standardizedFileURL.path)
    }

    /// A remembered root that has since been deleted must degrade to Everywhere
    /// rather than be recreated by the first write — `ensureFile` creates
    /// intermediate directories, so an unvalidated path would resurrect a folder
    /// somebody deleted on purpose.
    func testAMissingDirectoryIsNotAScope() {
        XCTAssertNil(PolicyScope.project("/nope/gone/\(UUID().uuidString)", globalFile: globalFile))
    }

    func testRelativeAndEmptyPathsAreRefused() {
        XCTAssertNil(PolicyScope.project("", globalFile: globalFile))
        XCTAssertNil(PolicyScope.project("relative/path", globalFile: globalFile))
        XCTAssertNil(PolicyScope.project("   ", globalFile: globalFile))
    }

    /// `cd ~/.airlock && claude` would make a "project" scope that edits the
    /// global file under another name — two segments, one file, and a rule that
    /// appears twice.
    func testThePolicyDirectoryItselfIsNotAProject() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let global = dir.appendingPathComponent("policy.yaml")
        XCTAssertNil(PolicyScope.project(dir.path, globalFile: global))
    }

    /// The label is what the segment reads. A monorepo package is named by its
    /// own folder, because that is the folder the gate actually reads.
    func testTheLabelIsTheLastPathComponent() {
        XCTAssertEqual(PolicyScope.project(root: "/a/outrun-app/packages/web").label, "web")
        XCTAssertEqual(PolicyScope.everywhere.label, "Everywhere")
    }

    // MARK: - Candidates

    /// The selected scope survives the session that suggested it disappearing.
    /// Sessions are pruned in minutes; the settings window is kept. A list drawn
    /// from live sessions alone would drop the selection mid-edit and the next
    /// rule would land in the global file.
    func testTheSelectedScopeIsAlwaysOffered() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let selected = PolicyScope.project(dir.path, globalFile: globalFile)!
        let candidates = PolicyScope.candidates(selected: selected, remembered: nil,
                                                sessions: [], globalFile: globalFile)
        XCTAssertEqual(candidates, [selected])
    }

    func testCandidatesAreDedupedAndValidated() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let candidates = PolicyScope.candidates(
            selected: .everywhere, remembered: dir.path,
            sessions: [dir.path, "/nope/\(UUID().uuidString)", dir.path],
            globalFile: globalFile)
        XCTAssertEqual(candidates.count, 1, "duplicates and dead paths must not appear")
    }

    func testEverywhereAloneOffersNoProjects() {
        XCTAssertTrue(PolicyScope.candidates(selected: .everywhere, remembered: nil,
                                             sessions: [], globalFile: globalFile).isEmpty)
    }

    // MARK: - The four list states

    /// The promise `LoadResult.problems` exists to keep: a broken file must
    /// never look like an empty one. Parse failure outranks everything,
    /// including "the file isn't there" — a file that failed to read may well
    /// exist.
    func testAParseFailureIsNeverShownAsEmpty() {
        XCTAssertEqual(RulesListState.of(exists: true, parseFailed: true, isEmpty: true), .unreadable)
        XCTAssertEqual(RulesListState.of(exists: false, parseFailed: true, isEmpty: true), .unreadable)
        XCTAssertEqual(RulesListState.of(exists: true, parseFailed: true, isEmpty: false), .unreadable)
    }

    func testTheOtherThreeStates() {
        XCTAssertEqual(RulesListState.of(exists: false, parseFailed: false, isEmpty: true), .missing)
        XCTAssertEqual(RulesListState.of(exists: true, parseFailed: false, isEmpty: true), .empty)
        XCTAssertEqual(RulesListState.of(exists: true, parseFailed: false, isEmpty: false), .listing)
    }
}
