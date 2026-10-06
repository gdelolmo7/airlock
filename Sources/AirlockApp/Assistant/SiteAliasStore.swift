import AppKit
import Foundation
import AirlockCore

/// Reads `~/.airlock/sites.txt`, and writes it once so there is something to open.
///
/// The same directory and the same override (`AIRLOCK_POLICY_HOME`) as
/// `PolicyStore`, deliberately: "the folder where Airlock keeps the files you
/// are allowed to edit" is a single idea, and a second location for it would be
/// a second thing to explain and a second thing to back up.
///
/// Nothing here fails loudly. A missing file is the normal state — it means the
/// user has not needed one yet — and an unreadable one still leaves the shipped
/// defaults working, because a typo in a convenience table must not take
/// "open Spotify" down with it.
struct SiteAliasStore {

    var directory: URL {
        let home = ProcessInfo.processInfo.environment["AIRLOCK_POLICY_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".airlock")
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    var fileURL: URL { directory.appendingPathComponent(VoiceSiteAliases.fileName) }

    /// Defaults merged with whatever the user has written, user winning.
    func load() -> [VoiceSiteAlias] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return VoiceSiteAliases.merged(user: [])
        }
        return VoiceSiteAliases.merged(user: VoiceSiteAliases.parse(text))
    }

    /// Create the file with its template, if it is not there.
    ///
    /// Written on first use rather than at install, and NEVER over an existing
    /// file: the whole value of this thing is that it is the user's, and an app
    /// that rewrites your config on launch is an app you stop putting anything
    /// important in. Same rule `IdentityMigration` follows — a destination that
    /// exists means leave it alone.
    @discardableResult
    func createTemplateIfMissing() -> Bool {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try VoiceSiteAliases.template.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.widgets.error("could not write sites.txt — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Just the user's own entries, for the editor to show and edit.
    ///
    /// Deliberately NOT the merged list: the editor is where somebody adds and
    /// removes THEIR phrases, and putting fifty shipped ones in it would make
    /// their three impossible to find — and imply they can be deleted, which
    /// they cannot.
    func loadUserEntries() -> [VoiceSiteAlias] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return VoiceSiteAliases.parse(text)
    }

    /// Write the user's entries back, preserving the template's header.
    ///
    /// The file stays the storage even though the editing happens in a window,
    /// because the file is what survives an update, goes in a dotfiles repo,
    /// and can be fixed when the UI cannot express something.
    func save(_ entries: [VoiceSiteAlias]) {
        let body = entries
            .filter { !$0.phrase.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.phrase) = \($0.url)" }
            .joined(separator: "\n")
        let text = VoiceSiteAliases.template + body + "\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Log.widgets.error("could not save sites.txt — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reveal it, creating it first so the reveal never lands on nothing.
    @MainActor
    func revealInFinder() {
        createTemplateIfMissing()
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
