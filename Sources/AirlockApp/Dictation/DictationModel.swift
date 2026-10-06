import AppKit
import AVFoundation
import Carbon.HIToolbox
import Observation
import Speech
import AirlockCore

/// Diagnostics for the dictation path.
///
/// It exists because the two obvious channels are both unusable here: NSLog
/// never appeared in `log show` for this process, and stderr is only capturable
/// when the binary is executed directly — which changes TCC attribution and so
/// changes the very thing being diagnosed.
///
/// **It does not record what you said.** An earlier version logged every
/// transcript verbatim, in a world-readable file, forever — a permanent
/// plaintext archive of everything ever dictated, swept into Time Machine and
/// indexed by Spotlight, and the one file in this app that was not 0600. What
/// gets written now is shape without content: how many characters, how loud the
/// input was, which stage ran. That answers every question the log was built to
/// answer, and none it had no business answering.
///
/// Full transcripts can be turned on for a debugging session with
/// `AIRLOCK_DICTATION_DEBUG=1`, which is a deliberate act by someone who
/// knows what they are switching on.
enum DictationDiagnostics {
    /// Owner-only, matching every other file this app writes. Built at the call
    /// site because `[FileAttributeKey: Any]` is not Sendable and so cannot be a
    /// static constant under Swift 6.
    /// Rotated rather than grown without bound — a diagnostic that eventually
    /// fills a disk is its own bug.
    private static let sizeLimit = 256 * 1024

    static let logsContent = ProcessInfo.processInfo.environment["AIRLOCK_DICTATION_DEBUG"] != nil
        || ProcessInfo.processInfo.arguments.contains("--dictation-debug")

    /// Not private so that `OwnerLogsTests` checks this exact file.
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Airlock/dictation.log")
    }

    /// Text is summarised unless content logging is explicitly on. Length and a
    /// word count are enough to tell "heard nothing" from "heard plenty" —
    /// which is the only thing the log ever needed text for.
    static func redact(_ text: String) -> String {
        guard !logsContent else { return "'\(text)'" }
        let words = text.split(whereSeparator: \.isWhitespace).count
        return "<\(text.count) chars, \(words) words>"
    }

    static func log(_ message: String) {
        // Logger, not NSLog: this type's own note above records that NSLog
        // never reached `log show` for this process. The file below stays — it
        // is the channel that survives a crash.
        Log.app.debug("dictation: \(message, privacy: .private)")
        // The app's alone: a test run reaches this line too (see `OwnerLogs`).
        guard OwnerLogs.areOpen else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let manager = FileManager.default
        let path = url.path
        if let size = (try? manager.attributesOfItem(atPath: path)[.size]) as? Int,
           size > sizeLimit {
            try? manager.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}

func dictationLog(_ message: String) { DictationDiagnostics.log(message) }

/// Hold a key, speak, and the words are typed where your cursor is.
///
/// This owns the wiring; the decisions live in Core. `HoldGesture` decides what
/// a press, a release or a missed release means, and `DictationTranscript`
/// decides how partial results become one sentence — both pure and tested.
/// What is left here is the part that cannot be: a microphone, an actor, a
/// hotkey and a stack of permissions.
@MainActor
@Observable
final class DictationModel {
    // MARK: - Settings

    /// A STORED property, seeded once, not a computed read of UserDefaults.
    /// `@Observable` cannot track a computed property backed by
    /// `@ObservationIgnored` storage — the toggle would write the value and
    /// nothing would redraw. This codebase has been bitten by that twice.
    var isEnabled: Bool = WidgetToggle.stored("dictation.enabled", default: false) {
        didSet {
            guard isEnabled != oldValue else { return }
            toggle.value = isEnabled
            if isEnabled {
                Task { await prepare() }
            } else {
                cancelEverything()
            }
            applyHotkey()
        }
    }

    /// A bare modifier held down, not a chord.
    ///
    /// A listen-only tap does not consume the key, so the hold key has to be one
    /// that types nothing — otherwise every dictation would also insert its
    /// character. That is why this is a modifier and why ⌥Space, the previous
    /// default, was wrong on its own terms.
    var holdKey: HoldKeyMonitor.Key = HoldKeyMonitor.Key(
        rawValue: Defaults.string("dictation.holdKey", default: "")) ?? .control {
        didSet {
            guard holdKey != oldValue else { return }
            Defaults.set(holdKey.rawValue, "dictation.holdKey")
            applyHotkey()
        }
    }

    /// A second hold key that asks instead of typing.
    ///
    /// Separate from `holdKey` because intent must be stated, not inferred. The
    /// first version of this feature guessed from focus and typed a dictation
    /// into a Gmail inbox, where Chrome reports an `AXTextArea` and every letter
    /// is a command. A key cannot be misread.
    ///
    /// `.none` turns asking off entirely.
    var askKey: HoldKeyMonitor.Key? = HoldKeyMonitor.Key(
        rawValue: Defaults.string("dictation.askKey", default: "option")) {
        didSet {
            guard askKey != oldValue else { return }
            Defaults.set(askKey?.rawValue ?? "", "dictation.askKey")
            applyHotkey()
        }
    }

    /// Tidy the transcript with the on-device model before typing it.
    ///
    /// On by default: this is what separates dictation you would send from a
    /// transcript full of "um" and half-finished sentences. It costs a beat
    /// between releasing the key and the text landing, and it degrades to the
    /// raw transcript on every failure — no model, no Apple Intelligence, a
    /// refusal, a timeout.
    var cleansTranscript: Bool = WidgetToggle.stored("dictation.cleanup", default: true) {
        didSet {
            UserDefaults.standard.set(cleansTranscript, forKey: "dictation.cleanup")
            if cleansTranscript { cleanup.prepare(instructions: cleanupInstructions) }
        }
    }

    /// The prompt handed to the model. Editable, because "clean this up" means
    /// different things to different people — some want filler gone and nothing
    /// else, some want full sentences.
    var cleanupInstructions: String = Defaults.string(
        "dictation.cleanupInstructions", default: TranscriptCleanup.defaultInstructions) {
        didSet {
            guard cleanupInstructions != oldValue else { return }
            Defaults.set(cleanupInstructions, "dictation.cleanupInstructions")
            cleanup.reset()
        }
    }

    /// Pause playback while you speak, resume after.
    ///
    /// Off by default, and that is a judgement rather than caution. On speakers
    /// it genuinely helps — music bleeds into the microphone and the recogniser
    /// has to compete with it. On headphones it helps with nothing and is purely
    /// irritating, and most dictations last a few seconds, so pause-then-resume
    /// can be a worse artefact than the background music was.
    var pausesMusic: Bool = WidgetToggle.stored("dictation.pausesMusic", default: false) {
        didSet { UserDefaults.standard.set(pausesMusic, forKey: "dictation.pausesMusic") }
    }

    /// Empty means "whatever macOS is using".
    ///
    /// The UID is persisted, never the numeric `AudioDeviceID`, which the system
    /// reassigns across reboots and replugs — saving that would quietly point at
    /// a different microphone later.
    var inputDeviceUID: String = Defaults.string("dictation.inputDevice", default: "") {
        didSet {
            guard inputDeviceUID != oldValue else { return }
            Defaults.set(inputDeviceUID, "dictation.inputDevice")
            refreshDevices()
        }
    }

    private(set) var availableInputs: [AudioInputDevice] = []
    /// What the preference resolves to right now — including "you picked
    /// something that is not here".
    private(set) var inputResolution: AudioInputSelection.Resolution = .systemDefault

    /// Empty means "follow the system".
    ///
    /// A setting rather than `Locale.current`, because the system locale answers
    /// a different question. Measured on this machine: `en_US@rg=eszzzz` — US
    /// language, Spain region — which resolves to an English model and then
    /// transcribes spoken Spanish into English-sounding nonsense. Nothing in the
    /// region subtag can tell us which language you intend to speak.
    var localeIdentifier: String = Defaults.string("dictation.locale", default: "") {
        didSet {
            guard localeIdentifier != oldValue else { return }
            Defaults.set(localeIdentifier, "dictation.locale")
            // The localized app aliases are keyed to the dictation languages,
            // so a cache warmed for the old ones must not run out its clock.
            assistant?.noteSpokenLanguagesChanged()
            Task { await prepare() }
        }
    }

    /// A second language recognised over the same audio, empty for off.
    ///
    /// There is no automatic language detection to switch on — `SpeechTranscriber`
    /// takes one locale and has no multilingual mode — so this is how a bilingual
    /// user gets one. Both languages are recognised in the same pass and the
    /// recogniser's own confidence picks the winner (`TranscriptRace`), which
    /// means you just speak and the right one comes out.
    ///
    /// Deliberately one, not a list. Measured cost is ~1.3× for the second
    /// transcriber, and every further locale is more audio work on the same
    /// deadline — the gap between releasing the key and seeing your text.
    var secondaryLocaleIdentifier: String = Defaults.string("dictation.locale.secondary", default: "") {
        didSet {
            guard secondaryLocaleIdentifier != oldValue else { return }
            Defaults.set(secondaryLocaleIdentifier, "dictation.locale.secondary")
            assistant?.noteSpokenLanguagesChanged() // see the primary above
            Task { await prepare() }
        }
    }

    // MARK: - Observable state

    /// Where this hold is going, decided at key-down and shown for its duration.
    ///
    /// `.type` until the probe says otherwise, so the pill never flickers from
    /// "ask" to "type" — and so a probe that never answers behaves exactly like
    /// the app did before this feature existed.
    private(set) var route: DictationRoute = .type
    /// The app the transcript would be typed into, for the pill.
    private(set) var destinationName: String?
    /// Whether the hold in progress was started by the ask key. Observable so
    /// the pill can say so before a word is spoken.
    private(set) var isAsking = false

    /// Who we promised to type into. Compared at key-up: if that process has
    /// gone, the promise cannot be kept and the transcript becomes a question
    /// instead — safe in that direction, because nothing gets typed.
    @ObservationIgnored private var destinationPID: pid_t?
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    /// Set by AppDelegate. Absent means the feature is off and every hold types,
    /// which is what this app did before it existed.
    @ObservationIgnored weak var assistant: AssistantModel?
    /// The screen guide. Consulted only on the ask key, and only while it is
    /// switched on; off, the ask key behaves exactly as it always has.
    #if AIRLOCK_GUIDE
    @ObservationIgnored weak var guide: GuideController?
    #endif

    /// Where the ask key's words are going, as far as they can be told yet:
    /// "how do I…" is a guide, "what is…" is an answer, and most sentences are
    /// `.unsure` until the on-device model has heard the whole thing. Nil when
    /// the guide is off, so the chip keeps saying what it always said.
    var askRoute: GuideRouting.Route? {
        #if AIRLOCK_GUIDE
        guard let guide, guide.isEnabled else { return nil }
        return GuideRouting.route(liveText)
        #else
        return nil
        #endif
    }

    /// Puts a transcript on the clipboard when there is nowhere to type it.
    /// Wired by AppDelegate, so history suppression stays in one place.
    @ObservationIgnored var onCopyTranscript: ((String) -> Void)?

    private(set) var isListening = false {
        didSet {
            guard isListening != oldValue else { return }
            Moments.shared.announce(isListening ? .listeningStarted : .listeningStopped)
        }
    }
    /// Listening OR still tidying up. What the panel should follow.
    ///
    /// Not the same as `isListening`, and the difference was a real bug: the
    /// panel collapsed the instant the key came up, so the "Tidying up" state
    /// existed and could never be seen — leaving the pause before the text
    /// lands as unexplained as it was before the state was added.
    var isActive: Bool { isListening || isCleaning || isSorting }

    /// `isActive`, but only once it has lasted long enough to be worth drawing.
    ///
    /// Everything visual keys off this rather than `isActive`. The microphone
    /// opens the instant you press — that is what keeps the first syllable — but
    /// a hold cancelled a few milliseconds later by a chord must never have put
    /// anything on screen. Delaying the *pixels* costs nothing; delaying the
    /// *audio* cost a syllable.
    private(set) var showsIndicator = false

    /// The floor, for reveals with no gesture behind them — a refusal message
    /// has nothing to qualify.
    private static let revealDelay: Duration = .milliseconds(140)
    @ObservationIgnored private var revealTask: Task<Void, Never>?

    /// Single funnel for the visual state, so a cancelled hold cannot leave the
    /// panel open or the widgets hidden.
    ///
    /// - Parameter notBefore: the instant the gesture becomes a hold. The panel
    ///   opens THEN, not when the analyzer happens to be ready.
    ///
    ///   Those came apart when `HoldGesture.minimumHold` rose to 0.375: the
    ///   reveal was 140ms after the audio engine was up, which on a fast start
    ///   put the panel on screen well before the gesture had earned it. Brush
    ///   the key and the notch opened for a hold that was discarded a moment
    ///   later as too short — reported as "the notch opens almost immediately,
    ///   which should not happen". Tying the two together means one threshold
    ///   governs both what counts as a hold and what is shown for one, so they
    ///   cannot drift apart again.
    private func setIndicator(_ visible: Bool, notBefore: Date? = nil) {
        revealTask?.cancel()
        revealTask = nil
        guard visible else {
            showsIndicator = false
            // A notice is drawn on the panel, so it goes with it — and one
            // still waiting for its hold must not open the panel again.
            clearHoldNotice()
            // The CALLBACK, not this method. Calling itself here was a stack
            // overflow that killed the app between cleaning a transcript and
            // typing it — so the words were transcribed, shown, and then lost
            // along with the process.
            onListeningChanged?(false)
            return
        }
        revealTask = Task { [weak self] in
            // Whatever is left of the qualifying window, or the bare floor when
            // there is no gesture behind this. Never negative: a slow engine
            // start has already spent the wait, and the panel should not then
            // be delayed a second time for a hold that is long since committed.
            let wait = notBefore.map { Duration.seconds(max(0, $0.timeIntervalSinceNow)) }
                ?? Self.revealDelay
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.showsIndicator = true
            self.onListeningChanged?(true)
        }
    }

    /// Live text while speaking, for the panel indicator.
    private(set) var liveText = ""
    /// Live microphone level, for the meter. Polled with the text rather than
    /// pushed, because it comes off the audio thread. The last few readings,
    /// already scaled by `MicLevel`, newest last — the wave ripples them outward.
    private(set) var inputLevels: [Double] = []
    /// The last thing dictated, kept so it is recoverable when typing is
    /// blocked — a transcript we produced and then dropped on the floor would
    /// be the most frustrating failure this feature has.
    private(set) var lastTranscript: String?
    private(set) var statusMessage: String?
    /// Shown while the model is working, so the gap between releasing the key
    /// and the text appearing is explained rather than just felt.
    private(set) var isCleaning = false

    /// A hold where the level never left the floor, and the input it was
    /// listening to.
    ///
    /// Its own state rather than one more `statusMessage`, because it is the
    /// one dictation failure that is neither the user's doing nor recoverable
    /// by trying harder: the hold registered and the transcriber ran, so the
    /// fault is between the microphone and the app. A line that vanishes with
    /// the panel cannot be acted on, and the action — pick a different input —
    /// is the whole point of saying it.
    /// Nil when the last hold produced audio. Carries the cause as well as the
    /// device, because the two cases need opposite advice: one says change your
    /// input, the other says hold it longer, and for a while this said the first
    /// to people who needed the second.
    private(set) var heardNothing: SilentHold?

    struct SilentHold: Equatable {
        let device: String
        let cause: SilentCapture
    }

    /// An ask-key hold that sounded like dictation — words for a document or
    /// a coding agent, spoken on the asking key. Nil until the sort says so.
    ///
    /// A card and not a guess: the sentence is never typed on the model's
    /// word alone, for the reason `askKey` gives — intent is stated by a key,
    /// and the key said "ask". What the card offers is the one click that
    /// states it: type it after all, ask it, or be guided. Live, 2026-09-30,
    /// the sentence in this position was "Just review and analyze and come up
    /// with a plan…", and the guide took six pictures of the Claude window.
    private(set) var heardDictation: HeardDictation?

    struct HeardDictation: Equatable {
        let text: String
        /// Where it would be typed — the app that was in front.
        let app: String?
        /// False when the sort could not say (the model refused) and the card
        /// is the safe place to wait rather than a verdict.
        let certain: Bool
    }

    /// The notch's one-sentence card for a hold that could not record, or
    /// that ended somewhere other than where the words were expected — see
    /// `DictationHoldNotice`. Nil after a hold that went as it should.
    ///
    /// `statusMessage` keeps saying the same things for Settings. This is the
    /// copy that reaches the surface the person was actually watching: before
    /// it, a denied microphone or a missing speech model made the key look
    /// dead, because the only sentence about it was on a page nobody had open.
    private(set) var holdNotice: DictationHoldNotice?
    /// A blocked hold's notice, waiting for the hold to qualify. See `showNotice`.
    @ObservationIgnored private var noticeRevealTask: Task<Void, Never>?
    /// Closes the notice on its own after `DictationHoldNotice.closesAfter`.
    @ObservationIgnored private var noticeCloseTask: Task<Void, Never>?

    /// Working out whether an ask was a question, a task or a dictation.
    /// Shown like `isCleaning`, for the same reason: an unexplained pause
    /// after the key comes up reads as the app having missed it.
    private(set) var isSorting = false

    /// For the card: which key asks and which types, in the user's own
    /// settings, so "you held the wrong one" names the right one.
    var askKeyHint: String { Self.askKeyHint(askKey: askKey, holdKey: holdKey) }

    /// The same line for any pair of keys — the state gallery's way in, since
    /// it may not build this model.
    static func askKeyHint(askKey: HoldKeyMonitor.Key?, holdKey: HoldKeyMonitor.Key) -> String {
        "\(askKey?.displayName ?? "the ask key") asks · \(holdKey.displayName) types"
    }

    /// When the analyzer actually came up. The window that could have carried
    /// audio starts HERE, not at key-down — the engine start sits between the
    /// two, and on a short hold it is most of it.
    @ObservationIgnored private var listeningSince: Date?

    /// The input actually in use, for the panel to name. `nil` resolution means
    /// macOS's own default, which has no name here worth printing over the
    /// system one.
    var inputDeviceName: String {
        inputResolution.device?.name ?? "the system input"
    }

    /// Opens Settings at the input picker. Wired by whoever owns the window.
    @ObservationIgnored var onChooseInput: (() -> Void)?

    func chooseInput() {
        dismissHeardNothing()
        onChooseInput?()
    }

    func dismissHeardNothing() {
        guard heardNothing != nil else { return }
        heardNothing = nil
        setIndicator(false)
    }

    // MARK: - The notice card

    /// Opens the subscribe window. Wired by whoever owns the licence.
    @ObservationIgnored var onSubscribe: (() -> Void)?

    /// The notice card's one button.
    func fixHoldNotice() {
        guard let fix = holdNotice?.fix else { return }
        dismissHoldNotice()
        switch fix {
        case .openMicrophoneSettings:
            guard let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
            NSWorkspace.shared.open(url)
        case .chooseInput:
            chooseInput()
        case .subscribe:
            onSubscribe?()
        }
    }

    /// Takes the panel with it unless something else is still holding it: a
    /// hold in progress, or one of the two cards above.
    func dismissHoldNotice() {
        guard holdNotice != nil else { return }
        clearHoldNotice()
        guard !isActive, heardNothing == nil, heardDictation == nil else { return }
        setIndicator(false)
    }

    /// Put a notice in the notch — now, or once the hold has earned it.
    ///
    /// - Parameter notBefore: when the gesture becomes a hold, for a notice
    ///   raised at key-down. Without it, every ⌃C on a Mac with the microphone
    ///   off would flash "Airlock can't use the microphone": a blocked hold
    ///   starts no capture, so nothing else stands between a brushed modifier
    ///   and the card. A release or a chord before then calls it off (`handle`).
    private func showNotice(_ notice: DictationHoldNotice, notBefore: Date? = nil) {
        clearHoldNotice()
        let wait = notBefore?.timeIntervalSinceNow ?? 0
        guard wait > 0 else { return revealNotice(notice) }
        noticeRevealTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.noticeRevealTask = nil
            self.revealNotice(notice)
        }
    }

    /// Straight onto the panel: a notice qualifies nothing, so it skips the
    /// hold's reveal delay — the hold it reports on has already earned it.
    private func revealNotice(_ notice: DictationHoldNotice) {
        holdNotice = notice
        revealTask?.cancel()
        revealTask = nil
        showsIndicator = true
        onListeningChanged?(true)
        noticeCloseTask?.cancel()
        guard let seconds = notice.closesAfter else { return }
        noticeCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.holdNotice == notice else { return }
            self.dismissHoldNotice()
        }
    }

    private func clearHoldNotice() {
        noticeRevealTask?.cancel()
        noticeRevealTask = nil
        noticeCloseTask?.cancel()
        noticeCloseTask = nil
        holdNotice = nil
    }

    // MARK: - The "sounded like dictation" card

    /// Type it after all. Serialised behind any delivery still running, like
    /// every other transcript, so two cannot interleave their keystrokes.
    func typeHeardDictation() {
        guard let card = takeHeardDictation() else { return }
        dictationLog("typing the sorted dictation after all")
        let previous = deliveryTask
        deliveryTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.typeOut(card.text, reason: .released)
        }
    }

    func askHeardDictation() {
        guard let assistant, assistant.isEnabled, let card = takeHeardDictation() else { return }
        setIndicator(false)
        assistant.ask(card.text)
    }

    /// Only the guide's sort raises the card, so without the guide this
    /// button is never on screen to be pressed.
    func guideHeardDictation() {
        #if AIRLOCK_GUIDE
        guard let guide, guide.isEnabled, let card = takeHeardDictation() else { return }
        setIndicator(false)
        guide.start(goal: card.text)
        #endif
    }

    func dismissHeardDictation() {
        guard takeHeardDictation() != nil else { return }
        setIndicator(false)
    }

    /// Whether the card may offer an answer — the assistant can be off.
    var canAskHeardDictation: Bool { assistant?.isEnabled == true }

    /// Each button clears the card first, so a second click cannot type the
    /// same sentence twice. The words stay in `lastTranscript` either way.
    private func takeHeardDictation() -> HeardDictation? {
        defer { heardDictation = nil }
        return heardDictation
    }

    /// What cleanup can and cannot do on this Mac.
    var cleanupAvailability: ModelAvailability { cleanup.availability }
    private(set) var availableLocales: [Locale] = []
    private(set) var readiness = DictationReadiness(blocker: .disabled, canType: false,
                                                    canWatchHoldKey: true)

    /// Raised when dictation takes over, so the notch can show it is listening.
    var onListeningChanged: ((Bool) -> Void)?

    // MARK: - Machinery

    @ObservationIgnored private let toggle = WidgetToggle(key: "dictation.enabled", defaultValue: false)
    @ObservationIgnored private let holdMonitor = HoldKeyMonitor()
    @ObservationIgnored private let askMonitor = HoldKeyMonitor()

    /// What the last `applyHotkey` measured, not what is true right now.
    ///
    /// Stored rather than read live inside `refreshReadiness`, because readiness
    /// is recomputed from several places that have nothing to do with the taps —
    /// including before any tap exists, where a live read would answer `.absent`
    /// and put a permission warning on screen for a hotkey that has simply not
    /// been started yet. It starts `.live` for the same reason: the honest
    /// default for "not measured" is "no problem found", and a warning that
    /// appears before the check has run teaches people to ignore warnings.
    @ObservationIgnored private var holdKeyHealth: EventTapHealth = .live

    /// Nil when the hold key works. Observed, because the two faults need
    /// opposite advice and the pane draws a different button for each.
    private(set) var holdKeyFault: HoldKeyFault?

    /// Which key started the hold currently in progress.
    @ObservationIgnored private var intent: DictationIntent = .dictate
    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private let session = SpeechSession()
    @ObservationIgnored private var gesture = HoldGesture()
    /// Bumped whenever a hold is abandoned out from under itself — see
    /// `recoverFromStall`. A teardown that finally returns compares the number
    /// it started with and stays out of the way if the world has moved on.
    @ObservationIgnored private var holdGeneration = 0
    @ObservationIgnored private var resolvedLocale: Locale?
    @ObservationIgnored private var resolvedSecondaryLocale: Locale?
    @ObservationIgnored private var analyzerFormat: AVAudioFormat?
    @ObservationIgnored private var watchdog: Timer?
    /// Consecutive ticks that read the key as up. The watchdog is a safety net
    /// for a rare lost release, not the primary path — the real key-up event is
    /// — so it has to be slow to act. Acting on a single reading is what ended
    /// every hold at the first tick.
    @ObservationIgnored private var liveTicker: Task<Void, Never>?
    /// Serialises the async work behind the gesture. A quick tap fires down and
    /// up faster than `begin` completes, and without a chain the teardown would
    /// overtake the setup and leave an engine running with nothing to stop it.
    @ObservationIgnored private var chain: Task<Void, Never>?
    /// Delivery runs off the gesture chain but still in order against itself —
    /// two transcripts typing at once would interleave their keystrokes.
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?
    @ObservationIgnored private let cleanup = CleanupService()
    #if AIRLOCK_GUIDE
    /// Sorts an ask the routing rules could not — see `deliver`.
    @ObservationIgnored private let askIntent = AskIntentService()
    #endif
    /// Set only when WE paused it. Resuming unconditionally would start music
    /// the user had deliberately stopped before ever touching dictation.
    @ObservationIgnored private var didPauseMusic = false
    /// The armed, not-yet-taken pause. See `musicPauseDelay`.
    @ObservationIgnored private var musicPauseTask: Task<Void, Never>?

    /// The resume that has been decided but not yet performed.
    ///
    /// Held because `resumeMusicIfPaused` clears `didPauseMusic` SYNCHRONOUSLY
    /// and does the work in a task — so by the time a spoken command runs, the
    /// flag says nothing is owed and the resume is still coming. Cancelling the
    /// flag was the first fix and it never fired once.
    @ObservationIgnored private var musicResumeTask: Task<Void, Never>?
    /// Injected rather than owned — the media widget is the only thing that
    /// knows how to talk to Spotify and Music.
    @ObservationIgnored var media: MediaWidgetModel?

    /// Re-enumerated rather than cached: microphones come and go, and a stale
    /// list is how you end up offering a device that left.
    func refreshDevices() {
        availableInputs = AudioDevices.inputs()
        inputResolution = AudioInputSelection.resolve(preferredUID: inputDeviceUID,
                                                      available: availableInputs)
    }

    func start() {
        refreshDevices()
        dictationLog("start enabled=\(isEnabled) holdKey=\(holdKey.displayName) "
                     + "cleanup=\(cleansTranscript) model=\(cleanup.availability)")
        if isEnabled, cleansTranscript { cleanup.prepare(instructions: cleanupInstructions) }
        Task { await prepare() }
        applyHotkey()
    }

    // MARK: - Readiness

    private func prepare() async {
        availableLocales = await SpeechTranscriber.supportedLocales

        let preferred = localeIdentifier.isEmpty ? Locale.current : Locale(identifier: localeIdentifier)
        resolvedLocale = await SpeechSession.resolvedLocale(preferred: preferred)

        // Resolved the same way as the primary, so an unsupported identifier
        // falls away instead of failing the whole hold. Never the same locale
        // twice — racing a transcriber against itself costs 1.3× for nothing.
        if secondaryLocaleIdentifier.isEmpty {
            resolvedSecondaryLocale = nil
        } else {
            let match = await SpeechSession.resolvedLocale(
                preferred: Locale(identifier: secondaryLocaleIdentifier))
            resolvedSecondaryLocale = match?.identifier == resolvedLocale?.identifier ? nil : match
        }

        if let locale = resolvedLocale, isEnabled {
            // Reservations are per-process and empty at every launch, so this
            // runs each time rather than once ever.
            await SpeechSession.prepareModel(for: locale)
            // The secondary needs its model installed too, or it loses every
            // race silently by producing nothing.
            if let secondary = resolvedSecondaryLocale {
                await SpeechSession.prepareModel(for: secondary)
            }

            let locales = [locale] + (resolvedSecondaryLocale.map { [$0] } ?? [])
            analyzerFormat = await SpeechSession.analyzerFormat(for: locales)

            // A second language must never be able to take dictation down with
            // it. If no format suits both, the secondary is what gets dropped.
            if analyzerFormat == nil, resolvedSecondaryLocale != nil {
                dictationLog("  no shared audio format with "
                             + "\(resolvedSecondaryLocale?.identifier ?? "") — secondary dropped")
                resolvedSecondaryLocale = nil
                analyzerFormat = await SpeechSession.analyzerFormat(for: [locale])
            }
        } else {
            analyzerFormat = nil
        }
        refreshReadiness()
    }

    private func refreshReadiness() {
        let microphone: MicrophoneAuthorization
        switch AVAudioApplication.shared.recordPermission {
        case .granted: microphone = .granted
        case .denied: microphone = .denied
        default: microphone = .undetermined
        }
        readiness = DictationReadiness.evaluate(
            isEnabled: isEnabled,
            isBundled: AppBundle.isBundled,
            microphone: microphone,
            // The only trustworthy readiness signal — `AssetInventory.status`
            // reported `.supported` for a locale whose model was installed and
            // working, so it cannot be used for this.
            hasSpeechModel: analyzerFormat != nil,
            locale: resolvedLocale?.identifier ?? localeIdentifier,
            isTrustedToType: TypeService.isTrusted,
            isWatchingHoldKey: holdKeyHealth.isLive)
    }

    /// Ask for the microphone. Only ever from an explicit user action — a
    /// background app that prompts at launch is one people deny reflexively.
    func requestMicrophoneAccess() async {
        guard AppBundle.isBundled else { return refreshReadiness() }
        _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        await prepare()
    }

    /// Ask for Input Monitoring, then rebuild the taps.
    ///
    /// The rebuild is the part that is easy to leave out and the part that
    /// matters: a tap WindowServer has already narrowed stays narrowed for its
    /// whole life, so granting the permission does nothing for the tap that was
    /// created under the refusal. `applyHotkey` tears both down and makes them
    /// again, which is also what re-measures `holdKeyHealth` — so the pane the
    /// user is looking at updates from a fresh reading rather than from the
    /// assumption that asking worked.
    ///
    /// Returns whether the hotkey is live afterwards, so the caller can offer
    /// System Settings when macOS declined to prompt — which it does for every
    /// app it has already asked about once.
    @discardableResult
    func requestInputMonitoring() -> Bool {
        InputMonitoring.request()
        applyHotkey()
        return readiness.canWatchHoldKey
    }

    /// Re-measure without touching anything.
    ///
    /// For coming back from System Settings, where the permission is granted
    /// outside this process with no notification worth observing. It rebuilds
    /// the taps for the reason above: a narrowed tap does not heal.
    func recheckHoldKey() { applyHotkey() }

    // MARK: - Hotkey

    private func applyHotkey() {
        holdMonitor.stop()
        askMonitor.stop()
        guard isEnabled else {
            dictationLog("hold monitor NOT started — dictation is disabled")
            // Nothing is being watched, but nothing is meant to be. Clearing
            // these stops a stale failure from an earlier run being drawn as a
            // permission problem against a switch the user turned off.
            holdKeyHealth = .live
            holdKeyFault = nil
            refreshReadiness()
            return
        }
        let ok = holdMonitor.start(
            key: holdKey,
            onDown: { [weak self] in
                dictationLog("hold DOWN")
                self?.beginHold(.dictate)
            },
            onUp: { [weak self] in
                dictationLog("hold UP")
                self?.handle(.keyUp(at: Date()))
            },
            onCancel: { [weak self] in
                self?.handle(.cancel)
            })
        holdMonitor.onCancelReason = { reason in
            dictationLog("hold CANCELLED — \(reason)")
        }
        dictationLog("holdMonitor(\(holdKey.displayName)) → \(ok ? "ok" : "FAILED")")

        // The ask key is a second tap on a different modifier. Both feed ONE
        // gesture and one microphone: `beginHold` refuses a second start while a
        // hold is live, so pressing both never opens two captures on the same
        // input device.
        if let askKey, askKey != holdKey, assistant?.isEnabled == true {
            let askOK = askMonitor.start(
                key: askKey,
                onDown: { [weak self] in
                    dictationLog("ask DOWN")
                    self?.beginHold(.ask)
                },
                onUp: { [weak self] in
                    dictationLog("ask UP")
                    self?.handle(.keyUp(at: Date()))
                },
                onCancel: { [weak self] in
                    self?.handle(.cancel)
                })
            askMonitor.onCancelReason = { reason in
                dictationLog("ask CANCELLED — \(reason)")
            }
            dictationLog("askMonitor(\(askKey.displayName)) → \(askOK ? "ok" : "FAILED")")
        }

        reportHoldKeyHealth(created: ok)
    }

    /// Say whether the hotkey actually works, rather than whether asking for it
    /// returned something.
    ///
    /// **The bug this replaces.** `applyHotkey` logged `holdMonitor(⌃ Control) →
    /// ok` and set a status message only when `tapCreate` returned nil. That
    /// return means nothing: a process with no event-listening access gets a
    /// port back and receives nothing, forever. So the log said ok, Settings
    /// said every permission was granted, and holding the key did nothing —
    /// three surfaces agreeing on a state none of them had checked. And the one
    /// message that did exist named **Accessibility**, which is not the
    /// permission involved, so anyone who followed it granted something already
    /// granted and came back no better off.
    private func reportHoldKeyHealth(created: Bool) {
        holdKeyHealth = created ? HoldKeyMonitor.health() : .absent
        let granted = InputMonitoring.isGranted
        holdKeyFault = EventTapCheck.fault(health: holdKeyHealth, isListenEventGranted: granted)
        dictationLog("holdMonitor tap health: \(describe(holdKeyHealth)) "
                     + "listenEventGranted=\(granted) "
                     + "fault=\(holdKeyFault.map { "\($0)" } ?? "none")")
        refreshReadiness()
        guard let holdKeyFault else { return }

        // A hold that does nothing produces no window, no sound and no error, so
        // the in-notch status line is a message delivered to a surface that
        // nothing has caused the user to look at. This is the one failure in
        // dictation with no visible symptom at all, which makes it the one that
        // most needs the channel that survives Airlock not being frontmost.
        switch holdKeyFault {
        case .notGranted:
            statusMessage = "Holding \(holdKey.displayName) does nothing — Airlock needs "
                + "Input Monitoring. Settings › Permissions has the button."
            Notifications.post(
                title: "Airlock can't see your dictation key",
                body: "Holding \(holdKey.displayName) won't start dictation until Airlock is "
                    + "allowed in Privacy & Security › Input Monitoring.",
                identifier: Notifications.ID.inputMonitoringMissing,
                opens: SettingsAnchor.permissionInputMonitoring)
        case .grantIsNotWorking:
            // Never send this one to "grant the permission": it is granted, and
            // the person has almost certainly just looked at the tick. Saying
            // "allow it" to somebody staring at it already allowed is how an
            // app loses the benefit of the doubt.
            // Never points at a row in System Settings: the pane is usually
            // EMPTY for this app, and a broken record shows nothing to remove.
            // Settings › Permissions has the command and a button to copy it.
            statusMessage = "Holding \(holdKey.displayName) does nothing, even though macOS says "
                + "it is allowed — a stale permission record. Settings › Permissions has the fix."
            Notifications.post(
                title: "Airlock's keyboard permission is stale",
                body: "macOS says it is allowed but it isn't working. Settings › Permissions "
                    + "has the one command that clears it.",
                identifier: Notifications.ID.inputMonitoringMissing,
                opens: SettingsAnchor.permissionInputMonitoring)
        }
    }

    /// Hex, because the missing bits are the diagnosis: a mask that kept
    /// `flagsChanged` and lost `keyDown` (`0x400`) is WindowServer refusing an
    /// untrusted process, not a mistake in the mask we asked for.
    private func describe(_ health: EventTapHealth) -> String {
        switch health {
        case .live: return "live"
        case .absent: return "ABSENT — no tap for this process"
        case .inert(let isEnabled, let missing):
            return String(format: "INERT enabled=%@ missingEvents=0x%llx",
                          isEnabled ? "1" : "0", missing)
        }
    }

    /// Start a hold with a stated intent, or ignore it if one is already live.
    ///
    /// The guard is what makes two taps safe: holding both modifiers cannot open
    /// a second `AudioCapture` on the same microphone, and whichever key went
    /// down first owns the hold.
    /// Whether voice is paid up. Voice is the second paid surface — see
    /// `Entitlement.allowsUse` — and unlike the agent surface it has no
    /// card of its own to put a message on, because a hold happens while you are
    /// looking at another app entirely.
    @ObservationIgnored var isEntitled: (() -> Bool)?
    /// Lifetime counts for the trial's last-day card — see `UsageTally`.
    @ObservationIgnored var tally: UsageTallyStore?

    /// Noted at the start of every hold, and only when it is on.
    ///
    /// This is the one line that turns "dictation fired while I was deleting a
    /// word" from unattributable into obvious: with secure input held, the chord
    /// that should have cancelled this hold is invisible to us, so the hold will
    /// run until the modifier comes up no matter what is typed in between.
    /// Silent when off, which is almost always — a log nobody can skim is a log
    /// nobody reads.
    ///
    /// Returns the notice for the hold, nil when secure input is off: the
    /// raised floor is why this hold's panel takes a second to open, and that
    /// pause unexplained reads as the key having been missed.
    private func noteSecureInputIfHeld() -> DictationHoldNotice? {
        guard SecureInput.isEnabled else { return nil }
        let holder = SecureInput.holderName()
        dictationLog("  secure input held by \(holder ?? "an unidentified app") — chords invisible, "
                     + "floor raised to \(HoldGesture.blindHold)s")
        return .secureInput(holder: holder)
    }

    private func beginHold(_ intent: DictationIntent) {
        let secureInput = noteSecureInputIfHeld()
        let blind = secureInput != nil
        // Refused at the START of the gesture, not at delivery. Transcribing a
        // sentence and then throwing it away would spend the microphone, the
        // model and your breath before saying no — and the status line is the
        // only surface a refused hold has.
        //
        // Said in the notch, once the hold has lasted long enough to be one —
        // a tap is not a request. It used to open the panel on a bare strip
        // that read like a hang, with the only sentence in Settings.
        guard isEntitled?() ?? true else {
            statusMessage = DictationHoldNotice.noSubscriptionSentence
            dictationLog("  \(intent.rawValue) refused — no subscription")
            showNotice(.noSubscription, notBefore: Date().addingTimeInterval(
                blind ? HoldGesture.blindHold : HoldGesture.minimumHold))
            return
        }
        if isListening {
            // Listening with a STOPPED microphone is not a state any gesture can
            // reach — every teardown stops the engine first and clears the flag
            // after. The two disagreeing means something in between stalled, and
            // refusing forever is what turned one stalled finish into dictation
            // being dead until relaunch: a panel stuck open, a microphone that
            // was not recording, and every later press answered with "a hold is
            // already running". Treat it as the wedge it is.
            guard !capture.isCapturing else {
                dictationLog("  ignoring \(intent.rawValue) — a hold is already running")
                return
            }
            dictationLog("  \(intent.rawValue) arrived on a stalled hold — resetting")
            recoverFromStall()
        }
        self.intent = intent
        isAsking = intent == .ask
        // A fresh hold answers the last one. Leaving the notice up under a live
        // microphone would be reporting silence while listening — and a card
        // offering to type the previous sentence under a new one is worse.
        heardNothing = nil
        heardDictation = nil
        // The last hold's notice too, and the panel with it when the notice was
        // all that held it open: this hold opens it again on its own terms.
        if holdNotice != nil || noticeRevealTask != nil { setIndicator(false) }
        // Drawn above the strip once this hold's panel opens, and gone when the
        // hold ends (`finishListening`, or the close of a discarded one).
        holdNotice = secureInput
        // Enumerate the Shortcuts library NOW, while the key is going down,
        // so the subprocess overlaps the speaking instead of delaying the card.
        // Cheap and cached — see `AssistantModel.refreshShortcutsIfStale`.
        // Whatever the intent: a receipt from the last action must not still be
        // on screen while this one is spoken. See `clearFinishedPresentation`.
        assistant?.clearFinishedPresentation()
        if intent == .ask {
            assistant?.refreshShortcutsIfStale()
            // Warm the sort while the key is going down, for the same reason:
            // the model's first call is the slow one, and it overlaps the
            // speaking instead of following it.
            #if AIRLOCK_GUIDE
            if guide?.isEnabled == true { askIntent.prepare() }
            #endif
        }
        // BOTH intents, unlike the Shortcuts enumeration above (a subprocess,
        // wanted only where a command card might need it). The apps scan is
        // three shallow directory reads, and it feeds `recognitionVocabulary`
        // — plain dictation wants the recogniser to know "Claude" and
        // "Xcode" exactly as much as a command does.
        assistant?.refreshAppsIfStale()
        // The floor for THIS hold, fixed before the key-down is applied.
        //
        // Raised only while secure input is held, because that is exactly when
        // `HoldKeyMonitor` cannot see the ⌫ that would otherwise disqualify the
        // hold. Note what this does NOT do: capture still starts immediately,
        // below, so the syllable-clipping the comment there records is not
        // reintroduced. Only the threshold for *delivering* the hold — and for
        // showing the panel — moves.
        if !gesture.isRecording {
            gesture = HoldGesture(floor: blind ? HoldGesture.blindHold : HoldGesture.minimumHold)
        }
        // Immediately. A 120ms grace was tried here to keep a fast ⌥⌫ from ever
        // opening the microphone, and it clipped the first syllable of anyone
        // who starts speaking quickly — measured, not theorised. Losing the
        // start of a sentence is a defect; a briefly-blinking recording
        // indicator is a cosmetic annoyance, and the chord cancel in
        // `HoldKeyMonitor` is what actually stops chords becoming dictations.
        handle(.keyDown(at: Date()))
    }

    private func handle(_ event: HoldGesture.Event) {
        // A blocked hold resets the gesture, so its release reaches nothing
        // below — but it still has to call off a notice waiting for the hold
        // to qualify. Once shown, a notice is not this release's to take back.
        switch event {
        case .keyUp, .cancel:
            noticeRevealTask?.cancel()
            noticeRevealTask = nil
        case .keyDown, .tick:
            break
        }
        guard let effect = gesture.apply(event) else { return }
        switch effect {
        case .startCapture:
            dictationLog("  effect=startCapture (queued)")
            enqueue { await self.beginListening() }
        case .finish(let reason):
            dictationLog("  effect=finish(\(reason)) (queued)")
            enqueue { await self.finishListening(reason) }
        case .discard(let reason):
            dictationLog("  effect=discard(\(reason)) (queued)")
            enqueue { await self.discardListening(reason) }
        }
    }

    private func enqueue(_ work: @escaping () async -> Void) {
        let previous = chain
        chain = Task { await previous?.value; await work() }
    }

    // MARK: - The gesture

    private func beginListening() async {
        // Holding the dictation key IS the explicit user action that earns the
        // prompt — so ask here rather than at launch, which is the request
        // people deny reflexively. This hold is spent on the dialog; the next
        // one records. Saying so is better than a key that silently does
        // nothing, which is exactly what it did before this existed.
        if readiness.blocker == .microphoneUndetermined {
            dictationLog("microphone undetermined — asking now")
            gesture = HoldGesture()
            await requestMicrophoneAccess()
            // Named for the key that was held: an ask that answers "hold ⌃
            // again to dictate" sends someone to the wrong key.
            let again = intent == .ask
                ? "hold \(askKey?.displayName ?? "the ask key") again and ask."
                : "hold \(holdKey.displayName) again to dictate."
            statusMessage = readiness.canRecord
                ? "Microphone allowed — " + again
                : readiness.blocker?.message
            dictationLog("after request: \(readiness.blocker.map { "\($0)" } ?? "ready")")
            // At once: the hold was spent on macOS's dialog, so it has long
            // since earned a reply, and the key is probably already up.
            if readiness.canRecord {
                showNotice(.microphoneAllowed(
                    key: intent == .ask ? askKey?.displayName ?? "the ask key" : holdKey.displayName,
                    asking: intent == .ask))
            } else if let notice = readiness.blocker.flatMap(DictationHoldNotice.init) {
                showNotice(notice)
            }
            return
        }

        guard readiness.canRecord, let locale = resolvedLocale, let format = analyzerFormat else {
            dictationLog("cannot record — \(readiness.blocker.map { "\($0)" } ?? "no analyzer format")")
            statusMessage = readiness.blocker?.message
            let earned = gesture.startedAt?.addingTimeInterval(gesture.floor)
            gesture = HoldGesture() // nothing is running; do not wait for a release
            if let notice = readiness.blocker.flatMap(DictationHoldNotice.init) {
                showNotice(notice, notBefore: earned)
            }
            return
        }
        // Concurrent with the engine, never before it. The probe is bounded at
        // 0.2s per AX call, and spending that before the first buffer would clip
        // the opening word of every dictation — the one failure this feature is
        // not allowed to introduce.
        startFocusProbe()

        do {
            dictationLog("  starting audio engine…")
            // Re-resolved at the moment of use, not at launch: a microphone
            // can be unplugged between the two.
            refreshDevices()
            let stream = try capture.start(analyzerFormat: format,
                                           deviceUID: inputResolution.device?.uid ?? "")
            dictationLog("  engine up; starting analyzer…")
            // What the recogniser should expect to hear — see
            // `SpeechSession.begin`. Read at the moment of starting, from the
            // caches the key-down warm just refreshed; empty only with no
            // assistant wired, which is only tests.
            let vocabulary = assistant?.recognitionVocabulary ?? []
            if !vocabulary.isEmpty { dictationLog("  vocabulary: \(vocabulary.count) names") }
            try await session.begin(locale: locale,
                                    secondary: resolvedSecondaryLocale,
                                    vocabulary: vocabulary,
                                    input: stream)
            dictationLog("  analyzer up; listening")
            isListening = true
            listeningSince = Date()
            liveText = ""
            statusMessage = nil
            // AFTER `isListening`, which the armed task checks before firing.
            schedulePauseMusic()
            // From the KEY going down, not from here — the engine start sits
            // between the two and is most of a short hold.
            setIndicator(true, notBefore: gesture.startedAt?
                .addingTimeInterval(gesture.floor))
            startWatchdog()
            startLiveTicker()
        } catch {
            dictationLog("  capture start failed: \(error.localizedDescription)")
            statusMessage = "The microphone couldn't start. Try again in a moment."
            let earned = gesture.startedAt?.addingTimeInterval(gesture.floor)
            capture.stop()
            gesture = HoldGesture()
            isListening = false
            setIndicator(false)
            // Behind the same floor as a blocked hold: an engine that will not
            // start fails in milliseconds, well before a brushed key is known
            // to be a tap.
            showNotice(.microphoneFailedToStart, notBefore: earned)
        }
    }

    private func finishListening(_ reason: HoldGesture.Finish) async {
        let generation = holdGeneration
        stopTimers()
        // MUST come first: `finalizeAndFinishThroughEndOfInput` waits on the
        // input sequence ending, so finishing the session against a live stream
        // never returns.
        capture.stop()
        let peak = capture.peakLevel
        // Measured before the flag is cleared, and against the analyzer coming
        // up rather than the key going down. See `listeningSince`.
        let listenedFor = listeningSince.map { Date().timeIntervalSince($0) } ?? 0
        // Nothing heard in a window too short to hear anything: there is
        // nothing to finalise, and the finalise is the call that hangs on an
        // empty input (`SpeechSession.finish`). Live, 2026-10-01: the engine
        // took four seconds to start, the key came up the moment it was
        // listening, and the panel said "recording" for ten seconds over a
        // stopped microphone until the timeout. A second is plenty here.
        let empty = SilentCapture.diagnose(peak: peak, listenedFor: listenedFor) == .tooShort
        let heard = await session.finish(within: empty ? .seconds(1) : .seconds(10))
        // A stalled finish that eventually returns must not land on a dictation
        // that started without it — see `recoverFromStall`.
        guard generation == holdGeneration else {
            dictationLog("  finish for a hold that was already reset — dropping it")
            return
        }
        listeningSince = nil
        isListening = false
        liveText = ""
        inputLevels = []
        resumeMusicIfPaused()
        // It explained this hold's wait to open, and the hold is over.
        if case .secureInput = holdNotice { clearHoldNotice() }

        // Delivery leaves the gesture chain here, deliberately.
        //
        // Cleanup takes about a second, and the chain serialises everything the
        // gesture does. Holding it for that second meant a second dictation
        // begun in the window — pressing the key again right after speaking,
        // which is exactly what people do — queued its `beginListening` behind
        // the cleanup and started recording partway through the sentence. The
        // opening words vanished with no error and no clue.
        //
        // The microphone and the analyzer are finished with by this point;
        // cleanup and typing need only the text. So they run outside, and the
        // chain is free for the next hold immediately.
        deliver(heard, peak: peak, listenedFor: listenedFor, reason: reason)
    }

    /// Cleanup, then keystrokes. Runs off the gesture chain — see `finishListening`.
    private func deliver(_ heard: String, peak: Float, listenedFor: TimeInterval,
                         reason: HoldGesture.Finish) {
        let previous = deliveryTask
        deliveryTask = Task { @MainActor [weak self] in
            // Still serialised against ITSELF: two transcripts typing into the
            // same document at once would interleave their keystrokes.
            await previous?.value
            guard let self else { return }

            dictationLog("heard \(DictationDiagnostics.redact(heard)) peak=\(peak)")
            guard let spoken = DictationText.prepared(heard) else {
                // Peak level is what separates "you said nothing" from "no
                // audio arrived at all" — identical outcomes otherwise, and only
                // one is the user's doing. A live level with no words means the
                // transcriber found none, which is not locatable.
                //
                // How long the window was open is what separates the two flat
                // cases, and leaving it out is what made this card confidently
                // wrong: see `SilentCapture`.
                if let cause = SilentCapture.diagnose(peak: peak, listenedFor: listenedFor) {
                    self.heardNothing = SilentHold(device: self.inputDeviceName, cause: cause)
                    self.statusMessage = nil
                    // Deliberately NOT hidden: this is the one status the user
                    // has to be able to act on, and it carries a button.
                    return
                }
                self.statusMessage = "Didn't catch anything."
                self.showNotice(.nothingCaught)
                return
            }

            // The fork, and it turns on which KEY was held — never on what the
            // probe saw. Detection decides only where typed text can land.
            //
            // `spoken` goes in RAW, and skipping cleanup here is the point
            // rather than an optimisation: `TranscriptCleanup.vetted` exists
            // specifically to stop the model answering a dictated question and
            // typing the answer into your document. In ask mode answering is
            // what we want, so vetting would reject every correct result — and
            // skipping it drops a model round-trip out of the latency budget.
            #if AIRLOCK_GUIDE
            if self.intent == .ask, await self.routeAsk(spoken) { return }
            #endif
            if self.intent == .ask, let assistant = self.assistant, assistant.isEnabled {
                dictationLog("asking the notch \(DictationDiagnostics.redact(spoken))")
                self.lastTranscript = spoken
                self.setIndicator(false)
                assistant.ask(spoken)
                return
            }
            await self.typeOut(spoken, reason: reason)
        }
    }

    #if AIRLOCK_GUIDE
    /// Where an ask goes, with the guide on. False means: not the guide, not
    /// the card — answer it, or type it if nothing answers.
    ///
    /// **The guide starts only on a confident Mac action**, and the rules and
    /// the model share that bar. Rules first, because "how do I…" needs no
    /// model and the chip has already said "Guide" while it was being spoken.
    /// Then, for everything the words alone could not settle, the on-device
    /// model sorts the sentence with the front app in view — a dictation for
    /// Claude Code and a task in Safari begin with the same verbs. Live,
    /// 2026-09-30, the default the other way round sent six screenshots of the
    /// Claude window to a cloud model for a sentence meant for me to type.
    ///
    /// A dictation is never typed on the model's word: the key said "ask", and
    /// the card puts the one click that says otherwise in front of the person.
    private func routeAsk(_ spoken: String) async -> Bool {
        guard let guide, guide.isEnabled else { return false }
        switch GuideRouting.route(spoken) {
        case .guide:
            startGuide(spoken, because: "rule")
            return true
        case .chat:
            return false
        case .unsure:
            isSorting = true
            let sorted = await askIntent.sort(spoken, frontApp: destinationName)
            isSorting = false
            dictationLog("sorted as \(sorted.map { "\($0.intent.rawValue)\($0.certain ? "" : " (unsure)")" } ?? "no model")"
                         + " in front of \(destinationName ?? "an unnamed app") \(DictationDiagnostics.redact(spoken))")
            switch sorted?.intent {
            case .action:
                startGuide(spoken, because: "sort")
                return true
            case .dictation:
                // The panel stays up: this is a status the person has to be
                // able to act on, and it carries the buttons.
                lastTranscript = spoken
                statusMessage = nil
                heardDictation = HeardDictation(text: spoken, app: destinationName,
                                                certain: sorted?.certain ?? false)
                return true
            case .question, nil:
                return false
            }
        }
    }

    private func startGuide(_ goal: String, because reason: String) {
        guard let guide else { return }
        dictationLog("guiding (\(reason)) \(DictationDiagnostics.redact(goal))")
        lastTranscript = goal
        setIndicator(false)
        guide.start(goal: goal)
    }
    #endif

    /// Cleanup, then keystrokes — or the clipboard when there is nowhere to
    /// type. The tail of every dictation, and of an ask the card sent back to
    /// be typed after all.
    private func typeOut(_ spoken: String, reason: HoldGesture.Finish) async {
        // Between transcription and typing, never after: the text that
        // reaches the document and the text recorded as "last dictation"
        // have to be the same thing, or the recovery path shows something
        // you never got.
        var text = spoken
        var tidyingFailed = false
        if self.cleansTranscript {
            self.isCleaning = true
            text = await self.cleanup.clean(spoken, instructions: self.cleanupInstructions)
            self.isCleaning = false
            if text != spoken {
                dictationLog("cleaned → \(DictationDiagnostics.redact(text))")
            }
            if let rejection = self.cleanup.lastRejection {
                self.statusMessage = rejection
                tidyingFailed = true
            }
        }

        self.lastTranscript = text

        // Nothing in front can take text. Typing anyway is what sent a
        // dictation into Gmail's keyboard shortcuts, so the words go to the
        // clipboard instead — recoverable, visible, and inert until pasted.
        // One decision, in Core, tested — see `DictationDelivery`. Written as
        // two separate `if`s here, the second one lost the transcript.
        let settled = self.settledRoute()
        let delivery = DictationDelivery.decide(route: settled,
                                                isAccessibilityTrusted: TypeService.isTrusted)
        let copies = delivery == .copy && settled == .copy

        // The panel closes here as it always did — unless there is something
        // to say about this hold, which takes the panel's place instead of
        // closing it and opening it again a moment later.
        if let notice = DictationHoldNotice.afterDelivery(copied: copies,
                                                          reachedLimit: reason == .reachedLimit,
                                                          tidyingFailed: tidyingFailed) {
            self.showNotice(notice)
        } else {
            self.setIndicator(false)
        }

        if copies {
            dictationLog("copying \(DictationDiagnostics.redact(text)) — nowhere to type")
            self.onCopyTranscript?(text)
            self.statusMessage = "Nothing to type into — copied to your clipboard."
            return
        }

        dictationLog("typing \(DictationDiagnostics.redact(text)) axTrusted=\(TypeService.isTrusted)")
        guard await TypeService.type(text) else {
            // THE SAME FALLBACK THE `.copy` ROUTE ABOVE GETS, and it was
            // missing here. Without Accessibility the words were
            // transcribed and then thrown away — the one surface saying so
            // was a status line in the notch, which by construction is not
            // where you are looking: dictation types into OTHER apps, so it
            // fails precisely when the panel is out of sight.
            //
            // The Permissions pane already promises this exact behaviour —
            // "dictation still listens and still transcribes, it just puts
            // the result on the clipboard instead of typing it" — so this is
            // a promise the app made and did not keep, not a new idea.
            // `type` returns false for two different reasons and only one of
            // them is a permission: it also gives up if `CGEvent` creation
            // fails part-way through a long transcript. Blaming
            // Accessibility there sends somebody to a pane where Airlock is
            // already ticked — the same wrong-permission trap that cost a
            // day on the hold key. The words reach the clipboard either way;
            // only the sentence differs.
            let trusted = TypeService.isTrusted
            dictationLog("  could not type (axTrusted=\(trusted)) — copying instead")
            // Whatever the notice said about this hold assumed it was typed.
            self.dismissHoldNotice()
            self.onCopyTranscript?(text)
            self.statusMessage = trusted
                ? "Couldn't type that one — copied to your clipboard instead."
                : "Copied to your clipboard — grant Accessibility to type it instead."
            guard !trusted else {
                self.refreshReadiness()
                return
            }
            // The status line above is in the notch, and dictation types
            // into OTHER apps — so at the moment this fails, that surface is
            // behind whatever the user is working in. A notification is the
            // only channel that survives not being frontmost.
            //
            // Not the transcript. What they said is theirs and could be
            // anything; the body says where it went, not what it was.
            Notifications.post(
                title: "Airlock needs Accessibility to type",
                body: "Your dictation was copied to the clipboard instead. "
                    + "Settings › Permissions explains how to grant it.",
                identifier: Notifications.ID.accessibilityMissing,
                opens: SettingsAnchor.permissionAccessibility)
            self.refreshReadiness()
            return
        }
        // Counted where the text actually LANDED, not where the hold
        // ended: a transcript that failed to type is not a dictation the
        // app did for you, and the trial card must not claim it.
        self.tally?.recordDictation()
        self.statusMessage = reason == .reachedLimit
            ? "Stopped at the two-minute limit." : nil
    }

    // MARK: - Routing

    /// Work out where this hold is going, without holding anything up.
    private func startFocusProbe() {
        route = .type
        destinationName = NSWorkspace.shared.frontmostApplication?.localizedName
        destinationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        probeTask?.cancel()
        guard assistant?.isEnabled == true else { return }

        probeTask = Task { [weak self] in
            let probe = await FocusProbe.current()
            guard let self, !Task.isCancelled else { return }
            self.route = DictationRoute.decide(probe)
            dictationLog("  focus probe → \(probe.shortDescription) route=\(self.route.rawValue)")
        }
    }

    /// The route to actually honour, checked against reality one last time.
    ///
    /// An app that quit mid-hold cannot be typed into, and the words are not
    /// thrown away for it — they go to the clipboard like any other unroutable
    /// dictation.
    private func settledRoute() -> DictationRoute {
        guard route == .type, let pid = destinationPID else { return route }
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            dictationLog("  destination app exited during the hold — copying instead of typing")
            return .copy
        }
        return .type
    }

    /// How long a hold must survive before it is allowed to touch playback.
    ///
    /// **A chord must never stop the music, and this is what buys that.** The
    /// hold keys are bare modifiers, so ⌃⌥← — Magnet's window shortcut — comes
    /// down as control-alone for a few milliseconds before the option joins.
    /// That was long enough to start a capture and pause Spotify, and the
    /// measured result was worse than a stutter (see `resumeMusicIfPaused`):
    ///
    ///     ask DOWN / paused playback / ask CANCELLED — another modifier joined
    ///     hold DOWN / paused playback / discard(tooShort)
    ///
    /// Both monitors fired, both paused, neither resumed. Waiting means the
    /// chord cancels first and playback is never touched at all.
    ///
    /// The cost is real and is the reason this is not longer: for a whole second
    /// the microphone hears the music it is meant to be spared. That trade is
    /// only taken by people who switched `pausesMusic` on, and it is one
    /// constant to change.
    private static let musicPauseDelay: Duration = .seconds(1)

    /// Arm the pause rather than take it. Cancelled by `resumeMusicIfPaused`,
    /// which every ending path calls — finish, discard and stall recovery alike.
    private func schedulePauseMusic() {
        guard pausesMusic, media?.state?.isPlaying == true else { return }
        musicPauseTask?.cancel()
        musicPauseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.musicPauseDelay)
            guard !Task.isCancelled, let self, self.isListening else { return }
            self.pauseMusicIfWanted()
        }
    }

    /// Only pauses what is actually playing, and remembers that it did.
    private func pauseMusicIfWanted() {
        // `didPauseMusic` first: two monitors can each reach here for one
        // gesture, and `state` is a POLL — within the same tick it still reads
        // "playing", so a second call toggled playback straight back on and left
        // the flag set. One pause per hold, tracked by us rather than inferred.
        guard !didPauseMusic, pausesMusic, let media,
              media.state?.isPlaying == true else { return }
        media.togglePlay()
        didPauseMusic = true
        dictationLog("paused playback for the duration of the hold")
    }

    /// True while dictation has paused this track for the hold and not put it
    /// back — so a spoken command can tell "the user paused this" from "we did,
    /// a second ago, and they never saw it stop".
    var pausedPlaybackForHold: Bool { didPauseMusic || musicResumeTask != nil }

    /// Give up the resume, because something the user asked for has taken over
    /// the player.
    ///
    /// **The bug this fixes looked exactly like the command not working.**
    /// Dictation pauses playback for the duration of a hold; "pause the music"
    /// then arrives at a player that is ALREADY paused, so the media arm
    /// correctly does nothing and reports success — and a moment later the
    /// resume runs and the music comes back. Net effect: a command that
    /// executed perfectly, logged `ok=true`, and visibly did the opposite.
    ///
    /// Called from the performer rather than inferred here, because only the
    /// performer knows the user commanded the transport at all.
    func forgetPausedMusic() {
        // The IN-FLIGHT RESUME, not the flag. `resumeMusicIfPaused` clears
        // `didPauseMusic` synchronously and then does the work inside a task —
        // it has to, because it must `await media.refresh()` before deciding —
        // so a command performed afterwards sees a flag saying nothing is owed
        // while the resume is still queued behind an await. Guarding on the flag
        // was the first attempt at this and it did not fire a single time.
        let owed = didPauseMusic || musicResumeTask != nil
        musicPauseTask?.cancel()
        musicPauseTask = nil
        musicResumeTask?.cancel()
        musicResumeTask = nil
        didPauseMusic = false
        guard owed else { return }
        dictationLog("not resuming playback — the spoken command owns the player now")
    }

    private func resumeMusicIfPaused() {
        musicPauseTask?.cancel()
        musicPauseTask = nil
        guard didPauseMusic, let media else { return }
        didPauseMusic = false
        // Refreshed BEFORE deciding, because the check below is the whole point
        // and `state` is a poll that stops running once nothing is playing —
        // read cold it can still say "playing" seconds after we paused it, which
        // is exactly how a resume went missing.
        // Held, so `forgetPausedMusic` can call it off. Every `return` below is
        // reached after an `await`, which is exactly the window a spoken media
        // command lands in.
        musicResumeTask = Task { @MainActor in
            await media.refresh()
            guard !Task.isCancelled else { return }
            // Only if it is still stopped: the user may have started something
            // else mid-hold, and restarting over that would be worse than doing
            // nothing.
            guard media.state?.isPlaying == false else {
                dictationLog("not resuming playback — something else is playing")
                return
            }
            media.togglePlay()
            dictationLog("resumed playback")
            self.musicResumeTask = nil
        }
    }

    private func discardListening(_ reason: HoldGesture.Discard) async {
        stopTimers()
        capture.stop()
        await session.abandon()
        isListening = false
        liveText = ""
        inputLevels = []
        resumeMusicIfPaused()
        setIndicator(false)
        // A tap is not an error. Saying "too short" every time someone brushes
        // the key would be nagging about a non-event.
        if reason == .cancelled { statusMessage = nil }
    }

    private func cancelEverything() {
        handle(.cancel)
    }

    /// Abandon a hold that a global chord started by accident.
    ///
    /// **This is what makes a hotkey like ⌥Space usable at all.** The hold keys
    /// are bare modifiers (`holdKey` ⌃, `askKey` ⌥ by default), and a Carbon
    /// hotkey only swallows the KEY — the modifier still reaches this monitor
    /// through `flagsChanged`, so ⌥ down opens the microphone before Space ever
    /// fires. Left alone, releasing ⌥ then delivers an empty transcript over the
    /// top of whatever the chord just opened.
    ///
    /// `.cancel` is the event `HoldGesture` already has for being torn down from
    /// outside: capture stops, nothing is transcribed, nothing is delivered, and
    /// the release that follows lands on an idle machine. The microphone is open
    /// for as long as the chord takes to press, which is the honest cost of
    /// binding a chord to a key that also means "listen".
    func abandonHoldForChord() {
        guard gesture.isRecording else { return }
        dictationLog("hold abandoned — a global chord fired on the same modifier")
        handle(.cancel)
    }

    /// Put a wedged hold back to idle, synchronously and without awaiting
    /// anything that might be the thing that is wedged.
    ///
    /// `chain` is dropped rather than drained. It is what serialises the
    /// gesture, so a task stuck inside it blocks every effect queued behind it
    /// — including the very cancel that would have cleared this. A fresh chain
    /// is the only way past; the old task is left suspended, holding nothing.
    ///
    /// `holdGeneration` is what stops the stall winning if it ever wakes up: the
    /// finish it belongs to checks the number it started with before touching
    /// anything, so a transcript from a dictation two holds ago cannot close the
    /// panel or type itself into the middle of the current one.
    private func recoverFromStall() {
        stopTimers()
        capture.stop()
        holdGeneration &+= 1
        chain = nil
        isListening = false
        liveText = ""
        inputLevels = []
        statusMessage = nil
        gesture = HoldGesture()
        resumeMusicIfPaused()
        setIndicator(false)
        Task { await session.abandon() } // fire and forget, for the same reason
    }

    // MARK: - Timers

    /// Polls the PHYSICAL key state, which is the whole point: it is the one
    /// source that cannot have missed the release event we may never be sent.
    /// Enforces the duration ceiling, and nothing else.
    ///
    /// It used to try to detect a missed key-up by polling the keyboard, which
    /// is how the app came to deadlock: `CGEventSource.keyState` blocks forever
    /// inside SkyLight when called from a live run loop. The event tap removed
    /// the need entirely — a release is now an ordinary event, so there is
    /// nothing to recover from and nothing to poll.
    private func startWatchdog() {
        stopTimers()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handle(.tick(at: Date(), isPhysicallyDown: true))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// Mirrors the session's transcript into observable state. The session
    /// updates a value type; SwiftUI needs to be told.
    private func startLiveTicker() {
        liveTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard let self, self.isListening else { return }
                self.liveText = self.session.transcript.display
                let level = MicLevel.scale(self.capture.currentLevel)
                self.inputLevels = Array((self.inputLevels + [level]).suffix(3))
            }
        }
    }

    private func stopTimers() {
        watchdog?.invalidate()
        watchdog = nil
        liveTicker?.cancel()
        liveTicker = nil
    }
}

/// Small typed wrappers, matching `ClipboardWidgetModel`.

