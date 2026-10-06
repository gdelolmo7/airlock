import Foundation

/// A phrase that means a web address. "youtube" → `https://youtube.com`.
public struct VoiceSiteAlias: Sendable, Equatable, Identifiable {
    /// What a person says. Folded before matching, so case and punctuation in
    /// the file do not matter.
    public let phrase: String
    /// Where it goes. Always absolute, always `https` unless the user wrote
    /// otherwise.
    public let url: String

    public var id: String { phrase }

    public init(phrase: String, url: String) {
        self.phrase = phrase
        self.url = url
    }
}

/// The table behind "go to YouTube" and "open my Gmail settings".
///
/// **Shipped defaults plus a plain text file the user owns**, merged with the
/// user winning. Both halves matter and for different reasons.
///
/// A shipped table is what makes the feature work on the first day, before
/// anybody has configured anything — and the phrases in it are the ones nobody
/// would think to add because they seem too obvious to need adding.
///
/// A user file is what makes it *theirs*, and the motivating example could not
/// be shipped by anyone: "open my Gmail settings" is a deep link into one
/// person's account layout. Nobody can guess it, everybody can write it once.
///
/// Same shape as `policy.yaml` — `~/.airlock/sites.txt`, overridable with
/// `AIRLOCK_POLICY_HOME` for tests — because a second convention for "the
/// user's own config" would be a second thing to explain.
public enum VoiceSiteAliases {

    /// The file, relative to the config directory.
    public static let fileName = "sites.txt"

    /// Enough to be useful on day one, short enough to read.
    ///
    /// Deliberately NOT a long directory of the web. Every entry here is a
    /// phrase that could otherwise be an app, and the resolution order settles
    /// that (an installed app always wins), so a bloated table would mostly add
    /// ways to be surprised.
    public static let defaults: [VoiceSiteAlias] = [
        // Sites people name out loud. An installed app of the same name always
        // wins, so "open spotify" is the app if you have it and the web player
        // if you do not.
        .init(phrase: "youtube", url: "https://youtube.com"),
        .init(phrase: "gmail", url: "https://mail.google.com"),
        .init(phrase: "my email", url: "https://mail.google.com"),
        .init(phrase: "google", url: "https://google.com"),
        .init(phrase: "google drive", url: "https://drive.google.com"),
        .init(phrase: "drive", url: "https://drive.google.com"),
        .init(phrase: "google docs", url: "https://docs.google.com"),
        .init(phrase: "google calendar", url: "https://calendar.google.com"),
        .init(phrase: "google maps", url: "https://maps.google.com"),
        .init(phrase: "maps", url: "https://maps.google.com"),
        .init(phrase: "google translate", url: "https://translate.google.com"),
        .init(phrase: "linkedin", url: "https://linkedin.com"),
        .init(phrase: "github", url: "https://github.com"),
        .init(phrase: "twitter", url: "https://x.com"),
        .init(phrase: "x", url: "https://x.com"),
        .init(phrase: "reddit", url: "https://reddit.com"),
        .init(phrase: "wikipedia", url: "https://wikipedia.org"),
        .init(phrase: "amazon", url: "https://amazon.com"),
        .init(phrase: "netflix", url: "https://netflix.com"),
        .init(phrase: "spotify", url: "https://open.spotify.com"),
        .init(phrase: "whatsapp", url: "https://web.whatsapp.com"),
        .init(phrase: "instagram", url: "https://instagram.com"),
        .init(phrase: "claude", url: "https://claude.ai"),
        .init(phrase: "chatgpt", url: "https://chatgpt.com"),
        .init(phrase: "hacker news", url: "https://news.ycombinator.com"),
        .init(phrase: "stack overflow", url: "https://stackoverflow.com"),

        // Places on this Mac. `file://` opens in Finder, which is what "go to
        // my downloads" means — and it is not an escalation, because opening a
        // folder is what the Finder does with a folder.
        .init(phrase: "downloads", url: "file://~/Downloads"),
        .init(phrase: "my downloads", url: "file://~/Downloads"),
        .init(phrase: "documents", url: "file://~/Documents"),
        .init(phrase: "my documents", url: "file://~/Documents"),
        .init(phrase: "desktop", url: "file://~/Desktop"),
        .init(phrase: "my desktop", url: "file://~/Desktop"),
        .init(phrase: "home folder", url: "file://~"),
        .init(phrase: "applications", url: "file:///Applications"),

        // Panes of System Settings, which is where half of "can you change X"
        // ends up and which nobody can navigate to by name.
        .init(phrase: "system settings", url: "x-apple.systempreferences:"),
        .init(phrase: "settings", url: "x-apple.systempreferences:"),
        .init(phrase: "display settings", url: "x-apple.systempreferences:com.apple.Displays-Settings.extension"),
        .init(phrase: "sound settings", url: "x-apple.systempreferences:com.apple.Sound-Settings.extension"),
        .init(phrase: "bluetooth settings", url: "x-apple.systempreferences:com.apple.BluetoothSettings"),
        .init(phrase: "wifi settings", url: "x-apple.systempreferences:com.apple.wifi-settings-extension"),
        .init(phrase: "keyboard settings", url: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"),
        .init(phrase: "privacy settings", url: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"),
        .init(phrase: "battery settings", url: "x-apple.systempreferences:com.apple.Battery-Settings.extension"),

        // The App Store, which has no other way in by name.
        .init(phrase: "the app store", url: "macappstore://apps.apple.com/us/genre/mac/id39"),
    ]

    /// What the file says, as a starting point for someone opening it.
    public static let template = """
        # Airlock — phrases that mean a web address.
        #
        #   phrase = url
        #
        # One per line. Anything after a # is a comment. The phrase is what you
        # SAY, so write it the way you would say it — case and punctuation are
        # ignored. A phrase here overrides a built-in one of the same name, and
        # an installed app of the same name still wins over both.
        #
        # This is the file for the things nobody could ship for you:
        #
        #   my gmail settings = https://mail.google.com/mail/u/0/#settings/general
        #   the standup doc   = https://docs.google.com/document/d/…
        #   our dashboard     = https://grafana.example.com/d/abc/overview

        """

    /// Parse `phrase = url` lines.
    ///
    /// **Fails soft, line by line**, which is the opposite of `PolicyParser` and
    /// deliberately so. Policy decides whether an agent may run a command, so a
    /// file it cannot read is an emergency and it stops loudly with a line
    /// number. This decides whether "go to youtube" works; one malformed line
    /// should cost that line, not the other forty.
    public static func parse(_ text: String) -> [VoiceSiteAlias] {
        var aliases: [VoiceSiteAlias] = []
        for rawLine in text.components(separatedBy: .newlines) {
            // A `#` inside a URL is a fragment — "…#settings" is the motivating
            // example — so only a comment that starts the line is stripped.
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }

            let phrase = line[..<separator].trimmingCharacters(in: .whitespaces)
            let target = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !phrase.isEmpty, let url = normalized(target) else { continue }
            aliases.append(VoiceSiteAlias(phrase: phrase, url: url))
        }
        return aliases
    }

    /// User entries override built-ins of the same phrase; everything else is
    /// added. Order is defaults-then-user so a `policy.yaml`-style read of the
    /// file — later wins — holds here too.
    public static func merged(user: [VoiceSiteAlias],
                              defaults builtIn: [VoiceSiteAlias] = defaults) -> [VoiceSiteAlias] {
        var byPhrase: [String: VoiceSiteAlias] = [:]
        var order: [String] = []
        for alias in builtIn + user {
            let key = VoiceMatch.fold(alias.phrase)
            guard !key.isEmpty else { continue }
            if byPhrase[key] == nil { order.append(key) }
            byPhrase[key] = alias
        }
        return order.compactMap { byPhrase[$0] }
    }

    /// A bare host typed or spoken as one — "open github.com".
    ///
    /// Only accepted when it already looks like a host: a dot, no spaces, and a
    /// last label that is letters. Without that "open a new account" would
    /// become a navigation the moment anybody said something with a full stop
    /// in it.
    public static func bareURL(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("https://") || trimmed.lowercased().hasPrefix("http://") {
            return normalized(trimmed)
        }
        guard !trimmed.contains(" "), trimmed.contains(".") else { return nil }
        let labels = trimmed.split(separator: ".")
        guard labels.count >= 2, let last = labels.last, last.count >= 2,
              last.allSatisfy({ $0.isLetter }),
              labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return normalized(trimmed)
    }

    /// Schemes a phrase may use.
    ///
    /// **An allowlist, because this string reaches `NSWorkspace.open`.** The
    /// four here each open a VIEWER — a browser, the Finder, System Settings,
    /// the App Store — and none of them runs anything. What is refused is the
    /// interesting half: `javascript:`, `ftp:`, and every custom scheme an
    /// installed app has registered, any of which can be an action rather than
    /// a destination.
    ///
    /// `file:` is included and is the one worth arguing about. It can name a
    /// `.app`, and opening one launches it — but `Voice.Open` already launches
    /// apps by name, so it grants nothing new, and without it "go to my
    /// downloads" is impossible.
    static let allowedSchemes: Set<String> = [
        "https", "http", "file", "x-apple.systempreferences", "macappstore",
    ]

    /// Add `https` if there is no scheme, expand a leading `~`, and refuse
    /// anything outside `allowedSchemes`.
    public static func normalized(_ target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        // Any scheme, not just one with `//` after it. `mailto:a@b.c` and
        // `javascript:…` have none, so a `contains("://")` test reads them as
        // schemeless, prepends `https://`, and hands
        // `https://mailto:a@b.c` to URL — which parses. The test caught it.
        let withScheme = hasScheme(trimmed) ? trimmed : "https://" + trimmed
        // `file://~/Downloads` is how a person writes it and not a path any
        // API accepts, so the tilde is expanded here rather than at every use.
        let expanded = withScheme.replacingOccurrences(
            of: "file://~", with: "file://" + NSHomeDirectory())

        guard let url = URL(string: expanded), let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else { return nil }
        // A host is required for the network schemes and meaningless for the
        // others — `x-apple.systempreferences:` is a bare scheme by design.
        if scheme == "https" || scheme == "http" {
            guard url.host?.isEmpty == false else { return nil }
        }
        return expanded
    }

    /// `scheme:` at the very start — letter, then letters/digits/`+`/`-`/`.`,
    /// then a colon. The RFC 3986 shape, which is what `URL` will read too.
    private static func hasScheme(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let candidate = value[..<colon]
        guard let first = candidate.first, first.isLetter else { return false }
        return candidate.allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
    }
}
