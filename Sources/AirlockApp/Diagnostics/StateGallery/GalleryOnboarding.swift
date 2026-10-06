import SwiftUI
import AirlockCore

/// The first-run rows (O): the setup wizard in the panel, where `--onboarding`
/// runs it, and the everyday welcome.
///
/// The wizard's `OnboardingModel` is built from previews — fixed agent rows
/// and an agents switch that read nothing from disk — plus widget models whose
/// inits only read preferences. The welcome uses `WelcomeModel(previewing:)`,
/// which has no guide behind it. Nothing is pressed: the gallery draws with
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
            GalleryState("O6", area, "Everyday welcome + practice", ground: .window, width: WelcomeView.width) {
                welcome(WelcomePlan(hookStatuses: []))
            },
            GalleryState("O7", area, "Everyday welcome with a different ask key", ground: .window,
                         width: WelcomeView.width) {
                welcome(WelcomePlan(hookStatuses: []), askWay: .hold(HoldKeyMonitor.Key.command.displayName))
            },
            GalleryState("O7a", area, "Everyday welcome, asking switched off", ground: .window,
                         width: WelcomeView.width) {
                welcome(WelcomePlan(hookStatuses: []), askWay: .notOn)
            },
            GalleryState("O8", area, "Practice not reached, Developer mode already on", ground: .window,
                         width: WelcomeView.width) {
                // Back at the welcome, saying so, with another go or Done.
                welcome(practiced(reached: false, hooks: [.installed]))
            },
            GalleryState("O9", area, "Practice reached / developer question", ground: .window,
                         width: WelcomeView.width) {
                welcome(practiced(reached: true))
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

    private static func practiced(reached: Bool, hooks: [HookInstallStatus] = []) -> WelcomePlan {
        var plan = WelcomePlan(hookStatuses: hooks)
        plan.startPractice()
        _ = plan.practiceEnded(reached: reached)
        return plan
    }

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

    private static func welcome(_ plan: WelcomePlan,
                                askWay: WelcomePlan.AskWay = .hold(HoldKeyMonitor.Key.option.displayName))
    -> some View {
        WelcomeView()
            .environment(WelcomeModel(previewing: plan, askWay: askWay))
            .environment(\.welcomeHeroStill, true)
    }
}
