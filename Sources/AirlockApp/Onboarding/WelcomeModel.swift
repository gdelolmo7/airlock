import AppKit
import Observation
import AirlockCore

/// Drives the everyday first run (`WelcomePlan`, designs 9a–9d).
///
/// The practice is the real guide on the real screen, not a demo: the window
/// gets out of the way, System Settings opens, and `GuideController` runs a
/// bundled goal through the same looks, rings and checks as any task. That is
/// the point of it — the first ring anybody follows should be one that works
/// the way every later one will. It also means the practice meets the
/// permission asks where they belong, at the moment the guide needs them.
@MainActor
@Observable
final class WelcomeModel {
    private(set) var plan: WelcomePlan
    /// Waiting for System Settings to come up before the guide starts.
    private(set) var isOpeningSettings = false
    /// The window is back on screen after a practice that got there: the
    /// cloud's cue to hop. Set after the window shows, not when the practice
    /// ends — the screen is built while the window is still hidden, and a hop
    /// played there is a hop nobody sees.
    private(set) var celebrating = false

    /// False only in `init(previewing:)`: a snapshot saves nothing.
    private let isLive: Bool
    #if AIRLOCK_GUIDE
    /// nil only in `init(previewing:)`.
    private let guide: GuideController?
    #endif
    private let agentsWidget: AgentsWidgetModel?
    private let dictation: DictationModel?
    private let assistant: AssistantModel?
    /// What `askWay` says in a snapshot, where there is no live model to read.
    private let previewAskWay: WelcomePlan.AskWay

    @ObservationIgnored var onHide: (() -> Void)?
    @ObservationIgnored var onShow: (() -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    /// "Yes, I do": the setup wizard, at its agents step.
    @ObservationIgnored var onConnectAgents: (() -> Void)?
    @ObservationIgnored var onReveal: (() -> Void)?

    @ObservationIgnored private var practiceTask: Task<Void, Never>?

    /// Where a first run left halfway was left (`WelcomePlan.resumePoint`).
    /// Only the question is saved — see `WelcomePlan.init(hookStatuses:resumingAt:)`
    /// — and `OnboardingModel.hasCompletedSetup` removes it with its own.
    static let resumeKey = "welcome.resumeStep"

    static let settingsBundleID = "com.apple.systempreferences"
    /// Long enough for the guide's ✓ to be seen before the window comes back.
    static let returnDelay: Duration = .milliseconds(1400)
    /// A beat for the window to land before the cloud moves.
    static let celebrateDelay: Duration = .milliseconds(300)

    /// `plan` is for drawing a later screen in a snapshot.
    init(agentsWidget: AgentsWidgetModel,
         dictation: DictationModel, assistant: AssistantModel,
         hookStatuses: [HookInstallStatus], plan: WelcomePlan? = nil) {
        isLive = true
        #if AIRLOCK_GUIDE
        guide = GuideController.shared
        #endif
        self.agentsWidget = agentsWidget
        self.dictation = dictation
        self.assistant = assistant
        previewAskWay = .notOn
        let stored = OnboardingModel.hasCompletedSetup ? nil : UserDefaults.standard.string(forKey: Self.resumeKey)
        self.plan = plan ?? WelcomePlan(hookStatuses: hookStatuses, resumingAt: stored)
    }

    /// A fixed screen for the state gallery, with nothing behind it.
    /// `GuideController()` cannot stand in: its init watches the workspace and
    /// clears a saved question a second later. Pressing anything here does
    /// nothing beyond moving `plan`, and nothing is saved.
    init(previewing plan: WelcomePlan, askWay: WelcomePlan.AskWay = .hold(HoldKeyMonitor.Key.option.displayName)) {
        isLive = false
        #if AIRLOCK_GUIDE
        guide = nil
        #endif
        agentsWidget = nil
        dictation = nil
        assistant = nil
        previewAskWay = askWay
        self.plan = plan
    }

    func restart(hookStatuses: [HookInstallStatus]) {
        practiceTask?.cancel()
        isOpeningSettings = false
        celebrating = false
        plan = WelcomePlan(hookStatuses: hookStatuses)
    }

    /// How the welcome says to ask: the key actually set, and only while
    /// holding it would ask — the same rule as the Home tab's Ask strip.
    var askWay: WelcomePlan.AskWay {
        guard let dictation, let assistant else { return previewAskWay }
        let asks = dictation.isEnabled && assistant.isEnabled && dictation.askKey != dictation.holdKey
        return WelcomePlan.AskWay(
            holdKey: asks ? dictation.askKey?.displayName : nil,
            typeKey: assistant.commandBarEnabled ? assistant.commandBarHotkey.displayName : nil)
    }

    /// Saves where the walk is, so a quit comes back to the question rather
    /// than to the start. Not from a snapshot, and not once setup is done.
    private func remember() {
        guard isLive, !OnboardingModel.hasCompletedSetup else { return }
        if plan.resumePoint == .welcome {
            UserDefaults.standard.removeObject(forKey: Self.resumeKey)
        } else {
            UserDefaults.standard.set(plan.resumePoint.rawValue, forKey: Self.resumeKey)
        }
    }

    // MARK: - Practice

    func tryIt() {
        plan.startPractice()
        remember()
        onHide?()
        isOpeningSettings = true
        if let url = URL(string: "x-apple.systempreferences:") { NSWorkspace.shared.open(url) }
        practiceTask?.cancel()
        practiceTask = Task { [weak self] in
            // The guide reads the app in front, so it starts once System
            // Settings is there, plus a beat for its window to draw.
            for _ in 0..<60 {
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.settingsBundleID { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.isOpeningSettings = false
            self.startGuide()
        }
    }

    private func startGuide() {
        #if AIRLOCK_GUIDE
        guard let guide else { return }
        guide.onPracticeEnded = { [weak self] reached in self?.practiceEnded(reached: reached) }
        guide.start(goal: WelcomePlan.practiceGoal, practice: true)
        // Not started and not ended either (the guide is off): the callback
        // was never taken, so carry on as a practice that did not get there.
        if !guide.isPractice, guide.onPracticeEnded != nil {
            guide.onPracticeEnded = nil
            practiceEnded(reached: false)
        }
        #else
        // No guide in this build: a practice that did not get there.
        practiceEnded(reached: false)
        #endif
    }

    private func practiceEnded(reached: Bool) {
        let after = plan.practiceEnded(reached: reached)
        remember()
        switch after {
        case .ask, .offerAgain:
            // `.offerAgain` comes back too, to the welcome, which says the
            // practice didn't finish and offers another go or Done. It used
            // to close the window without a word.
            practiceTask = Task { [weak self] in
                try? await Task.sleep(for: Self.returnDelay)
                guard !Task.isCancelled, let self else { return }
                self.onShow?()
                try? await Task.sleep(for: Self.celebrateDelay)
                guard !Task.isCancelled else { return }
                self.celebrating = self.plan.practice == .reached
            }
        case .finish:
            finish()
        }
    }

    /// The welcome's other button: past the practice without (another) go.
    /// To the question when it is asked, else finished.
    func skip() {
        practiceTask?.cancel()
        celebrating = false
        switch plan.skipPractice() {
        case .ask, .offerAgain: remember()
        case .finish: finish()
        }
    }

    // MARK: - The question

    func answer(_ answer: WelcomePlan.Answer) {
        switch WelcomePlan.after(answer) {
        case .done:
            agentsWidget?.choose(false)
            finish()
        case .connectAgents:
            agentsWidget?.choose(true)
            // Not finished yet: setup carries on at its agents step, which
            // saves its own place (`OnboardingModel.continueFromWelcome`) so a
            // quit there picks up there. Its own ending settles the flag.
            if isLive { UserDefaults.standard.removeObject(forKey: Self.resumeKey) }
            onClose?()
            onConnectAgents?()
        }
    }

    func back() {
        celebrating = false
        plan.back()
        remember()
    }

    private func finish() {
        OnboardingModel.hasCompletedSetup = true
        onClose?()
        onReveal?()
    }

    /// The window closed by its red button, mid-walk. Same rule as the setup
    /// wizard: closing is finishing. A practice still running is left to run.
    func closedByUser() {
        OnboardingModel.hasCompletedSetup = true
        if plan.step != .practice { practiceTask?.cancel() }
    }
}
