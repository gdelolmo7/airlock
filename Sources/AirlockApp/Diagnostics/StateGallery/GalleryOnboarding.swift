import SwiftUI
import AirlockCore

/// The first-run rows (O): the setup wizard in the panel, where `--onboarding`
/// runs it, and in its window.
///
/// The wizard's `OnboardingModel` is built from previews — fixed agent rows
/// and an agents switch that read nothing from disk — plus widget models whose
/// inits only read preferences. Nothing is pressed: the gallery draws with
/// hit testing off.
@MainActor
enum GalleryOnboarding {
    static let area = "Onboarding"

    static var states: [GalleryState] {
        [
            GalleryState("O1", area, "Setup chrome (\"setup · 1 of 5\")") {
                panel(at: .welcome)
            },
            GalleryState("O2", area, "Welcome: \"This is Airlock\"") {
                panel(at: .welcome)
            },
            GalleryState("O2a", area, "Welcome window: the usage counts question", ground: .window,
                         width: windowWidth) {
                window(at: .welcome)
            },
            GalleryState("O3", area, "Connect your agents") {
                panel(at: .agents)
            },
            GalleryState("O4", area, "The keys that reach it") {
                panel(at: .features)
            },
            GalleryState("O5", area, "Two permissions / that's setup") {
                // Each at its own height: stacked, the first would be squeezed
                // into its scroll area.
                VStack(spacing: 12) {
                    panel(at: .permissions).fixedSize(horizontal: false, vertical: true)
                    panel(at: .finish).fixedSize(horizontal: false, vertical: true)
                }
            },
            GalleryState("O10", area, "Wizard: \"The rest of it\"", ground: .window, width: windowWidth) {
                window(at: .features)
            },
            GalleryState("O11", area, "Wizard: agent conflict (window / panel)") {
                panel(at: .agents, agents: conflicted)
            },
            GalleryState("O12", area, "Wizard: agents declined") {
                panel(at: .agents, basis: .chosen(false))
            },
            GalleryState("O13", area, "Wizard: Calendar in the island") {
                // Refused: the same card and System Settings button as the
                // calendar widget, not an "Ask macOS" that does nothing.
                panel(at: .permissions, calendar: CalendarWidgetModel(previewing: .denied))
            },
            GalleryState("O13a", area, "Wizard window: Calendar refused", ground: .window, width: windowWidth) {
                window(at: .permissions, calendar: CalendarWidgetModel(previewing: .denied))
            },
            GalleryState("O14", area, "Wizard: Automation") {
                panel(at: .permissions)
            },
            // Apple Intelligence writes call notes on the Mac, and on Free it
            // is the only thing that does, so setup says which of these it is.
            GalleryState("O14a", area, "Setup: Apple Intelligence switched off") {
                panel(at: .permissions, appleIntelligence: .needsAppleIntelligence)
            },
            GalleryState("O14b", area, "Setup: Apple Intelligence not on this Mac") {
                panel(at: .permissions, appleIntelligence: .deviceNotEligible)
            },
            GalleryState("O14c", area, "Setup: Apple Intelligence still downloading") {
                panel(at: .permissions, appleIntelligence: .modelNotReady)
            },
            GalleryState("O14d", area, "Setup: Apple Intelligence on") {
                panel(at: .permissions, appleIntelligence: .ready)
            },
            GalleryState("O15", area, "Wizard: \"Skip Setup\" vs \"Skip setup\"", ground: .window,
                         width: windowWidth) {
                // The window's footer; the panel's "Skip setup" is in O1.
                window(at: .agents)
            },
            GalleryState("O16", area, "Setup picked up after a quit") {
                panel(at: .features, resumed: true)
            },
            GalleryState("O17", area, "After an update: what's new, once") {
                // The newest entry, so the gallery always shows the card the
                // next release will open with — as it rests, after arriving.
                WhatsNewCard(card: WhatsNew.card(for: WhatsNew.catalog[0]), arrives: false)
            },
            GalleryState("O18", area, "After skipping an update: folded, newest first") {
                if let sample = WhatsNewLaunch.sample {
                    WhatsNewCard(card: sample, arrives: false)
                }
            },
            GalleryState("O19", area, "After an unexpected quit: crash reports, asked once") {
                CrashQuestionCard()
            },
            GalleryState("O20", area, "Set up before counts existed: usage counts, asked once") {
                UsageQuestionCard()
            },
            // Hold to talk's three switches, one at a time: the microphone is
            // asked, the other two are switches in a list that opens.
            GalleryState("O21", area, "Setup: hold to talk, 1 of 3 (microphone)") {
                panel(at: .permissions, switches: walk(.notAsked))
            },
            GalleryState("O21a", area, "Setup: hold to talk, microphone refused") {
                panel(at: .permissions, switches: walk(.refused))
            },
            GalleryState("O21b", area, "Setup: hold to talk, 2 of 3 (Input Monitoring)") {
                panel(at: .permissions, switches: walk(.allowed))
            },
            GalleryState("O21c", area, "Setup: hold to talk, 3 of 3 (Accessibility)") {
                panel(at: .permissions, switches: walk(.allowed, keyNoticed: true))
            },
            GalleryState("O21d", area, "Setup: hold to talk, ready") {
                panel(at: .permissions, switches: walk(.allowed, keyNoticed: true, canType: true))
            },
            GalleryState("O21e", area, "Setup window: hold to talk, 2 of 3", ground: .window,
                         width: windowWidth) {
                window(at: .permissions, switches: walk(.allowed))
            },
            GalleryState("O21f", area, "Setup: hold to talk, microphone turned off by the Mac's manager") {
                panel(at: .permissions, switches: walk(.blocked))
            },
            GalleryState("O21g", area, "Setup: hold to talk, Input Monitoring on but an old approval") {
                panel(at: .permissions, switches: walk(.allowed, keyApprovalIsOld: true))
            },
        ]
    }

    // MARK: - Fixtures

    /// The wizard's window (the fallback, and the menu bar's "Set up
    /// Airlock…"). Its Liquid Glass is composited by the window server, so
    /// it is drawn here with `onboardingFlatGlass`: bordered buttons, same words.
    static let windowWidth: CGFloat = 640

    /// The once-only notice after the rename (L10), naming every permission
    /// row Settings can show.
    static func permissionsAgain(_ area: String) -> GalleryState {
        GalleryState("L10", area, "Permissions again after the rename", ground: .window,
                     width: PermissionsAgainView.width) {
            PermissionsAgainView(names: PermissionsAgainView.names)
        }
    }

    /// Claude Code and Codex, neither wired yet — what a first run meets.
    private static let unwired: [SettingsModel.AgentRow] = [
        .init(kind: .claudeCode, name: "Claude Code", configPath: "~/.claude/settings.json", status: .notInstalled),
        .init(kind: .codex, name: "Codex", configPath: "~/.codex/config.toml", status: .notInstalled),
    ]

    /// Codex is the one installer that reports a conflict, in these words.
    private static let conflicted: [SettingsModel.AgentRow] = [
        .init(kind: .claudeCode, name: "Claude Code", configPath: "~/.claude/settings.json", status: .notInstalled),
        .init(kind: .codex, name: "Codex", configPath: "~/.codex/config.toml",
              status: .conflict("unmanaged Airlock entries in ~/.codex/config.toml")),
    ]

    // MARK: - Drawing

    /// `appleIntelligence` stands in for this Mac's own answer, so a picture
    /// says the same thing on every Mac it is taken on.
    private static func model(at step: OnboardingPlan.Step, agents: [SettingsModel.AgentRow],
                              basis: AgentsPresence.Basis, calendar: CalendarWidgetModel,
                              resumed: Bool = false,
                              appleIntelligence: ModelAvailability = .ready) -> OnboardingModel {
        let dictation = DictationModel()
        dictation.previewCleanupAvailability = appleIntelligence
        let model = OnboardingModel(settings: SettingsModel(previewing: agents),
                                    calendar: calendar,
                                    dictation: dictation,
                                    clipboard: ClipboardWidgetModel(history: ClipboardHistory(items: [])),
                                    agentsWidget: AgentsWidgetModel(previewing: basis))
        // The first and last steps as a release build draws them, with the
        // usage-counts and crash-reports questions, whether or not this
        // build carries somewhere to send.
        model.offersCrashReports = true
        model.offersUsageCounts = true
        model.restart(at: step, resumed: resumed)
        return model
    }

    /// Every tab on, which is what a first run with the agents half on shows.
    /// `switches` stands in for this Mac's dictation switches, and shows the
    /// hold to talk walk whether or not dictation is on here.
    private static func panel(at step: OnboardingPlan.Step, agents: [SettingsModel.AgentRow] = unwired,
                              basis: AgentsPresence.Basis = .noHooksInstalled,
                              calendar: CalendarWidgetModel = CalendarWidgetModel(),
                              resumed: Bool = false,
                              appleIntelligence: ModelAvailability = .ready,
                              switches: DictationSwitches? = nil) -> some View {
        let wizard = model(at: step, agents: agents, basis: basis, calendar: calendar, resumed: resumed,
                           appleIntelligence: appleIntelligence)
        wizard.previewSwitches = switches
        return PanelOnboardingView(maxContentHeight: 420, tabs: NotchTab.allCases)
            .environment(wizard)
            .environment(NotchUIState())
    }

    private static func window(at step: OnboardingPlan.Step,
                               calendar: CalendarWidgetModel = CalendarWidgetModel(),
                               switches: DictationSwitches? = nil) -> some View {
        let wizard = model(at: step, agents: unwired, basis: .noHooksInstalled, calendar: calendar)
        wizard.previewSwitches = switches
        return OnboardingView()
            .environment(wizard)
            .environment(\.onboardingFlatGlass, true)
    }

    /// Hold to talk's walk, at one step each.
    private static func walk(_ microphone: DictationSwitches.Microphone, keyNoticed: Bool = false,
                             canType: Bool = false, keyApprovalIsOld: Bool = false) -> DictationSwitches {
        DictationSwitches(microphone: microphone, keyNoticed: keyNoticed, canType: canType,
                          keyApprovalIsOld: keyApprovalIsOld)
    }
}
