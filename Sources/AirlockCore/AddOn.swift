import Foundation

/// The bigger features, each with its own switch, as opposed to the base app.
///
/// Home (music, system controls, sound) and Dashboard (calendar, This Mac) are
/// the app itself and are deliberately not in this list: a notch with neither
/// would be an empty black shape. Everything here either draws a tab of its
/// own, holds a key, or watches the Mac for something, so each is a thing a
/// person can reasonably not want.
///
/// Only the UI-free facts live here, so they are tested. Which model's switch
/// each one flips is the app's business (`AddOnSwitches`), because the models
/// are main-actor AppKit objects that this target cannot see.
public enum AddOn: String, CaseIterable, Sendable, Identifiable {
    case shelf
    case clipboard
    case meetingNotes
    case codingAgents
    case windowLayouts
    case dictation

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .shelf: return String(localized: "Shelf")
        case .clipboard: return String(localized: "Clipboard")
        case .meetingNotes: return String(localized: "Meeting notes")
        case .codingAgents: return String(localized: "Coding agents")
        case .windowLayouts: return String(localized: "Window layouts")
        case .dictation: return String(localized: "Dictation")
        }
    }

    /// One line, said from the user's side: what they get, not what it is.
    public var summary: String {
        switch self {
        case .shelf:
            return String(localized: "Drop files on the notch to keep them close at hand.")
        case .clipboard:
            return String(localized: "Everything you copied, a shortcut away.")
        case .meetingNotes:
            return String(localized: "A transcript and notes for your calls.")
        case .codingAgents:
            return String(localized: "Answer Claude Code and other coding agents from the notch.")
        case .windowLayouts:
            return String(localized: "Snap windows into place with a shortcut or a drag.")
        case .dictation:
            return String(localized: "Hold a key and talk to type anywhere.")
        }
    }

    /// The raw value of the notch tab this add-on brings, or nil when it has
    /// none (window layouts and dictation are a key and a gesture, not a
    /// place). A string rather than the app's tab type because that type lives
    /// on the SwiftUI side; a test there pins that each one names a real tab,
    /// so a renamed tab cannot leave this pointing nowhere.
    public var tabID: String? {
        switch self {
        case .shelf: return "tray"
        case .clipboard: return "clipboard"
        case .meetingNotes: return "calls"
        case .codingAgents: return "agents"
        case .windowLayouts, .dictation: return nil
        }
    }

    /// Where it shows up once added, the first half of the card's small print.
    /// Said because "add" is only a fair offer when you know what will change:
    /// a new tab is something you see, a key is something you would not.
    public var notchPlace: String {
        switch self {
        case .shelf: return String(localized: "Adds a Shelf tab")
        case .clipboard: return String(localized: "Adds a Clipboard tab")
        case .meetingNotes: return String(localized: "Adds a Calls tab")
        case .codingAgents: return String(localized: "Adds Agents, by the gear")
        case .windowLayouts: return String(localized: "No tab: drag a window to the notch")
        case .dictation: return String(localized: "No tab, just the key")
        }
    }

    /// What macOS will be asked for, the second half of the small print.
    /// Named before anything is added so a permission prompt is never the
    /// first a person hears of it. Kept in step with what the Permissions page
    /// says each permission is for.
    public var asks: String {
        switch self {
        case .shelf, .clipboard: return String(localized: "Asks for nothing")
        case .meetingNotes: return String(localized: "Asks for the microphone and system audio")
        // Not a macOS permission: adding it sets up Claude Code's hooks, which
        // the Agents page shows and can undo.
        case .codingAgents: return String(localized: "Asks for nothing; connects to Claude Code")
        case .windowLayouts: return String(localized: "Asks for Accessibility")
        case .dictation: return String(localized: "Asks for the microphone, Input Monitoring and Accessibility")
        }
    }

    /// The small print beside the switch, when part of the add-on belongs to a
    /// paid plan. Meeting notes is the only one: the transcript works on Free,
    /// the full notes are Plus and Pro. Saying so next to the switch keeps
    /// someone on Free from switching it on, finding no notes and deciding it
    /// is broken.
    public var planBadge: String? {
        switch self {
        case .meetingNotes: return String(localized: "Plus for full notes")
        default: return nil
        }
    }
}

/// The one-time decision about what a new Mac starts with, made without
/// changing anything for someone who updates.
///
/// Every add-on starts ON: a new Mac gets the whole app, and anything not
/// wanted is switched off later on Settings › Add-ons (the owner's call,
/// 2026-11-05, dictation included, 2026-11-07).
///
/// What needs writing is every switch that defaults to OFF in its own model:
/// This Mac and dictation today. Their default cannot
/// change, because a default is the one thing an update cannot ask about,
/// and everyone who updates would see a card appear. So "on for newcomers"
/// is written, once, on the first launch of an install that has never
/// stored anything. Anything else (setup finished or started, or any add-on
/// switch already stored) is somebody who already lives with their own
/// choice, and keeps it.
public enum AddOnSeed {
    /// Set on every path, so the decision is made exactly once per install.
    /// Without it, a fresh install whose owner later switched This Mac off and
    /// cleared its key (a reset, a defaults tool) would get it back.
    public static let sentinelKey = "addOns.seeded"

    public enum Decision: Equatable, Sendable {
        /// The sentinel was already there. Nothing is written.
        case alreadyRan
        /// Someone already uses this Mac's Airlock: mark it and touch nothing.
        case existingInstall
        /// Nothing here yet: what a new Mac starts with is switched on.
        case freshInstall
    }

    /// What this Mac has stored that bears on the decision. A value type so
    /// the rule is a pure function of it.
    public struct Evidence: Equatable, Sendable {
        public var alreadyRan: Bool
        public var setupFinished: Bool
        public var setupStarted: Bool
        public var anySwitchStored: Bool
        /// Something only an earlier launch leaves behind (the last
        /// what's-new version read, say). Not in the original rule, and
        /// there on purpose: an install that predates the setup flow, or got
        /// past it without the flag, has still been used, and losing its
        /// features on update is the one outcome this must never produce.
        public var launchedBefore: Bool

        public init(alreadyRan: Bool, setupFinished: Bool, setupStarted: Bool,
                    anySwitchStored: Bool, launchedBefore: Bool = false) {
            self.alreadyRan = alreadyRan
            self.setupFinished = setupFinished
            self.setupStarted = setupStarted
            self.anySwitchStored = anySwitchStored
            self.launchedBefore = launchedBefore
        }
    }

    public static func decide(_ evidence: Evidence) -> Decision {
        if evidence.alreadyRan { return .alreadyRan }
        if evidence.setupFinished || evidence.setupStarted
            || evidence.anySwitchStored || evidence.launchedBefore {
            return .existingInstall
        }
        return .freshInstall
    }

    /// Reads the evidence from `defaults`, decides, and writes the outcome.
    ///
    /// - Parameters:
    ///   - switchKeys: every add-on's switch key, read as evidence only: one
    ///     stored means somebody has used this Mac's Airlock. Never written.
    ///   - setupFinishedKey, setupStartedKey: the setup flow's own keys,
    ///     passed in because they belong to the onboarding code, not here.
    ///   - launchMarkerKeys: keys any earlier launch writes; one being there
    ///     makes this an existing install too.
    ///   - baseOnKeys: switches that default to off in their
    ///     own model but belong to what a new Mac starts with. On a fresh
    ///     install each gets an explicit `true`.
    @discardableResult
    public static func run(in defaults: UserDefaults,
                           switchKeys: [String],
                           setupFinishedKey: String,
                           setupStartedKey: String,
                           launchMarkerKeys: [String] = [],
                           baseOnKeys: [String] = []) -> Decision {
        let evidence = Evidence(
            alreadyRan: defaults.object(forKey: sentinelKey) != nil,
            setupFinished: defaults.bool(forKey: setupFinishedKey),
            // A resume step of any value means setup was opened and left: that
            // person has already seen the app with today's features on.
            setupStarted: defaults.object(forKey: setupStartedKey) != nil,
            anySwitchStored: switchKeys.contains { defaults.object(forKey: $0) != nil },
            launchedBefore: launchMarkerKeys.contains { defaults.object(forKey: $0) != nil })
        let decision = decide(evidence)
        switch decision {
        case .alreadyRan:
            break
        case .existingInstall:
            defaults.set(true, forKey: sentinelKey)
        case .freshInstall:
            for key in baseOnKeys { defaults.set(true, forKey: key) }
            defaults.set(true, forKey: sentinelKey)
        }
        return decision
    }
}

/// Whether the open notch's tab row shows its "+", the way to the Add-ons
/// page from the notch itself.
///
/// Two things hide it. Everything added: there is nothing left to add, and a
/// button that opens a page of "all done" is clutter. And no room: the left
/// gutter holds the tabs, the collapse chevron and the "+", and at five tabs
/// on a narrow panel the "+" would push the chevron behind the camera. The
/// tabs and the chevron are what the row is for, so the "+" is the one that
/// gives way; Settings › Add-ons is still one click away on the gear.
///
/// The widths are the drawn ones, restated: a tab is 36 wide, the chevron 22,
/// the "+" 28, with 3 between each. The left tabs never carry a badge (only
/// Agents does, and it sits on the right).
public enum AddOnsPlusButton {
    public static let width: Double = 28
    static let tabWidth: Double = 36
    static let chevronWidth: Double = 22
    static let spacing: Double = 3

    /// What the left gutter's row takes, with or without the "+".
    public static func rowWidth(leadingTabs: Int, withPlus: Bool) -> Double {
        let items = Double(max(0, leadingTabs)) * tabWidth + chevronWidth + (withPlus ? width : 0)
        let gaps = Double(max(0, leadingTabs) + (withPlus ? 1 : 0)) * spacing
        return items + gaps
    }

    /// `room` is what the row may take: the gutter clear of the camera, less
    /// the row's own inset from the screen edge.
    public static func shows(everythingAdded: Bool, leadingTabs: Int, room: Double) -> Bool {
        !everythingAdded && rowWidth(leadingTabs: leadingTabs, withPlus: true) <= room
    }
}

// MARK: - What an add-on needs from macOS

/// A macOS permission an add-on needs to work, in the words the Permissions
/// page uses for it.
public enum MacAccess: String, CaseIterable, Sendable {
    case microphone
    case inputMonitoring
    case accessibility
    /// The "System Audio Recording" half of Screen & System Audio Recording.
    /// macOS has no way to ask for it ahead: it asks the first time a call is
    /// heard, and only that call can tell whether the answer was yes.
    case systemAudio

    public var name: String {
        switch self {
        case .microphone: return String(localized: "Microphone")
        case .inputMonitoring: return String(localized: "Input Monitoring")
        case .accessibility: return String(localized: "Accessibility")
        case .systemAudio: return String(localized: "System audio")
        }
    }

    /// Whether Airlock can raise macOS's question itself, on Add.
    public var canBeAskedAhead: Bool { self != .systemAudio }
}

extension AddOn {
    /// The macOS permissions this add-on needs, in the order they are asked
    /// for. Accessibility is always last: its question sends the person to
    /// System Settings, and anything asked after it would land in a window
    /// they have already left. Empty means adding it asks nothing.
    ///
    /// What each add-on can ask for later, for an optional part of itself
    /// (the clipboard's paste-for-you, the shelf's Finder selection, the
    /// terminal jump), is left out: those ask when that part is first used.
    public var needs: [MacAccess] {
        switch self {
        case .shelf, .clipboard, .codingAgents: return []
        case .meetingNotes: return [.microphone, .systemAudio]
        case .windowLayouts: return [.accessibility]
        case .dictation: return [.microphone, .inputMonitoring, .accessibility]
        }
    }

    /// Why it needs them, in one line, for the note shown on Add.
    public var needsBecause: String? {
        switch self {
        case .shelf, .clipboard, .codingAgents: return nil
        case .meetingNotes:
            return String(localized: "To hear you and the other side of your calls. macOS asks about the microphone now, and about the other side's sound on your first call.")
        case .windowLayouts:
            return String(localized: "To move and resize your windows.")
        case .dictation:
            return String(localized: "To hear you, to notice the key you hold, and to type what you said.")
        }
    }
}

/// Where one permission stands, as far as an add-on cares.
public enum MacAccessState: Equatable, Sendable {
    case allowed
    /// Never asked: pressing the button raises macOS's question.
    case notAsked
    /// Asked and refused, or simply off. For the microphone macOS will not
    /// ask again; for Accessibility and Input Monitoring it never asks more
    /// than once anyway. Either way the way on is System Settings' list.
    case notAllowed
    /// On in System Settings and still not working: an old approval from a
    /// differently signed copy. Fixed in the list, by hand.
    case notWorking
    /// An administrator's decision. Nothing anyone here can change.
    case restricted
    /// macOS asks on first use, and Airlock can't read the answer before it.
    case asksOnFirstUse
}

/// What an added add-on's row says about its permissions: nothing when it
/// has what it needs, otherwise the first thing missing and what the button
/// does about it. Pure, so every state can be pinned without a Mac in it.
public struct AddOnAccessCheck: Equatable, Sendable {
    public enum Remedy: Equatable, Sendable {
        /// macOS can still be asked; the button asks again.
        case askAgain
        /// Only System Settings can change it now; the button opens the list.
        case openSystemSettings
        /// Nothing anyone here can do (restricted).
        case none
    }

    /// Everything it needs that is not allowed, in asking order.
    public let missing: [MacAccess]
    /// What the button does about the first of them.
    public let remedy: Remedy

    public var isComplete: Bool { missing.isEmpty }

    /// The row's line: which permissions are missing and what that costs.
    public func sentence(for addOn: AddOn) -> String? {
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.name).formatted(.list(type: .and))
        if remedy == .none {
            return String(localized: "Turned off on this Mac by its administrator: \(names).")
        }
        return String(localized: "Not working yet. Still to allow: \(names).")
    }

    public var buttonTitle: String? {
        switch remedy {
        case .askAgain: return String(localized: "Try again")
        case .openSystemSettings: return String(localized: "Open System Settings")
        case .none: return nil
        }
    }

    /// Checks `addOn` against what macOS says now. Permissions macOS asks
    /// for on first use are not counted missing: nothing has said no yet.
    public static func check(_ addOn: AddOn, state: (MacAccess) -> MacAccessState) -> AddOnAccessCheck {
        let missing = addOn.needs.filter {
            switch state($0) {
            case .allowed, .asksOnFirstUse: return false
            default: return true
            }
        }
        guard let first = missing.first else { return AddOnAccessCheck(missing: [], remedy: .none) }
        let remedy: Remedy
        switch (first, state(first)) {
        case (_, .restricted): remedy = .none
        case (_, .notWorking): remedy = .openSystemSettings
        case (_, .notAsked): remedy = .askAgain
        // macOS never asks again about a refused microphone, and never asks
        // about system audio from a button at all.
        case (.microphone, _), (.systemAudio, _): remedy = .openSystemSettings
        // Accessibility and Input Monitoring: asking again raises macOS's
        // note and opens the list, the same as Allow on the Permissions page.
        default: remedy = .askAgain
        }
        return AddOnAccessCheck(missing: missing, remedy: remedy)
    }

    init(missing: [MacAccess], remedy: Remedy) {
        self.missing = missing
        self.remedy = remedy
    }
}
