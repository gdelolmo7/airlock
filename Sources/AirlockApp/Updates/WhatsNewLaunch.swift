import Foundation
import OSLog
import AirlockCore

/// The app's side of `WhatsNew`: which version is running, which one was last
/// shown, and the command-line way in.
@MainActor
enum WhatsNewLaunch {
    private static let log = Logger(subsystem: "com.airlock.app", category: "whatsnew")

    /// The version whose card was last read or skipped.
    static let seenKey = "whatsNew.lastSeenVersion"

    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// The card to open at launch, if any. Writes the version down when there
    /// is nothing to show, so a new user who finishes setup is not shown it
    /// on their second launch either.
    ///
    /// - Parameter isFirstRun: setup or the welcome opened this launch.
    static func cardForLaunch(isFirstRun: Bool) -> WhatsNew.Card? {
        let version = runningVersion
        let lastSeen = UserDefaults.standard.string(forKey: seenKey)
        switch WhatsNew.decide(version: version, lastSeen: lastSeen, isFirstRun: isFirstRun) {
        case .show(let card):
            log.notice("showing \(version, privacy: .public) (last seen \(lastSeen ?? "none", privacy: .public), \(card.items.count + card.moreCount) lines)")
            return card
        case .remember:
            markSeen(version)
            return nil
        case .nothing:
            return nil
        }
    }

    /// The card, whatever was seen, for looking at it on purpose:
    ///   open -a Airlock --args --whats-new           this version's card
    ///   open -a Airlock --args --whats-new-sample    two pretend versions folded
    /// Never written down as seen, so trying it does not use up the real one.
    static var forcedCard: WhatsNew.Card? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--whats-new-sample") { return sample }
        guard arguments.contains("--whats-new") else { return nil }
        return (WhatsNew.notes(for: runningVersion) ?? WhatsNew.catalog.first).map(WhatsNew.card(for:))
    }

    /// Someone who skipped an update: two pretend versions, six lines, so the
    /// folded title, the label and "and 2 more changes" all show. Pretend on
    /// purpose and kept out of `WhatsNew.catalog`, so no release can ship it.
    static let sample: WhatsNew.Card? = WhatsNew.card(
        version: "1.0.20", lastSeen: "1.0.18",
        unseen: [
            WhatsNew.Notes(version: "1.0.20", title: "Sample", items: [
                WhatsNew.Item("calendar", "Your next meeting shows in the notch an hour before it starts."),
                WhatsNew.Item("doc.on.clipboard", "Copied passwords leave the clipboard history after a minute."),
                WhatsNew.Item("speaker.wave.2", "Each app's volume is remembered when you plug in headphones."),
            ]),
            WhatsNew.Notes(version: "1.0.19", title: "Sample", items: [
                WhatsNew.Item("mic", "Dictation starts faster after the Mac wakes up."),
                WhatsNew.Item("battery.75percent", "The battery level shows while charging."),
                WhatsNew.Item("moon", "The notch stays dark while Focus is on."),
            ]),
        ])

    static func markSeen(_ version: String) {
        guard !version.isEmpty else { return }
        UserDefaults.standard.set(version, forKey: seenKey)
        log.notice("seen \(version, privacy: .public)")
    }

    /// `Airlock --whats-new-html [version]`: prints the notes as the HTML
    /// fragment Sparkle's update window shows, and exits — before the app,
    /// its logs or its windows start. The release script runs it on the
    /// freshly built bundle, so the appcast carries exactly what that build
    /// would show. Prints nothing (and still exits 0) for a version without
    /// notes, and the script then writes no file.
    static func printHTMLIfAsked(_ arguments: [String]) -> Bool {
        guard let flag = arguments.firstIndex(of: "--whats-new-html") else { return false }
        let next = arguments.index(after: flag)
        let version = next < arguments.endIndex ? arguments[next] : runningVersion
        if let notes = WhatsNew.notes(for: version) {
            print(WhatsNew.html(notes), terminator: "")
        }
        return true
    }
}
