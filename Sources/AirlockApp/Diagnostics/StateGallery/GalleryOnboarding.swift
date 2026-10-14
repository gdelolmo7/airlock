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
        ]
    }

    // MARK: - Fixtures

    /// The wizard's window (the fallback, and the menu bar's "Set up
    /// Airlock…"). Its Liquid Glass is composited by the window server, so
    /// it is drawn here with `onboardingFlatGlass`: bordered buttons, same words.
    static let windowWidth: CGFloat = 640

    /// The once-only notice after the rename (L10), with the guide on so
    /// every permission row Settings can show is named.
    static func permissionsAgain(_ area: String) -> GalleryState {
        GalleryState("L10", area, "Permissions again after the rename", ground: .window,
                     width: PermissionsAgainView.width) {
            PermissionsAgainView(names: PermissionsAgainView.names(guideOn: true))
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

    private static func model(at step: OnboardingPlan.Step, agents: [SettingsModel.AgentRow],
                              basis: AgentsPresence.Basis, calendar: CalendarWidgetModel,
                              resumed: Bool = false) -> OnboardingModel {
        let model = OnboardingModel(settings: SettingsModel(previewing: agents),
                                    calendar: calendar,
                                    dictation: DictationModel(),
                                    clipboard: ClipboardWidgetModel(history: ClipboardHistory(items: [])),
                                    assistant: AssistantModel(),
                                    agentsWidget: AgentsWidgetModel(previewing: basis))
        // The last step as a release build draws it, with the crash-reports
        // question, whether or not this build carries somewhere to send.
        model.offersCrashReports = true
        model.restart(at: step, resumed: resumed)
        return model
    }

    /// Every tab on, which is what a first run with the agents half on shows.
    private static func panel(at step: OnboardingPlan.Step, agents: [SettingsModel.AgentRow] = unwired,
                              basis: AgentsPresence.Basis = .noHooksInstalled,
                              calendar: CalendarWidgetModel = CalendarWidgetModel(),
                              resumed: Bool = false) -> some View {
        PanelOnboardingView(maxContentHeight: 420, tabs: NotchTab.allCases)
            .environment(model(at: step, agents: agents, basis: basis, calendar: calendar, resumed: resumed))
            .environment(NotchUIState())
    }

    private static func window(at step: OnboardingPlan.Step,
                               calendar: CalendarWidgetModel = CalendarWidgetModel()) -> some View {
        OnboardingView()
            .environment(model(at: step, agents: unwired, basis: .noHooksInstalled, calendar: calendar))
            .environment(\.onboardingFlatGlass, true)
    }
}
