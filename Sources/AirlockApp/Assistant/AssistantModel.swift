import AppKit
import Foundation
import Observation
import AirlockCore

/// The question, the answer as it arrives, and what to do when the local model
/// cannot help.
///
/// Owns no I/O of its own: `AssistantService` talks to the model, `AppModel`
/// owns the escalation to Claude Code, and this is the state the notch draws.
@MainActor
@Observable
final class AssistantModel {
    /// On by default *given dictation is on*, because the feature it replaces is
    /// a bug: holding the key with nothing focused used to type into the void, or
    /// into single-letter keyboard shortcuts.
    var isEnabled: Bool = WidgetToggle.stored("assistant.enabled", default: true) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "assistant.enabled")
            if isEnabled { service.prepare(instructions: instructions) }
        }
    }

    /// Let a spoken phrase propose an action instead of being answered.
    ///
    /// **Off by default**, and it stays that way until someone chooses it. The
    /// feature arrives because you turned it on, never because you updated —
    /// which matters more here than for any other toggle, since the thing being
    /// switched on is the microphone's ability to start things.
    var actionsEnabled: Bool = WidgetToggle.stored("voice.actions.enabled", default: false) {
        didSet {
            UserDefaults.standard.set(actionsEnabled, forKey: "voice.actions.enabled")
            }
    }

    /// The typed way in: a hotkey, a one-line field, the same resolver.
    ///
    /// **A separate switch from `actionsEnabled`, and not a sub-setting of it.**
    /// That one is off by default because of an argument about the MICROPHONE —
    /// "the thing being switched on is the microphone's ability to start
    /// things" — and none of that reasoning survives being typed at. Somebody
    /// who left spoken actions off has said something about a channel anyone in
    /// earshot can use, not about whether their Mac may act on what they
    /// deliberately typed into a bar they deliberately summoned.
    ///
    /// Off by default all the same, for a different reason: turning this on
    /// claims a system-wide hotkey, and `GlobalHotkey` calls that "a scarce
    /// global resource". Taking one on somebody's behalf during an update is
    /// not this app's habit.
    var commandBarEnabled: Bool = WidgetToggle.stored("assistant.commandBar.enabled",
                                                      default: false) {
        didSet {
            guard commandBarEnabled != oldValue else { return }
            UserDefaults.standard.set(commandBarEnabled, forKey: "assistant.commandBar.enabled")
            if !commandBarEnabled { closeCommandBar() }
            applyCommandBarHotkey()
        }
    }

    /// ⌥Space, and it took two wrong answers to get back here.
    ///
    /// It was ⌥Space, which fought the ask gesture. It became ⌘⇧Space, which
    /// 1Password owns on a great many Macs. The real problem was never which
    /// chord: it was that a chord on a hold key started a hold, and that is
    /// fixed at the source now — `DictationModel.abandonHoldForChord` throws the
    /// accidental hold away when the chord fires, so a modifier can mean both
    /// things again.
    ///
    /// Which frees the default to be the one people already reach for. The
    /// remaining cost is honest and stated in `CommandBarChord`: the microphone
    /// is open for as long as the chord takes to press, then discarded.
    var commandBarHotkey: GlobalHotkey.Binding = Defaults.binding(
        "assistant.commandBar.hotkey", default: .optionSpace) {
        didSet {
            guard commandBarHotkey != oldValue else { return }
            Defaults.setBinding(commandBarHotkey, "assistant.commandBar.hotkey")
            applyCommandBarHotkey()
        }
    }

    /// Non-nil when the combination is already owned by another app — the same
    /// reporting the clipboard and gate hotkeys do, because a hotkey that
    /// silently did not register is indistinguishable from a broken feature.
    private(set) var commandBarHotkeyError: String?

    /// Raised when the hotkey fires, so the controller can open the panel first.
    /// Wired by `NotchController`, exactly like `onGateHotkey`.
    @ObservationIgnored var onCommandBarHotkey: (() -> Void)?
    /// Escape closed the bar. Wired to collapse the panel.
    @ObservationIgnored var onCommandBarEscaped: (() -> Void)?

    /// When the grammar does not recognise a phrase, ask the model what it was.
    ///
    /// **Off by default, and this one is off for a measured reason rather than
    /// a cautious one.** `docs/voice-actions-plan.md` has the table: asked to
    /// do this job, Apple's on-device model fired on 2/6 cases in its best
    /// configuration and 0/2 in the one that shipped, and — the part that
    /// matters — it turned questions into commands. `VoiceGrammar` replaced it
    /// and scores 6/6 and 18/18 with no model at all.
    ///
    /// What is different now is the POSITION. This is a fallback, not the
    /// primary: the grammar has already declined, so the model only sees
    /// phrasings nobody listed. That is also the honest risk, and it is the
    /// wrong way round — most phrases the grammar declines are questions, which
    /// is the worst possible input for a classifier that was measured turning
    /// questions into commands.
    ///
    /// So it stays off until `swift run PromptProbe actions` says otherwise on
    /// the machine in front of you, and the card still stands between it and
    /// anything happening.
    ///
    /// It also costs a round-trip on every miss. The grammar path is
    /// deliberately synchronous — "an instruction becomes a card instantly and
    /// a question reaches `answerNow` on exactly the path it took before this
    /// feature existed" — and switching this on gives that up for phrases the
    /// grammar did not recognise.
    var modelFallbackEnabled: Bool = WidgetToggle.stored("voice.modelFallback.enabled",
                                                         default: false) {
        didSet {
            UserDefaults.standard.set(modelFallbackEnabled,
                                      forKey: "voice.modelFallback.enabled")
        }
    }

    /// Let a spoken or typed phrase run one of the user's own Shortcuts.
    ///
    /// **Off by default and its own switch**, for two reasons the risk floor
    /// does not cover. Enumerating the library runs a subprocess, so somebody
    /// who owns no Shortcuts should not pay for one on every phrase. And this is
    /// the one action whose vocabulary the user wrote rather than Airlock, which
    /// is a materially different thing to agree to.
    var shortcutsEnabled: Bool = WidgetToggle.stored("voice.shortcuts.enabled", default: false) {
        didSet {
            guard shortcutsEnabled != oldValue else { return }
            UserDefaults.standard.set(shortcutsEnabled, forKey: "voice.shortcuts.enabled")
            shortcutNames = []
            if shortcutsEnabled { Task { await refreshShortcuts() } }
        }
    }

    /// The library, cached. Empty when the feature is off, which is what makes
    /// `VoiceShortcutAction.propose` return nil rather than guess.
    private(set) var shortcutNames: [String] = []

    /// When the cache was last filled, so a phrase does not pay for a subprocess
    /// it does not need.
    @ObservationIgnored private var shortcutsFetchedAt: Date?

    /// Long enough that speaking twice in a row costs one enumeration, short
    /// enough that a Shortcut made a minute ago is reachable.
    private static let shortcutsCacheLifetime: TimeInterval = 60

    func refreshShortcuts() async {
        guard shortcutsEnabled else { return }
        shortcutNames = await ShortcutsService.names()
        shortcutsFetchedAt = Date()
        dictationLog("  shortcuts: \(shortcutNames.count) in the library")
    }

    /// Called as the hold key goes DOWN, not when speech ends — the enumeration
    /// then overlaps the speaking rather than delaying the card.
    func refreshShortcutsIfStale() {
        guard shortcutsEnabled else { return }
        if let at = shortcutsFetchedAt,
           Date().timeIntervalSince(at) < Self.shortcutsCacheLifetime { return }
        Task { await refreshShortcuts() }
    }

    /// Installed apps, cached. Rescanned on the same staleness rule as the
    /// Shortcuts library, and for the same reason: this is filesystem work and
    /// the moment of asking is the wrong time to do it.
    ///
    /// No toggle of its own. Opening an app carries no risk floor and starts
    /// nothing the user did not name, so it rides on whichever action switch is
    /// already on rather than asking for a third.
    private(set) var appTargets: [VoiceAppTarget] = []
    @ObservationIgnored private var appsScannedAt: Date?

    /// Longer than the Shortcuts window: people install apps far less often
    /// than they write Shortcuts, and this walks several directories.
    private static let appsCacheLifetime: TimeInterval = 600

    /// Language codes the user dictates in beyond English — wired by the app
    /// delegate from the dictation locales, because those settings are the one
    /// honest statement of which languages will be SPOKEN here. Feeds the
    /// scan's localized-alias reads; nil or empty keeps the scan English-only.
    @ObservationIgnored var spokenLanguageCodes: (() -> [String])?

    /// The dictation languages changed, so every cached alias is for the
    /// wrong ones — the next warm rescans instead of trusting the clock.
    func noteSpokenLanguagesChanged() {
        appsScannedAt = nil
    }

    func refreshApps() async {
        let languages = spokenLanguageCodes?() ?? []
        appTargets = await InstalledApps.scan(languages: languages)
        appsScannedAt = Date()
        let store = siteAliasStore
        siteAliases = await Task.detached(priority: .utility) { store.load() }.value
        let aliased = appTargets.reduce(0) { $0 + $1.aliases.count }
        dictationLog("  apps: \(appTargets.count) installed, \(aliased) localized names, "
            + "\(siteAliases.count) site aliases")
    }

    func refreshAppsIfStale() {
        if let at = appsScannedAt,
           Date().timeIntervalSince(at) < Self.appsCacheLifetime { return }
        Task { await refreshApps() }
    }

    /// Names the speech recogniser should expect — handed to
    /// `SpeechSession.begin` as contextual strings, which is what stops
    /// "Claude" arriving as "cloud" in the first place.
    ///
    /// Built-ins first: they are the names this product exists around, and the
    /// cap trims from the tail. The cap itself is caution, not a measured
    /// limit — the biasing API documents no ceiling, and a Mac with four
    /// hundred apps should not be the machine that discovers one mid-hold.
    var recognitionVocabulary: [String] {
        var names = VoiceMishearings.recognitionVocabulary
        names += siteAliases.map(\.phrase)
        names += shortcutNames
        // Every spoken name, not just the on-disk one: the es transcriber in
        // the race should expect "Música" exactly as the en one expects
        // "Music".
        names += appTargets.flatMap(\.spokenNames)
        return Array(names.prefix(400))
    }

    /// Phrases that mean a web address. Defaults merged with the user's file.
    ///
    /// Re-read whenever the apps are, because the two are asked the same
    /// question a moment apart and the file is small enough that a staleness
    /// window would only ever be a source of "I added it and it did not work".
    private(set) var siteAliases: [VoiceSiteAlias] = VoiceSiteAliases.merged(user: [])

    @ObservationIgnored let siteAliasStore = SiteAliasStore()

    #if AIRLOCK_GUIDE
    /// The screen guide, when it is on. See `submitCommand`.
    @ObservationIgnored weak var guide: GuideController?
    #endif
    private(set) var isCommandBarOpen = false
    var commandText = ""

    @ObservationIgnored private let commandBarRegistration = GlobalHotkey()

    private func applyCommandBarHotkey() {
        commandBarRegistration.unregister()
        commandBarHotkeyError = nil
        guard commandBarEnabled else { return }
        commandBarRegistration.register(commandBarHotkey) { [weak self] in
            self?.onCommandBarHotkey?()
        }
        commandBarHotkeyError = commandBarRegistration.lastError
        // Registration is the other half of the same unexplained report: a
        // Carbon chord that failed to register is silent and looks exactly like
        // a chord that fired and did nothing.
        dictationLog("commandBar hotkey \(commandBarHotkey.displayName) → "
                     + (commandBarHotkeyError.map { "FAILED: \($0)" } ?? "registered"))
    }

    var instructions: String = Defaults.string(
        "assistant.instructions", default: AssistantPrompt.defaultInstructions) {
        didSet {
            guard instructions != oldValue else { return }
            Defaults.set(instructions, "assistant.instructions")
            service.reset()
        }
    }

    /// Wired to `TerminalJumpService` by AppDelegate.
    var onRunInTerminal: ((String) -> Void)?

    // MARK: - Live state

    private(set) var question = ""
    private(set) var answer = ""
    private(set) var isStreaming = false
    /// Set when the model refused or failed. The escalation button is attached
    /// to this rather than replacing the panel, because "ask Claude Code
    /// instead" is the answer to every one of these.
    private(set) var failure: String?

    // Named so the state gallery draws the shipping words.
    static let couldNotAnswer = "Airlock couldn't answer that. Try asking another way."
    static let hadNoAnswer = "Airlock didn't have an answer for that. Try asking another way."

    var isPresenting = false {
        didSet {
            guard isPresenting != oldValue else { return }
            onPresentingChanged?(isPresenting)
        }
    }

    var onPresentingChanged: ((Bool) -> Void)?
    /// Hands the question to a real coding agent. Wired to `AppModel`.
    var onEscalate: ((String) -> Void)?
    /// Whether that hand-off is offered at all: Developer mode, which is the
    /// agents switch (card 3.02). Somebody who has said they do not use a
    /// coding agent is not offered one to run their question in. Read during
    /// the view's body, so the button follows the switch.
    var offersAgentHandOff: () -> Bool = { true }
    var onCopy: ((String) -> Void)?

    // MARK: - Acting

    /// A proposal on screen, waiting. Nothing has happened yet.
    /// What resolved the phrase into an action.
    ///
    /// The only way to tell a trigger match from a model guess once the card is
    /// on screen, and they deserve different trust: `VoiceGrammar` matched
    /// words you actually said against a device that actually exists, while the
    /// classifier inferred an action from a sentence it half understood. The
    /// card says which, because approving them is the same click.
    enum Provenance: Sendable, Equatable {
        case grammar
        case classifier

        var label: String {
            switch self {
            case .grammar: return "grammar match"
            case .classifier: return "model guess"
            }
        }
    }

    struct Pending: Equatable {
        let proposal: ActionProposal
        let request: PermissionRequest
        let outcome: VoiceActionOutcome
        let provenance: Provenance
    }

    private(set) var pending: Pending?

    /// Routes offered for a typed phrase the grammar declined, top first.
    ///
    /// Empty means no ladder — the phrase read as a question and was answered.
    /// See `PromptRouting`: the point is that spawning a terminal becomes a
    /// pick, so Return takes the top rung and the top rung is only ever the
    /// expensive one when the phrase actually reads as work.
    private(set) var routeCandidates: [PromptRouting.Route] = []
    /// What happened to the last one, in a sentence. Replaces the card rather
    /// than sitting beside it — the card's job is over once it is answered.
    private(set) var performed: String?

    /// Everything that exists on this Mac right now. Assembled by `AppDelegate`
    /// from the live widget models, because Core may not reach into them.
    var contextProvider: (() -> VoiceContext)?
    /// Does the thing. Returns false when it could not, which the card reports
    /// rather than swallowing — a card that says "done" over nothing happening
    /// is worse than no card.
    var onPerform: ((VoiceEffect) -> Bool)?
    /// False only for a finished trial. Every other licence state allows use.
    var isEntitled: (() -> Bool)?
    /// Records the decision in the gate log, exactly like an agent's.
    var onRecordGate: ((PermissionRequest, GateOutcome, String?) -> Void)?
    /// Opens Settings at the licence pane. Set by whoever owns both windows —
    /// the card cannot reach a window controller, and should not.
    var onShowLicence: (() -> Void)?
    /// Writes an allow rule when Always is clicked.
    var onAlwaysAllow: ((String) -> Void)?

    var availability: ModelAvailability { previewAvailability ?? service.availability }

    /// What `availability` says instead of asking the system. State gallery
    /// only — nil everywhere else, which is the shipping path unchanged. A
    /// picture of the error card must not turn into the no-model card on a Mac
    /// without Apple Intelligence.
    @ObservationIgnored var previewAvailability: ModelAvailability?

    @ObservationIgnored private let service = AssistantService()
    @ObservationIgnored private var stream: Task<Void, Never>?
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?

    /// How long a finished answer stays up with nothing happening.
    ///
    /// The panel covers the top of the screen, so an answer nobody dismissed
    /// cannot be allowed to own it indefinitely. Long enough to read a few
    /// sentences, short enough that a forgotten one clears itself.
    private static let idleTimeout: Duration = .seconds(45)

    /// How long a FINISHED action stays up.
    ///
    /// Much shorter than `idleTimeout`, because the two are not the same kind of
    /// thing. An answer is prose you have to read, so it gets three quarters of
    /// a minute. "Allowed by Voice.OpenApp(Spotify)" is a receipt — you already
    /// know what you asked for, and the app you asked for is now in front of
    /// you. Leaving that on screen for 45 seconds means the panel is still
    /// showing it when you have moved on and started dictating into something
    /// else, which is exactly what happened: a stale receipt read as a reply to
    /// a sentence it had nothing to do with.
    ///
    /// It is also the closest this path can get to the island contract, which
    /// says completions should pulse rather than expand at all.
    private static let completionTimeout: Duration = .seconds(2)

    func prepare() {
        // Before the `isEnabled` guard: the bar is a separate switch from
        // "hold a second key to ask", and a hotkey that only registered when
        // the spoken path happened to be on would be a dead key for anyone who
        // wanted typing and not talking.
        applyCommandBarHotkey()
        // Both caches warmed at launch, so the FIRST phrase resolves as well as
        // the second. Off the main actor, and nothing waits on them.
        Task { await refreshApps() }
        if shortcutsEnabled { Task { await refreshShortcuts() } }
        guard isEnabled else { return }
        service.prepare(instructions: instructions)
    }

    // MARK: - Asking

    /// Which channel the words arrived on.
    ///
    /// Not cosmetic: it decides whether the action half runs at all, and whether
    /// the card may offer an Always button — see `actionsAllowed` and
    /// `VoiceActionOutcome.resolve(…, offersStandingPermission:)`.
    enum Origin: Sendable, Equatable { case spoken, typed }

    private(set) var origin: Origin = .spoken

    /// Whether this channel may propose actions rather than only answer.
    ///
    /// Two switches because there are two consents. `actionsEnabled` is about
    /// the microphone; `commandBarEnabled` is about a bar you had to turn on and
    /// then summon, which is its own statement and a clearer one.
    private var actionsAllowed: Bool {
        switch origin {
        case .spoken: return actionsEnabled
        case .typed: return commandBarEnabled
        }
    }

    /// The default keeps both existing callers — `DictationModel.deliver` and
    /// the `--say` flag — spoken without touching them.
    func ask(_ spoken: String, origin: Origin = .spoken) {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.origin = origin
        pending = nil
        performed = nil
        // Never a silent return. Dropping a question without a word on screen is
        // exactly what "the notch quit and I lost the text" looked like from the
        // outside, and the panel is the only place that can say otherwise.
        guard AssistantPrompt.isWorthAsking(trimmed) else {
            dictationLog("  nothing to ask — heard \(DictationDiagnostics.redact(trimmed))")
            question = trimmed.isEmpty ? "…" : trimmed
            answer = ""
            failure = "Didn't catch a question there."
            isPresenting = true
            beginKeyboardSession()
            startIdleTimer()
            return
        }

        stream?.cancel()
        question = trimmed
        answer = ""
        failure = nil
        // A new phrase answers the last ladder — leaving it up would offer
        // routes for a sentence that is no longer on screen.
        routeCandidates = []
        isPresenting = true

        // Classify FIRST, and only then answer.
        //
        // The panel is already open showing the question, so the extra
        // round-trip lands inside the beat that was already there — the same
        // gap a streamed answer's first token fills. What it must never do is
        // change the answering path below, which is why it is a separate call
        // rather than a cleverer prompt: measured, one prompt doing both jobs
        // took answering from 13/14 to 8/14.
        dictationLog("assistant asked \(DictationDiagnostics.redact(trimmed)) "
                     + "actions=\(actionsEnabled)")
        // Synchronous, and that is the headline. `VoiceGrammar` is a few array
        // lookups, so an instruction becomes a card instantly and a question
        // reaches `answerNow` on exactly the path it took before this feature
        // existed — no extra round-trip, no added beat, nothing to cancel.
        //
        // It replaced a model call that was measured and lost: Apple's on-device
        // model fired on 0/2 audio cases in the shipped configuration and
        // claimed two questions in another. `VoiceGrammarTests` scores the same
        // case set at 6/6 and 18/18, in milliseconds, with no Apple Intelligence
        // required to run it.
        if actionsAllowed, let proposal = instruction(in: trimmed) {
            beginKeyboardSession()
            propose(proposal, from: .grammar)
            return
        }
        // The grammar declined, and this was typed. Offer the routes rather
        // than picking one by wording — see `PromptRouting`. A question falls
        // straight through to answering, which is the path it has always taken.
        if origin == .typed, offersAgentHandOff() {
            let candidates = PromptRouting.candidates(for: trimmed)
            if !candidates.isEmpty {
                beginKeyboardSession()
                routeCandidates = candidates
                startIdleTimer()
                return
            }
        }
        // The grammar declined. Ask the model what it was, if that is switched
        // on — and answer the phrase either way, so a classifier that says
        // nothing costs a beat rather than an outcome.
        if actionsAllowed, modelFallbackEnabled {
            beginKeyboardSession()
            isStreaming = true
            stream = Task { [weak self] in
                guard let self else { return }
                let offering = VoiceActionCatalog.offered(shortcuts: shortcutsEnabled)
                let reply = await service.classify(trimmed, offering: offering)
                self.isStreaming = false
                guard !Task.isCancelled else { return }
                if case .action(let name, let arguments) = reply,
                   let proposal = VoiceActionCatalog.propose(
                       actionNamed: name, arguments: arguments,
                       in: self.contextProvider?() ?? VoiceContext(), offering: offering) {
                    dictationLog("  classifier → \(proposal.toolName)(\(proposal.subject))")
                    self.propose(proposal, from: .classifier)
                    return
                }
                dictationLog("  classifier named nothing doable — answering")
                self.answerNow(trimmed)
            }
            return
        }
        answerNow(trimmed)
    }

    /// Nil when this was a question — which is most of the time, and is the
    /// path that must stay free.
    private func instruction(in spoken: String) -> ActionProposal? {
        let offering = VoiceActionCatalog.offered(shortcuts: shortcutsEnabled)
        let context = contextProvider?() ?? VoiceContext()
        // One call: every trigger that captures gets its own `propose`, and the
        // first that resolves wins. A trigger that matches and then declines no
        // longer swallows the phrase.
        let proposal = VoiceActionCatalog.resolve(spoken: spoken, in: context,
                                                  offering: offering)
        if let proposal {
            dictationLog("  grammar → \(proposal.toolName)(\(proposal.subject))")
        } else if !VoiceGrammar.candidates(spoken, offering: offering).isEmpty {
            dictationLog("  matched a trigger but nothing by that name on this Mac")
        }
        return proposal
    }

    /// The answering path, unchanged from before actions existed.
    private func answerNow(_ trimmed: String) {
        guard availability.isReady else {
            // Not an error state to recover from — the model is simply absent —
            // but the escalation still works, which is the point of saying so
            // here rather than silently showing an empty panel.
            failure = availability.message(feature: "answering") ?? "Answering isn't available on this Mac right now."
            beginKeyboardSession()
            startIdleTimer()
            return
        }

        beginKeyboardSession()
        isStreaming = true
        stream = Task { [weak self] in
            guard let self else { return }
            do {
                for try await partial in service.answer(trimmed, instructions: instructions) {
                    // Each element is the answer so far, not a delta.
                    self.answer = partial
                }
            } catch {
                // A guardrail refusal lands here and reads as a dead end unless
                // the way out is named.
                self.failure = Self.couldNotAnswer
                dictationLog("  assistant failed: \(error.localizedDescription)")
            }
            self.isStreaming = false
            self.settleAnswer(question: trimmed)
        }
    }

    /// Put a canned answer on screen without a microphone, a model, or a word
    /// spoken. Demo and verification only — reached from `AIRLOCK_DEMO_ANSWER`
    /// or `--demo-answer`, never from the UI.
    ///
    /// It exists because "an answer is up" is the hardest state in the panel to
    /// reach by hand: it wants dictation permission, a local model and a spoken
    /// question, all at the same moment as a live agent hitting a permission
    /// check. That combination is exactly where a gate went invisible, and a bug
    /// you cannot stand in front of is a bug you cannot confirm fixed.
    ///
    /// Deliberately the same path a real answer takes — the idle timer and the
    /// Escape monitor included. A shortcut that skipped them would be verifying
    /// a panel state nobody ever actually sees.
    func presentDemoAnswer(question: String, answer: String) {
        stream?.cancel()
        stream = nil
        self.question = question
        self.answer = answer
        failure = nil
        isStreaming = false
        isPresenting = true
        beginKeyboardSession()
        startIdleTimer()
    }

    // MARK: - Acting

    /// Put a resolved proposal in front of the policy engine, and then either in
    /// front of the user or straight through.
    private func propose(_ proposal: ActionProposal, from provenance: Provenance) {
        let request = proposal.request(id: UUID().uuidString, at: Date())
        // Two small local file reads, on the path `PolicyEngine.plan` documents
        // as fine to do inline — and by this point a model call has already run,
        // so it is not the thing anyone will feel.
        let verdict = PolicyEngine().plan(for: request, projectRoot: nil).verdict
        // Only a microphone may be granted standing permission, because only a
        // microphone is what a `Voice.` rule claims on its face.
        let outcome = VoiceActionOutcome.resolve(verdict: verdict, for: request,
                                                 isEntitled: isEntitled?() ?? true,
                                                 offersStandingPermission: origin == .spoken)
        dictationLog("  proposal \(proposal.toolName)(\(proposal.subject)) → \(outcome)")

        if case .perform(let rule) = outcome {
            // A rule already said yes. No card — the island contract reserves
            // expansion for something that needs answering, and this does not.
            carryOut(proposal, request: request, gate: .autoAllowed, note: "Allowed by \(rule).")
            return
        }
        pending = Pending(proposal: proposal, request: request, outcome: outcome,
                          provenance: provenance)
        if case .refused(let rule) = outcome { onRecordGate?(request, .autoDenied, rule) }
        startIdleTimer()
    }

    /// Install a proposal without a microphone, a grammar or a device attached.
    ///
    /// Snapshot and demo only — reached from `--snapshot`, never from the UI.
    /// It exists because the card is the one part of this feature that cannot be
    /// read from a log: `PanelSnapshot` renders each of its states offscreen, so
    /// the wording and the layout can be looked at rather than described.
    ///
    /// Deliberately does NOT set `isPresenting`. The panel must stay shut — this
    /// builds a view to render, not a card to answer, and opening the notch to
    /// take a picture of it would be taking a picture of something else.
    func presentDemoAction(question: String, proposal: ActionProposal,
                           outcome: VoiceActionOutcome,
                           provenance: Provenance = .grammar) {
        self.question = question
        performed = nil
        pending = Pending(proposal: proposal,
                          request: proposal.request(id: "snapshot", at: Date()),
                          outcome: outcome,
                          provenance: provenance)
    }

    /// Set the answer card's fields and nothing else. State gallery only —
    /// reached from `--state-gallery`, never from the UI.
    ///
    /// Unlike `presentDemoAnswer` this starts no stream, no idle timer and no
    /// Escape monitor, and like `presentDemoAction` it leaves `isPresenting`
    /// alone: the gallery draws `AssistantView` on its own, so nothing here may
    /// open the notch or outlive the picture.
    func presentPreview(question: String, answer: String = "", isStreaming: Bool = false,
                        failure: String? = nil, routes: [PromptRouting.Route] = [],
                        availability: ModelAvailability = .ready) {
        self.question = question
        self.answer = answer
        self.isStreaming = isStreaming
        self.failure = failure
        routeCandidates = routes
        performed = nil
        pending = nil
        previewAvailability = availability
    }

    /// Take one rung of the ladder.
    ///
    /// Clears the candidates FIRST: both destinations present something new,
    /// and a ladder still on screen underneath it is a second live choice for
    /// a phrase that has already gone somewhere.
    func take(_ route: PromptRouting.Route) {
        guard !routeCandidates.isEmpty else { return }
        routeCandidates = []
        switch route {
        case .claudeCode:
            let asked = question
            dismiss()
            onEscalate?(asked)
        case .answer:
            answerNow(question)
        }
    }

    /// The way out of a `.blocked` card. Dismisses first: the panel is about to
    /// lose focus to another window, and leaving a dead card behind it is how a
    /// stale proposal gets answered on the way back.
    func showLicence() {
        dismiss()
        onShowLicence?()
    }

    /// Approve, deny, or approve and write a rule.
    func resolve(_ decision: PermissionDecision) {
        guard let pending else { return }
        self.pending = nil
        switch decision {
        case .allowOnce, .alwaysAllow:
            if decision == .alwaysAllow, case .ask(_, let always) = pending.outcome,
               let always {
                // The generalisation the card SHOWED, never a wider one worked
                // out here — nothing may widen between reading and clicking.
                onAlwaysAllow?(always.text)
            }
            carryOut(pending.proposal, request: pending.request,
                     gate: GateOutcome(decision), note: nil)
        case .deny:
            onRecordGate?(pending.request, .denied, nil)
            performed = "Left alone."
            startIdleTimer(Self.completionTimeout)
        case .deferred:
            break // not reachable from the card; the idle timer just clears it
        }
    }

    /// Do it, say so, and record it. Reports a failure rather than claiming
    /// success — a card that says "done" over nothing happening is worse than
    /// no card at all.
    private func carryOut(_ proposal: ActionProposal, request: PermissionRequest,
                          gate: GateOutcome, note: String?) {
        let ok = onPerform?(proposal.effect) ?? false
        onRecordGate?(request, gate, nil)
        performed = ok ? (note ?? proposal.summary) : "Couldn't — \(proposal.subject) went away."
        dictationLog("  performed \(proposal.toolName) ok=\(ok)")
        startIdleTimer(Self.completionTimeout)
    }

    /// Common tail for both backends: catch an echo, then start the idle clock.
    ///
    /// An echo is a non-answer wearing an answer's clothes. Saying so, with the
    /// escalation attached, beats presenting the user's own question back to
    /// them as though it were a result.
    private func settleAnswer(question: String) {
        if failure == nil, AssistantPrompt.isEcho(question: question, answer: answer) {
            dictationLog("  assistant echoed the question — treating as no answer")
            answer = ""
            failure = Self.hadNoAnswer
        }
        startIdleTimer()
    }

    /// Escape dismisses, the same two-stage arrangement the clipboard uses.
    ///
    /// A local `NSEvent` monitor rather than `.onKeyPress`, for the reason
    /// recorded on `ClipboardWidgetModel.beginKeyboardSession`: the panel is a
    /// non-activating one and SwiftUI's key handling never sees these. It only
    /// receives anything while `NotchController` has made the panel key.
    private func beginKeyboardSession() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only a Bool crosses the isolation boundary — NSEvent is not
            // Sendable and cannot be returned out of `assumeIsolated`.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard event.keyCode == 53 else { return false }
                // The ladder decides, and `.pass` is a real answer — see
                // `AssistantEscape`. This monitor is global, so swallowing an
                // Escape that is not ours breaks Escape in every other app.
                return AssistantKeyRouter.shared?.handleEscape() ?? false
            }
            return handled ? nil : event
        }
        AssistantKeyRouter.shared = self
    }

    private func endKeyboardSession() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if AssistantKeyRouter.shared === self { AssistantKeyRouter.shared = nil }
    }

    /// An unread answer must not pin the panel over the top of the screen
    /// forever. Restarted rather than merely started, so a follow-up question
    /// gets a full window of its own.
    private func startIdleTimer(_ timeout: Duration = AssistantModel.idleTimeout) {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Drop a finished answer or receipt before something new begins.
    ///
    /// Called as a hold key goes down. Without it the panel can still be showing
    /// the last action's outcome while you dictate into another app entirely,
    /// and there is no way to tell from the screen that the two are unrelated —
    /// the reading is "it answered my sentence with something about Spotify".
    ///
    /// A PENDING card is never dropped here: that is a question waiting on the
    /// user, and starting to speak is not answering it.
    func clearFinishedPresentation() {
        guard pending == nil, isPresenting else { return }
        dismiss()
    }

    // MARK: - The command bar

    func openCommandBar() {
        guard commandBarEnabled else { return }
        isCommandBarOpen = true
        // Warm the same caches the hold key warms. This was missing, and the
        // symptom was not an error: with `shortcutNames` empty,
        // `VoiceShortcutAction.propose` bailed at its `guard` and the phrase
        // fell through to the local model, which duly explained that there were
        // no shortcuts. A typed command has no key-down to hang this on, so it
        // hangs on the bar opening — which is earlier than the phrase is
        // finished either way.
        refreshShortcutsIfStale()
        refreshAppsIfStale()
        // The same single monitor the spoken path uses. A second one would put
        // two closures on keyCode 53 — see `AssistantEscape`.
        beginKeyboardSession()
    }

    func closeCommandBar() {
        isCommandBarOpen = false
        commandText = ""
        // Only hand the keyboard back if nothing else still wants it: a card
        // raised BY the bar outlives the bar, and Escape has to keep reaching it.
        if pending == nil, !isPresenting { endKeyboardSession() }
    }

    /// Enter. Empty input closes rather than asking nothing.
    ///
    /// With the guide on, ↩ sends "how do I…" to the guide and ⌘↩ always
    /// answers, so a wrong guess about which one was wanted costs one key.
    func submitCommand(forceAnswer: Bool = NSEvent.modifierFlags.contains(.command)) {
        let text = commandText
        commandText = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            closeCommandBar()
            return
        }
        #if AIRLOCK_GUIDE
        if !forceAnswer, let guide, guide.isEnabled, GuideRouting.route(text) == .guide {
            closeCommandBar()
            guide.start(goal: text)
            return
        }
        #endif
        // The bar gets out of the way: whatever `ask` puts up — a card, an
        // answer, a failure — is the thing to read next, and the panel is a
        // ~100pt strip with no room for both.
        isCommandBarOpen = false
        ask(text, origin: .typed)
    }

    /// One press of Escape. False means it was not ours, so the monitor hands
    /// the event on rather than swallowing it.
    @discardableResult
    func handleEscape() -> Bool {
        switch AssistantEscape.step(hasPending: pending != nil,
                                    barHasText: !commandText.isEmpty,
                                    barOpen: isCommandBarOpen,
                                    isPresenting: isPresenting) {
        case .dismissCard, .dismissAnswer:
            // `dismiss` records an unanswered proposal as `.deferred` and never
            // performs it — Escape is not somebody saying yes.
            dismiss()
        case .clearTypedText:
            commandText = ""
        case .closeBar:
            closeCommandBar()
            // The bar opened an empty notch; Escape out of it is "done", and
            // leaving the panel open would reveal the tab the bar replaced.
            onCommandBarEscaped?()
        case .pass:
            return false
        }
        return true
    }

    // MARK: - Actions

    func copyAnswer() {
        guard !answer.isEmpty else { return }
        onCopy?(answer)
    }

    /// The recovery path for every local-model shortfall, and a first-class
    /// action in its own right — the on-device model is ~3B-class and knows it.
    func escalate() {
        let text = question
        dismiss()
        guard !text.isEmpty else { return }
        onEscalate?(text)
    }

    func dismiss() {
        idleTimer?.cancel()
        idleTimer = nil
        endKeyboardSession()
        stream?.cancel()
        stream = nil
        isStreaming = false
        isPresenting = false
        isCommandBarOpen = false
        commandText = ""
        // `question`, `answer` and `failure` are deliberately NOT cleared.
        // The panel keeps rendering the answer through the collapse this
        // dismissal causes (`NotchUIState.holdAnswerThroughCollapse`) —
        // cleared here, that final stretch showed an empty card, and before
        // the hold existed it showed the home tab, mounted for 70ms under a
        // closing panel. Every ask() overwrites all three on its way in, so
        // keeping them costs three strings nobody can see once the panel is
        // compact.
        // An unanswered proposal is dropped, never performed. Escape, the idle
        // timer and an explicit collapse all land here, and none of them is
        // somebody saying yes.
        if let pending { onRecordGate?(pending.request, .deferred, nil) }
        pending = nil
        performed = nil
        // An unpicked ladder is dropped too. Nothing was chosen, so nothing
        // runs — which is the safe end of the asymmetry it exists to manage.
        routeCandidates = []
    }
}


/// Routes the local key monitor to the live model, the same shape as
/// `ClipboardKeyRouter` — a monitor closure cannot capture an actor-isolated
/// reference, so the hop goes through a main-actor static instead.
@MainActor
enum AssistantKeyRouter {
    static weak var shared: AssistantModel?
}
