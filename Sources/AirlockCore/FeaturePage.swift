import Foundation

/// The website's pages about one thing Airlock does, which Settings links to
/// as "Learn more".
///
/// One case per file in the website's `features` folder, named as the file
/// is. The site serves them without `.html`, and there is no page at
/// `/features/` itself: the home page's "What it does" tiles are the list
/// (`HelpLinks.allFeatures`). A page renamed or removed there must change
/// here as well, or the link lands on a 404.
///
/// Nothing is fetched to draw these. A page opens in the browser only when
/// the person clicks, so the app sends nothing it did not send before.
public enum FeaturePage: String, CaseIterable, Sendable {
    // In the order of the home page's tiles.
    case callNotes = "call-notes"
    case clipboardHistory = "clipboard-history"
    case mediaAndSound = "media-and-sound"
    case dictation
    case today
    case thisMac = "this-mac"
    case dropShelf = "drop-shelf"
    case keepAwake = "keep-awake"
    case codingAgents = "coding-agents"

    public var url: URL {
        URL(string: "https://useairlock.app/features/\(rawValue)")!
    }

    /// What the app calls it, for a menu that offers several. The website's
    /// page titles are longer and written to sell; these are the words
    /// Settings already uses for the same things.
    public var title: String {
        switch self {
        case .callNotes: String(localized: "Call notes")
        case .clipboardHistory: String(localized: "Clipboard history")
        case .mediaAndSound: String(localized: "Media and sound")
        case .dictation: String(localized: "Dictation")
        case .today: String(localized: "Calendar and meetings")
        case .thisMac: String(localized: "CPU, GPU and memory")
        case .dropShelf: String(localized: "Shelf")
        case .keepAwake: String(localized: "Keep awake")
        case .codingAgents: String(localized: "Coding agents")
        }
    }
}

/// Where help is: the website and the one address that reaches a person.
///
/// For the Help menu, in the menu bar and the status item. Opened on a
/// click only, never fetched.
public enum HelpLinks {
    public static let website = URL(string: "https://useairlock.app/")!
    /// The home page's "What it does" tiles, one per feature page.
    public static let allFeatures = URL(string: "https://useairlock.app/#features")!
    public static let email = "hello@useairlock.app"
    public static let emailURL = URL(string: "mailto:hello@useairlock.app")!
}
