import Foundation
import AirlockCore

/// Where each add-on's switch really lives: the one place that ties the
/// UI-free `AddOn` list to the models that own the switches.
///
/// The models keep their own switches (and their own reasons for how each
/// is stored); this only knows which is which. The Add-ons page and the "+"
/// in the tab strip read and flip add-ons through here, so neither needs to
/// know that Coding agents is a choice rather than a toggle, or that Meeting
/// notes is read straight from the defaults.
@MainActor
struct AddOnSwitches {
    let tray: TrayModel
    let clipboard: ClipboardWidgetModel
    let agents: AgentsWidgetModel
    let dictation: DictationModel
    var windowLayouts: WindowLayoutModel = .shared

    /// The defaults key each add-on's switch is stored under.
    static func key(for addOn: AddOn) -> String {
        switch addOn {
        case .shelf: return TrayModel.enabledKey
        case .clipboard: return ClipboardWidgetModel.enabledKey
        case .meetingNotes: return MeetingNotesModel.enabledKey
        case .codingAgents: return AgentsWidgetModel.choiceKey
        case .windowLayouts: return WindowLayoutModel.enabledKey
        case .dictation: return DictationModel.enabledKey
        }
    }

    func isOn(_ addOn: AddOn) -> Bool {
        switch addOn {
        case .shelf: return tray.isEnabled
        case .clipboard: return clipboard.isEnabled
        case .meetingNotes: return MeetingNotesModel.isOn
        // The tab, not the stored flag. With no agent connected and nobody
        // asked, the flag is off while the Agents tab is on screen asking to
        // be set up; a card reading "off" beside a visible tab cannot be used
        // to hide it (switching an off switch off is not a gesture), and it
        // kept the "+" showing on a Mac that already had everything. The
        // Agents switch in Settings reads it the same way.
        case .codingAgents: return AgentsWidget.showsTabAtRest(agents)
        case .windowLayouts: return windowLayouts.isEnabled
        case .dictation: return dictation.isEnabled
        }
    }

    /// Flips the switch through its model, so whatever the model does on a
    /// change (stop a poller, drop a key monitor, unregister shortcuts)
    /// happens exactly as it does from Settings.
    func set(_ addOn: AddOn, on: Bool) {
        switch addOn {
        case .shelf: tray.isEnabled = on
        case .clipboard: clipboard.isEnabled = on
        // The notes model has no setter: it watches this key and follows it,
        // which is also how Settings moves it.
        case .meetingNotes: UserDefaults.standard.set(on, forKey: MeetingNotesModel.enabledKey)
        // A choice, not a toggle: see `AgentsWidgetModel.choose(_:)`.
        case .codingAgents: agents.choose(on)
        case .windowLayouts: windowLayouts.isEnabled = on
        case .dictation: dictation.isEnabled = on
        }
    }

    /// The run-once seed for a new Mac: it switches on what a new Mac starts
    /// with but whose model defaults to off (This Mac and dictation), for a
    /// fresh install only. Called at launch after the identity migration (so an old
    /// install's preferences are already in place and count as evidence) and
    /// before any model is built, because the models read their switch once,
    /// at construction.
    @discardableResult
    static func seedAtLaunch(in defaults: UserDefaults = .standard) -> AddOnSeed.Decision {
        AddOnSeed.run(
            in: defaults,
            switchKeys: AddOn.allCases.map(key(for:)),
            setupFinishedKey: OnboardingModel.completedKey,
            setupStartedKey: OnboardingModel.resumeStepKey,
            // Written by every launch since the what's-new card shipped, so an
            // install that somehow has neither setup key still counts as used.
            launchMarkerKeys: [WhatsNewLaunch.seenKey],
            // Switches whose model defaults to off for the installs that never
            // chose them: This Mac (CPU, GPU and memory), half of the
            // Dashboard, and dictation, which a new Mac starts with like every
            // other add-on. Setup then walks dictation's three permissions on
            // its Permissions step, as it always has once dictation is on.
            baseOnKeys: [SystemStatsWidgetModel.enabledKey, DictationModel.enabledKey])
    }
}
