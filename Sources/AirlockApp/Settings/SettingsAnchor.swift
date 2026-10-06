import AirlockCore
import SwiftUI

/// A setting that search can find and a link can land on (card Settings 3).
///
/// Each case is one row on one page: its title as search shows it, the words
/// somebody might type for it, and the page it lives on. The row itself wears
/// `.settingsAnchor(_:)`, which is what the page scrolls to and lights up.
///
/// A row that is not on screen when the link lands (a section that only shows
/// in some states) still opens the right page; it just has nothing to scroll
/// to.
enum SettingsAnchor: String, CaseIterable, Identifiable {
    // General
    case launchAtLogin, displays, sounds, updates, diagnostics
    // The notch
    case surface, panelWidth, textSize, usageLimits, batteryPercentage
    case widgets, reactiveWave, perAppVolume
    case keepAwakeAgents, keepAwakeCutoff, keepAwakeScreen, keepAwakeShortcut
    case agentsSwitch, calendars, shelf
    // Voice
    case holdToDictate, holdToAsk, microphoneInput, language, cleanup, pauseMusic, commandBar
    // Clipboard
    case clipboardHistory, neverRecorded, clipboardShortcut, autoPaste
    // Agents / Developer
    case developerMode, gateHotkey, promptSound, usageWarning, givingUp, rules
    // Permissions
    case permissionCalendar, permissionMicrophone, permissionInputMonitoring
    case permissionAccessibility, permissionScreenRecording, permissionAutomation
    // Licence
    case licenceKey
    // Guide and Privacy, while the guide is on
    case guideVoice, guideLayout, guideKeys, privacyPromise, neverLook
    // The guide's access key, on General while the guide is a prototype
    case guideAccessKey

    var id: String { rawValue }

    var pane: SettingsPane {
        switch self {
        case .launchAtLogin, .displays, .sounds, .updates, .diagnostics, .guideAccessKey: return .general
        case .surface, .panelWidth, .textSize, .usageLimits, .batteryPercentage,
             .widgets, .reactiveWave, .perAppVolume,
             .keepAwakeAgents, .keepAwakeCutoff, .keepAwakeScreen, .keepAwakeShortcut,
             .agentsSwitch, .calendars, .shelf: return .appearance
        case .holdToDictate, .holdToAsk, .microphoneInput, .language, .cleanup,
             .pauseMusic, .commandBar: return .voice
        case .clipboardHistory, .neverRecorded, .clipboardShortcut, .autoPaste: return .clipboard
        case .developerMode, .gateHotkey, .promptSound, .usageWarning, .givingUp, .rules: return .agents
        case .permissionCalendar, .permissionMicrophone, .permissionInputMonitoring,
             .permissionAccessibility, .permissionScreenRecording, .permissionAutomation: return .permissions
        case .licenceKey: return .license
        case .guideVoice, .guideLayout, .guideKeys: return .guide
        case .privacyPromise, .neverLook: return .privacy
        }
    }

    var title: String {
        switch self {
        case .launchAtLogin: return "Launch at login"
        case .sounds: return "Sounds"
        case .displays: return "Show on the main display"
        case .updates: return "Check for updates automatically"
        case .diagnostics: return "Health and diagnostics"
        case .surface: return "Background"
        case .panelWidth: return "How wide the open notch is"
        case .textSize: return "Text size"
        case .usageLimits: return "Claude usage limits"
        case .batteryPercentage: return "Battery percentage"
        case .widgets: return "What shows when it's open"
        case .reactiveWave: return "Wave follows the audio"
        case .perAppVolume: return "Per-app volume"
        case .keepAwakeAgents: return "Keep awake while an agent is working"
        case .keepAwakeCutoff: return "Keep awake: stop on battery"
        case .keepAwakeScreen: return "Keep awake: let the screen turn off"
        case .keepAwakeShortcut: return "Keep awake: keyboard shortcut"
        case .agentsSwitch: return SettingsPane.guideIsOn ? "Developer mode" : "AI agents"
        case .calendars: return "Calendars"
        case .shelf: return "Shelf"
        case .holdToDictate: return "Hold a key to dictate"
        case .holdToAsk: return "Hold a key to ask"
        case .microphoneInput: return "Microphone"
        case .language: return "Language"
        case .cleanup: return "Tidy up what I said"
        case .pauseMusic: return "Pause music while speaking"
        case .commandBar: return "Type at the notch too"
        case .clipboardHistory: return "Clipboard history"
        case .neverRecorded: return "What it never remembers"
        case .clipboardShortcut: return "Clipboard shortcut"
        case .autoPaste: return "Paste automatically"
        case .developerMode: return "Developer mode"
        case .gateHotkey: return "Answer with a shortcut"
        case .promptSound: return "Play a sound when a request arrives"
        case .usageWarning: return "Warn near Claude's usage limit"
        case .givingUp: return "Hand the question back"
        case .rules: return "Rules"
        case .permissionCalendar: return "Calendar access"
        case .permissionMicrophone: return "Microphone access"
        case .permissionInputMonitoring: return "Input Monitoring"
        case .permissionAccessibility: return "Accessibility"
        case .permissionScreenRecording: return "Screen Recording"
        case .permissionAutomation: return "Automation"
        case .licenceKey: return "Licence key"
        case .guideVoice: return "Speak replies"
        case .guideLayout: return "Where the step appears"
        case .guideKeys: return "Guide keys"
        case .privacyPromise: return "What the guide sends"
        case .neverLook: return "Never look at these apps"
        case .guideAccessKey: return "Guide access key"
        }
    }

    /// The words somebody might type instead of the title.
    var keywords: [String] {
        switch self {
        case .launchAtLogin: return ["startup", "login", "start", "open"]
        case .sounds: return ["sound", "audio", "chime", "alert", "mute", "quiet", "volume"]
        case .displays: return ["display", "monitor", "screen", "external", "lid", "main"]
        case .updates: return ["update", "version", "new"]
        case .diagnostics: return ["log", "report", "debug", "problem", "health"]
        case .surface: return ["background", "glass", "dark", "look", "colour", "color"]
        case .panelWidth: return ["width", "size", "wide", "narrow"]
        case .textSize: return ["font", "bigger", "larger", "smaller", "zoom", "read"]
        case .usageLimits: return ["usage", "limits", "rate", "hours", "weekly", "top bar", "claude"]
        case .batteryPercentage: return ["battery", "percent", "top bar"]
        case .widgets: return ["widget", "media", "music", "spotify", "calendar", "system", "cpu",
                               "memory", "repository", "git", "show", "hide"]
        case .reactiveWave: return ["wave", "bars", "audio", "music", "animation"]
        case .perAppVolume: return ["volume", "mixer", "sound", "app", "loud", "quiet"]
        case .keepAwakeAgents: return ["awake", "sleep", "agent", "claude", "codex", "working", "caffeinate"]
        case .keepAwakeCutoff: return ["awake", "sleep", "battery", "caffeinate", "cutoff"]
        case .keepAwakeScreen: return ["awake", "sleep", "screen", "display", "dark"]
        case .keepAwakeShortcut: return ["awake", "sleep", "shortcut", "hotkey", "key"]
        case .agentsSwitch: return ["agents", "claude", "codex", "developer", "hooks", "connect"]
        case .calendars: return ["calendar", "events", "meetings"]
        case .shelf: return ["shelf", "tray", "files", "drop", "folder"]
        case .holdToDictate: return ["dictation", "dictate", "voice", "speech", "talk", "hold", "key"]
        case .holdToAsk: return ["ask", "question", "assistant", "voice", "hold", "key"]
        case .microphoneInput: return ["microphone", "mic", "input", "device", "headset"]
        case .language: return ["language", "spanish", "english", "speak"]
        case .cleanup: return ["cleanup", "punctuation", "filler", "tidy"]
        case .pauseMusic: return ["music", "pause", "speaking"]
        case .commandBar: return ["command bar", "type", "shortcut", "option space", "ask"]
        case .clipboardHistory: return ["clipboard", "history", "copy", "paste"]
        case .neverRecorded: return ["password", "ignore", "private", "skip", "clipboard"]
        case .clipboardShortcut: return ["shortcut", "hotkey", "clipboard", "key"]
        case .autoPaste: return ["paste", "clipboard"]
        case .developerMode: return ["agents", "claude", "codex", "developer", "hooks", "connect"]
        case .gateHotkey: return ["approve", "allow", "shortcut", "hotkey", "request", "key", "answer"]
        case .promptSound: return ["sound", "alert", "notification", "request"]
        case .usageWarning: return ["usage", "limit", "warning", "rate", "weekly", "hours", "reset", "claude"]
        case .givingUp: return ["timeout", "giving up", "wait"]
        case .rules: return ["policy", "rules", "allow", "deny", "block"]
        case .permissionCalendar: return ["calendar", "permission", "privacy"]
        case .permissionMicrophone: return ["microphone", "mic", "permission", "privacy"]
        case .permissionInputMonitoring: return ["keyboard", "keys", "permission", "privacy", "input"]
        case .permissionAccessibility: return ["accessibility", "typing", "permission", "privacy"]
        case .permissionScreenRecording: return ["screen", "recording", "permission", "privacy", "see"]
        case .permissionAutomation: return ["automation", "apple events", "permission", "spotify", "music"]
        case .licenceKey: return ["license", "licence", "key", "subscription", "purchase", "buy", "trial"]
        case .guideVoice: return ["voice", "speak", "read aloud", "guide"]
        case .guideLayout: return ["bubble", "card", "layout", "guide", "step"]
        case .guideKeys: return ["keys", "shortcut", "esc", "guide", "ask"]
        case .privacyPromise: return ["privacy", "screen", "picture", "send", "ai", "guide"]
        case .neverLook: return ["privacy", "apps", "never", "look", "block", "guide"]
        case .guideAccessKey: return ["key", "access key", "guide", "service", "anthropic", "openai", "openrouter"]
        }
    }

    /// Whether the row exists in the Settings shown now: the guide's pages and
    /// the Developer switch only with the guide on, the screen-recording row
    /// only for the guide. With the guide on, the agent rows wait behind
    /// Developer mode (`agentsOn`), as the page does.
    func isAvailable(guideOn: Bool, agentsOn: Bool = true) -> Bool {
        switch self {
        case .guideVoice, .guideLayout, .guideKeys, .privacyPromise, .neverLook,
             .developerMode, .permissionScreenRecording, .guideAccessKey: return guideOn
        case .gateHotkey, .promptSound, .usageWarning, .givingUp, .rules: return !guideOn || agentsOn
        case .licenceKey: return !Pricing.isFree
        default: return true
        }
    }

    /// Matching settings for the search field, best first.
    static func search(_ query: String, guideOn: Bool = SettingsPane.guideIsOn,
                       agentsOn: Bool = true) -> [SettingsAnchor] {
        allCases
            .filter { $0.isAvailable(guideOn: guideOn, agentsOn: agentsOn) }
            .compactMap { anchor -> (SettingsAnchor, Int)? in
                SettingsSearch.score(query: query, title: anchor.title, keywords: anchor.keywords,
                                     page: anchor.pane.title).map { (anchor, $0) }
            }
            // Stable among equals: the order above is page order.
            .enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
            .map(\.element.0)
    }
}

extension View {
    /// Marks the row a link or a search result for `anchor` lands on: the page
    /// scrolls to it, and it lights up for a moment.
    func settingsAnchor(_ anchor: SettingsAnchor) -> some View {
        modifier(SettingsAnchorHighlight(anchor: anchor))
    }
}

private struct SettingsAnchorHighlight: ViewModifier {
    let anchor: SettingsAnchor
    /// Optional so a pane can be drawn on its own — the state gallery draws
    /// Settings pages without the settings window's model. In that window it
    /// is always there.
    @Environment(SettingsModel.self) private var model: SettingsModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(model?.highlighted == anchor ? 0.22 : 0))
                    .padding(-6)
                    .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: model?.highlighted)
                    .allowsHitTesting(false)
            }
    }
}
