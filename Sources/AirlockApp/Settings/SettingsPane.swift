import AirlockCore
import SwiftUI

/// Sidebar destinations. A tab bar stopped scaling once there was more than
/// agents/policy/general to say — every new group made the tabs narrower and the
/// panes longer. A sidebar takes as many groups as the app grows.
///
/// **Eight rows, from fourteen cases, and the extra cases are deliberate.**
/// `tray`, `about`, `widgets` and `policy` no longer earn a room of their own,
/// but they stay as cases because the raw values are stored in preferences and
/// used as deep links. Deleting them would turn "reopen where I was" into a
/// decode failure for anybody who last had one of them selected. They resolve
/// to their new homes instead; see `resolved`.
///
/// The two newest folds answer a complaint worth recording: the sidebar read as
/// a list of the app's internals rather than of a person's intentions. What a
/// panel looks like and what it shows are one question — you are thinking about
/// the notch, not about a rendering layer and a widget registry — so `widgets`
/// joins `appearance`. And rules are meaningless without agents to apply them
/// to: a `policy` room of its own offered a stranger a YAML file and a
/// precedence table before they had installed a single hook.
///
/// The renames are **title and symbol only** for the same reason: `appearance`
/// reads "Panel" and `policy` reads "Rules", and neither raw value moves.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    /// What Airlock adds to the notch beyond Home and Dashboard, and where
    /// each piece is switched on or off. Second, after General, because on a
    /// new Mac it is the first place there is anything to do.
    case addOns
    case appearance
    case widgets
    case tray
    case clipboard
    /// Dictation and call notes. The raw value stays `dictation` — it is
    /// what is already on disk.
    case voice = "dictation"
    case agents
    /// Meeting notes, which shared the Voice page with dictation until each
    /// add-on got a page of its own. Folded `voice` keeps dictation alone.
    case callNotes
    /// Window layouts, which sat at the bottom of the notch page.
    case windowLayouts
    case policy
    case permissions
    case license
    case about
    /// The screen guide's two pages, which are gone. Kept as cases because a
    /// stored "reopen where I was" may still name them; they resolve to General.
    case guide
    case privacy

    var id: String { rawValue }

    /// The sidebar's groups, in order: the base app, one row per add-on, then
    /// the account. Every add-on has a page of its own, so the old Add-ons
    /// page is not a row any more; its raw value still opens the first add-on.
    struct SidebarGroup: Identifiable {
        let title: String
        let panes: [SettingsPane]
        var id: String { title }
    }

    static var sidebarGroups: [SidebarGroup] {
        [
            SidebarGroup(title: String(localized: "Airlock"), panes: [.general, .appearance]),
            SidebarGroup(title: String(localized: "Add-ons"), panes: AddOn.allCases.map(\.pane)),
            SidebarGroup(title: String(localized: "Account"), panes: [.permissions, .license]),
        ]
    }

    /// Every row the sidebar offers, in order.
    ///
    /// Not `allCases`: the folded cases are reachable by deep link and by a
    /// stored preference, and must not be offered as destinations of their own.
    static let sidebarCases: [SettingsPane] = sidebarGroups.flatMap(\.panes)

    /// The page's colour: the add-on's own, nil for the app's own pages
    /// (they wear grey).
    var tint: Color? { addOn?.tint }

    /// The add-on this page belongs to, for the pages that are one.
    var addOn: AddOn? {
        AddOn.allCases.first { $0.pane == self }
    }

    /// Where a pane actually goes. Identity for the sidebar's rows; the folded
    /// cases land where their contents moved.
    var resolved: SettingsPane {
        switch self {
        // Through `widgets` to where the widgets now live, rather than at it —
        // a fold that lands on another fold is a blank pane.
        case .widgets: return .appearance
        case .addOns: return AddOn.allCases[0].pane
        case .policy: return .agents
        case .about, .guide, .privacy: return .general
        default: return self
        }
    }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .addOns: return String(localized: "Add-ons")
        // "Appearance" described a paint job and "Panel" described the thing we
        // built; this one is named after the thing the reader is looking at.
        case .appearance: return String(localized: "The notch")
        case .widgets: return String(localized: "Widgets")
        case .tray: return String(localized: "Shelf")
        case .clipboard: return String(localized: "Clipboard")
        case .voice: return String(localized: "Dictation")
        case .callNotes: return String(localized: "Meeting notes")
        case .agents: return String(localized: "Coding agents")
        case .windowLayouts: return String(localized: "Window layouts")
        case .guide: return String(localized: "Guide")
        case .privacy: return String(localized: "Privacy")
        // The file calls them rules and so does every button that writes one.
        // "Policy" was the implementation's word for it.
        case .policy: return String(localized: "Rules")
        case .permissions: return String(localized: "Permissions")
        case .license: return String(localized: "Plans")
        case .about: return String(localized: "About")
        }
    }

    /// The word on the page's tab. The title, except where the title is a
    /// phrase: "The notch" reads as a sentence fragment in a column of words.
    var tabTitle: String {
        switch self {
        case .appearance: return String(localized: "Notch")
        default: return title
        }
    }

    /// The website's pages about what this page sets up, behind its "Learn
    /// more" (`LookLearnMore`). Several make a menu. General, Add-ons,
    /// Permissions and Plans have no page of their own on the site, so they
    /// show none.
    var learnMore: [FeaturePage] {
        switch self {
        case .appearance: return [.mediaAndSound, .today, .thisMac, .keepAwake]
        case .tray: return [.dropShelf]
        case .voice: return [.dictation]
        case .callNotes: return [.callNotes]
        case .clipboard: return [.clipboardHistory]
        case .agents: return [.codingAgents]
        default: return []
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .addOns: return "puzzlepiece.extension"
        case .appearance: return "macwindow"
        case .widgets: return "square.grid.2x2"
        case .tray: return "tray.full"
        case .clipboard: return "list.clipboard"
        case .voice: return "waveform"
        case .agents: return "sparkle"
        case .callNotes: return "mic"
        case .windowLayouts: return "rectangle.split.2x1"
        case .policy: return "checkmark.shield"
        case .permissions: return "lock.shield"
        case .license: return "crown"
        case .about: return "info.circle"
        case .guide: return "hand.point.up.left"
        case .privacy: return "hand.raised"
        }
    }

    /// Sidebar rows carry a line of context so the group names don't have to
    /// carry all the meaning on their own.
    var blurb: String {
        switch self {
        case .general: return String(localized: "Startup, updates and diagnostics")
        case .addOns: return String(localized: "What Airlock adds to the notch")
        case .appearance: return String(localized: "What it shows, and how it looks")
        case .widgets: return String(localized: "What the panel shows, and where")
        case .tray: return String(localized: "Files kept on the notch")
        case .clipboard: return String(localized: "History, privacy and hotkey")
        case .voice: return String(localized: "Hold a key, talk, and it types")
        case .callNotes: return String(localized: "A transcript and notes for calls")
        case .windowLayouts: return String(localized: "Snap windows into place")
        case .agents: return String(localized: "Connecting, answering and rules")
        case .guide: return String(localized: "Voice, layout and keys")
        case .privacy: return String(localized: "What the guide looks at")
        case .policy: return String(localized: "What runs without asking")
        case .permissions: return String(localized: "What macOS has allowed")
        case .license: return String(localized: "Free, Plus and Pro")
        case .about: return String(localized: "Version and links")
        }
    }
}

extension AddOn {
    /// The Settings page of this add-on, a row of its own in the sidebar.
    var pane: SettingsPane {
        switch self {
        case .shelf: return .tray
        case .clipboard: return .clipboard
        case .meetingNotes: return .callNotes
        case .codingAgents: return .agents
        case .windowLayouts: return .windowLayouts
        case .dictation: return .voice
        }
    }
}
