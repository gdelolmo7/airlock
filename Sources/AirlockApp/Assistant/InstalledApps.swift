import AppKit
import AirlockCore

/// The applications on this Mac, by the name printed under their icon.
///
/// **Scanned rather than asked for.** There is no public API that enumerates
/// installed apps by display name, and the name is the whole point here — a
/// person says "open Spotify", not a bundle identifier, and going display name
/// → bundle ID is a lookup that fails for exactly the apps whose names are
/// unusual. So this reads the directories where apps live and takes the name
/// off the bundle, which is the same string Finder shows.
///
/// Cheap enough to do on a timer and cached anyway: three shallow directory
/// reads, no recursion into bundles, `localizedName` only where AppKit already
/// has it.
enum InstalledApps {

    /// Where apps actually are. `/System/Applications` is separate on modern
    /// macOS and is where Music, Safari and Mail now live — omitting it was the
    /// first draft's bug, and it would have broken "open the music" specifically.
    private static var searchPaths: [String] {
        var paths = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     "/Applications/Utilities"]
        paths.append(NSHomeDirectory() + "/Applications")
        return paths
    }

    /// Every app, newest scan. Empty only if the filesystem refuses us entirely.
    ///
    /// `nonisolated` and `async` so the caller hops off the main actor — this is
    /// filesystem work and the notch must not wait on it.
    ///
    /// `languages` are the codes the user dictates in beyond English ("es"),
    /// and each adds a read of the bundle's own localization per app — see
    /// `localizedNames`. Empty means the scan stays the three shallow
    /// directory reads it always was.
    nonisolated static func scan(languages: [String] = []) async -> [VoiceAppTarget] {
        await Task.detached(priority: .utility) {
            var found: [String: VoiceAppTarget] = [:]
            let manager = FileManager.default
            for directory in searchPaths {
                guard let entries = try? manager.contentsOfDirectory(atPath: directory) else { continue }
                for entry in entries where entry.hasSuffix(".app") {
                    let path = directory + "/" + entry
                    let name = String(entry.dropLast(4))
                    // Keyed by NAME, not path, so a second copy of an app does
                    // not become an ambiguity that `VoiceMatch.unique` then
                    // refuses to resolve. First one wins, and the search order
                    // puts /Applications before the user's own folder.
                    if found[name] == nil {
                        found[name] = VoiceAppTarget(
                            path: path, name: name,
                            aliases: localizedNames(appPath: path, name: name,
                                                    languages: languages))
                    }
                }
            }
            return found.values.sorted { $0.name < $1.name }
        }.value
    }

    /// What the bundle calls itself in each requested language, when that
    /// differs from the on-disk name.
    ///
    /// **From the bundle's own localizations, never from the system.** The
    /// system's answer (`displayName`) is the macOS UI language, and the
    /// person this exists for runs an English Mac and speaks Spanish at it —
    /// "abre la música" has to find Music.app on a system that calls it
    /// Music. The bundle carries every language it was localized into,
    /// whatever the system shows.
    ///
    /// Two formats, because macOS moved: system apps consolidated their
    /// strings into `InfoPlist.loctable` (one plist keyed by language);
    /// third-party apps still ship `<lang>.lproj/InfoPlist.strings`. Both are
    /// plists `NSDictionary(contentsOfFile:)` reads, a missing file is a cheap
    /// nil, and apps that never localized — most of them, Spotify is Spotify
    /// everywhere — contribute nothing.
    /// Internal for the one test that verifies the two formats against the
    /// system's own bundles — the format assumption is the part of this that
    /// can rot under a macOS update, and a test is where that shows up first.
    nonisolated static func localizedNames(appPath: String, name: String,
                                           languages: [String]) -> [String] {
        guard !languages.isEmpty else { return [] }
        let resources = appPath + "/Contents/Resources"
        let loctable = NSDictionary(contentsOfFile: resources + "/InfoPlist.loctable")

        var names: Set<String> = []
        for language in languages {
            var display: String?
            if let entry = loctable?[language] as? [String: Any] {
                display = (entry["CFBundleDisplayName"] ?? entry["CFBundleName"]) as? String
            }
            if display == nil,
               let strings = NSDictionary(contentsOfFile:
                    resources + "/\(language).lproj/InfoPlist.strings") {
                display = (strings["CFBundleDisplayName"] ?? strings["CFBundleName"]) as? String
            }
            if let display, display != name { names.insert(display) }
        }
        return names.sorted()
    }

    /// Front an app by bundle path, launching it if it is not running.
    ///
    /// Re-checked here rather than trusted from the proposal: the gap between
    /// the card appearing and Do it being pressed is as long as the user wants,
    /// and an app can be deleted or moved inside it.
    @MainActor
    static func open(_ target: VoiceOpenTarget) -> Bool {
        switch target {
        case .app(let path): return openApp(path: path)
        case .url(let url): return openURL(url)
        }
    }

    /// `VoiceSiteAliases` has already refused anything that is not http(s), so
    /// this only has to check that the string still parses.
    @MainActor
    private static func openURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return false }
        return NSWorkspace.shared.open(url)
    }

    @MainActor
    private static func openApp(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        // Front an already-running instance rather than starting a second one.
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                           configuration: configuration) { _, error in
            if let error {
                Log.widgets.error("open app failed — \(error.localizedDescription, privacy: .public)")
            }
        }
        // True means HANDED OFF. `openApplication` is asynchronous and its
        // completion arrives long after the card is gone, so the honest claim
        // here is the one `runShortcut` makes: it was started.
        return true
    }
}
