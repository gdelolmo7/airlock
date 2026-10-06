import AppKit
import EventKit
import Observation
import AirlockCore

/// Drives the first-run window.
///
/// Deliberately thin: it owns navigation and the completion flag, and delegates
/// every action to the model that already does it. Hook installation in
/// particular routes straight through `SettingsModel` — staging the binary,
/// idempotent installs, per-agent error text and the refresh afterwards are all
/// solved there, and a second copy of that logic would be a second copy of its
/// bugs.
@MainActor
@Observable
final class OnboardingModel {
    private(set) var plan: OnboardingPlan

    /// Opened on a step saved by a setup that never finished (Airlock quit,
    /// the Mac restarted). The step then says so, once, until the first move.
    private(set) var isResuming: Bool

    /// Set once the user reaches the end, so a skipped step is still a finished
    /// setup — nobody gets the wizard twice for declining calendar access.
    private(set) var didFinish = false

    let settings: SettingsModel
    let calendar: CalendarWidgetModel
    let dictation: DictationModel
    let clipboard: ClipboardWidgetModel
    let assistant: AssistantModel
    let agentsWidget: AgentsWidgetModel

    /// Expands the notch so the last step can point at the thing itself rather
    /// than describe it.
    var onReveal: (() -> Void)?
    var onClose: (() -> Void)?

    private enum Keys {
        static let completed = "onboarding.completed"
        /// The step a setup was left on, as `OnboardingPlan.Step`'s raw
        /// value. Written on each move, removed the moment setup counts as
        /// finished, so it only ever exists for a setup left halfway.
        static let resumeStep = "onboarding.resumeStep"
    }

    init(settings: SettingsModel, calendar: CalendarWidgetModel,
         dictation: DictationModel, clipboard: ClipboardWidgetModel,
         assistant: AssistantModel, agentsWidget: AgentsWidgetModel) {
        self.settings = settings
        self.calendar = calendar
        self.dictation = dictation
        self.clipboard = clipboard
        self.assistant = assistant
        self.agentsWidget = agentsWidget
        let stored = Self.hasCompletedSetup ? nil : UserDefaults.standard.string(forKey: Keys.resumeStep)
        let plan = OnboardingPlan(resumingAt: stored)
        self.plan = plan
        isResuming = plan.step != .welcome
    }

    // MARK: - Presentation decision

    static var hasCompletedSetup: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.completed) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.completed)
            // Finished by any route — Done, Skip setup, the red button, an
            // explicit collapse — leaves nothing to pick up again.
            if newValue {
                UserDefaults.standard.removeObject(forKey: Keys.resumeStep)
                UserDefaults.standard.removeObject(forKey: WelcomeModel.resumeKey)
            }
        }
    }

    /// A first run was started and never finished: a step was saved by
    /// either walk. See `OnboardingPlan.shouldPresent`.
    static var leftHalfway: Bool {
        !hasCompletedSetup
            && (UserDefaults.standard.string(forKey: Keys.resumeStep) != nil
                || UserDefaults.standard.string(forKey: WelcomeModel.resumeKey) != nil)
    }

    /// The setup wizard, not the welcome, was the walk left halfway — so a
    /// relaunch returns to it even while the guide is on (which would
    /// otherwise open the welcome).
    static var wizardLeftHalfway: Bool {
        !hasCompletedSetup && UserDefaults.standard.string(forKey: Keys.resumeStep) != nil
    }

    /// Saves where setup is, so a quit can be resumed. Never once setup is
    /// finished: running the guide again from the menu bar is a look back,
    /// not a first run to return to.
    static func remember(_ step: OnboardingPlan.Step) {
        guard !hasCompletedSetup else { return }
        UserDefaults.standard.set(step.rawValue, forKey: Keys.resumeStep)
    }

    /// Call once at launch, with a refreshed `SettingsModel`.
    ///
    /// When an existing install suppresses the wizard this also *records* the
    /// suppression, so uninstalling hooks later doesn't resurrect a first-run
    /// experience months into using the app.
    static func shouldPresentAtLaunch(settings: SettingsModel) -> Bool {
        let show = OnboardingPlan.shouldPresent(hasCompletedSetup: hasCompletedSetup,
                                                hookStatuses: settings.agents.map(\.status),
                                                leftHalfway: leftHalfway)
        if !show { hasCompletedSetup = true }
        return show
    }

    // MARK: - Navigation

    func advance() {
        guard !plan.isLast else { return finish() }
        plan.advance()
        moved()
    }

    func retreat() {
        plan.retreat()
        moved()
    }

    /// Writes nothing: the state gallery draws every step through here, and
    /// a picture must never leave a step saved in somebody's preferences.
    /// `resumed` draws the "picking up" line, for a snapshot.
    func restart(at step: OnboardingPlan.Step = .welcome, resumed: Bool = false) {
        plan = OnboardingPlan()
        plan.jump(to: step)
        didFinish = false
        isResuming = resumed
        settings.refresh()
    }

    /// The welcome's "Yes, I do": setup carries on at its agents step, and
    /// a quit there comes back to it rather than to nothing.
    func continueFromWelcome() {
        restart(at: .agents)
        Self.remember(.agents)
    }

    private func moved() {
        isResuming = false
        Self.remember(plan.step)
    }

    func finish() {
        Self.hasCompletedSetup = true
        didFinish = true
        onClose?()
    }

    // MARK: - Steps

    var step: OnboardingPlan.Step { plan.step }
    var isFirst: Bool { plan.isFirst }
    var isLast: Bool { plan.isLast }
    var stepCount: Int { plan.stepCount }
    var stepIndex: Int { plan.index }

    // MARK: - Agents

    var agents: [SettingsModel.AgentRow] { settings.agents }

    /// True once anything is wired up — the difference between a working install
    /// and a decorative one, so the primary button reflects it.
    var anyHookInstalled: Bool { settings.agents.contains { $0.status == .installed } }

    func install(_ row: SettingsModel.AgentRow) {
        guard row.status == .notInstalled else { return }
        settings.toggle(row)
    }

    /// The whole point of the step, in one button. Skips agents that are already
    /// installed or in conflict, so it stays safe to press twice.
    func installAll() {
        for row in settings.agents where row.status == .notInstalled {
            settings.toggle(row)
        }
    }

    var installableCount: Int {
        settings.agents.filter { $0.status == .notInstalled }.count
    }

    /// "I don't use coding agents" — the answer this step had no way to give.
    ///
    /// Skipping it merely postponed the question: the Agents tab was still
    /// there afterwards, permanently empty, and so was a usage KPI for a product
    /// the user does not run. Saying so once turns the whole surface off, and
    /// because it is a stated choice rather than a derived default, installing
    /// hooks later never quietly overrides it.
    func declineAgents() {
        agentsWidget.choose(false)
        advance()
    }

    /// For the person who declines and then reads the next screen. Symmetrical
    /// with `declineAgents` on purpose — an irreversible click in a wizard is
    /// how people end up reinstalling an app to undo one.
    func reconsiderAgents() {
        agentsWidget.choose(true)
    }

    var hasDeclinedAgents: Bool { agentsWidget.basis == .chosen(false) }

    // MARK: - Features

    /// Read through to the real models rather than mirrored, so the wizard shows
    /// the binding actually in force — both of these are user-configurable, and
    /// a guide that prints the default while the app listens for something else
    /// is worse than one that stays quiet.
    var holdKeyName: String { dictation.holdKey.displayName }
    var clipboardHotkeyName: String { clipboard.hotkey.displayName }
    var clipboardHotkeyEnabled: Bool { clipboard.hotkeyEnabled }

    var dictationEnabled: Bool { dictation.isEnabled }
    /// nil when asking is off or has no key — the wizard then says nothing
    /// about it rather than naming a key that does nothing.
    var askKeyName: String? {
        guard assistant.isEnabled, let key = dictation.askKey, key != dictation.holdKey
        else { return nil }
        return key.displayName
    }

    /// Turning it on here also starts the speech model downloading, which is the
    /// real reason to offer the switch during setup rather than only in Settings:
    /// the first hold is otherwise the one that waits.
    func setDictationEnabled(_ enabled: Bool) { dictation.isEnabled = enabled }

    // MARK: - Dictation languages

    /// One row of the second-language picker: the identifier the model wants,
    /// and the name a person recognises.
    struct SpokenLanguage: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// What dictation listens for when nobody has said otherwise.
    ///
    /// The LANGUAGE, not the locale. A Mac set to English in Spain is `en_ES`,
    /// and "English (Spain)" inside a sentence about which language you speak
    /// reads as a mistake the app has made about you.
    var dictationPrimaryName: String {
        let identifier = dictation.localeIdentifier.isEmpty
            ? Locale.current.identifier : dictation.localeIdentifier
        if let code = Locale(identifier: identifier).language.languageCode?.identifier,
           let name = Locale.current.localizedString(forLanguageCode: code) {
            return name
        }
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Sorted by the name on screen rather than the identifier behind it:
    /// "Spanish (Spain)" belongs under S, not between `es_419` and `et_EE`.
    var dictationLanguages: [SpokenLanguage] {
        dictation.availableLocales
            .map { SpokenLanguage(id: $0.identifier,
                                  name: Locale.current.localizedString(forIdentifier: $0.identifier)
                                      ?? $0.identifier) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Empty for "nothing else", which is the default and stays the default —
    /// see `SpokenLanguages` for why this is asked rather than assumed.
    var secondDictationLanguage: String {
        get { dictation.secondaryLocaleIdentifier }
        set { dictation.secondaryLocaleIdentifier = newValue }
    }

    /// nil when the Mac gives no reason to offer one, and then the picker says
    /// nothing about a language nobody has hinted at.
    var suggestedSecondLanguage: SpokenLanguage? {
        guard let identifier = SpokenLanguages.suggestedSecond(
            preferred: Locale.preferredLanguages,
            primary: dictation.localeIdentifier,
            available: dictation.availableLocales.map(\.identifier)) else { return nil }
        return dictationLanguages.first { $0.id == identifier }
    }

    // MARK: - Permissions

    var calendarGranted: Bool { calendar.authStatus == .fullAccess }

    /// What the Calendar row says and offers, from the same card Settings
    /// and the calendar widget use — so a refusal reads as a refusal here too.
    /// nil once access is granted.
    var calendarCard: CalendarAccessCard? { calendar.accessCard }

    /// The Calendar row's button. After a refusal macOS will not ask again,
    /// so that button opens System Settings at Calendars instead of doing
    /// nothing. Opened directly, not through `CalendarWidgetModel`'s remedy:
    /// that one also collapses the notch, which here would end setup.
    func performCalendarRemedy() {
        switch calendarCard?.remedy ?? .nothing {
        case .ask, .tryAgain: Task { await calendar.requestAccess() }
        case .openSystemSettings: PermissionPage.permission(.calendar).open()
        case .nothing: break
        }
    }

    // MARK: - Finish

    var isBundled: Bool { settings.isBundled }
    var launchAtLogin: Bool { settings.launchAtLogin }

    func setLaunchAtLogin(_ enabled: Bool) { settings.setLaunchAtLogin(enabled) }

    func revealNotch() { onReveal?() }
}
