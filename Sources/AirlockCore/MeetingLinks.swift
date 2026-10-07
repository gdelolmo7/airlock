import Foundation

/// A joinable video call found in a calendar event, and who hosts it.
///
/// Detection used to return a bare `URL?`, which threw away the two things the
/// UI actually needs: the provider — known at detection time, so the button can
/// say *what* it joins — and whether there is an app scheme that skips the
/// browser round trip a Zoom link otherwise forces you through.
public struct MeetingLink: Equatable, Hashable, Sendable {
    /// Who hosts the call. `.unknown` is a real, joinable outcome and not a
    /// failure: see `MeetingLinks.looksLikeARoom` for what earns it.
    public enum Provider: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
        case zoom
        case googleMeet
        case teams
        case webex
        case whereby
        case around
        case jitsi
        case blueJeans
        case discord
        case unknown

        /// Full name, for tooltips and VoiceOver. `nil` for `.unknown`, because
        /// there is nothing honest to put here — the caller names the host.
        public var displayName: String? {
            switch self {
            case .zoom: "Zoom"
            case .googleMeet: "Google Meet"
            case .teams: "Microsoft Teams"
            case .webex: "Webex"
            case .whereby: "Whereby"
            case .around: "Around"
            case .jitsi: "Jitsi Meet"
            case .blueJeans: "BlueJeans"
            case .discord: "Discord"
            case .unknown: nil
            }
        }

        /// What fits in a capsule beside a meeting title. "Join Microsoft
        /// Teams" does not; "Join Teams" does, and nobody is confused by it.
        public var shortName: String? {
            switch self {
            case .googleMeet: "Meet"
            case .teams: "Teams"
            case .jitsi: "Jitsi"
            default: displayName
            }
        }
    }

    public let provider: Provider
    /// The https link exactly as it appeared in the event — always openable,
    /// and always the fallback when no app claims `appURL`.
    public let url: URL

    public init(provider: Provider, url: URL) {
        self.provider = provider
        self.url = url
    }

    /// The app-scheme URL, when this provider has a documented scheme AND this
    /// particular link's shape converts without guessing. Never a replacement
    /// for `url`: nothing here proves the app is installed, so the caller opens
    /// this first and falls back to `url` when the open fails.
    public var appURL: URL? { MeetingLinks.appURL(for: self) }

    /// What the Join button says.
    public var buttonTitle: String {
        provider.shortName.map { "Join \($0)" } ?? "Join"
    }

    /// Tooltip and accessibility hint. An unknown provider is named by its host
    /// rather than dressed up as one we recognise — "Join the call at
    /// vc.acme.com" is the whole truth we have.
    public var joinDescription: String {
        if let name = provider.displayName { return "Join the \(name) call" }
        return "Join the call at \(url.host ?? url.absoluteString)"
    }

    /// The call as a noun, for a place with no room for a labelled button. An
    /// all-day chip is a dot, a truncated title and a glyph the size of the
    /// type beside it; "Offsite, all day, Zoom call" is the only way any of
    /// that reaches somebody who cannot see it.
    ///
    /// Unknown providers are named by their host for the same reason as
    /// `joinDescription`: the host is the whole of what we know, and inventing
    /// a brand for it is the one thing worse than saying nothing.
    public var callSummary: String {
        if let name = provider.displayName { return "\(name) call" }
        return "call at \(url.host ?? url.absoluteString)"
    }
}

/// Finds the video-call link inside calendar event fields — the one-click
/// "Join" that makes a meeting hint worth interrupting your eyes for.
/// Pure string work, so it lives in Core where the tests are.
public enum MeetingLinks {
    /// Hosts that mean "this URL joins a call", and who is behind them.
    /// Matched on the host itself or on any subdomain of it, so `zoom.us`
    /// covers `us02web.zoom.us` and `jit.si` covers `meet.jit.si`.
    private static let knownHosts: [(provider: MeetingLink.Provider, hosts: [String])] = [
        (.zoom, ["zoom.us"]),
        (.googleMeet, ["meet.google.com"]),
        (.teams, ["teams.microsoft.com", "teams.live.com"]),
        (.webex, ["webex.com"]),
        (.whereby, ["whereby.com"]),
        (.around, ["around.co"]),
        (.jitsi, ["jit.si", "8x8.vc"]),
        (.blueJeans, ["bluejeans.com"]),
        (.discord, ["discord.gg", "discord.com"]),
    ]

    /// Leftmost host labels that name a room rather than a website:
    /// `meet.acme.com`, `vc.example.org`, `video.university.edu`.
    private static let roomHostLabels: Set<String> = [
        "meet", "meeting", "meetings", "video", "call", "conference", "vc",
        "webconf", "join",
    ]

    /// First path segments that name a room: `…/join/abc`, `…/j/123`,
    /// `…/room/standup`.
    private static let roomPathSegments: Set<String> = [
        "j", "join", "meet", "meeting", "call", "conference", "room", "video",
        "webconf",
    ]

    // MARK: - Detection

    /// Find the joinable link across an event's fields.
    ///
    /// **Two passes, and the order between them is the whole point.** A known
    /// provider ANYWHERE beats a room-shaped guess EVERYWHERE; only once no
    /// listed host appears in any field does the vocabulary rule get a turn.
    /// Field priority (explicit URL → location → notes) still decides *within*
    /// each pass, and document order within each field.
    ///
    /// One pass in document order loses to prose, and loses badly:
    /// `Slack: https://join.slack.com/t/acme/… — call: https://acme.zoom.us/j/8412`
    /// hands the Join button to a workspace invite whose leftmost label happens
    /// to sit in `roomHostLabels`, and the real Zoom link two words later is
    /// never reached. The guess is a fallback, so it has to run like one.
    public static func detect(url: String?, location: String?, notes: String?) -> MeetingLink? {
        let fields = [url, location, notes].compactMap { $0 }.filter { !$0.isEmpty }
        for field in fields {
            if let link = firstKnownProviderLink(in: field) { return link }
        }
        for field in fields {
            if let link = firstRoomShapedLink(in: field) { return link }
        }
        return nil
    }

    /// The same known-beats-guess order, for a single field.
    static func firstMeetingLink(in text: String) -> MeetingLink? {
        firstKnownProviderLink(in: text) ?? firstRoomShapedLink(in: text)
    }

    static func firstKnownProviderLink(in text: String) -> MeetingLink? {
        firstLink(in: text) { host, _ in knownProvider(forHost: host) }
    }

    static func firstRoomShapedLink(in text: String) -> MeetingLink? {
        firstLink(in: text) { host, url in looksLikeARoom(host: host, url: url) ? .unknown : nil }
    }

    /// Walk the https URLs in `text` in document order, returning the first one
    /// `classify` claims.
    private static func firstLink(
        in text: String,
        classify: (String, URL) -> MeetingLink.Provider?
    ) -> MeetingLink? {
        // Grab https URLs, tolerate trailing punctuation from prose/notes.
        let pattern = #"https://[^\s<>"')\]]+"#
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: pattern, options: .regularExpression, range: searchRange) {
            let raw = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            if let url = URL(string: raw), let host = url.host?.lowercased(),
               let provider = classify(host, url) {
                return MeetingLink(provider: provider, url: url)
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return nil
    }

    static func knownProvider(forHost host: String) -> MeetingLink.Provider? {
        for entry in knownHosts
        where entry.hosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return entry.provider
        }
        return nil
    }

    /// What makes an *unlisted* URL "plainly a meeting link".
    ///
    /// The rule is **vocabulary, not optimism**: either the host's leftmost
    /// label or the first path segment has to be a word that essentially only
    /// ever names a room — `meet.acme.com/standup`, `https://vc.example.org/x`,
    /// `…/join/abc`, `…/j/123`. That is the shape self-hosted Jitsi,
    /// BigBlueButton and every corporate `vc.` box actually ships, and it is
    /// also the shape of all nine listed providers, which is the reason to
    /// trust it on a tenth.
    ///
    /// It deliberately does NOT accept a bare https link. Notes fields are full
    /// of agendas, dashboards and docs; promoting any of those to a Join button
    /// makes the button lie, and you cannot tell a lying Join button from a
    /// real one until the meeting has already started without you. A false
    /// negative costs one copy-paste out of the notes; a false positive costs
    /// the meeting. The asymmetry is the whole argument.
    ///
    /// That argument only holds because `detect` runs this pass SECOND, over
    /// every field, after no listed host was found anywhere. The vocabulary is
    /// broad on purpose — `join`, `conference` and `video` are ordinary words,
    /// and `join.slack.com` matches — so it is a last resort by construction,
    /// never something that can outrank a `zoom.us` link further down the page.
    static func looksLikeARoom(host: String, url: URL) -> Bool {
        if let label = host.split(separator: ".").first.map(String.init),
           roomHostLabels.contains(label) {
            return true
        }
        guard let first = url.pathComponents.first(where: { $0 != "/" })?.lowercased(),
              roomPathSegments.contains(first) else { return false }
        // A room segment has to name a room: `/join` alone is a marketing page,
        // `/join/abc` is somewhere to be.
        return url.pathComponents.filter { $0 != "/" }.count >= 2
    }

    // MARK: - App handoff

    /// The app-scheme URL for a link, when there is one worth trusting.
    ///
    /// Only two are implemented, and only because both are documented by the
    /// vendor rather than reverse-engineered:
    ///
    /// - **Zoom** `zoommtg://<host>/join?confno=<id>&pwd=<pwd>` — the scheme
    ///   Zoom's own "launch meeting" interstitial fires, which is precisely the
    ///   page this handoff exists to skip. Converted only for the numeric
    ///   `/j/<id>` form; a personal-room link (`/my/<name>`) resolves server
    ///   side, so there is no id to hand over and it stays on https.
    /// - **Teams** `msteams://teams.microsoft.com/l/…` — Microsoft's deep-link
    ///   format is the https URL with the scheme swapped, for the `/l/` family
    ///   that meeting joins belong to. Nothing else is touched.
    ///
    /// Google Meet, Webex, Whereby, Around, Jitsi, BlueJeans and Discord stay
    /// on https: they either have no desktop app scheme or none this codebase
    /// has verified, and a wrong scheme fails *silently into the wrong app*,
    /// which is worse than the browser trip it was meant to save.
    static func appURL(for link: MeetingLink) -> URL? {
        switch link.provider {
        case .zoom: zoomAppURL(link.url)
        case .teams: teamsAppURL(link.url)
        default: nil
        }
    }

    static func zoomAppURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count == 2, segments[0].lowercased() == "j" else { return nil }
        let confno = segments[1]
        guard !confno.isEmpty, confno.allSatisfy(\.isNumber) else { return nil }

        var components = URLComponents()
        components.scheme = "zoommtg"
        components.host = host
        components.path = "/join"
        var items = [URLQueryItem(name: "confno", value: confno)]
        if let pwd = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "pwd" })?.value, !pwd.isEmpty {
            items.append(URLQueryItem(name: "pwd", value: pwd))
        }
        components.queryItems = items
        return components.url
    }

    static func teamsAppURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.hasPrefix("/l/") else { return nil }
        components.scheme = "msteams"
        return components.url
    }
}
