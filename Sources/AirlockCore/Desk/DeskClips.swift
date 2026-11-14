import Foundation

/// The last things copied, as the "Last copied" desktop widget shows them.
///
/// The widget is sandboxed and cannot read clipboard history, so the app
/// writes this, and a small picture of each copied image, where the widget
/// can read them (`DeskShelf`). It only ever holds copies the history already
/// kept, so everything `PasteboardClassifier` skips (password managers,
/// anything an app marks as concealed or transient) never reaches it.
///
/// On top of that, text that looks like a password, a key or a token
/// (`DeskSecretCheck`) is carried as its length alone: its words are never
/// written where the widget can read them.
///
/// A click on a copy opens `airlock://clip?id=<uuid>`, and the app copies it
/// again only if that copy is in the history and shown on this plan. A link
/// typed by anybody can at most put back something you copied yourself.
public struct DeskClips: Codable, Equatable, Sendable {
    public struct Clip: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable { case text, image, file }

        public var id: UUID
        public var kind: Kind
        /// What to show: the text (one line, cut short), or a file's name.
        /// Nil for a picture, and for text that looks secret.
        public var text: String?
        /// Set instead of `text` when the text looks secret: how many
        /// characters it has, so it can be told apart from the others.
        public var hiddenLength: Int?
        public var app: String?
        public var copiedAt: Date
        public var pinned: Bool
        /// The picture's file name under `DeskClips.thumbsFolder`.
        public var thumb: String?
        public var width: Int?
        public var height: Int?

        public init(id: UUID, kind: Kind, text: String? = nil, hiddenLength: Int? = nil, app: String? = nil,
                    copiedAt: Date, pinned: Bool = false, thumb: String? = nil,
                    width: Int? = nil, height: Int? = nil) {
            self.id = id
            self.kind = kind
            self.text = text
            self.hiddenLength = hiddenLength
            self.app = app
            self.copiedAt = copiedAt
            self.pinned = pinned
            self.thumb = thumb
            self.width = width
            self.height = height
        }

        public var isHidden: Bool { hiddenLength != nil }

        public var copyURL: URL {
            var parts = URLComponents()
            parts.scheme = "airlock"
            parts.host = DeskClips.host
            parts.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
            return parts.url!
        }

        /// The picture's name: one per copy, since a copy never changes.
        public var thumbKey: String { id.uuidString + ".png" }

        /// The line a row shows.
        public var line: String {
            if let hiddenLength { return DeskClipsWords.hidden(hiddenLength) }
            switch kind {
            case .image:
                if let width, let height { return DeskClipsWords.picture + " · \(width)×\(height)" }
                return DeskClipsWords.picture
            case .text, .file: return text ?? ""
            }
        }
    }

    /// Newest first, up to `limit`.
    public var clips: [Clip]
    /// The clipboard's own switch. Off, the widget says so and shows nothing.
    public var isOn: Bool
    public var surface: DeskSurface?

    public init(clips: [Clip], isOn: Bool = true, surface: DeskSurface? = nil) {
        self.clips = clips
        self.isOn = isOn
        self.surface = surface
    }

    public static let empty = DeskClips(clips: [])
    public static let snapshotName = "desk-clips.json"
    public static let thumbsFolder = "clip-thumbs"
    public static let widgetKind = "com.airlock.clips"
    public static let host = "clip"
    /// The most copies any size draws (large: six rows).
    public static let limit = 6
    /// The most characters of text written for a copy.
    public static let textLimit = 200

    /// A click anywhere but a copy: the notch, on the Clipboard.
    public static let openURL = URL(string: "airlock://clip")!

    /// The copies a plan shows, in the history's order: every pinned copy,
    /// and unpinned ones up to `planShows`. The same rule as the notch.
    public static func shown(_ items: [ClipboardItem], planShows: Int?) -> [ClipboardItem] {
        var unpinned = 0
        return items.filter { item in
            if item.pinned { return true }
            unpinned += 1
            return planShows.map { unpinned <= $0 } ?? true
        }
    }

    /// The snapshot for what the plan shows, newest copy first. Off, nothing
    /// is carried at all, so an old copy cannot linger on the desk.
    /// `thumb` names the picture made for a copied image, or nil.
    public static func make(_ items: [ClipboardItem], planShows: Int?, isOn: Bool, surface: DeskSurface?,
                            limit: Int = limit,
                            thumb: (ClipboardItem) -> String? = { _ in nil }) -> DeskClips {
        guard isOn else { return DeskClips(clips: [], isOn: false, surface: surface) }
        let newest = shown(items, planShows: planShows).sorted { $0.copiedAt > $1.copiedAt }
        return DeskClips(clips: newest.prefix(limit).map { clip(for: $0, thumb: thumb($0)) },
                         isOn: true, surface: surface)
    }

    public static func clip(for item: ClipboardItem, thumb: String? = nil) -> Clip {
        var clip = Clip(id: item.id, kind: .text, app: item.sourceAppName, copiedAt: item.copiedAt,
                        pinned: item.pinned)
        switch item.payload {
        case .text(let value):
            if DeskSecretCheck.looksSecret(value) {
                clip.hiddenLength = value.trimmingCharacters(in: .whitespacesAndNewlines).count
            } else {
                clip.text = String(item.preview.prefix(textLimit))
            }
        case .image(_, let width, let height):
            clip.kind = .image
            clip.width = width
            clip.height = height
            clip.thumb = thumb
        case .file(let path):
            clip.kind = .file
            clip.text = (path as NSString).lastPathComponent
        }
        return clip
    }

    public static func isOpenURL(_ url: URL) -> Bool {
        url.scheme == "airlock" && url.host == host && clipID(from: url) == nil
    }

    /// The copy a link names.
    public static func clipID(from url: URL) -> UUID? {
        guard url.scheme == "airlock", url.host == host,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value
        else { return nil }
        return UUID(uuidString: value)
    }

    /// Pictures under `thumbsFolder` no copy in `clips` uses any more.
    public func staleThumbs(among names: [String]) -> [String] {
        let kept = Set(clips.compactMap(\.thumb))
        return names.filter { $0.hasSuffix(".png") && !kept.contains($0) }
    }
}

/// Whether copied text looks like a password, a key or a token, so the
/// desktop widget shows its length instead of its words.
///
/// It errs toward hiding: a false alarm costs a row that says "Hidden" and
/// still copies again on a click; a miss puts a secret on the desk. It knows
/// what secrets look like, never anybody's in particular.
public enum DeskSecretCheck {
    /// Prefixes providers put on their keys and tokens.
    static let prefixes = [
        "sk-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "whsec_",
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-",
        "xoxb-", "xoxp-", "xoxa-", "xoxr-", "xoxs-", "xapp-",
        "AKIA", "ASIA", "AIza", "ya29.", "npm_", "pypi-", "hf_", "shpat_", "shpss_",
        "SG.", "dop_v1_", "lin_api_", "sntrys_",
    ]

    public static func looksSecret(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("-----BEGIN") && trimmed.contains("PRIVATE KEY") { return true }
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace || "=:\"'`,;()[]{}<>".contains($0) })
            .map(String.init)
        if tokens.contains(where: isKeyLike) { return true }
        // A single word on its own, mixed like a password.
        if !trimmed.contains(where: \.isWhitespace) { return isPasswordLike(trimmed) }
        return false
    }

    /// A provider's key, a signed web token, or a long random string.
    static func isKeyLike(_ token: String) -> Bool {
        if token.count >= 20, prefixes.contains(where: { token.hasPrefix($0) }) { return true }
        if isWebToken(token) { return true }
        return isRandom(token)
    }

    static func isWebToken(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.hasPrefix("eyJ"), parts.allSatisfy({ $0.count >= 8 }) else { return false }
        return parts.allSatisfy { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
    }

    /// 32 characters or more of mixed letters and digits with little
    /// repetition. A web address, a path, a hash of 40 hex digits or fewer,
    /// and an id written as a UUID are left alone: people copy those daily.
    static func isRandom(_ token: String) -> Bool {
        guard token.count >= 32, !token.contains("://"), !token.hasPrefix("/"), !token.hasPrefix("~"),
              UUID(uuidString: token) == nil
        else { return false }
        let isHex = token.allSatisfy(\.isHexDigit)
        if isHex && token.count <= 40 { return false }
        guard token.contains(where: \.isLetter), token.contains(where: \.isNumber) else { return false }
        return entropy(token) >= 4.0
    }

    /// 8 to 64 characters with no space, and three of: lower case, upper
    /// case, digits, symbols. `_`, `-` and `.` are not counted as symbols,
    /// so names like `user_id2` and versions like `v1.2.3` stay visible.
    static func isPasswordLike(_ word: String) -> Bool {
        guard (8...64).contains(word.count), !word.contains("://"), !word.contains("@"),
              !word.hasPrefix("/"), !word.hasPrefix("~")
        else { return false }
        var classes = 0
        if word.contains(where: \.isLowercase) { classes += 1 }
        if word.contains(where: \.isUppercase) { classes += 1 }
        if word.contains(where: \.isNumber) { classes += 1 }
        if word.contains(where: { !$0.isLetter && !$0.isNumber && !"_-.".contains($0) }) { classes += 1 }
        return classes >= 3
    }

    /// Bits per character.
    static func entropy(_ token: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in token { counts[character, default: 0] += 1 }
        let total = Double(token.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }
}

/// The Last copied widget's words.
public enum DeskClipsWords {
    public static let name = String(localized: "Last copied")
    public static let blurb = String(localized: "What you copied last. Click one to copy it again. Passwords are never shown.")
    public static let title = String(localized: "Last copied")
    public static let emptyTitle = String(localized: "Nothing copied yet")
    public static let emptyLine = String(localized: "What you copy shows up here.")
    public static let offTitle = String(localized: "Clipboard history is off")
    public static let offLine = String(localized: "Switch it on in Airlock's Settings.")
    public static let picture = String(localized: "Picture")
    public static let pinned = String(localized: "Pinned")
    public static let clickToCopy = String(localized: "Click to copy again")

    public static func hidden(_ length: Int) -> String {
        length == 1 ? String(localized: "Hidden · 1 character") : String(localized: "Hidden · \(length) characters")
    }
}
