import AirlockCore
import SwiftUI

/// Sidebar destinations. A tab bar stopped scaling once there was more than
/// agents/policy/general to say — every new group made the tabs narrower and the
/// panes longer. A sidebar takes as many groups as the app grows.
///
/// **Seven rows, from eleven cases, and the four extra cases are deliberate.**
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
    case appearance
    case widgets
    case tray
    case clipboard
    /// Dictation and the assistant, in one pane. The raw value stays
    /// `dictation` — it is what is already on disk.
    case voice = "dictation"
    case agents
    case policy
    case permissions
    case license
    case about
    /// The guide's pages (card 3.05), in the sidebar only while it is on.
    case guide
    case privacy

    var id: String { rawValue }

    /// The seven the sidebar offers, in order.
    ///
    /// Not `allCases`: the folded cases are reachable by deep link and by a
    /// stored preference, and must not be offered as destinations of their own.
    static let sidebarCases: [SettingsPane] = [
        .general, .appearance, .voice, .clipboard,
        .agents, .permissions, .license,
    ]

    /// The sidebar as shown. With the guide on it gains Guide and Privacy
    /// (designs 11a–b), and Agents reads "Developer" (11c): the Developer mode
    /// switch heads it, and the hooks and rules below it show only while the
    /// switch is on. With the guide off, nothing changes.
    ///
    /// A free Airlock (`Pricing.isFree`) has no Licence page: there is
    /// nothing to buy, renew or paste.
    static func sidebar(guideOn: Bool = guideIsOn, free: Bool = Pricing.isFree) -> [SettingsPane] {
        let all: [SettingsPane] = guideOn
            ? [.general, .guide, .privacy, .appearance, .voice, .clipboard,
               .agents, .permissions, .license]
            : sidebarCases
        return free ? all.filter { $0 != .license } : all
    }

    static var guideIsOn: Bool { GuideSwitch.isOn }

    /// Where a pane actually goes. Identity for the seven; the folded cases
    /// land where their contents moved.
    var resolved: SettingsPane {
        switch self {
        // Through `widgets` to where the widgets now live, rather than at it —
        // a fold that lands on another fold is a blank pane.
        case .tray, .widgets: return .appearance
        case .policy: return .agents
        case .about: return .general
        // A stored "last page" or an old deep link to a page that is gone.
        case .license where Pricing.isFree: return .general
        default: return self
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        // "Appearance" described a paint job and "Panel" described the thing we
        // built; this one is named after the thing the reader is looking at.
        case .appearance: return "The notch"
        case .widgets: return "Widgets"
        case .tray: return "Shelf"
        case .clipboard: return "Clipboard"
        case .voice: return "Voice"
        case .agents: return Self.guideIsOn ? "Developer" : "Agents"
        case .guide: return "Guide"
        case .privacy: return "Privacy"
        // The file calls them rules and so does every button that writes one.
        // "Policy" was the implementation's word for it.
        case .policy: return "Rules"
        case .permissions: return "Permissions"
        case .license: return "Licence"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "macwindow"
        case .widgets: return "square.grid.2x2"
        case .tray: return "tray.full"
        case .clipboard: return "list.clipboard"
        case .voice: return "waveform"
        case .agents: return "sparkle"
        case .policy: return "checkmark.shield"
        case .permissions: return "lock.shield"
        case .license: return "key"
        case .about: return "info.circle"
        case .guide: return "hand.point.up.left"
        case .privacy: return "hand.raised"
        }
    }

    /// Sidebar rows carry a line of context so the group names don't have to
    /// carry all the meaning on their own.
    var blurb: String {
        switch self {
        case .general: return "Startup, updates and diagnostics"
        case .appearance: return "What it shows, and how it looks"
        case .widgets: return "What the panel shows, and where"
        case .tray: return "Shelf and workspace folder"
        case .clipboard: return "History, privacy and hotkey"
        case .voice: return "Hold to talk, and hold to ask"
        case .agents: return Self.guideIsOn ? "Coding agents in the notch" : "Connecting, answering and rules"
        case .guide: return "Voice, layout and keys"
        case .privacy: return "What the guide looks at"
        case .policy: return "What runs without asking"
        case .permissions: return "What macOS has allowed"
        case .license: return "Trial, licence and renewal"
        case .about: return "Version and links"
        }
    }
}
