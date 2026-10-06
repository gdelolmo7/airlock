import XCTest
@testable import AirlockCore

/// Everything this app caches under Application Support is owner-only.
///
/// Pinned as a rule rather than per call site, because the failure is silent:
/// two of these stores wrote 0644 for months, and nothing anywhere would have
/// noticed. Whoever adds the next store gets a failing test instead of a
/// permission nobody checks.
final class StatePermissionTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("airlock-perm-\(UUID().uuidString)")
        setenv("AIRLOCK_STATE_HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("AIRLOCK_STATE_HOME")
        try? FileManager.default.removeItem(at: home)
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// Walks whatever the stores actually wrote, rather than naming files —
    /// a new cache is covered the day it appears.
    func testEveryCachedFileIsOwnerOnly() throws {
        try SessionRegistry().save(SessionState())
        try GateLogStore().save(GateLog())
        SessionNameCache.record(sessionID: "sess-1", name: "a title", at: Date())
        try UsageSnapshot(fiveHour: RateLimitWindow(usedPercentage: 12, resetsAt: nil),
                          sevenDay: nil, capturedAt: Date()).save()

        var checked: Set<String> = []
        let walker = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            checked.insert(url.lastPathComponent)
            XCTAssertEqual(try mode(of: url), 0o600,
                           "\(url.lastPathComponent) is not owner-only")
        }
        // Named explicitly, so the test cannot pass by walking an empty tree or
        // by missing the two files this was written for.
        XCTAssertTrue(checked.contains("session-names.json"), "wrote: \(checked.sorted())")
        XCTAssertTrue(checked.contains("usage.json"), "wrote: \(checked.sorted())")
        XCTAssertGreaterThanOrEqual(checked.count, 4, "wrote: \(checked.sorted())")
    }

    /// The containing directory too: a 0600 file inside a traversable directory
    /// still leaks its name, its size and when it changed.
    func testTheStateDirectoryIsOwnerOnly() throws {
        try SessionRegistry().save(SessionState())
        let attributes = try FileManager.default.attributesOfItem(atPath: home.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
