import XCTest
@testable import AirlockCore

/// The staged hook is a snapshot, so it drifts from the app on every update and
/// says nothing about it. Settings goes on reporting "installed" in green while
/// an old binary talks to a newer bridge.
final class HookBinaryStagerDriftTests: XCTestCase {
    private var directory: URL!
    private var source: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stager-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("airlock-hook")
        destination = directory.appendingPathComponent("staged/airlock-hook")
        try Data("v2-binary".utf8).write(to: source)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func stage(_ contents: String) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: destination)
    }

    // MARK: - Detection

    func testMissingStagedCopyCountsAsOutdated() {
        XCTAssertTrue(HookBinaryStager.isOutdated(source: source, destination: destination))
    }

    func testDifferentSizeIsOutdated() throws {
        try stage("v1")
        XCTAssertTrue(HookBinaryStager.isOutdated(source: source, destination: destination))
    }

    /// Two builds can be the same length and different code, which is why size
    /// alone is only the fast path.
    func testSameSizeDifferentBytesIsOutdated() throws {
        try stage("v1-binary") // same length as "v2-binary"
        XCTAssertTrue(HookBinaryStager.isOutdated(source: source, destination: destination))
    }

    func testIdenticalIsNotOutdated() throws {
        try stage("v2-binary")
        XCTAssertFalse(HookBinaryStager.isOutdated(source: source, destination: destination))
    }

    /// Restaging is cheap; a stale hook is not.
    func testUnreadableSourceCountsAsOutdated() {
        let missing = directory.appendingPathComponent("gone")
        XCTAssertTrue(HookBinaryStager.isOutdated(source: missing, destination: destination))
    }

    // MARK: - Refresh

    func testRefreshReplacesADriftedCopy() throws {
        try stage("v1")
        XCTAssertTrue(try HookBinaryStager.refreshIfInstalled(near: source, destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testRefreshIsANoOpWhenAlreadyCurrent() throws {
        try stage("v2-binary")
        XCTAssertFalse(try HookBinaryStager.refreshIfInstalled(near: source, destination: destination))
    }

    /// A missing staged copy means the user never installed hooks. Creating one
    /// would be installing something they did not ask for.
    func testRefreshDoesNotInstallWhereNothingWasInstalled() throws {
        XCTAssertFalse(try HookBinaryStager.refreshIfInstalled(near: source, destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// Launched from somewhere with no hook binary beside it, there is nothing
    /// to copy — leave the working one alone rather than breaking it.
    func testRefreshLeavesTheStagedCopyWhenNoSourceIsFound() throws {
        try stage("v1")
        let elsewhere = directory.appendingPathComponent("nowhere/app")
        XCTAssertFalse(try HookBinaryStager.refreshIfInstalled(near: elsewhere, destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("v1".utf8))
    }

    /// The hook is exec'd by the agent, so a restage that lost the mode bit
    /// would break every hook it was meant to fix.
    func testRestagedBinaryStaysExecutable() throws {
        try stage("v1")
        try HookBinaryStager.refreshIfInstalled(near: source, destination: destination)
        let mode = try FileManager.default
            .attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o755)
    }
}
