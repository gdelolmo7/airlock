import Foundation

/// A name a person recognises, for a bundle identifier.
///
/// The "Never recorded" list is the one thing somebody reads before trusting a
/// clipboard manager at all, and it printed `com.bitwarden.desktop` and
/// `in.sinew.Enpass-Desktop`. The pane asked LaunchServices for the name and
/// fell back to the identifier — and LaunchServices only knows the apps you
/// have INSTALLED, which for a list of seven password managers is one of them
/// at most. So the fallback was the normal case, not the edge one.
public enum AppDisplayName {

    /// Named by hand, because this is our own list: Airlock ships these
    /// identifiers in `PasteboardClassifier.defaultIgnoredApps`, so it can
    /// ship the names too rather than guessing at them.
    ///
    /// A few that are not in the skip list are here anyway — the ones people
    /// add themselves most often — since naming an app costs a line and
    /// guessing wrongly costs the reader's trust in the list.
    public static let known: [String: String] = [
        "com.apple.keychainaccess": "Keychain Access",
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.agilebits.onepassword-osx": "1Password 6",
        "com.bitwarden.desktop": "Bitwarden",
        "com.dashlane.Dashlane": "Dashlane",
        "in.sinew.Enpass-Desktop": "Enpass",
        "com.lastpass.LastPass": "LastPass",
        "net.antelle.keeweb": "KeeWeb",
        "org.keepassxc.keepassxc": "KeePassXC",
        "com.proton.pass.electron": "Proton Pass",
        "com.nordpass.macos": "NordPass",
        "com.strongbox.mac.strongbox": "Strongbox",
    ]

    /// The last resort: an identifier, made readable.
    ///
    /// `com.bitwarden.desktop` → "Bitwarden". Not clever, and it does not need
    /// to be — anything it gets wrong is a name nobody had before, and the full
    /// identifier stays in the tooltip either way.
    public static func readable(_ bundleID: String) -> String {
        var parts = bundleID.split(separator: ".").map(String.init)
        // Reverse DNS: the first component is the seller's country or kind, and
        // never the product. "in.sinew.Enpass-Desktop" is not called In.
        if parts.count > 1, prefixes.contains(parts[0].lowercased()) { parts.removeFirst() }
        // Trailing platform words, which name the build rather than the app.
        while parts.count > 1, generic.contains(parts[parts.count - 1].lowercased()) {
            parts.removeLast()
        }
        guard let last = parts.last, !last.isEmpty else { return bundleID }

        var words = last.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        while words.count > 1, generic.contains(words[words.count - 1].lowercased()) {
            words.removeLast()
        }
        let name = words.map(capitalisedKeepingCase).joined(separator: " ")
        return name.isEmpty ? bundleID : name
    }

    /// `LastPass` and `KeeWeb` are already spelled the way their makers spell
    /// them; only an all-lowercase component needs a capital.
    private static func capitalisedKeepingCase(_ word: String) -> String {
        guard word == word.lowercased(), let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    private static let prefixes: Set<String> = [
        "com", "org", "net", "io", "co", "in", "eu", "de", "fr", "uk", "me", "app", "dev", "ai",
    ]

    private static let generic: Set<String> = [
        "desktop", "app", "mac", "macos", "osx", "client", "electron", "gui",
    ]
}
