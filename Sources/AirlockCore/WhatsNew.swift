import Foundation

/// What a new version tells the person who just got it, once.
///
/// The owner asked for it on 2026-10-07 ("when I release new things, is there
/// an automated way for users … a new window appears with the new changes?").
/// Sparkle's own window only says that a version exists, and the appcast had no
/// notes in it, so an update arrived silently and nobody learned what it was
/// for.
///
/// **The notes live here, in the app, not on the website.** The card needs no
/// network, works offline, and cannot be told something different from what the
/// build actually contains. The release script reads the same entry back out
/// of the built app (`--whats-new-html`) and puts it beside the DMG, so
/// Sparkle's update window shows it too, before anyone installs. One text, two
/// places, no way for them to drift.
///
/// Writing an entry is part of releasing: a version with no entry shows no
/// card, which is the right failure — a quiet update, not a wrong one.
public enum WhatsNew {
    /// One line on the card: an SF Symbol and a sentence in plain words.
    public struct Item: Equatable, Sendable {
        public let symbol: String
        public let text: String

        public init(_ symbol: String, _ text: String) {
            self.symbol = symbol
            self.text = text
        }
    }

    /// One version's card.
    public struct Notes: Equatable, Sendable {
        /// `CFBundleShortVersionString`, e.g. "1.0.18".
        public let version: String
        /// What the release is, in a few words. Not "What's new" — the card
        /// already says that above it.
        public let title: String
        /// Three or four. The card has no scroll view on purpose: notes that
        /// need one are notes nobody reads. Folded with older versions, the
        /// card keeps the newest `maxItems` lines.
        public let items: [Item]

        public init(version: String, title: String, items: [Item]) {
            self.version = version
            self.title = title
            self.items = items
        }
    }

    /// Every version's notes, newest first. Add the new one at the top when
    /// releasing; old ones stay so a test can check the shape of all of them.
    ///
    /// Written for someone who is not technical: what changes for them on the
    /// Mac, never how.
    public static let catalog: [Notes] = [
        Notes(version: "1.0.18", title: "Cleaner calls, and this note", items: [
            Item("phone", "During a call, the notch shows a crisp logo of the app you're calling."),
            Item("video", "A Google Meet call in your browser shows Meet's logo, even after you switch tabs."),
            Item("sparkles", "After each update, this card tells you what changed. Once."),
        ]),
    ]

    public static func notes(for version: String, in catalog: [Notes] = catalog) -> Notes? {
        catalog.first { $0.version == version }
    }

    /// What the card shows: one version's notes, or every version the person
    /// has not seen yet folded into one card.
    ///
    /// **Why folded** (owner, 2026-10-07: "what if a user does two updates in
    /// a row?"). The updater always installs the newest version, so someone
    /// back from a month away goes from 1.0.17 straight to 1.0.19, and a card
    /// that showed only 1.0.19's notes would lose 1.0.18's for good. So would
    /// quitting before reading a card. One card, newest first, never more
    /// than `maxItems` lines, and a count of the rest.
    public struct Card: Equatable, Sendable {
        /// The running version: the one written down as seen when it goes.
        public let version: String
        /// The small line above the title: "new in 1.0.18", or "new since
        /// 1.0.17" when several versions are folded together.
        public let label: String
        public let title: String
        /// Newest version's lines first.
        public let items: [Item]
        /// Lines left off to keep the card short. Said, never dropped quietly.
        public let moreCount: Int

        public init(version: String, label: String, title: String, items: [Item], moreCount: Int) {
            self.version = version
            self.label = label
            self.title = title
            self.items = items
            self.moreCount = moreCount
        }
    }

    /// The card has no scroll view on purpose.
    public static let maxItems = 4

    /// The title of a card that folds several versions together.
    public static let foldedTitle = "New since your last update"

    /// What to do at launch.
    public enum Decision: Equatable, Sendable {
        /// Open the card.
        case show(Card)
        /// Show nothing, but write this version down as seen.
        case remember
        /// Show nothing and write nothing.
        case nothing
    }

    /// - Parameters:
    ///   - version: the running app's version.
    ///   - lastSeen: the version whose card was last shown or skipped, or nil
    ///     on an install that has never recorded one — which is every install
    ///     from before this existed, and they are exactly the people updating.
    ///   - isFirstRun: setup or the welcome is on screen this launch. A new
    ///     user is learning the whole app; a list of what changed since a
    ///     version they never had means nothing to them.
    public static func decide(version: String,
                              lastSeen: String?,
                              isFirstRun: Bool,
                              catalog: [Notes] = catalog) -> Decision {
        // A build with no version (`swift run`) has nothing to compare.
        guard !version.isEmpty else { return .nothing }
        if isFirstRun { return lastSeen == version ? .nothing : .remember }
        if let lastSeen {
            // Only forwards. Going back to an older copy (the owner's backups,
            // a reinstall from an old DMG) is not news, and showing an old card
            // would overwrite the newer version as "seen".
            guard isNewer(version, than: lastSeen) else { return .nothing }
        }
        // Every version after the last one seen, up to the one running.
        // Never a version newer than this build: a catalog entry written ahead
        // of a release describes something this copy does not have.
        let unseen = catalog
            .filter { !isNewer($0.version, than: version) }
            .filter { notes in lastSeen.map { isNewer(notes.version, than: $0) } ?? true }
            .sorted { isNewer($0.version, than: $1.version) }
        guard let card = card(version: version, lastSeen: lastSeen, unseen: unseen) else {
            return .remember
        }
        return .show(card)
    }

    /// Folds notes (newest first) into one card. Nil when there is nothing
    /// to say.
    public static func card(version: String, lastSeen: String?, unseen: [Notes]) -> Card? {
        let lines = unseen.flatMap(\.items)
        guard let newest = unseen.first, !lines.isEmpty else { return nil }
        let shown = Array(lines.prefix(maxItems))
        if unseen.count == 1 {
            return Card(version: version, label: "new in \(newest.version)", title: newest.title,
                        items: shown, moreCount: lines.count - shown.count)
        }
        let label = lastSeen.map { "new since \($0)" } ?? "new in \(newest.version)"
        return Card(version: version, label: label, title: foldedTitle,
                    items: shown, moreCount: lines.count - shown.count)
    }

    /// One version's card on its own, for looking at it on purpose.
    public static func card(for notes: Notes) -> Card {
        let shown = Array(notes.items.prefix(maxItems))
        return Card(version: notes.version, label: "new in \(notes.version)", title: notes.title,
                    items: shown, moreCount: notes.items.count - shown.count)
    }

    private static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    /// The same notes for Sparkle's update window: an HTML fragment with no
    /// DOCTYPE or body tags, which `generate_appcast` embeds in the appcast as
    /// CDATA when it finds it beside the DMG under the same name.
    public static func html(_ notes: Notes) -> String {
        var lines = ["<h3>\(escape(notes.title))</h3>", "<ul>"]
        lines += notes.items.map { "  <li>\(escape($0.text))</li>" }
        lines.append("</ul>")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
