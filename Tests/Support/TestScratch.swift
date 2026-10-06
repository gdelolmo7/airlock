import Foundation

/// A throwaway directory for one test's files, deleted when the test lets go of
/// it.
///
/// It exists because a test run was making the developer's Mac dirtier every
/// time: a socket file in `/tmp` for every bridge test, a preference file in
/// `~/Library/Preferences` for every defaults test. Thousands of each had
/// collected, none of them read again by anything, and none of them
/// distinguishable at a glance from something real. The build folder is the
/// only place a run is allowed to leave anything.
///
/// **Cleanup is `deinit`, deliberately.** A tidy-up that has to be remembered
/// at each of a dozen call sites is one that eventually is not, which is how
/// this started. Holding the scratch is all a test has to do.
///
/// The name is short on purpose: a Unix socket path cannot exceed 104 bytes
/// (`sun_path`), and that limit is why these files were written straight into
/// `/tmp` in the first place. A per-run temporary directory plus `an-XXXXXXXX/`
/// plus `s.sock` fits with room to spare.
public final class TestScratch {
    private let url: URL
    private var made = false

    /// The directory, made on FIRST USE rather than at init.
    ///
    /// XCTest builds one instance of a test class per test method before it
    /// runs any of them, so a directory made in a property initialiser is made
    /// for every test in the class — including, under `swift test --filter`,
    /// the ones that never run and therefore never tear down. Thirty-one empty
    /// directories from a seven-test run, measured, all of them from tests that
    /// did nothing.
    public var root: URL {
        if !made {
            made = true
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    public init(_ name: String = "an") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    deinit { remove() }

    /// For a test that holds the scratch in a property: XCTest keeps its test
    /// cases alive, so `deinit` alone would wait for the process to end.
    public func remove() {
        guard made else { return }
        try? FileManager.default.removeItem(at: url)
        made = false
    }

    /// A path for a Unix socket inside it — short, see above. A fresh name per
    /// call, so a test can stand up two bridges without naming them.
    public func socket(_ name: String = String(UUID().uuidString.prefix(8))) -> String {
        root.appendingPathComponent("\(name).sock").path
    }

    /// A path inside it. The file need not exist: an empty policy file that was
    /// never written is how several tests get a deterministic "ask".
    public func file(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    /// A directory inside it, made now.
    @discardableResult
    public func folder(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A `UserDefaults` suite for tests, and one that does not multiply.
///
/// `UserDefaults(suiteName:)` hands the domain to `cfprefsd`, which owns the
/// plist under `~/Library/Preferences` — and writes it AFTER the test process
/// has exited. Deleting the file from the test therefore loses the race every
/// time: measured, it is back about a second later. With a fresh name per test
/// that is one new file per test per run, and four and a half thousand of them
/// had collected on one Mac.
///
/// So the name is FIXED per purpose. The same few domains are reused by every
/// run and emptied at both ends: the values stay isolated, because the tests in
/// one class run one at a time, and the file count stops growing. Two classes
/// must not share a name — under `swift test --parallel` they are separate
/// processes — which is why the name is passed in rather than generated.
public final class TestDefaults {
    public let name: String
    public let defaults: UserDefaults

    public init(_ name: String) {
        self.name = name
        defaults = UserDefaults(suiteName: name) ?? .standard
        // Whatever the last run left, before this one reads anything.
        defaults.removePersistentDomain(forName: name)
    }

    deinit { remove() }

    /// Empties the domain. The file is cfprefsd's and outlives the process —
    /// see above — but it stays one file rather than thousands.
    public func remove() {
        defaults.removePersistentDomain(forName: name)
    }
}
