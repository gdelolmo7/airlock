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
    /// Named so the add-on list (`AddOnSwitches`) reads the same key this does.
    static let enabledKey = "dictation.enabled"

    var isEnabled: Bool = WidgetToggle.stored(DictationModel.enabledKey, default: false) {
        didSet {
            guard isEnabled != oldValue else { return }
            toggle.value = isEnabled
            if isEnabled {
                Task { await prepare() }
            } else {
                cancelEverything()
            }
            applyHotkey()
            applyPasteLastHotkey()
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

    /// A quick tap of the dictation key locks dictation on until the next
    /// tap; holding works as it always did. On by default. Never applies
    /// while another app holds secure input (`HoldGesture.locksOnTap`).
    var tapToLock: Bool = WidgetToggle.stored("dictation.tapToLock", default: true) {
        didSet { UserDefaults.standard.set(tapToLock, forKey: "dictation.tapToLock") }
    }

    /// A soft sound when dictation starts and when it stops. Its own switch,
    /// apart from Settings › General › Sounds: those are about agents.
    var playsSounds: Bool = WidgetToggle.stored("dictation.sounds", default: true) {
        didSet { UserDefaults.standard.set(playsSounds, forKey: "dictation.sounds") }
    }

    /// True while call notes are recording. Dictation makes no sound then:
    /// it would land in the call's recording. Wired by AppDelegate.
    @ObservationIgnored var isCallRecording: (() -> Bool)?

    /// Dictation is locked on by a tap: the key is up and it keeps listening
    /// until the key is tapped again or Escape is pressed.
    private(set) var isLockedOn = false

    /// The held key's symbol, for the notch's "tap to stop" line.
    var holdKeyGlyph: String { holdKey.glyph }

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

    /// "Keep history": every dictation in Settings › Dictation › History. On
    /// unless switched off; off clears nothing by itself (Clear history does).
    var keepsHistory: Bool = DictationHistoryStore.keepsHistory {
        didSet {
            guard keepsHistory != oldValue else { return }
            UserDefaults.standard.set(keepsHistory, forKey: DictationHistoryStore.keepsHistoryKey)
        }
    }

    /// "Keep recordings for Try again": a week, on this Mac. Off removes the
    /// recordings already kept.
    var keepsRecordings: Bool = UserDefaults.standard.object(
        forKey: DictationHistoryStore.keepsRecordingsKey) as? Bool ?? true {
        didSet {
            guard keepsRecordings != oldValue else { return }
            UserDefaults.standard.set(keepsRecordings, forKey: DictationHistoryStore.keepsRecordingsKey)
            if !keepsRecordings { history.removeAllRecordings() }
        }
    }

    /// A shortcut that types the last dictation again, wherever the cursor is.
    var pastesLast: Bool = UserDefaults.standard.object(
        forKey: DictationHistoryStore.pastesLastKey) as? Bool ?? true {
        didSet {
            guard pastesLast != oldValue else { return }
            UserDefaults.standard.set(pastesLast, forKey: DictationHistoryStore.pastesLastKey)
            applyPasteLastHotkey()
        }
    }

    var pasteLastHotkey: GlobalHotkey.Binding = Defaults.binding(
        DictationHistoryStore.pasteLastBindingKey, default: .controlOptionCommandD) {
        didSet {
            guard pasteLastHotkey != oldValue else { return }
            Defaults.setBinding(pasteLastHotkey, DictationHistoryStore.pasteLastBindingKey)
            applyPasteLastHotkey()
        }
    }

    /// Why the paste-again shortcut is not registered, for Settings.
    var pasteLastHotkeyError: String?

    @ObservationIgnored let history = DictationHistoryStore.shared
    @ObservationIgnored let pasteLastRegistration = GlobalHotkey()
    /// This hold's record and recorder, from the microphone opening until the
    /// words are handed to `deliver`.
    @ObservationIgnored var historyEntry: DictationEntry?
    @ObservationIgnored var historyRecorder: DictationRecorder?
    /// This hold is into a password field: nothing of it is kept.
    @ObservationIgnored var historySecure = false

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
            Task { await prepare() }
        }
    }

    // MARK: - Observable state

    /// Where this hold is going, decided at key-down and shown for its duration.
    ///
    /// `.type` until the probe says otherwise, so a probe that never answers
    /// behaves exactly like the app did before this feature existed.
    private(set) var route: DictationRoute = .type
    /// The app the transcript would be typed into, for the pill.
    private(set) var destinationName: String?
    /// Who we promised to type into. Compared at key-up: if that process has
    /// gone, the promise cannot be kept and the transcript goes to the
    /// clipboard instead — safe in that direction, because nothing gets typed.
    @ObservationIgnored private var destinationPID: pid_t?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    /// Whether the probe actually SAW a text box at key-down, as opposed to
    /// `.type` by default (no answer yet, or an app it could not read). Only a
    /// box that was seen lets an unreadable one after typing go unchecked —
    /// see `DictationLanding.copiesToo`.
    @ObservationIgnored private var targetWasConfirmed = false

    /// Puts a transcript on the clipboard when there is nowhere to type it.
    /// Wired by AppDelegate, so history suppression stays in one place.
    @ObservationIgnored var onCopyTranscript: ((String) -> Void)?

    private(set) var isListening = false {
        didSet {
            guard isListening != oldValue else { return }
            isFinishing = false
            Moments.shared.announce(isListening ? .listeningStarted : .listeningStopped)
        }
    }
    /// The key is up and the microphone off, but the last words are still
    /// being written down. `isListening` stays true through it, so without
    /// this the strip kept saying "Release to type" to someone who had.
    private(set) var isFinishing = false
    /// Listening OR still tidying up. What the panel should follow.
    ///
    /// Not the same as `isListening`, and the difference was a real bug: the
    /// panel collapsed the instant the key came up, so the "Tidying up" state
    /// existed and could never be seen — leaving the pause before the text
    /// lands as unexplained as it was before the state was added.
    var isActive: Bool { isListening || isCleaning }

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
            // With the panel and not at key-down: by now the press has
            // earned being called a dictation. At key-down every ⌃C would
            // chime.
            if self.gesture.isRecording { self.playCue(started: true) }
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

    /// When the analyzer actually came up. The window that could have carried
    /// audio starts HERE, not at key-down — the engine start sits between the
    /// two, and on a short hold it is most of it.
    @ObservationIgnored private var listeningSince: Date?

    /// The input actually in use, for the panel to name. `nil` resolution means
    /// macOS's own default, which has no name here worth printing over the
    /// system one.
    var inputDeviceName: String {
        inputResolution.device?.name ?? String(localized: "the system input")
    }

    /// Opens Settings at the input picker. Wired by whoever owns the window.
    @ObservationIgnored var onChooseInput: (() -> Void)?
    /// Opens Settings › Voice at the language picker, for a language this
    /// Mac can't dictate in.
    @ObservationIgnored var onChooseLanguage: (() -> Void)?

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
        case .chooseLanguage:
            onChooseLanguage?()
        case .letAirlockType:
            PermissionSwitch.allowAccessibility()
        case .rememberWord:
            if let learned = offeredWord { DictationWordsStore.keep(learned) }
        }
        offeredWord = nil
    }

    /// The word the "Remember" card is offering, until it is answered or goes.
    @ObservationIgnored private var offeredWord: DictationCorrection.Learned?

    /// A word fixed by hand after a dictation: asked about in the notch, or
    /// kept straight away with "Add without asking" on. Never over another
    /// card or a hold in progress: the fix is just not offered then.
    private func offerToRemember(_ learned: DictationCorrection.Learned) {
        guard !isActive, heardNothing == nil, holdNotice == nil else { return }
        if DictationWordsStore.learnsSilently {
            DictationWordsStore.keep(learned)
            showNotice(.rememberedWord(learned.word))
        } else {
            offeredWord = learned
            showNotice(.rememberWord(learned.word))
        }
    }

    /// Takes the panel with it unless something else is still holding it: a
    /// hold in progress, or one of the two cards above.
    func dismissHoldNotice() {
        guard holdNotice != nil else { return }
        clearHoldNotice()
        guard !isActive, heardNothing == nil else { return }
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

    /// What cleanup can and cannot do on this Mac.
    var cleanupAvailability: ModelAvailability { previewCleanupAvailability ?? cleanup.availability }

    /// What `cleanupAvailability` says instead of asking the system. State
    /// gallery only: nil everywhere else.
    @ObservationIgnored var previewCleanupAvailability: ModelAvailability?

    /// Names the recogniser should expect to hear out of the box — the tools
    /// people dictate about, which it otherwise turns into ordinary words.
    /// They are the built-ins of "Words to know", removable there.
    static let recognitionVocabulary: [String] = DictationWords.builtIns

    /// Watches the box a dictation was typed into for a word fixed by hand.
    @ObservationIgnored private let fixWatcher = DictationFixWatcher()
    /// What the last dictation typed, so "scratch that" can take it back.
    /// In memory only, never for a password box, and gone once used.
    @ObservationIgnored private var lastTyped: String?
    private(set) var availableLocales: [Locale] = []
    private(set) var readiness = DictationReadiness(blocker: .disabled, canType: false,
                                                    canWatchHoldKey: true)

    /// Raised when dictation takes over, so the notch can show it is listening.
    var onListeningChanged: ((Bool) -> Void)?

    // MARK: - Machinery

    @ObservationIgnored private let toggle = WidgetToggle(key: DictationModel.enabledKey, defaultValue: false)
    @ObservationIgnored private let holdMonitor = HoldKeyMonitor()

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
    /// The fault the last banner was about. The key is re-measured on every
    /// return to Airlock while setup or Settings is open, and a banner each
    /// time — landing on the very card that already says it — is nagging, not
    /// news. One per fault, again only once it was fixed and came back.
    @ObservationIgnored private var notifiedHoldKeyFault: HoldKeyFault?

    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private let session = SpeechSession()
    @ObservationIgnored private var gesture = HoldGesture() {
        didSet {
            // Escape is looked for only while a dictation is running — see
            // `HoldKeyMonitor.watchesEscape`.
            holdMonitor.watchesEscape = gesture.isRecording
            if isLockedOn != gesture.isLocked { isLockedOn = gesture.isLocked }
        }
    }
    /// The ceiling of the dictation that last finished, in minutes: five for
    /// a hold, ten when locked on. Noted when it finishes, because the
    /// gesture is reset by then.
    /// The start sound played for the dictation in progress.
    @ObservationIgnored private var cueStarted = false
    @ObservationIgnored private var finishedLimitMinutes = Int(HoldGesture.maximumHold / 60)
    /// Scrolls, keys and clicks during the hold in progress — see
    /// `HoldInterruption`. Reset when a hold starts, and handed to the
    /// delivery by value, since the next hold may start before it runs.
    @ObservationIgnored private var interruptions = HoldInterruptions()
    /// Bumped whenever a hold is abandoned out from under itself — see
    /// `recoverFromStall`. A teardown that finally returns compares the number
    /// it started with and stays out of the way if the world has moved on.
    @ObservationIgnored private var holdGeneration = 0
    /// When the finish now running began, nil when none is. A key-down in
    /// that window finds the microphone already stopped and `isListening`
    /// still true, which is what a stall looks like too.
    @ObservationIgnored private var finishStartedAt: Date?
    /// How long a finish may run before a new hold treats it as wedged: the
    /// longest `session.finish` wait plus room for the microphone to settle.
    private static let finishBound: TimeInterval = 12
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
        Task {
            await prepare()
            // After `prepare`, which finds the recogniser recovery needs.
            await recoverCutOff()
            history.prune()
        }
        applyHotkey()
        applyPasteLastHotkey()
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
        SystemQuestionWatch.shared.begin()
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
        SystemQuestionWatch.shared.begin()
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
                self?.beginHold()
            },
            onUp: { [weak self] in
                dictationLog("hold UP")
                // Released with a mouse button down: the key was modifying a
                // drag that began before it, which no event here announces.
                // Not a tap, so it must not lock on or stop a locked one.
                if Self.mouseButtonIsDown() { self?.handle(.pressAbandoned) }
                self?.handle(.keyUp(at: Date()))
            },
            onInterrupt: { [weak self] input in
                self?.interrupted(by: input, on: "hold") ?? true
            },
            onEscape: { [weak self] in
                self?.escapePressed()
            })
        dictationLog("holdMonitor(\(holdKey.displayName)) → \(ok ? "ok" : "FAILED")")

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
        guard let holdKeyFault else {
            notifiedHoldKeyFault = nil
            return
        }
        // Setup walks through this very switch, on screen, one step at a time.
        let notify = holdKeyFault != notifiedHoldKeyFault && OnboardingModel.hasCompletedSetup
        if notify { notifiedHoldKeyFault = holdKeyFault }

        // A hold that does nothing produces no window, no sound and no error, so
        // the in-notch status line is a message delivered to a surface that
        // nothing has caused the user to look at. This is the one failure in
        // dictation with no visible symptom at all, which makes it the one that
        // most needs the channel that survives Airlock not being frontmost.
        switch holdKeyFault {
        case .notGranted:
            statusMessage = String(localized: "Holding \(holdKey.displayName) does nothing — Airlock needs Input Monitoring. Settings › Permissions has the button.")
            guard notify else { return }
            Notifications.post(
                title: String(localized: "Airlock can't see your dictation key"),
                body: String(localized: "Holding \(holdKey.displayName) won't start dictation until Airlock is allowed in Privacy & Security › Input Monitoring."),
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
            statusMessage = String(localized: "Holding \(holdKey.displayName) does nothing, even though macOS says it is allowed. Settings › Permissions has the fix.")
            guard notify else { return }
            Notifications.post(
                title: String(localized: "Your dictation key isn't reaching Airlock"),
                body: String(localized: "It's switched on in Input Monitoring, but macOS isn't passing the key along. Click to fix it."),
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

    /// Start a hold, or ignore it if one is already live, so a second
    /// key-down can never open another `AudioCapture` on the same microphone.
    private func beginHold() {
        // Locked on by a tap: this press is the one that stops it, when it
        // comes back up. Nothing below applies — no new hold is starting.
        if gesture.isLocked {
            dictationLog("  locked on — this press stops it")
            handle(.keyDown(at: Date()))
            return
        }
        let secureInput = noteSecureInputIfHeld()
        let blind = secureInput != nil
        if isListening {
            // Listening with a STOPPED microphone is not a state any gesture can
            // reach — every teardown stops the engine first and clears the flag
            // after. The two disagreeing means something in between stalled, and
            // refusing forever is what turned one stalled finish into dictation
            // being dead until relaunch: a panel stuck open, a microphone that
            // was not recording, and every later press answered with "a hold is
            // already running". Treat it as the wedge it is.
            guard !capture.isCapturing else {
                dictationLog("  ignoring — a hold is already running")
                return
            }
            // Except while the last hold is still being written down, which
            // looks the same from here: microphone off, flag still set.
            // Pressing again right after speaking is what people do, and
            // resetting then threw away the words still finishing AND left
            // the new hold sharing a session the old finish went on to clear.
            // The chain already runs this start after that finish, so it waits.
            if let since = finishStartedAt,
               Date().timeIntervalSince(since) < Self.finishBound {
                dictationLog("  last hold still finishing — this one starts after it")
            } else {
                dictationLog("  hold arrived on a stalled hold — resetting")
                recoverFromStall()
            }
        }
        // A fresh hold answers the last one. Leaving the notice up under a live
        // microphone would be reporting silence while listening.
        heardNothing = nil
        // The last hold's notice too, and the panel with it when the notice was
        // all that held it open: this hold opens it again on its own terms.
        if holdNotice != nil || noticeRevealTask != nil { setIndicator(false) }
        // Drawn above the strip once this hold's panel opens, and gone when the
        // hold ends (`finishListening`, or the close of a discarded one).
        holdNotice = secureInput
        // The floor for THIS hold, fixed before the key-down is applied.
        //
        // Raised only while secure input is held, because that is exactly when
        // `HoldKeyMonitor` cannot see the ⌫ that would otherwise disqualify the
        // hold. Note what this does NOT do: capture still starts immediately,
        // below, so the syllable-clipping the comment there records is not
        // reintroduced. Only the threshold for *delivering* the hold — and for
        // showing the panel — moves.
        if !gesture.isRecording {
            // A tap locks only where a chord can be seen: blind, a tap and
            // ⌥⌫ look the same, and locking on a word-delete would leave the
            // microphone open behind a password field.
            gesture = HoldGesture(floor: blind ? HoldGesture.blindHold : HoldGesture.minimumHold,
                                  locksOnTap: tapToLock && !blind)
            interruptions = HoldInterruptions()
        }
        // Immediately. A 120ms grace was tried here to keep a fast ⌥⌫ from ever
        // opening the microphone, and it clipped the first syllable of anyone
        // who starts speaking quickly — measured, not theorised. Losing the
        // start of a sentence is a defect; a briefly-blinking recording
        // indicator is a cosmetic annoyance, and the chord cancel in
        // `HoldKeyMonitor` is what actually stops chords becoming dictations.
        // What waits instead is the STOP that cancel makes: stopping the input
        // moments after starting it crashed the app (`MicrophoneSettle`).
        handle(.keyDown(at: Date()))
    }

    /// A scroll, key, click or second modifier while the hold key is down.
    /// Returns true when it ended the hold.
    ///
    /// Words heard so far decide it (`HoldInterruption`): before any, a key or
    /// click is a shortcut and the hold is called off as it always was; after
    /// some, nothing the other hand does throws them away.
    private func interrupted(by input: HoldInterruption, on key: String) -> Bool {
        // Not recording: a blocked hold waiting to show its notice, or one
        // already finished at the limit. The cancel still calls off the
        // notice, which is all it ever did here.
        guard gesture.isRecording else {
            handle(.cancel)
            return true
        }
        // Locked on, and the key went down again with something else: a
        // shortcut that happens to start with the dictation key. The
        // dictation carries on, and the release that follows stops nothing.
        if gesture.isLocked {
            dictationLog("\(key) \(input.rawValue) while locked on — a shortcut, still listening")
            handle(.pressAbandoned)
            return true
        }
        let heardWords = HoldInterruption.soundsLikeTalking(
            heardWords: !session.transcript.display
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            heldFor: gesture.startedAt.map { Date().timeIntervalSince($0) } ?? 0,
            peak: capture.peakLevel)
        switch interruptions.note(input, heardWords: heardWords) {
        case .carryOn:
            dictationLog("\(key) \(input.rawValue) — still listening")
            // Still a hold if it lasts, but no longer a tap: a quick
            // ⌃-scroll must not lock the microphone on.
            handle(.pressAbandoned)
            return false
        case .carryOnThenCopy:
            dictationLog("\(key) \(input.rawValue) after words — still listening; they'll be copied, not typed")
            return false
        case .discard:
            dictationLog("\(key) CANCELLED — \(input.rawValue) before any words "
                         + "(held \(String(format: "%.1f", gesture.startedAt.map { Date().timeIntervalSince($0) } ?? 0))s, "
                         + "peak \(String(format: "%.3f", capture.peakLevel)))")
            handle(.cancel)
            return true
        }
    }

    private func handle(_ event: HoldGesture.Event) {
        // A blocked hold resets the gesture, so its release reaches nothing
        // below — but it still has to call off a notice waiting for the hold
        // to qualify. Once shown, a notice is not this release's to take back.
        switch event {
        case .keyUp, .cancel:
            noticeRevealTask?.cancel()
            noticeRevealTask = nil
        case .keyDown, .tick, .pressAbandoned:
            break
        }
        let limit = gesture.limit
        guard let effect = gesture.apply(event) else { return }
        switch effect {
        case .lock:
            // Nothing to queue: the capture that the key-down started simply
            // carries on. The notch says how to stop.
            dictationLog("  effect=lock — listening until the next tap")
        case .startCapture:
            dictationLog("  effect=startCapture (queued)")
            enqueue { await self.beginListening() }
        case .finish(let reason):
            dictationLog("  effect=finish(\(reason)) (queued)")
            finishedLimitMinutes = Int(limit / 60)
            playCue(started: false)
            // Now, not inside the queued work: a new hold resets it.
            let interruptions = self.interruptions
            enqueue { await self.finishListening(reason, interruptions: interruptions) }
        case .discard(let reason):
            dictationLog("  effect=discard(\(reason)) (queued)")
            playCue(started: false)
            enqueue { await self.discardListening(reason) }
        }
    }

    /// Whether a mouse button is held right now, from the hardware state
    /// and not from the event stream.
    private static func mouseButtonIsDown() -> Bool {
        [CGMouseButton.left, .right, .center].contains {
            CGEventSource.buttonState(.combinedSessionState, button: $0)
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
            let allowed = String(localized: "Microphone allowed — hold \(holdKey.displayName) again to dictate.")
            statusMessage = readiness.canRecord
                ? allowed
                : readiness.blocker?.message
            dictationLog("after request: \(readiness.blocker.map { "\($0)" } ?? "ready")")
            // At once: the hold was spent on macOS's dialog, so it has long
            // since earned a reply, and the key is probably already up.
            if readiness.canRecord {
                showNotice(.microphoneAllowed(key: holdKey.displayName))
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
        // A new dictation ends the look at the last one's text box.
        fixWatcher.stop()
        // Written before a word is heard, so a dictation cut off on its way
        // still has a record and its audio. Never for a password field.
        beginHistoryEntry()

        do {
            dictationLog("  starting audio engine…")
            // Re-resolved at the moment of use, not at launch: a microphone
            // can be unplugged between the two.
            refreshDevices()
            let stream = try capture.start(analyzerFormat: format,
                                           deviceUID: inputResolution.device?.uid ?? "")
            dictationLog("  engine up; starting analyzer…")
            // What the recogniser should expect to hear — see
            // `SpeechSession.begin`.
            // Everything on "Words to know", built-ins included.
            let vocabulary = DictationWordsStore.load().spellings
            try await session.begin(locale: locale,
                                    secondary: resolvedSecondaryLocale,
                                    vocabulary: vocabulary,
                                    input: DictationRecorder.tee(stream, into: historyRecorder))
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
            forgetHistoryEntry()
            statusMessage = String(localized: "The microphone couldn't start. Try again in a moment.")
            let earned = gesture.startedAt?.addingTimeInterval(gesture.floor)
            // The analyzer can fail after the engine came up, which makes this
            // a stop moments after a start like any other.
            await capture.stopWhenSettled()
            gesture = HoldGesture()
            isListening = false
            setIndicator(false)
            // Behind the same floor as a blocked hold: an engine that will not
            // start fails in milliseconds, well before a brushed key is known
            // to be a tap.
            showNotice(.microphoneFailedToStart, notBefore: earned)
        }
    }

    private func finishListening(_ reason: HoldGesture.Finish,
                                 interruptions: HoldInterruptions) async {
        let generation = holdGeneration
        finishStartedAt = Date()
        defer { if generation == holdGeneration { finishStartedAt = nil } }
        stopTimers()
        // MUST come first: `finalizeAndFinishThroughEndOfInput` waits on the
        // input sequence ending, so finishing the session against a live stream
        // never returns. Settled, like a discard: a slow start can leave the
        // engine only moments old when even a qualifying hold ends.
        await capture.stopWhenSettled()
        isFinishing = true
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
        deliver(heard, peak: peak, listenedFor: listenedFor, reason: reason,
                interruptions: interruptions, keeping: takeHistoryEntry())
    }

    /// Cleanup, then keystrokes. Runs off the gesture chain — see `finishListening`.
    private func deliver(_ heard: String, peak: Float, listenedFor: TimeInterval,
                         reason: HoldGesture.Finish, interruptions: HoldInterruptions,
                         keeping: HistoryKeeping) {
        let previous = deliveryTask
        deliveryTask = Task { @MainActor [weak self] in
            // Still serialised against ITSELF: two transcripts typing into the
            // same document at once would interleave their keystrokes.
            await previous?.value
            guard let self else { return }

            dictationLog("heard \(DictationDiagnostics.redact(heard)) peak=\(peak)")
            guard let spoken = DictationText.prepared(heard) else {
                // Nothing heard is nothing to keep.
                if let entry = keeping.entry { self.history.remove(entry.id) }
                // A hold that only scrolled — ⌃-scroll zooming the screen —
                // was never dictation, so it gets no card.
                if interruptions.endsQuietlyWhenSilent {
                    self.statusMessage = nil
                    self.setIndicator(false)
                    return
                }
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
                self.statusMessage = String(localized: "Didn't catch anything.")
                self.showNotice(.nothingCaught(key: self.holdKey.displayName))
                return
            }

            await self.typeOut(spoken, reason: reason,
                               copyInstead: interruptions.copiesInstead,
                               keeping: keeping)
        }
    }

    /// The word list, then the tidy step, then the word list again, so a name
    /// the tidy step "corrected" comes back. Shared by a dictation and by Try
    /// again, so both give the same words for the same speech.
    func polish(_ spoken: String, showsProgress: Bool) async -> (text: String, tidyingFailed: Bool) {
        let words = DictationWordsStore.load()
        let respelled = words.respelled(spoken, isDictionaryWord: DictationWordsStore.isDictionaryWord)
        if respelled != spoken {
            dictationLog("words → \(DictationDiagnostics.redact(respelled))")
        }
        var text = respelled
        var tidyingFailed = false
        if cleansTranscript {
            if showsProgress { isCleaning = true }
            text = await cleanup.clean(respelled, instructions: cleanupInstructions)
            if showsProgress { isCleaning = false }
            text = words.respelled(text, isDictionaryWord: DictationWordsStore.isDictionaryWord)
            if text != respelled {
                dictationLog("cleaned → \(DictationDiagnostics.redact(text))")
            }
            if let rejection = cleanup.lastRejection {
                if showsProgress { statusMessage = rejection }
                tidyingFailed = true
            }
        }
        return (text, tidyingFailed)
    }


    /// Cleanup, then keystrokes — or the clipboard when there is nowhere to
    /// type. The tail of every dictation, and of an ask the card sent back to
    /// be typed after all.
    ///
    /// `copyInstead`: a key or click came while the person was talking, so the
    /// cursor may not be where it was — the words go to the clipboard.
    private func typeOut(_ spoken: String, reason: HoldGesture.Finish,
                         copyInstead: Bool = false,
                         keeping: HistoryKeeping = HistoryKeeping()) async {
        // "comma", "scratch that", a saved text's name: before the word list
        // and the tidy step, so both see the signs and not the words.
        let commands = spokenCommands(spoken)
        if commands.erasePrevious {
            let erased = await eraseLastTyped()
            dictationLog("  scratch that: \(erased ? "took back the last dictation" : "nothing to take back")")
            if !erased {
                statusMessage = String(localized: "Nothing taken back: the text there has changed since.")
            }
        }
        if commands.text.isEmpty {
            // Only a command was said; it has been carried out.
            if let entry = keeping.entry { history.remove(entry.id) }
            setIndicator(false)
            return
        }

        // Between transcription and typing, never after: the text that
        // reaches the document and the text recorded as "last dictation"
        // have to be the same thing, or the recovery path shows something
        // you never got.
        let (text, tidyingFailed) = commands.isSavedText
            ? (commands.text, false)
            : await polish(commands.text, showsProgress: true)
        // A saved text may be an address or an account number: it is typed,
        // and never written to a log or to the history.
        let shown = commands.isSavedText ? spoken : text
        func logged(_ value: String) -> String {
            commands.isSavedText ? "a saved text" : DictationDiagnostics.redact(value)
        }

        // A password field keeps nothing, not even in memory.
        if !keeping.secure { self.lastTranscript = shown }
        func finish(_ delivery: DictationEntry.Delivery) {
            guard var entry = keeping.entry else { return }
            entry.heard = spoken
            entry.text = shown
            entry.finished = true
            entry.delivery = delivery
            history.put(entry)
        }

        // Nothing in front can take text. Typing anyway is what sent a
        // dictation into Gmail's keyboard shortcuts, so the words go to the
        // clipboard instead — recoverable, visible, and inert until pasted.
        // One decision, in Core, tested — see `DictationDelivery`. Written as
        // two separate `if`s here, the second one lost the transcript.
        let settled = copyInstead ? .copy : self.settledRoute()
        let delivery = DictationDelivery.decide(route: settled,
                                                isAccessibilityTrusted: TypeService.isTrusted)
        let copies = delivery == .copy && settled == .copy
        // Read now: the next hold resets it, and this delivery runs after.
        let targetWasConfirmed = self.targetWasConfirmed

        // The panel closes here as it always did — unless there is something
        // to say about this hold, which takes the panel's place instead of
        // closing it and opening it again a moment later.
        if let notice = DictationHoldNotice.afterDelivery(copied: copies,
                                                          afterKeyOrClick: copyInstead,
                                                          reachedLimit: reason == .reachedLimit,
                                                          limitMinutes: finishedLimitMinutes,
                                                          tidyingFailed: tidyingFailed) {
            self.showNotice(notice)
        } else {
            self.setIndicator(false)
        }

        if copies {
            dictationLog("copying \(logged(text)) — "
                         + (copyInstead ? "a key or click came while talking" : "nowhere to type"))
            self.onCopyTranscript?(text)
            finish(.copied)
            self.statusMessage = copyInstead
                ? String(localized: "You pressed a key or clicked while talking — copied to your clipboard.")
                : String(localized: "Nothing to type into — copied to your clipboard.")
            return
        }

        dictationLog("typing \(logged(text)) axTrusted=\(TypeService.isTrusted)")
        // What the box held before, so the look after typing can tell
        // whether anything took the words. See `DictationLanding`.
        let before = await LandingCheck.look()
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
            // Without Accessibility the notch says why instead, with the
            // button that leads to the switch: the person is looking at the
            // app they meant to type into, and "on the clipboard" with no
            // reason is what made dictation look like it chose at random.
            if trusted {
                self.dismissHoldNotice()
            } else {
                self.showNotice(.copiedCantTypeYet)
            }
            self.onCopyTranscript?(text)
            finish(.copied)
            self.statusMessage = trusted
                ? String(localized: "Couldn't type that one — copied to your clipboard instead.")
                : DictationHoldNotice.copiedCantTypeYet.sentence
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
                title: String(localized: "Airlock can't type yet"),
                body: String(localized: "Your words are on the clipboard — ⌘V pastes them. Click here to let Airlock type them for you."),
                identifier: Notifications.ID.accessibilityMissing,
                opens: SettingsAnchor.permissionAccessibility)
            self.refreshReadiness()
            return
        }
        // Posting the keystrokes is not the words arriving. An app can say a
        // text box has the focus while nothing on screen has the cursor, and
        // then the words went nowhere and, before this, not to the clipboard
        // either: lost. So look, and when they can't be seen landing, copy
        // them too and say so in the notch.
        let landing = await LandingCheck.verdict(typed: text, before: before)
        // A password box is never put on the clipboard, whatever the look said.
        let copiesToo = !keeping.secure
            && DictationLanding.copiesToo(landing, targetWasConfirmed: targetWasConfirmed)
        if copiesToo {
            dictationLog("  typed, but not seen landing (\(landing.rawValue), before=\(before.shortDescription), "
                         + "confirmed=\(targetWasConfirmed)) — copying too")
            self.onCopyTranscript?(text)
            self.showNotice(.copiedNotSeenLanding)
            self.statusMessage = DictationHoldNotice.copiedNotSeenLanding.sentence
            guard landing == .cannotTell else {
                // Visibly not typed: not a dictation the app did for you.
                finish(.copied)
                return
            }
        } else {
            dictationLog("  landing: \(landing.rawValue)")
        }
        // Counted where the text actually LANDED, not where the hold
        // ended: a transcript that failed to type is not a dictation the
        // app did for you, and the trial card must not claim it.
        finish(.typed)
        self.tally?.recordDictation()
        UsageCounts.shared.record(.used(.dictation))
        FirstStepsModel.shared.note(.dictate)
        if !copiesToo {
            self.statusMessage = reason == .reachedLimit
                ? String(localized: "Stopped at the \(finishedLimitMinutes)-minute limit.") : nil
        }
        lastTyped = keeping.secure ? nil : text
        // Only after Airlock typed, and only into where it typed. A saved
        // text is the person's own words already: nothing to learn from it.
        guard !commands.isSavedText else { return }
        fixWatcher.watch(typed: text) { [weak self] learned in
            self?.offerToRemember(learned)
        }
    }

    /// The spoken commands, in the dictation's languages, by the switches
    /// in Settings › Voice.
    private func spokenCommands(_ spoken: String) -> SpokenCommands.Outcome {
        let languages = [resolvedLocale, resolvedSecondaryLocale].compactMap { $0?.identifier }
            + (localeIdentifier.isEmpty ? [] : [localeIdentifier])
        return SpokenCommands.apply(spoken, switches: DictationWordsStore.commandSwitches(),
                                    saved: DictationWordsStore.savedTexts(), languages: languages)
    }

    /// Backspaces over what the last dictation typed, only when the box with
    /// the focus still ends with exactly that text. Anything else (another
    /// box, words typed since, a box that can't be read) leaves it alone.
    /// Backspaces only when the text just BEFORE THE CURSOR is still what
    /// was typed: nothing selected, nothing typed since, the cursor not
    /// moved. Checking the end of the whole box was not enough: a letter
    /// typed elsewhere left the end unchanged, and the backspaces then
    /// landed wherever the cursor was.
    private func eraseLastTyped() async -> Bool {
        guard let last = lastTyped, !last.isEmpty else { return false }
        lastTyped = nil
        fixWatcher.stop()
        guard let field = DictationFixWatcher.focusedField(),
              let value = DictationFixWatcher.text(of: field) else {
            dictationLog("  scratch that: the box can't be read")
            return false
        }
        guard let caret = DictationFixWatcher.caret(of: field) else {
            dictationLog("  scratch that: no cursor, or text is selected")
            return false
        }
        let units = Array(value.utf16)
        guard caret <= units.count else { return false }
        let beforeCaret = String(decoding: units[..<caret], as: UTF16.self)
        let normalised = beforeCaret.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalised.hasSuffix(last) else {
            dictationLog("  scratch that: the text before the cursor has changed")
            return false
        }
        return await TypeService.erase(count: last.count)
    }

    // MARK: - Routing

    /// Work out where this hold is going, without holding anything up.
    private func startFocusProbe() {
        route = .type
        targetWasConfirmed = false
        destinationName = NSWorkspace.shared.frontmostApplication?.localizedName
        destinationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        probeTask?.cancel()

        probeTask = Task { [weak self] in
            let probe = await FocusProbe.current()
            guard let self, !Task.isCancelled else { return }
            self.route = DictationRoute.decide(probe)
            if case .focused = probe { self.targetWasConfirmed = self.route == .type }
            dictationLog("  focus probe → \(probe.shortDescription) route=\(self.route.rawValue)")
            if case .focused(let snapshot) = probe, FocusTarget.containsPasswordField(snapshot) {
                dictationLog("  password field — this dictation is not kept")
                self.historySecure = true
                self.forgetHistoryEntry()
            }
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
        // Settled, because this is the stop a shortcut makes moments after the
        // start — the one that crashed the app. See `MicrophoneSettle`.
        await capture.stopWhenSettled()
        await session.abandon()
        forgetHistoryEntry()
        isListening = false
        liveText = ""
        inputLevels = []
        resumeMusicIfPaused()
        setIndicator(false)
        // A tap is not an error. Saying "too short" every time someone brushes
        // the key would be nagging about a non-event.
        if reason == .cancelled { statusMessage = nil }
    }

    /// Escape while a dictation is running: stop, type nothing, copy nothing.
    private func escapePressed() {
        guard gesture.isRecording else { return }
        dictationLog("Escape — dictation cancelled, nothing typed")
        handle(.cancel)
    }

    /// A locked dictation that has heard nothing at all was a brush of the
    /// key, not somebody about to talk. Ends it quietly, like any other tap.
    private func endStrayLockIfSilent() {
        guard gesture.isLocked else { return }
        let heardWords = !session.transcript.display
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard HoldGesture.lockLooksStray(runningFor: gesture.heldFor(at: Date()),
                                         heardWords: heardWords,
                                         peak: capture.peakLevel) else { return }
        dictationLog("locked on and silent for \(Int(HoldGesture.strayLockWindow))s — taken for a stray tap")
        handle(.cancel)
    }

    /// The start and stop sounds. Silent with the switch off, and while call
    /// notes are recording: the sound would be in the recording.
    ///
    /// The stop sound only answers a start sound: a press that never got as
    /// far as opening the notch ends as silently as it began.
    private func playCue(started: Bool) {
        if started {
            guard !cueStarted, playsSounds, isCallRecording?() != true else { return }
            cueStarted = true
            Sounds.play("AirlockDictationStart")
        } else if cueStarted {
            cueStarted = false
            Sounds.play("AirlockDictationStop")
        }
    }

    private func cancelEverything() {
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
        finishStartedAt = nil
        chain = nil
        // The record stays unfinished on purpose: the next launch transcribes
        // its recording again and shows it as recovered.
        historyEntry = nil
        historyRecorder = nil
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
                self?.endStrayLockIfSilent()
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


// MARK: - History

/// What one hold leaves in the History list, handed from the microphone to
/// delivery so a later hold cannot change it.
struct HistoryKeeping {
    var entry: DictationEntry?
    /// Into a password field: no text kept, not even as "last dictation".
    var secure = false
}

extension DictationModel {
    /// A record for this hold, and a recorder when recordings are kept. None
    /// at all when macOS says a password is being typed somewhere.
    func beginHistoryEntry() {
        historySecure = SecureInput.isEnabled
        historyEntry = nil
        historyRecorder = nil
        guard !historySecure, keepsHistory else { return }
        let records = keepsHistory && keepsRecordings
        guard let entry = history.begin(app: destinationName, recording: records) else { return }
        historyEntry = entry
        if records { historyRecorder = DictationRecorder(url: history.recordingURL(entry.id)) }
    }

    /// Hands this hold's record to delivery and clears it here.
    func takeHistoryEntry() -> HistoryKeeping {
        defer {
            historyEntry = nil
            historyRecorder = nil
        }
        return HistoryKeeping(entry: historyEntry, secure: historySecure)
    }

    /// A hold that was discarded or went into a password field: its record and
    /// its audio go at once.
    func forgetHistoryEntry() {
        let entry = historyEntry
        let recorder = historyRecorder
        historyEntry = nil
        historyRecorder = nil
        guard let entry else { return }
        Task { @MainActor [history] in
            // The recorder first, so it can't write the file again after it goes.
            await recorder?.discard()
            history.remove(entry.id)
        }
    }

    // MARK: Try again and recovery

    /// Listens to a saved recording again, with the same recogniser and the
    /// same word list and tidy step as a dictation. Nil when there is no
    /// recording, no recogniser yet, or nothing was heard.
    private func transcribeRecording(_ id: UUID) async -> (heard: String, text: String)? {
        guard let locale = resolvedLocale, let format = analyzerFormat else { return nil }
        guard let buffers = DictationRecorder.buffers(from: history.recordingURL(id), as: format) else {
            dictationLog("history: a recording could not be read")
            return nil
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        for buffer in buffers { continuation.yield(AnalyzerInput(buffer: buffer)) }
        continuation.finish()
        let again = SpeechSession()
        do {
            try await again.begin(locale: locale, secondary: resolvedSecondaryLocale,
                                  vocabulary: DictationWordsStore.load().spellings, input: stream)
        } catch {
            dictationLog("history: the recogniser would not start — \(error.localizedDescription)")
            return nil
        }
        let heard = await again.finish(within: .seconds(60))
        guard let spoken = DictationText.prepared(heard) else { return nil }
        let commands = spokenCommands(spoken)
        // A saved text never goes into the history; its name stands for it.
        guard !commands.isSavedText, !commands.text.isEmpty else { return (spoken, spoken) }
        let polished = await polish(commands.text, showsProgress: false)
        return (spoken, polished.text)
    }

    /// "Try again": the entry gets the new words and keeps the old ones one
    /// click away. Nothing heard leaves it as it was.
    func tryAgain(_ id: UUID) async {
        guard let entry = history.entry(id), entry.hasRecording,
              !history.retrying.contains(id) else { return }
        history.retrying.insert(id)
        defer { history.retrying.remove(id) }
        guard let result = await transcribeRecording(id), let current = history.entry(id) else { return }
        history.put(DictationHistory.retried(current, heard: result.heard, text: result.text))
    }

    /// Dictations cut off before their words reached anywhere (a crash, a
    /// force quit, a power cut) are transcribed from their recording and kept
    /// as "Recovered". One with no recording or no words is removed.
    func recoverCutOff() async {
        history.loadIfNeeded()
        for entry in DictationHistory.toRecover(history.entries) {
            // The hold happening right now is unfinished too, and is not lost.
            guard entry.id != historyEntry?.id else { continue }
            guard entry.hasRecording, let result = await transcribeRecording(entry.id) else {
                history.remove(entry.id)
                continue
            }
            var recovered = entry
            recovered.heard = result.heard
            recovered.text = result.text
            recovered.finished = true
            recovered.recovered = true
            recovered.delivery = .none
            history.put(recovered)
            dictationLog("history: recovered a dictation that was cut off")
        }
    }

    // MARK: Typing again

    /// Copies an entry's words.
    func copyHistoryText(_ text: String) {
        onCopyTranscript?(text)
    }

    /// "Type it again where the cursor is", from Settings: Airlock steps
    /// aside so the app underneath has the cursor back, then types.
    func typeAgain(_ text: String) {
        NSApp.hide(nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            if await !TypeService.type(text) { self.onCopyTranscript?(text) }
        }
    }

    /// The newest dictation's words: from History, or from this run when
    /// History is off.
    var lastDictationText: String? {
        if keepsHistory {
            history.loadIfNeeded()
            if let last = DictationHistory.last(history.entries) { return last.text }
        }
        return lastTranscript
    }

    /// The paste-again shortcut. Waits for its keys to come up first, or the
    /// app in front would read the typing as ⌃⌥⌘ shortcuts.
    func pasteLast() {
        guard let text = lastDictationText, !text.isEmpty else {
            NSSound.beep()
            return
        }
        Task { @MainActor [weak self] in
            for _ in 0..<30 where !NSEvent.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self else { return }
            if await !TypeService.type(text) { self.onCopyTranscript?(text) }
        }
    }

    func applyPasteLastHotkey() {
        pasteLastRegistration.unregister()
        guard isEnabled, pastesLast else {
            pasteLastHotkeyError = nil
            return
        }
        pasteLastRegistration.register(pasteLastHotkey) { [weak self] in self?.pasteLast() }
        pasteLastHotkeyError = pasteLastRegistration.lastError
    }

    /// "Clear history": every record and every recording.
    func clearHistory() {
        history.clear()
        lastTranscript = nil
        lastTyped = nil
    }
}
