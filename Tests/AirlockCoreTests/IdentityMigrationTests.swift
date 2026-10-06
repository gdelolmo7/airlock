import AirlockTestSupport
import XCTest
@testable import AirlockCore

final class IdentityMigrationTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func move(_ from: String, _ to: String) -> IdentityMigration.Move {
        IdentityMigration.Move(from: url(from), to: url(to))
    }

    // MARK: - The rules

    func testCopiesWhenTheOldExistsAndTheNewDoesNot() {
        let plan = IdentityMigration.plan(candidates: [move("/old", "/new")]) { $0.path == "/old" }
        XCTAssertEqual(plan.copies, [move("/old", "/new")])
    }

    /// An existing destination directory is NOT a reason to skip. It was once,
    /// and that made a failed copy permanent: the app recreates the directory
    /// seconds after launch regardless, so every later run saw it, decided the
    /// migration was done, and skipped forever. Non-overwrite lives at the file
    /// level now — see `testAHalfMigratedInstallHealsItself`.
    func testAnExistingDestinationDirectoryStillMerges() {
        let plan = IdentityMigration.plan(candidates: [move("/old", "/new")]) { _ in true }
        XCTAssertEqual(plan.copies, [move("/old", "/new")])
    }

    func testSkipsWhatWasNeverThere() {
        let plan = IdentityMigration.plan(candidates: [move("/old", "/new")]) { _ in false }
        XCTAssertTrue(plan.copies.isEmpty)
        XCTAssertTrue(plan.isEmpty)
    }

    func testOnlyASourceThatExistsIsWorthVisiting() {
        let candidates = [move("/a", "/A"), move("/b", "/B"), move("/c", "/C")]
        let present: Set<String> = ["/a", "/c", "/C"]
        let plan = IdentityMigration.plan(candidates: candidates) { present.contains($0.path) }
        XCTAssertEqual(plan.copies, [move("/a", "/A"), move("/c", "/C")],
                       "b never existed; c is visited so any missing file inside it is filled in")
    }

    func testHookReinstallIsCarriedThrough() {
        XCTAssertTrue(IdentityMigration.plan(candidates: [], hasLegacyHooks: true) { _ in false }
            .reinstallsHooks)
        XCTAssertFalse(IdentityMigration.plan(candidates: [], hasLegacyHooks: false) { _ in false }
            .isEmpty == false)
    }

    // MARK: - Against a real filesystem

    func testCopiesLeaveTheOriginalInPlace() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("airlock-migration-\(UUID().uuidString)")
        let old = root.appendingPathComponent("legacy")
        let new = root.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("rules: []".utf8).write(to: old.appendingPathComponent("policy.yaml"))
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = IdentityMigration.plan(candidates: [IdentityMigration.Move(from: old, to: new)]) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let done = IdentityMigration.perform(plan)

        XCTAssertEqual(done.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: new.appendingPathComponent("policy.yaml").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: old.appendingPathComponent("policy.yaml").path),
            "the legacy copy is the fallback if anything went wrong — it must survive")
    }

    /// Running the app twice must not fail, duplicate or clobber.
    func testRunningTwiceLeavesEditsAlone() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("airlock-migration-\(UUID().uuidString)")
        let old = root.appendingPathComponent("legacy")
        let new = root.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: old.appendingPathComponent("state.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        let exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        let candidates = [IdentityMigration.Move(from: old, to: new)]

        IdentityMigration.perform(IdentityMigration.plan(candidates: candidates, exists: exists))
        // Someone edits the migrated copy; a second run must not overwrite it.
        try Data("edited since".utf8).write(to: new.appendingPathComponent("state.json"))
        let second = IdentityMigration.perform(
            IdentityMigration.plan(candidates: candidates, exists: exists))

        // The directory IS re-entered — that is what heals a half-migrated
        // install — but nothing lands, so nothing is reported.
        //
        // That distinction is load-bearing, not pedantry. `perform` returning
        // "done" for a directory it merely visited made every launch look like
        // a first migration, and the caller raises the permission notice from
        // exactly that signal — so the notice came back forever.
        XCTAssertTrue(second.isEmpty, "a run that copies nothing has migrated nothing")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("state.json"),
                                  encoding: .utf8), "edited since")
    }

    /// The state a real user was left in, and the reason non-overwrite moved
    /// from the directory to the file.
    ///
    /// The first migration failed on the socket, but the app then created the
    /// destination directory itself seconds later and filled it with fresh empty
    /// state. Under the old directory-level rule every later launch saw that
    /// directory, concluded the work was done, and skipped — permanently, with
    /// the real history sitting untouched next door. Now the directory is
    /// re-entered and only the genuinely missing files are filled in.
    func testAHalfMigratedInstallHealsItself() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("airlock-heal-\(UUID().uuidString)")
        let old = root.appendingPathComponent("legacy")
        let new = root.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("106KB of history".utf8).write(to: old.appendingPathComponent("clipboard.json"))
        try Data("the gate log".utf8).write(to: old.appendingPathComponent("gates.json"))
        // What the app wrote for itself after the failed migration.
        try Data("[]".utf8).write(to: new.appendingPathComponent("clipboard.json"))

        let plan = IdentityMigration.plan(candidates: [IdentityMigration.Move(from: old, to: new)]) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        IdentityMigration.perform(plan)

        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("gates.json"),
                                  encoding: .utf8), "the gate log",
                       "a file the failed run never delivered must arrive now")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("clipboard.json"),
                                  encoding: .utf8), "[]",
                       "but one the app has since written is the newer truth and stays")
    }

    // MARK: - Preferences

    func testDefaultsAreCopiedOnceAndOnlyOnce() throws {
        // Throwaway suites: the domain AND the file it writes into
        // ~/Library/Preferences go when the test does — see `TestDefaults`.
        let legacyStore = TestDefaults("com.airlock.test.legacy")
        let currentStore = TestDefaults("com.airlock.test.new")
        let (legacyDomain, legacy) = (legacyStore.name, legacyStore.defaults)
        let current = currentStore.defaults

        legacy.set(640.0, forKey: "notch.panelWidth")
        legacy.set(true, forKey: "onboarding.completed")

        let copied = IdentityMigration.migrateDefaults(fromDomain: legacyDomain, into: current)
        XCTAssertEqual(copied, 2)
        XCTAssertEqual(current.double(forKey: "notch.panelWidth"), 640)
        XCTAssertTrue(current.bool(forKey: "onboarding.completed"),
                      "losing this is what greets a long-time user with the setup wizard")

        // Second run: the sentinel stops it, so a later change here is not undone.
        current.set(720.0, forKey: "notch.panelWidth")
        XCTAssertEqual(IdentityMigration.migrateDefaults(fromDomain: legacyDomain, into: current), 0)
        XCTAssertEqual(current.double(forKey: "notch.panelWidth"), 720)
    }

    /// A value already chosen under the new identity outranks the legacy one,
    /// even within the very first migration.
    func testExistingNewValuesAreNotOverwritten() throws {
        // Throwaway suites: the domain AND the file it writes into
        // ~/Library/Preferences go when the test does — see `TestDefaults`.
        let legacyStore = TestDefaults("com.airlock.test.legacy")
        let currentStore = TestDefaults("com.airlock.test.new")
        let (legacyDomain, legacy) = (legacyStore.name, legacyStore.defaults)
        let current = currentStore.defaults

        legacy.set("control", forKey: "dictation.holdKey")
        current.set("option", forKey: "dictation.holdKey")

        XCTAssertEqual(IdentityMigration.migrateDefaults(fromDomain: legacyDomain, into: current), 0)
        XCTAssertEqual(current.string(forKey: "dictation.holdKey"), "option")
    }

    /// THE bug that lost a real user's clipboard history.
    ///
    /// The state directory holds `bridge.sock`, and `FileManager.copyItem` on a
    /// directory containing a Unix socket fails with POSIX 45 — atomically, so
    /// NOTHING is copied. A zero-byte file the app recreates on every launch
    /// took the whole clipboard history, session cache and gate log with it.
    /// It survived review because the other migrated directory has no socket
    /// and copied perfectly, which made the failure look like flakiness.
    func testASocketDoesNotTakeTheWholeDirectoryWithIt() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("airlock-socket-\(UUID().uuidString)")
        let old = root.appendingPathComponent("legacy")
        let new = root.appendingPathComponent("current")
        let images = old.appendingPathComponent("clipboard-images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("the history".utf8).write(to: old.appendingPathComponent("clipboard.json"))
        try Data("an image".utf8).write(to: images.appendingPathComponent("1.png"))

        // A real socket, not a stand-in — the whole point is that the failure
        // comes from the file's TYPE, which only a real one reproduces.
        let socketPath = old.appendingPathComponent("bridge.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        // Capacity read into a local first: reading `address.sun_path` inside
        // the closure is a second access to the value already borrowed there.
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            socketPath.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                        source, capacity)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // Qualified: XCTestCase has its own `bind`, and the unqualified
                // name resolves to that instance method instead.
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, "test needs a real socket to reproduce the bug")
        defer { close(fd) }

        let plan = IdentityMigration.plan(candidates: [IdentityMigration.Move(from: old, to: new)]) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let done = IdentityMigration.perform(plan)

        XCTAssertEqual(done.count, 1, "the copy must succeed despite the socket")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("clipboard.json"),
                                  encoding: .utf8), "the history")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("clipboard-images/1.png"),
                                  encoding: .utf8), "an image",
                       "nested directories have to come across too")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: new.appendingPathComponent("bridge.sock").path),
            "the socket itself is not state — the app rebuilds it on launch")
    }

    // MARK: - The permission notice

    func testPermissionReviewIsRaisedThenSettledOnce() {
        let store = TestDefaults("com.airlock.test.review")
        let defaults = store.defaults

        XCTAssertFalse(IdentityMigration.needsPermissionReview(in: defaults),
                       "a fresh install has nothing to re-grant and must never be told it does")

        IdentityMigration.flagPermissionReview(in: defaults)
        XCTAssertTrue(IdentityMigration.needsPermissionReview(in: defaults))

        // "Later" is an answer. An alert that returns every launch is nagging.
        IdentityMigration.clearPermissionReview(in: defaults)
        XCTAssertFalse(IdentityMigration.needsPermissionReview(in: defaults))
    }

    func testAnEmptyLegacyDomainIsHarmless() {
        let currentStore = TestDefaults("com.airlock.test.new")
        let current = currentStore.defaults
        XCTAssertEqual(
            IdentityMigration.migrateDefaults(fromDomain: "com.airlock.test.absent", into: current), 0)
    }
}
