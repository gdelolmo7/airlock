import Foundation

/// Carries a user's state across the agentic-notch → Airlock rename.
///
/// The rename changes the four things a running install actually depends on:
/// the bundle identifier (and with it the preferences domain), the Application
/// Support directory, `~/.agentic-notch/`, and the hook binary's name and path.
/// Without this, updating would silently present a fresh install — no sessions,
/// no clipboard history, no policy rules, every setting back to default, the
/// onboarding wizard again, and agent hooks pointing at a binary that no longer
/// exists.
///
/// **It copies. It never moves and never deletes.** A move is one bad path away
/// from destroying the only copy of someone's policy file, and the disk cost
/// here is a few hundred kilobytes. The legacy directories are left exactly
/// where they are, so a migration that goes wrong costs nothing but confusion.
///
/// **It never overwrites.** A destination that already exists means either the
/// migration ran before or the user has been using the new version already;
/// both are cases where the old data is the stale one. Silence beats a clobber.
///
/// The decision half is pure and lives in `plan`, which is where the rules that
/// can be wrong actually are — the copying itself is a call to FileManager.
public struct IdentityMigration: Sendable {
    public struct Move: Equatable, Sendable {
        public let from: URL
        public let to: URL

        public init(from: URL, to: URL) {
            self.from = from
            self.to = to
        }
    }

    public struct Plan: Equatable, Sendable {
        public var copies: [Move]
        /// Legacy hook entries were found, so the caller must reinstall against
        /// the new binary once the copying is done.
        public var reinstallsHooks: Bool

        public var isEmpty: Bool { copies.isEmpty && !reinstallsHooks }

        public init(copies: [Move] = [], reinstallsHooks: Bool = false) {
            self.copies = copies
            self.reinstallsHooks = reinstallsHooks
        }
    }

    /// Everything the pre-rename build owned. These strings are frozen: they
    /// name what is already on disk, so "fixing" them to say Airlock would make
    /// the migration look in a place that has never existed.
    public enum Legacy {
        public static let bundleIdentifier = "com.agenticnotch.app"
        public static let supportDirectory = "AgenticNotch"
        public static let dotDirectory = ".agentic-notch"
        public static let workspaceDirectory = "agentic-notch"
        public static let hookBinary = "agentic-notch-hook"
    }

    /// The real set of copies for this Mac: `~/.agentic-notch` → `~/.airlock`,
    /// the Application Support directory, and the workspace folder.
    ///
    /// `~/.agentic-notch/bin` comes across with its parent but is deliberately
    /// NOT relied on — the staged hook is a snapshot of a binary that has since
    /// been renamed, so the caller restages rather than trusting the copy.
    public static func standardCandidates(home: URL, applicationSupport: URL) -> [Move] {
        [
            Move(from: home.appendingPathComponent(Legacy.dotDirectory),
                 to: home.appendingPathComponent(".airlock")),
            Move(from: applicationSupport.appendingPathComponent(Legacy.supportDirectory),
                 to: applicationSupport.appendingPathComponent("Airlock")),
            Move(from: home.appendingPathComponent(Legacy.workspaceDirectory),
                 to: home.appendingPathComponent("Airlock")),
        ]
    }

    /// What to do, given what exists. Pure: `exists` is injected so the rules
    /// can be tested without a filesystem.
    ///
    /// A candidate survives whenever the source is there — the destination being
    /// present is NOT a reason to skip, because "don't overwrite" belongs at the
    /// file level, not the directory level.
    ///
    /// It was at directory level once, and that turned a bad copy into a
    /// permanent one: a first run that failed still left the destination
    /// directory behind (the app creates it seconds later regardless), so every
    /// later launch saw it, concluded the migration was done, and skipped. The
    /// user was stuck half-migrated with no way back. Merging per file makes the
    /// migration self-healing — it fills in whatever is missing, every launch,
    /// until nothing is.
    public static func plan(candidates: [Move],
                            hasLegacyHooks: Bool = false,
                            exists: (URL) -> Bool) -> Plan {
        let copies = candidates.filter { exists($0.from) }
        return Plan(copies: copies, reinstallsHooks: hasLegacyHooks)
    }

    /// Runs a plan, returning what actually got copied.
    ///
    /// Failures are collected rather than thrown: one unreadable directory must
    /// not stop the others, because a user who loses their clipboard history but
    /// keeps their policy rules is far better off than one who gets neither.
    @discardableResult
    public static func perform(_ plan: Plan,
                               fileManager: FileManager = .default) -> [Move] {
        var done: [Move] = []
        for move in plan.copies {
            do {
                try fileManager.createDirectory(
                    at: move.to.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                // Only when a file GENUINELY arrived. `copyTree` succeeds
                // quietly when everything is already in place, and the legacy
                // directories never go away — so counting "did not throw" as
                // migration made every launch look like a first one, and the
                // permission notice returned forever.
                if try copyTree(from: move.from, to: move.to, fileManager: fileManager) > 0 {
                    done.append(move)
                }
            } catch {
                Log.migration.error(
                    "could not migrate \(move.from.path, privacy: .private) — \(error.localizedDescription, privacy: .private)")
            }
        }
        return done
    }

    /// Copies a tree entry by entry, skipping anything that is not a regular
    /// file or a directory.
    ///
    /// `FileManager.copyItem` on the whole directory looks obviously right and
    /// silently loses everything. The Application Support directory contains
    /// `bridge.sock` — a Unix domain socket — and copying one fails with POSIX
    /// 45, `Operation not supported`. The failure is ATOMIC: the call aborts at
    /// the socket and nothing else lands, so an entire clipboard history,
    /// session cache and gate log vanish because of a zero-byte file that is
    /// recreated on every launch anyway.
    ///
    /// It only showed up in one of the two directories being migrated, which is
    /// exactly what made it look like flakiness rather than a rule: `~/.airlock`
    /// has no socket in it and copied perfectly.
    ///
    /// So: sockets, FIFOs and devices are skipped rather than fatal. None of
    /// them is state — they are endpoints the app rebuilds when it starts.
    /// Returns how many files actually landed — zero means everything was
    /// already there, which is a no-op and not a migration.
    @discardableResult
    private static func copyTree(from source: URL, to destination: URL,
                                 fileManager: FileManager) throws -> Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        let values = try source.resourceValues(forKeys: keys)

        if values.isDirectory == true {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let entries = try fileManager.contentsOfDirectory(
                at: source, includingPropertiesForKeys: Array(keys))
            var copied = 0
            for entry in entries {
                copied += try copyTree(from: entry,
                                       to: destination.appendingPathComponent(entry.lastPathComponent),
                                       fileManager: fileManager)
            }
            return copied
        }

        guard values.isRegularFile == true else { return 0 } // socket, fifo, device
        // Per-FILE non-overwrite: anything already at the new identity was
        // written after the rename and is the newer truth.
        guard !fileManager.fileExists(atPath: destination.path) else { return 0 }
        try fileManager.copyItem(at: source, to: destination)
        return 1
    }

    // MARK: - Permissions

    /// Whether the app still owes the user an explanation for the permission
    /// reset.
    ///
    /// macOS keys TCC grants to the bundle identifier, so renaming it empties
    /// Accessibility, Microphone, Automation and Calendar at once. What makes
    /// that worth a flag rather than a release note is HOW each one then fails:
    /// the calendar shows no events, dictation types nothing, jump-back does
    /// nothing, the audio tap reads silence. Four unrelated silences, none of
    /// them saying "permission", and nobody connects them to a rename they did
    /// not perform. The app has to say it once, out loud.
    ///
    /// Set only when a migration actually carried something across — a genuinely
    /// new install has nothing to re-grant and should never see this.
    private static let permissionReviewKey = "identity.permissionsNeedReview"

    public static func flagPermissionReview(in defaults: UserDefaults) {
        defaults.set(true, forKey: permissionReviewKey)
    }

    public static func needsPermissionReview(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: permissionReviewKey)
    }

    /// Cleared whatever the user chooses. Saying "later" is an answer, and an
    /// alert that returns every launch until you obey it is nagging.
    public static func clearPermissionReview(in defaults: UserDefaults) {
        defaults.removeObject(forKey: permissionReviewKey)
    }

    // MARK: - Preferences

    /// Copies every key from the old bundle's defaults domain into the new one.
    ///
    /// The preferences domain follows the bundle identifier, so changing the
    /// identifier is what loses every toggle, the panel width, the dictation
    /// keys, the clipboard capacity and — most visibly — the flag that says
    /// setup is already done, which is why an un-migrated update greets a
    /// long-time user with the first-run wizard.
    ///
    /// Guarded by a sentinel rather than by "is the new domain empty": the app
    /// writes defaults during launch, so emptiness stops being true almost
    /// immediately and the guard would fail open on the second run.
    @discardableResult
    public static func migrateDefaults(fromDomain legacyDomain: String,
                                       into defaults: UserDefaults,
                                       sentinel: String = "identity.migratedFromLegacyDomain") -> Int {
        guard defaults.object(forKey: sentinel) == nil else { return 0 }
        defer { defaults.set(true, forKey: sentinel) }

        guard let legacy = UserDefaults(suiteName: legacyDomain) else { return 0 }
        let values = legacy.persistentDomain(forName: legacyDomain) ?? [:]
        guard !values.isEmpty else { return 0 }

        var copied = 0
        for (key, value) in values {
            // Never overwrite something already set under the new identity —
            // anything present there was chosen after the rename.
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }
}
