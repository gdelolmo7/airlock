import AVFoundation
import AppKit
import AirlockCore
import CoreAudio
import IOKit.pwr_mgt
import Speech

/// `meetings.log`: what the call notes did, for the owner. Same rules as the
/// wave's log (`WaveDiagnostics`): main actor only, shut in tests, capped,
/// except that past the cap it is cut back rather than started over, so a
/// long call keeps its first lines (`MeetingLogTrim`).
/// Never a word of what was said: only counts, languages and timings.
enum MeetingDiagnostics {
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Airlock/meetings.log")
    }

    @MainActor
    static func log(_ message: String) {
        guard OwnerLogs.areOpen else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let manager = FileManager.default
        MeetingLogTrim.trimIfNeeded(at: url)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

/// Notes of your calls, written on this Mac: asked once per call in the
/// panel, listened to as two tracks (you, them), saved as text as it is said,
/// and summarised when the call ends. Also notes of a meeting in the room,
/// started by hand ("Take notes"): the Mac's microphone as the one track,
/// every voice on it told apart by the voice model.
///
/// The rules live in `MeetingNotesFlow` and `CallChannelHealth` (Core,
/// tested); this is the part that touches the microphone, the call app's
/// sound, the disk and the model, and it looks once a second while notes are
/// taken to tell them what it sees.
///
/// **On unless switched off** (`meetings.enabled`, the "Call notes" switch
/// on the Voice page in Settings). It was a prototype switched on by hand on
/// the owner's Mac from 2026-10-08, and on for everyone from 1.0.19. Off,
/// the call pill behaves exactly as before and none of this listens to
/// anything.
@MainActor
@Observable
final class MeetingNotesModel {
    static let enabledKey = "meetings.enabled"
    /// What the switch says before anybody has touched it.
    static let onByDefault = true
    /// Whether call notes are on, read the way every part of the app reads it.
    static var isOn: Bool { Defaults.bool(enabledKey, default: onByDefault) }
    static let autoStartKey = "meetings.autoStart"
    /// Taking the speakers out of your side: on unless set to false.
    static let echoRemovalKey = "meetings.echoRemoval"
    /// The words typed in Settings for transcripts to spell their way
    /// (`MeetingKnownWords`), as a list of strings.
    static let knownWordsKey = "meetings.knownWords"
    /// How long notes have listened on a plan that caps it
    /// (`NotesListening`, as JSON), so a quit and a relaunch carry it on.
    static let listeningKey = "meetings.listening"
    /// How often the count is kept while notes listen: what a crash can
    /// lose of it.
    static let listeningKeptEvery: TimeInterval = 60
    /// How many of the latest meetings are read for names given to voices.
    static let namesLookedBack = 50
    static let echoLogEvery: TimeInterval = 60
    /// How recent the Mac's last voice must be to count as playing one at a
    /// look: a look's second, and the speakers' drain's slack.
    static let speakingWithin: TimeInterval = 1.5
    /// How long "Notes ready" stays in the panel before it tidies itself away.
    static let readyLinger: Duration = .seconds(600)
    /// How often the model looks while notes are taken. The waits it serves
    /// are seconds long, and each look is a handful of property reads.
    static let lookEvery: Duration = .seconds(1)
    /// After the Mac wakes, how long before looking whether the call its
    /// sleep stopped notes on is still on. The call detector looks once a
    /// second, and a call that ended during the sleep is only over once it
    /// has been missing for the detector's grace, counted from its first look
    /// after waking. Looking sooner would find a finished call still "on" and
    /// start listening to nothing.
    static let wakeWait: Duration = .seconds(CallDetector.grace + 2)

    private(set) var flow = MeetingNotesFlow()
    /// Whether each side is reaching the notes, for the panel's lines.
    private(set) var health = CallChannelHealth()
    /// The short "writing down: you, them" check at the top of the call
    /// card while notes start. Nil until the first look of a call.
    private(set) var startCheck: CallStartCheck?
    /// The calendar event the call now belongs to, looked up once when the
    /// call started (`CallEventMatch`). Nil without one, or without calendar
    /// access: the notes are then named after the app, as before.
    private(set) var callEvent: MeetingEvent?
    /// Lines typed into the notes of the call now.
    private(set) var jotCount = 0
    /// The notes behind the "Notes ready" line, while it shows.
    private(set) var readyNotes: MeetingNotes?
    /// Whether that line says the notes are ready or that too little was
    /// said for any. Set as the notes are saved, before the line goes up.
    private(set) var readyOutcome: CallNotesPanel.Ready = .notes
    /// Until when this month's online notes are used, said under that line
    /// once a month (`CloudNotesAllowance`): these notes were written on the
    /// Mac for that reason.
    private(set) var readyAllowance: Date?
    /// False on a Mac that can't write notes: this call has none, and they
    /// are written online on `readyAllowance` instead. Said every time.
    private(set) var readyAllowanceMacWrites = true
    /// Under "Call saved, notes later": why there are no notes yet, as the
    /// page says it, when that isn't this month's notes being used up
    /// (`readyAllowance` says that one, with the day).
    private(set) var readyWaiting: String?
    /// Under "Notes ready" for a Free call locked past its limit: how many
    /// minutes are kept, and until when (`LockedCallWords.ready`).
    private(set) var readyLocked: ReadyLocked?

    struct ReadyLocked: Equatable {
        let minutes: Int
        let until: Date
    }
    /// To-dos in those notes, for the line to mention.
    var readyTodoCount: Int { readyNotes?.todos.count ?? 0 }
    /// When the finished call began, so its lines say times of day as the
    /// notes window does. The record stays the last call's until a new one
    /// begins.
    var readyStartedAt: Date? { record?.startedAt }
    /// On Free, whether the finished call's other side was two or more
    /// people heard as one "Them", so the card says Plus would have told
    /// them apart (`FreeVoicesHint`). The plan now: a call that started on
    /// a trial still says it once the trial has gone.
    var voicesHint: Bool {
        record.map { FreeVoicesHint.shows(for: $0, plan: CloudNotesService.shared.plan()) } ?? false
    }

    /// The call pill's mark. Stored rather than read off the flow, because
    /// it also hangs on the clock (the ask's ten seconds) and on the call
    /// app's mute, and the pill should redraw when those change, not on every
    /// look.
    private(set) var pillMark: MeetingNotesFlow.PillMark = .none
    /// What the pill and the notes card say about Free's limit, and when it
    /// started saying it: the closed notch shows it for
    /// `LimitWord.pillFor` from then.
    private(set) var limitWord: MeetingNotesFlow.LimitWord?
    private(set) var limitWordAt: Date?
    /// The plan's limit stopped a call's notes: Free's reminders count it
    /// (`UpgradeReminders.notesStopped`).
    @ObservationIgnored var onNotesStopped: () -> Void = {}
    /// The call app's own mute, as last seen while notes are taken.
    private(set) var isMuted = false
    /// What the compact island says once the call is over, and when it began
    /// saying it: "Writing notes…", then "Notes ready" (`CompactIsland`).
    private(set) var glance: CallNotesGlance?
    private(set) var glanceAt: Date?

    var isPaused: Bool { flow.pausedSince != nil }

    /// The call or meeting being written down right now, paused included:
    /// what a quit would stop (`QuitCheck`). Nil before the notes start and
    /// once they are being written up, which a relaunch finishes anyway.
    var takingNotes: OngoingCall? {
        if case let .recording(call, _) = flow.phase { return call }
        return nil
    }

    /// Read from the switch every time, so a call that starts just after it
    /// moved goes by the new answer. `seenSwitch` is read too only so that a
    /// view drawn from this (the Calls tab, the Voice page's call rows)
    /// redraws when Settings moves it: `@Observable` cannot see a defaults
    /// read on its own.
    var isEnabled: Bool {
        _ = seenSwitch
        return Self.isOn
    }
    /// The switch as last seen (`watchSwitch`).
    private var seenSwitch = MeetingNotesModel.isOn
    @ObservationIgnored private var switchWatch: NSObjectProtocol?
    var autoStart: Bool { Defaults.bool(Self.autoStartKey, default: false) }

    /// Where this Mac would write a call's notes now, for the line under
    /// "Take notes" (`NotesPlace`).
    var notesPlace: NotesPlace {
        if let previewNotesPlace { return previewNotesPlace }
        let service = CloudNotesService.shared
        return NotesPlace.of(online: service.offering, planWritesOnline: service.plan().limits.writesNotesOnline,
                             availability: CleanupService().availability)
    }
    /// What `notesPlace` says instead of asking, for the state gallery.
    @ObservationIgnored var previewNotesPlace: NotesPlace?

    /// Collapses the island when "Show" opens the notes window.
    @ObservationIgnored var onNavigateAway: (() -> Void)?
    /// Opens Settings › Plans. Wired by whoever owns the windows.
    @ObservationIgnored var onShowPlans: (() -> Void)?
    /// The glance changed: it brings the compact island up, so the island
    /// has to look again at whether to be on screen.
    @ObservationIgnored var onChange: (() -> Void)?
    /// The call as the call detector knows it NOW. The call the panel asked
    /// about was copied when it started, before a browser's tab could say
    /// it was Meet.
    @ObservationIgnored var latestCall: (() -> OngoingCall?)?
    /// The calendar event that fits a call starting at a time, in a meeting
    /// service if known (`CalendarWidgetModel.callEvent`). Never asks for
    /// calendar access; nil without it.
    @ObservationIgnored var eventNear: ((Date, MeetingLink.Provider?) -> MeetingEvent?)?

    @ObservationIgnored private let store = MeetingStore()
    /// The last few calls, for the notch's Calls tab. Kept here because
    /// this is what knows when a call's notes are saved.
    let recentCalls: RecentCalls
    /// "Add a recording": a recording somebody already has, read into a
    /// meeting of its own.
    let recordings: RecordingImporter
    /// The call notes are being taken of, as it is written: for the window
    /// beside the call and the notes window (`CallNotesLive`).
    let live: CallNotesLive
    /// The window beside the call; made the first time it is opened.
    @ObservationIgnored private var liveWindow: LiveTranscriptWindowController?
    @ObservationIgnored private let log: (String) -> Void = { MeetingDiagnostics.log($0) }
    /// Made on the first call with notes, so a Mac that never takes any
    /// never builds an audio engine for them.
    @ObservationIgnored private var mic: AudioCapture?
    @ObservationIgnored private var tap: CallAudioTap?
    /// What the Mac plays, and your side with it taken back out
    /// (`SpeakerEcho`); `echo` is the running call's, logged once a minute.
    @ObservationIgnored private var speakers: SpeakersTap?
    @ObservationIgnored private var echo: SpeakerEcho?
    @ObservationIgnored private var echoLoggedAt: Date?
    /// When the listening count was last kept (`keepCount`).
    @ObservationIgnored private var countKeptAt: Date?
    /// The call tap gone dead while the Mac still plays a voice
    /// (`CallTapWatch`), and what its two steps need: when the call tap
    /// last started, and the transcriber's format for the other side.
    @ObservationIgnored private var tapWatch = CallTapWatch()
    @ObservationIgnored private var callTapStartedAt: Date?
    @ObservationIgnored private var theirFormat: AVAudioFormat?
    /// Words written down for each side, and when the minute's line on both
    /// sides was last written.
    @ObservationIgnored private var wordsHeard: [MeetingSpeaker: Int] = [:]
    /// The lines each side has finished but holds back while its language
    /// is decided (`MeetingTrack.onHearing`): in the recent lines, never in
    /// the record.
    @ObservationIgnored private var heldLines: [MeetingSpeaker: [MeetingSegment]] = [:]
    @ObservationIgnored private var sidesLoggedAt: Date?
    /// Seals what is heard past Free's limit (`CallLock`), from the lock
    /// until the call is over and can no longer carry on. It holds the
    /// call's key, which is nowhere else on the Mac.
    @ObservationIgnored private var sealer: CallLock.Sealer?
    @ObservationIgnored private var mute: CallMuteWatcher?
    /// Made the first time it is asked for.
    @ObservationIgnored private var madeCallsPage: CallsPage?
    @ObservationIgnored private var me: MeetingTrack?
    @ObservationIgnored private var them: MeetingTrack?
    /// Tells the other side's voices apart, when the voice model is here
    /// (`CallVoiceModel`), and from how far into the call it listens: a
    /// call that came back keeps the numbers it already gave.
    @ObservationIgnored private var voices: CallVoiceListener?
    @ObservationIgnored private var voicesFrom: TimeInterval = 0
    /// The voices told apart so far, so each keeps its number from one
    /// look to the next (`CallVoices.Numbering`), and how far the last look
    /// reached, in seconds of the call.
    @ObservationIgnored private var voicesNumbering = CallVoices.Numbering()
    @ObservationIgnored private var voicesThrough: TimeInterval = 0
    /// Numbers the voices heard so far, every few seconds of the call.
    @ObservationIgnored private var voicesLooking: Task<Void, Never>?
    /// The voices are being told apart: from when the model starts until
    /// the call's lines are numbered for the last time.
    @ObservationIgnored private var splittingVoices = false
    /// Each side's sound on its way to its track, measured as it passes.
    @ObservationIgnored private var mine: MeetingInput?
    @ObservationIgnored private var theirs: MeetingInput?
    /// When each side's sound was first asked for: the microphone when the
    /// notes began, the call when its tap first started.
    @ObservationIgnored private var mineSince: Date?
    @ObservationIgnored private var theirsSince: Date?
    /// The microphone stream now running: when it started (nil when the last
    /// start failed), on which device, in which format. The start is also
    /// what tells a microphone with a noise gate from a dead one
    /// (`CallChannelHealth.microphoneInput`), so it is reset on every restart.
    @ObservationIgnored private var micStartedAt: Date?
    @ObservationIgnored private var micDevice: AudioDeviceID?
    @ObservationIgnored private var micFormat: AVAudioFormat?
    @ObservationIgnored private var micRestart = MicRestart()
    /// When the last finished sentence ended, either side: speech the level
    /// alone might have missed, for the silence rule.
    @ObservationIgnored private var lastWords: Date?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var record: MeetingRecord? {
        didSet { if recordIsLive { live.follow(record, in: folder) } }
    }
    /// Whether `record` is the one these notes write to. Not between a new
    /// start and `begin`: until then it is the last call's, still finishing.
    @ObservationIgnored private var recordIsLive = false
    /// The call `callEvent` was looked up for, so a call that drops and
    /// comes back is not looked up again.
    @ObservationIgnored private var eventCall: OngoingCall?
    /// Start and finish, one after the other, never overlapping: a call that
    /// drops and returns must not start listening before the last listening
    /// has stopped.
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var summaries: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var looking: Task<Void, Never>?
    @ObservationIgnored private var themRetry: Task<Void, Never>?
    @ObservationIgnored private var linger: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The app whose call the Mac's sleep stopped notes on, until the Mac
    /// has woken and looked whether that call is still on. The call detector
    /// may never say it started again: as far as it knows, it never ended.
    @ObservationIgnored private var stoppedBySleep: String?
    @ObservationIgnored private var wakeLook: Task<Void, Never>?
    /// Settles "Notes?" to a dot once its ten seconds are up.
    @ObservationIgnored private var askSettle: Task<Void, Never>?
    /// Held while notes in the room are taken, so the Mac does not doze off
    /// in the middle of a meeting nobody is typing through. Closing the lid
    /// still sleeps it, and that stops the notes.
    @ObservationIgnored private var awake: IOPMAssertionID?
    /// Starts the notes when "Always"'s countdown runs out.
    @ObservationIgnored private var countdown: Task<Void, Never>?
    /// The to-dos in the notes just saved, for "Notes ready · 2 to-dos".
    @ObservationIgnored private var savedTodos = 0
    /// Every pause, oldest first; the last is open while paused. Spans
    /// rather than a flag, because a recogniser hands a sentence over a
    /// moment after it was said: one said just before "Resume" arrives after
    /// it, and must still be left out.
    @ObservationIgnored private var pauses: [Pause] = []

    private struct Pause {
        var from: Date
        var to: Date?

        func holds(_ date: Date) -> Bool { date >= from && (to.map { date < $0 } ?? true) }
    }

    init() {
        recentCalls = RecentCalls(store: MeetingStore())
        recordings = RecordingImporter()
        live = CallNotesLive()
        recordings.onFolder = { [weak self] folder in
            guard let self else { return }
            callsPage.show(folder: folder)
            onNavigateAway?()
        }
        recordings.onSaved = { [weak self] folder, record, notes in
            self?.recordingSaved(record, notes: notes, in: folder)
        }
        recordings.onEnded = { [weak self] in
            self?.madeCallsPage?.refreshIfOpen()
            self?.recentCalls.refresh()
        }
    }

    /// A model standing in one state, for drawing it (the state gallery):
    /// no microphone, no call app's sound, no timers, no calendar, and no
    /// folder, so nothing is ever written. `event` is the calendar's for the
    /// call in `flow`, as if it had been looked up when the call started.
    init(previewing flow: MeetingNotesFlow, record: MeetingRecord? = nil,
         notes: MeetingNotes? = nil, event: MeetingEvent? = nil, reading: RecordingImporter.Reading? = nil,
         allowanceUntil: Date? = nil, locks: Bool = false,
         hearing: [CallLive.Hearing] = [], startCheck: CallStartCheck? = nil) {
        self.flow = flow
        self.startCheck = startCheck
        self.record = record
        readyNotes = notes
        readyAllowance = allowanceUntil
        readyOutcome = record.map { CallNotesPanel.ready(of: $0, notes: notes, writer: $0.notesWriter) } ?? .notes
        jotCount = record?.jots.count ?? 0
        if let event, let call = flow.phase.call {
            eventCall = call
            callEvent = event
        }
        pillMark = flow.pillMark(now: Date(), muted: false)
        let word = flow.limitWord(running: RunningTime.now(), plan: .free, locks: locks)
        if let record, let part = record.locked, let minutes = record.lockedMinutes {
            readyLocked = ReadyLocked(minutes: minutes, until: part.keptUntil)
        }
        limitWord = word
        limitWordAt = word.map { _ in Date() }
        recentCalls = RecentCalls(previewing: [])
        recordings = RecordingImporter(previewing: reading)
        live = CallNotesLive(previewing: record, hearing: hearing)
    }

    /// Notices the switch moving, wherever it was moved from. Set once, at
    /// launch, so the models the tests and the state gallery make never
    /// register.
    private func watchSwitch() {
        guard switchWatch == nil else { return }
        switchWatch = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookAtSwitch() }
        }
    }

    private func lookAtSwitch() {
        guard seenSwitch != Self.isOn else { return }
        seenSwitch = Self.isOn
        log("call notes switched \(seenSwitch ? "on" : "off")")
    }

    /// At launch: finish the notes of any call the app quit or crashed during.
    func start() {
        watchSwitch()
        // The listening count from before the quit: notes started again soon
        // after carry it on rather than starting a new one.
        if let data = UserDefaults.standard.data(forKey: Self.listeningKey),
           let kept = try? JSONDecoder().decode(NotesListening.self, from: data) {
            flow.restore(kept)
        }
        // Notes the Mac wrote offline, written online later: the window and
        // the Calls tab show the new ones. On a Mac that can't write notes,
        // these are the call's first, and the Mac says they are ready.
        CloudNotesService.shared.onRedone = { [weak self] folder, notes, first in
            guard let self else { return }
            // Still under the "Notes ready" line: it counts the new to-dos.
            if case let .ready(name, _) = flow.phase, name == folder.lastPathComponent {
                readyNotes = notes.isEmpty ? nil : notes
                if first {
                    // "Call saved, notes later" becomes "Notes ready".
                    readyOutcome = .notes
                    savedTodos = notes.todos.count
                    readyWaiting = nil
                    readyAllowance = nil
                    readyAllowanceMacWrites = true
                }
            }
            if first {
                live.settle(folder, as: .saved(.notes, todos: notes.todos.count), title: notes.title)
            }
            live.retitle(folder, as: notes.title)
            madeCallsPage?.refreshIfOpen()
            recentCalls.refresh()
            if first, let record = store.loadRecord(in: folder),
               let notice = CallNotesPanel.readyNotice(of: record, ready: CallNotesPanel.ready(of: record, notes: notes),
                                                       todos: notes.todos.count) {
                Notifications.post(title: notice.title, body: notice.body,
                                   identifier: Notifications.ID.notesReady(folder.lastPathComponent),
                                   opensCall: folder.lastPathComponent)
            }
        }
        guard isEnabled else { return }
        let unfinished = store.unfinishedFolders()
        guard !unfinished.isEmpty else { return }
        log("launch: \(unfinished.count) unfinished call(s) to finish")
        for folder in unfinished {
            guard var record = store.loadRecord(in: folder) else { continue }
            // Too short to keep, and the app quit before it went.
            if record.droppedAt != nil {
                remove(folder)
                continue
            }
            // A recording the app quit while it read: half its transcript
            // would make half its notes. The file is untouched, and can be
            // added again.
            if record.recording != nil, record.endedAt == nil {
                do {
                    try store.remove(folder)
                    log("launch: a recording read only in part, removed")
                } catch {
                    log("launch: part-read recording remove FAILED: \(error.localizedDescription)")
                }
                continue
            }
            var changed = MeetingKnownWords.forMeeting(record, typed: Self.typedWords()).respell(&record) > 0
            if record.endedAt == nil {
                let lastWord = record.segments.map(\.end).max() ?? 0
                record.endedAt = record.startedAt.addingTimeInterval(lastWord)
                changed = true
            }
            if changed { try? store.saveTranscript(record, in: folder) }
            summarise(record, in: folder, announce: false)
        }
    }

    // MARK: - From the call detector

    func callChanged(_ change: CallDetector.Change) {
        switch change {
        case .started(let call), .resumed(let call):
            log("call started: \(call.bundleID)")
            // Another app's call: the one the sleep stopped is not coming back.
            if let slept = stoppedBySleep, slept != call.bundleID {
                stoppedBySleep = nil
                wakeLook?.cancel()
                wakeLook = nil
            }
            lookUpEvent(for: call)
            send(.callStarted(call, at: Date()))
        case .ended(let call, let at):
            log("call ended: \(call.bundleID)")
            send(.callEnded(at: at))
        }
    }

    // MARK: - From the panel

    func takeNotes(always: Bool = false) {
        send(always ? .acceptAlways(at: Date()) : .accept(at: Date()))
    }

    func notNow() { send(.decline) }
    func stop() { send(.stop) }
    func dismiss() { send(.dismiss) }

    /// "Take notes" with no call: a meeting in the room, through the Mac's
    /// microphone, until "Stop". The calendar is asked which meeting it is,
    /// as for a call, so the notes can carry its name and who was invited.
    func takeNotesInPerson() {
        guard isEnabled, flow.handButton == .takeNotes else { return }
        let now = Date()
        let room = OngoingCall.inPerson(at: now)
        eventCall = room
        callEvent = eventNear?(now, nil)
        log("notes: in person, " + (callEvent.map { "event found, \($0.attendees.count) other(s)" } ?? "no event"))
        send(.takeNotesInPerson(at: now))
    }

    /// What the one "Take notes" button does now (`MeetingNotesFlow.handButton`).
    var handButton: MeetingNotesFlow.HandButton { flow.handButton }

    /// The "Take notes" button, in the Calls tab and the menu bar: notes in
    /// the room, the call's own notes while one is on, or "Stop".
    func pressHandButton() {
        switch flow.handButton {
        case .takeNotes: takeNotesInPerson()
        case .takeNotesOfCall: takeNotes()
        case .stop: stop()
        case .busy: break
        }
    }

    /// The meeting in the room while its notes are taken, for the island to
    /// show the way it shows a call. Nil otherwise: once the notes stop,
    /// there is nothing on to show.
    var inPersonCall: OngoingCall? {
        if case let .recording(call, _) = flow.phase, call.isInPerson { return call }
        return nil
    }

    /// The countdown tapped away: not now, but the offer stays.
    func skipCountdown() {
        guard case .startingSoon = flow.phase else { return }
        log("notes: countdown skipped")
        send(.decline)
    }

    /// The countdown cut short.
    func startNow() {
        guard case .startingSoon = flow.phase else { return }
        send(.accept(at: Date()))
    }

    func pause() { send(.pause(at: Date())) }
    func resume() { send(.resume(at: Date())) }

    /// The calls in the Airlock window, on this call.
    func showNotes() {
        guard case let .ready(name, _) = flow.phase else { return }
        callsPage.show(folder: store.root.appendingPathComponent(name, isDirectory: true))
        onNavigateAway?()
    }

    /// "See Plus" and "Get Plus" in the notes window, the comparison window's
    /// buttons and "Upgrade" under the notes once this month's online notes
    /// are used: Settings › Plans, where paying starts.
    func showPlans() {
        onShowPlans?()
        log("notes online: plans opened")
        onNavigateAway?()
    }

    /// The calls, on the one an answer in the notch came from, at the
    /// moment it cites.
    func showCall(folder: String, saidAt time: TimeInterval) {
        callsPage.show(folder: store.root.appendingPathComponent(folder, isDirectory: true), saidAt: time)
        UsageCounts.shared.record(.used(.callNotesOpened))
        onNavigateAway?()
    }

    /// The call "Welcome to Plus" offers to write again, read off the main
    /// thread: the last one, when the notes window would offer the same redo
    /// (`WelcomeCard.redoCall`). Nil when there is none.
    func welcomeRedo(plan: PlanSnapshot) async -> (folder: URL, record: MeetingRecord)? {
        let store = store
        let online = CloudNotesService.shared.offering
        return await Task.detached(priority: .utility) {
            WelcomeCard.redoCall(store.calls(), page: { store.notesPage(in: $0) }, plan: plan, online: online)
        }.value
    }

    /// Whether the notes still hold `folder`'s call in memory: being heard,
    /// written up, or waiting a moment in case it carries on. What is on disk
    /// for it may be rewritten from memory, so `CallUnlockService` leaves it.
    func isHolding(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        if self.folder?.standardizedFileURL.path == path { return true }
        return summaries.keys.contains { $0.standardizedFileURL.path == path }
    }

    /// A call changed on disk from elsewhere (`CallUnlockService`): the
    /// Calls tab and an open calls window read it again.
    func callsChangedOnDisk() {
        madeCallsPage?.refreshIfOpen()
        recentCalls.refresh()
    }

    /// "Redo" on the welcome card: the same request as the notes window's.
    func redoNotes(in folder: URL) async -> CloudNotesService.Redo {
        let result = await CloudNotesService.shared.redo(folder, log: { MeetingDiagnostics.log($0) })
        recentCalls.refresh()
        return result
    }

    /// The calls, on one picked on the notch's Calls tab.
    func showCall(folder: String) {
        callsPage.show(folder: store.root.appendingPathComponent(folder, isDirectory: true))
        UsageCounts.shared.record(.used(.callNotesOpened))
        onNavigateAway?()
    }

    /// "Add a recording", from the Calls tab and the menu bar: asks which.
    /// While one is being read, opens the window on it instead, where how
    /// far along it is shows.
    func addRecording() {
        if let folder = recordings.reading?.folder {
            callsPage.show(folder: folder)
        } else {
            recordings.choose()
        }
    }

    /// The calls, on the newest, from the menu bar, Settings or
    /// the Calls tab's "All calls": any call, whenever, not only the one
    /// "Open notes" offers as it ends. With none saved yet the window says
    /// so. The menu bar and Settings are not the island, so there is nothing
    /// to collapse; from the tab, the island steps aside for the window.
    func showPastCalls(fromIsland: Bool = false) {
        callsPage.show(folder: nil)
        UsageCounts.shared.record(.used(.callNotesOpened))
        if fromIsland { onNavigateAway?() }
    }

    /// "Open in a window": the transcript of the call notes are being taken
    /// of, in a narrow window beside the call, as it is written.
    func openLiveWindow() {
        let shown = liveWindow ?? LiveTranscriptWindowController(live: live, actions: LiveTranscriptActions(
            isPaused: { [weak self] in self?.isPaused ?? false },
            pause: { [weak self] in self?.pause() },
            resume: { [weak self] in self?.resume() },
            stop: { [weak self] in self?.stop() },
            open: { [weak self] tab in
                // The big window takes over: two windows on one call is one
                // too many to close afterwards.
                self?.showLiveCall(on: tab)
                self?.liveWindow?.close()
            },
            close: { [weak self] in self?.liveWindow?.close() },
            canName: { [weak self] voice in self?.canNameLive(voice) ?? true },
            name: { [weak self] names in self?.nameLiveCall(names) }))
        liveWindow = shown
        shown.show()
        log("live transcript: opened")
        onNavigateAway?()
    }

    /// The calls, on the one the live transcript shows, on `tab`.
    func showLiveCall(on tab: CallNotesLibrary.Tab) {
        guard let folder = live.folder else { return }
        callsPage.show(folder: folder, on: tab)
    }

    /// The Calls page of the Airlock window, which the app hands to the window
    /// at launch. Every way into a call here goes through it.
    var callsPage: CallsPage {
        if let madeCallsPage { return madeCallsPage }
        let made = CallsPage(store: store)
        made.follow(live, openWindow: { [weak self] in self?.openLiveWindow() },
                    isPaused: { [weak self] in self?.isPaused ?? false })
        made.takeNotes(state: { [weak self] in self?.handButton ?? .busy },
                       press: { [weak self] in self?.pressHandButton() })
        made.saveNames { [weak self] folder, names in self?.saveNames(names, in: folder) }
        made.checkWords { [weak self] folder, answer in self?.checkWord(answer, in: folder) }
        made.recordings(CallNotesLibrary.Recordings(
            reading: { [weak self] in self?.recordings.reading },
            takes: { [weak self] url in self?.recordings.takes(url) ?? false },
            add: { [weak self] in self?.recordings.choose() },
            drop: { [weak self] url in self?.recordings.add(url) },
            stop: { [weak self] in self?.recordings.stop() }))
        let notes = CloudNotesService.shared
        made.offering(CallNotesLibrary.Offering(
            offers: { call in
                CallNotesOffers.of(call.record, page: call.page, plan: notes.plan(), online: notes.offering)
            },
            showPlans: { [weak self] in self?.showPlans() },
            showComparison: { [weak self] in self?.showComparison() },
            redo: { [weak self] call in
                let result = await notes.redo(call.folder, log: { MeetingDiagnostics.log($0) })
                self?.recentCalls.refresh()
                return result
            },
            plan: { notes.plan() }))
        madeCallsPage = made
        return made
    }

    /// "What each plan writes": one sample call's notes as each plan writes
    /// them, one plan at a time.
    func showComparison() {
        NotesComparisonWindowController.shared.show(plan: CloudNotesService.shared.plan().plan,
                                                    showPlans: { [weak self] in self?.showPlans() })
        log("notes online: comparison shown")
    }

    /// Names given to a call's voices in the notes window. The call these
    /// notes hold, which may still carry on, is named in memory as well, or
    /// its next save would write the names away again. Names said while its
    /// notes are being written are kept too: the page is named as it is
    /// saved (`MeetingStore.saveNotes`).
    func saveNames(_ names: [MeetingVoiceName], in folder: URL) {
        let held = folder == self.folder
        guard var record = held ? self.record : store.loadRecord(in: folder) else { return }
        record.replaceNames(with: names)
        if held { self.record = record }
        do {
            try store.saveNames(of: record, in: folder)
            log("names: \(record.names.count) of \(record.voices.count) voice(s) named")
        } catch {
            log("names: save FAILED: \(error.localizedDescription)")
        }
        madeCallsPage?.refreshIfOpen()
        recentCalls.refresh()
    }

    /// A word on "Check these words" answered in the calls window. "Use"
    /// also adds it to the words in Settings, so the next call spells it
    /// the same way, unless it is a figure (`MeetingWordCheck`).
    func checkWord(_ answer: CallNotesLibrary.WordAnswer, in folder: URL) {
        let held = folder == self.folder
        do {
            let record = try store.checkWord(answer.best, heard: answer.heard, use: answer.use, in: folder,
                                             record: held ? self.record : nil)
            if held, let record { self.record = record }
            log("words: \(answer.use ? "used" : "left") one word to check")
        } catch {
            log("words: save FAILED: \(error.localizedDescription)")
        }
        if answer.use, MeetingWordCheck.belongsInKnownWords(answer.best) {
            let typed = Self.typedWords()
            let list = MeetingKnownWords.adding(answer.best, to: typed)
            if list != typed { UserDefaults.standard.set(list, forKey: Self.knownWordsKey) }
        }
        madeCallsPage?.refreshIfOpen()
        recentCalls.refresh()
    }

    /// Names given in the side window, to the call it shows: during the
    /// call, as its voices are told apart, or once it is over. The other
    /// side named before any of it was told apart is one person from then
    /// on, and the voice model stops.
    private func nameLiveCall(_ names: [MeetingVoiceName]) {
        guard let folder = live.folder else { return }
        saveNames(names, in: folder)
        live.rename(names, in: folder)
        guard folder == self.folder, let record else { return }
        if CallVoices.isNamedAsOne(record) { stopTellingVoicesApart() }
    }

    /// Whether the side window can name `voice` now. While the voices are
    /// told apart, the other side heard as one can be named until any of
    /// its lines has a number (`CallVoices.canName`), and not at all while
    /// the call's last pass numbers them.
    private func canNameLive(_ voice: Int) -> Bool {
        guard splittingVoices else { return true }
        guard voices != nil, let record else { return voice != MeetingRecord.otherSide }
        return CallVoices.canName(voice, of: record)
    }

    /// The name the panel gives a call: Meet once the tab has said so, even
    /// if it had not yet when the call was offered.
    func callName(_ call: OngoingCall) -> String {
        var site = current(call).site
        if site == nil, record?.bundleID == call.bundleID {
            if case .offering = flow.phase {} else { site = record?.site }
        }
        return site?.displayName ?? call.appName
    }

    /// What the panel calls a call while asking about it: the meeting's
    /// name from the calendar, else the other person's on a one-to-one call,
    /// else the app's or the service's (`callName`).
    func callTitle(_ call: OngoingCall) -> String {
        if call.isInPerson { return listedTitle(call) }
        guard let event = event(for: call) else { return callName(call) }
        return event.name ?? event.oneToOne ?? callName(call)
    }

    /// What the call notes list calls the call (`MeetingFiles.title`), for
    /// the lines about its notes once the call is over: "Writing your
    /// notes…" and "Notes ready" name the notes as they will be found,
    /// "Notes ready" by the name the notes gave it.
    func listedTitle(_ call: OngoingCall) -> String {
        MeetingFiles.title(event: event(for: call), callName: callName(call), inPerson: call.isInPerson,
                           topic: readyTitle(for: call))
    }

    /// The name the notes gave the call, while "Notes ready" is about them.
    private func readyTitle(for call: OngoingCall) -> String? {
        guard case let .ready(_, ready) = flow.phase, ready.bundleID == call.bundleID else { return nil }
        return readyNotes?.title
    }

    /// The notes' own event once they have started (they keep the one they
    /// started with), the call's before that.
    private func event(for call: OngoingCall) -> MeetingEvent? {
        if record?.bundleID == call.bundleID, let event = record?.event {
            if case .offering = flow.phase {} else { return event }
        }
        return eventCall?.bundleID == call.bundleID ? callEvent : nil
    }

    /// Looks the call up in the calendar, once per call, and only when notes
    /// are on: nothing reads the calendar for a feature nobody uses.
    private func lookUpEvent(for call: OngoingCall) {
        guard isEnabled, eventCall != call else { return }
        eventCall = call
        let site = call.site ?? CallEventMatch.provider(ofApp: call.bundleID)
        callEvent = eventNear?(call.startedAt, site)
        // Never the title or the names: the log is counts only.
        log(callEvent.map { "event: found, \($0.attendees.count) other(s)" } ?? "event: none")
    }

    /// A typed line for the notes, at the moment it was typed.
    func jot(_ text: String) {
        guard case .recording = flow.phase, var record else { return }
        let before = record.jots.count
        record.jot(text, at: Date().timeIntervalSince(record.startedAt))
        guard record.jots.count > before else { return }
        self.record = record
        jotCount = record.jots.count
        log("jot: \(jotCount)")
        saveSoon()
    }

    /// "That was important": the last half-minute is marked for the notes.
    /// Not while paused (`CallNotesPanel.offersMark`). Returns whether a
    /// mark was made, so the panel says "Marked" only then.
    @discardableResult
    func mark() -> Bool {
        guard CallNotesPanel.offersMark(flow), var record else { return false }
        record.mark(at: Date().timeIntervalSince(record.startedAt))
        self.record = record
        log("mark: \(record.marks.count)")
        saveSoon()
        return true
    }

    /// The ready call's notes, as written, for pasting anywhere.
    func copyNotes() {
        guard case let .ready(name, _) = flow.phase,
              let page = store.notesPage(in: store.root.appendingPathComponent(name, isDirectory: true))
        else { return }
        AirlockCopy.put(page)
        log("copy: notes")
    }

    /// A line to paste into the call's chat, so the others know.
    func copyHeadsUp() {
        AirlockCopy.put(CallNotesPanel.headsUp)
    }

    /// Where macOS keeps "System Audio Recording", the permission a tap on
    /// the call app's sound needs.
    func openAudioPermission() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
        onNavigateAway?()
    }

    /// Whether macOS was told no for the microphone. Asked only once your
    /// side has gone quiet, so the line can say why instead of just that.
    var microphoneRefused: Bool { AVAudioApplication.shared.recordPermission == .denied }

    /// Where macOS keeps the Microphone permission.
    func openMicrophonePermission() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
        onNavigateAway?()
    }

    /// When notes have been running, for the panel's timer.
    var recordingSince: Date? {
        if case let .recording(_, since) = flow.phase { return since }
        return nil
    }

    // MARK: - Flow

    private func send(_ event: MeetingNotesFlow.Event) {
        // Applied to a copy and stored only when something changed: the ticks
        // come every second, and every store redraws whatever reads `flow`.
        var next = flow
        let running = RunningTime.now()
        let plan = CloudNotesService.shared.plan()
        let effects = next.apply(event, enabled: isEnabled, autoStart: autoStart, running: running, plan: plan,
                                 locks: Self.locks)
        let before = flow
        if next != flow { flow = next }
        if next.listening != before.listening { keepCount(next.listening) }
        if next.stoppedAtLimit, !before.stoppedAtLimit {
            log("notes: stopped, the plan's listening time is used up")
            onNotesStopped()
        }
        if event.asksToStart, !effects.contains(where: \.startsNotes),
           next.listening?.isSpent(at: running, plan: plan) == true {
            log("notes: not started, this meeting's listening time is used up")
        }
        if before.isWaitingForCallBack != next.isWaitingForCallBack, case .recording = next.phase {
            log(next.isWaitingForCallBack ? "notes: waiting to be sure the call ended" : "notes: the call is back")
        }
        // Before the effects, so notes that end while paused close their
        // pause in their own record, not the next one's.
        followPauseInRecord()
        for effect in effects {
            switch effect {
            case .rememberAlways:
                Defaults.set(true, Self.autoStartKey)
                log("always: on")
            case let .startNotes(call, continuing):
                recordIsLive = false
                enqueue { await self.begin(call, continuing: continuing) }
            case .lockNotes:
                log("notes: locked, the plan's listening time is used up; still listening")
                lockIfDue()
                onNotesStopped()
            case .finishNotes:
                // Stopped or locked by the plan's limit: the page says how
                // much it covers.
                let cut = next.stoppedAtLimit || next.locked ? next.listening?.limit(now: plan) : nil
                enqueue { await self.finish(stoppedAtLimit: cut) }
            case .dropNotes:
                enqueue { await self.finish(keeping: false) }
            case .pauseNotes:
                // The listening carries on; what is heard meanwhile is left
                // out as it arrives (`heard`).
                pauses.append(Pause(from: next.pausedSince ?? Date()))
                log("notes: paused")
            case .resumeNotes:
                log("notes: resumed")
            }
        }
        // Unpaused, by a resume or by the notes ending, the open pause ends
        // here. Ending notes keep their pause up to this moment, so the
        // recognisers' last sentences from the pause are still left out.
        if next.pausedSince == nil { closePause(at: Date()) }
        // Put away, the call can't carry on: its key goes.
        if before.locked, !next.locked, !next.phase.isRecording { sealer = nil }
        if before.phase != next.phase {
            // Said beside the call too, whether it stopped mid-call or once
            // it was over.
            if case let .failed(reason) = next.phase, recordIsLive { live.failed(reason) }
            if case .ready = next.phase {} else {
                if readyNotes != nil { readyNotes = nil }
                if readyAllowance != nil { readyAllowance = nil }
                if readyWaiting != nil { readyWaiting = nil }
                if readyLocked != nil { readyLocked = nil }
            }
            if !next.phase.isRecording, isMuted { isMuted = false }
            scheduleLinger()
            followRecording()
            followCountdown()
            followGlance()
        }
        // The call is over and nothing is left to show for it: its event
        // goes with it, so the next call starts clean.
        if case .idle = flow.phase, eventCall != nil, latestCall?() == nil {
            eventCall = nil
            callEvent = nil
        }
        refreshPillMark()
        // Each new offer asks for its own ten seconds.
        if case .callStarted = event {
            askSettle?.cancel()
            askSettle = nil
        }
        settleTheAsk()
    }

    /// Keeps the listening count as it stands now, closed here, for the next
    /// launch (`MeetingNotesFlow.restore`).
    private func keepCount(_ count: NotesListening?) {
        countKeptAt = Date()
        guard let count, let data = try? JSONEncoder().encode(count.kept(at: RunningTime.now())) else { return }
        UserDefaults.standard.set(data, forKey: Self.listeningKey)
    }

    private func refreshPillMark() {
        let mark = flow.pillMark(now: Date(), muted: isMuted)
        if mark != pillMark { pillMark = mark }
        let word = flow.limitWord(running: RunningTime.now(), plan: CloudNotesService.shared.plan(),
                                  locks: Self.locks)
        if word != limitWord {
            limitWord = word
            limitWordAt = word == nil ? nil : Date()
        }
    }

    /// "Notes?" settles to a dot after `askWiden`: one wake to redraw it,
    /// since nothing else happens while an offer waits. Still asking after
    /// it (a clock set back a little), it waits again.
    private func settleTheAsk() {
        guard pillMark == .ask else {
            askSettle?.cancel()
            askSettle = nil
            return
        }
        guard askSettle == nil else { return }
        askSettle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MeetingNotesFlow.askWiden))
            guard !Task.isCancelled, let self else { return }
            self.askSettle = nil
            self.refreshPillMark()
            self.settleTheAsk()
        }
    }

    /// "Always": the notes start when the countdown runs out, unless it was
    /// skipped or the call ended first.
    private func followCountdown() {
        countdown?.cancel()
        countdown = nil
        guard case let .startingSoon(_, startsAt) = flow.phase else { return }
        log("always: notes in \(Int(MeetingNotesFlow.countdown))s")
        let phase = flow.phase
        countdown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, startsAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.flow.phase == phase else { return }
            self.countdown = nil
            self.send(.accept(at: Date()))
        }
    }

    /// The island's few words after the call. Stamped when they change, so
    /// "Notes ready" is shown for its eight seconds from the moment it was.
    private func followGlance() {
        let glance: CallNotesGlance?
        switch flow.phase {
        case .writing: glance = .writing
        case .ready:
            glance = Self.glance(readyOutcome, todos: savedTodos)
        default: glance = nil
        }
        guard glance != self.glance else { return }
        self.glance = glance
        glanceAt = glance == nil ? nil : Date()
        onChange?()
    }

    /// The island's few words for notes saved as `ready` says.
    static func glance(_ ready: CallNotesPanel.Ready, todos: Int) -> CallNotesGlance {
        switch ready {
        case .notes: .ready(todos: todos)
        case .tooLittleSaid: .tooLittleSaid
        case .later: .later
        }
    }

    /// A recording's notes are saved: the island's tick, as after a call,
    /// unless a call's notes are under way and the island is theirs. It
    /// goes again once shown, so the next call's glance is stamped afresh.
    private func recordingSaved(_ record: MeetingRecord, notes: MeetingNotes?, in folder: URL) {
        guard isEnabled, case .idle = flow.phase else { return }
        let ready = CallNotesPanel.ready(of: record, notes: notes, writer: store.loadRecord(in: folder)?.notesWriter)
        glance = Self.glance(ready, todos: notes?.todos.count ?? 0)
        let stamp = Date()
        glanceAt = stamp
        onChange?()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(CompactIsland.notesReadyDuration))
            guard let self, glanceAt == stamp, case .idle = flow.phase else { return }
            glance = nil
            glanceAt = nil
        }
    }

    /// The saved record keeps the notes' pauses, so the transcript says
    /// where nothing was written down. Opened where the pause began, closed
    /// on a resume or when the notes end, whichever comes first.
    private func followPauseInRecord() {
        guard recordIsLive, var record, record.endedAt == nil,
              record.followPause(since: flow.pausedSince, now: Date()) else { return }
        self.record = record
        log(record.isPaused ? "notes: pause kept in the record" : "notes: pause closed in the record")
        saveSoon()
    }

    private func closePause(at date: Date) {
        guard let last = pauses.indices.last, pauses[last].to == nil else { return }
        pauses[last].to = date
    }

    /// Whether `date` fell inside a pause.
    private func wasPaused(at date: Date) -> Bool {
        pauses.contains { $0.holds(date) }
    }

    /// Speech heard at `date`, unless it was during a pause: what is said
    /// then is not written down, so it is not the call's either. It neither
    /// shows the call is live nor holds off its end.
    private func spoken(_ date: Date?) -> Date? {
        guard let date, !wasPaused(at: date) else { return nil }
        return date
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task {
            await previous?.value
            await work()
        }
    }

    private func scheduleLinger() {
        linger?.cancel()
        linger = nil
        switch flow.phase {
        case .ready, .failed:
            let phase = flow.phase
            linger = Task { [weak self] in
                try? await Task.sleep(for: Self.readyLinger)
                guard !Task.isCancelled, let self, self.flow.phase == phase else { return }
                self.send(.dismiss)
            }
        default:
            break
        }
    }

    // MARK: - Looking while notes are taken

    /// Looks once a second while notes are taken, and not at all otherwise.
    /// The flow's waits are dates compared on these looks, so they hold
    /// across the Mac sleeping: the wall clock keeps counting through it.
    private func followRecording() {
        guard case .recording = flow.phase else {
            looking?.cancel()
            looking = nil
            return
        }
        watchTheMac()
        guard looking == nil else { return }
        looking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.lookEvery)
                guard !Task.isCancelled, let self else { return }
                self.look()
            }
        }
    }

    private func look() {
        guard case let .recording(call, _) = flow.phase else { return }
        let now = Date()
        if now.timeIntervalSince(countKeptAt ?? .distantPast) >= Self.listeningKeptEvery {
            keepCount(flow.listening)
        }
        keepMicrophoneGoing(now: now)
        if let echo, now.timeIntervalSince(echoLoggedAt ?? now) >= Self.echoLogEvery {
            echoLoggedAt = now
            log(echoLine(echo))
        }
        watchCallTap(call, now: now)
        if theirs != nil, now.timeIntervalSince(sidesLoggedAt ?? now) >= Self.echoLogEvery {
            sidesLoggedAt = now
            log(sidesLine(now: now))
        }

        let yours = mine?.reading ?? MeetingInput.Reading()
        let theirs = self.theirs?.reading ?? MeetingInput.Reading()
        let (yourSpeech, theirSpeech) = (spoken(yours.lastSpeech), spoken(theirs.lastSpeech))
        // In the room there is no call app, so no mute button to follow.
        let muted = call.isInPerson ? false : mute?.gate.isMuted(at: now) ?? false
        var health = self.health
        let yourInput = CallChannelHealth.microphoneInput(
            lastBuffer: yours.lastBuffer, lastSound: yours.lastSound, streamStartedAt: micStartedAt)
        let yourSide = CallChannelHealth.Side(since: mineSince, lastInput: yourInput,
                                              lastSpeech: yourSpeech, heardAnything: yours.heardAnything)
        if call.isInPerson {
            health.update(room: yourSide, now: now)
        } else {
            health.update(
                yours: yourSide,
                theirs: .init(since: theirsSince, lastInput: theirs.lastBuffer,
                              lastSpeech: theirSpeech, heardAnything: theirs.heardAnything),
                youAreMuted: muted,
                now: now)
        }
        if health != self.health {
            log("reaching: yours missing \(health.yoursMissing), theirs missing \(health.theirsMissing), "
                + "theirs not allowed \(health.theirsNotAllowed)")
            self.health = health
        }
        if muted != isMuted { isMuted = muted }
        checkStart(call, yours: yours, theirs: theirs, health: health, now: now)

        let lastSpeech = [yourSpeech, theirSpeech, lastWords].compactMap { $0 }.max()
        let onMic = flow.isWaitingForCallBack ? Self.isOnMicrophone(call.bundleID) : nil
        send(.tick(.init(now: now, callOnMic: onMic, lastSpeech: lastSpeech,
                         theirLastSpeech: theirSpeech)))
    }

    /// Feeds the start check, and keeps how the other side went for the
    /// next call and for Settings › Permissions (`OtherSideHistory`).
    private func checkStart(_ call: OngoingCall, yours: MeetingInput.Reading, theirs: MeetingInput.Reading,
                            health: CallChannelHealth, now: Date) {
        let history = OtherSideHistory.read()
        if !call.isInPerson {
            let seen: OtherSideHistory? = theirs.heardAnything ? .worked
                : health.theirsNotAllowed ? .refused : nil
            if let seen, seen != history {
                log("other side: \(seen.rawValue)")
                seen.save()
            }
        }
        var check = startCheck ?? CallStartCheck(inPerson: call.isInPerson)
        check.update(micHeard: yours.heardAnything, micRefused: microphoneRefused,
                     theirsHeard: theirs.heardAnything, theirsNotAllowed: health.theirsNotAllowed,
                     lastCallRefused: history == .refused, now: now)
        if check != startCheck { startCheck = check }
    }

    /// Whether any of the call app's processes is taking sound from a
    /// microphone, by the rule that found the call.
    private static func isOnMicrophone(_ bundleID: String) -> Bool {
        CallMonitor.audioProcesses(ofCallApp: bundleID).contains {
            AudioProcesses.bool($0, kAudioProcessPropertyIsRunningInput)
        }
    }

    /// The call app quitting and the Mac going to sleep, which the flow
    /// stops on, and the Mac waking, which may find the call still on.
    /// Watched from the first notes on, for the app's lifetime: three
    /// observers, and nothing happens unless notes are being taken or a
    /// sleep stopped them.
    private func watchTheMac() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bundleID = app?.bundleIdentifier else { return }
            Task { @MainActor [weak self] in self?.appQuit(bundleID) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.macWillSleep() }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.macDidWake() }
        })
    }

    private func appQuit(_ bundleID: String) {
        guard case let .recording(call, _) = flow.phase, call.bundleID == bundleID else { return }
        log("call app quit: \(bundleID)")
        send(.appQuit(bundleID: bundleID, at: Date()))
    }

    private func macWillSleep() {
        // Asleep again before the last wake looked: the next wake looks.
        wakeLook?.cancel()
        wakeLook = nil
        guard case let .recording(call, _) = flow.phase else { return }
        log("mac going to sleep: notes stop")
        // A meeting in the room has no call to find again on waking.
        stoppedBySleep = call.isInPerson ? nil : call.bundleID
        send(.sleep(at: Date()))
    }

    /// The flow decides what a call still on after waking means: the same
    /// notes carried on inside `sameMeetingWindow`, asked about again after
    /// it (or new notes, with "Always").
    private func macDidWake() {
        guard let bundleID = stoppedBySleep else { return }
        wakeLook?.cancel()
        wakeLook = Task { [weak self] in
            try? await Task.sleep(for: Self.wakeWait)
            guard !Task.isCancelled, let self else { return }
            self.wakeLook = nil
            self.stoppedBySleep = nil
            if let call = self.latestCall?(), call.bundleID == bundleID {
                self.log("mac woke: \(bundleID) still on a call")
                self.send(.callStarted(call, at: Date()))
            } else {
                self.log("mac woke: the call is over")
            }
        }
    }

    // MARK: - Listening

    private func begin(_ call: OngoingCall, continuing: Bool) async {
        let call = current(call)
        let now = Date()
        if continuing, let folder, var record {
            summaries[folder]?.cancel()
            summaries[folder] = nil
            record.endedAt = nil
            record.droppedAt = nil
            self.record = record
            jotCount = record.jots.count
            log("notes: continuing \(folder.lastPathComponent)")
        } else {
            // The event found when the call started, if it is this call's.
            let event = eventCall?.bundleID == call.bundleID ? callEvent : nil
            // Nothing from before these notes can be heard in them.
            pauses.removeAll { $0.to.map { $0 <= now } ?? false }
            // The plan is fixed here: a plan that ends during the call does
            // not change how its notes are written (`PlanSnapshot.kept`).
            let record = MeetingRecord(bundleID: call.bundleID, appName: call.appName,
                                       site: call.site, startedAt: now, event: event,
                                       startedOn: CloudNotesService.shared.plan())
            sealer = nil
            jotCount = 0
            do {
                folder = try store.makeFolder(for: record)
            } catch {
                log("notes: folder FAILED: \(error.localizedDescription)")
                send(.failed(CallLive.Stopped.noFolder))
                return
            }
            self.record = record
            log("notes: new \(folder?.lastPathComponent ?? "?")")
        }
        // A pause made while this waited its turn belongs to these notes.
        recordIsLive = true
        live.follow(record, in: folder)
        followPauseInRecord()
        // Locked while this waited its turn.
        lockIfDue()
        saveNow()
        // On disk now: a notes window left open lists the call as it starts.
        madeCallsPage?.refreshIfOpen()

        guard let setup = await speechSetup() else {
            send(.failed(CallLive.Stopped.noSpeechModel))
            return
        }
        let (picked, format, listeners) = setup
        // Still wanted? The call may have ended while the model loaded.
        guard case .recording = flow.phase else { return }
        record?.languages = picked.map(\.identifier)
        let offset = record.map { Date().timeIntervalSince($0.startedAt) } ?? 0
        lastWords = nil
        if call.isInPerson {
            beginInPerson(picked: picked, format: format, listeners: listeners, offset: offset)
            return
        }

        // Your side. The track is made whether or not the microphone starts:
        // `keepMicrophoneGoing` keeps trying, into the same track.
        let mute = mute ?? CallMuteWatcher(log: log)
        self.mute = mute
        mute.start(call: call)
        let gate = mute.gate
        let mine = MeetingInput(isMuted: { gate.isMuted(at: $0) })
        self.mine = mine
        mineSince = Date()
        micFormat = format
        micRestart = MicRestart()
        startMicrophone(into: mine, format: format)
        let track = MeetingTrack(speaker: .me, listeners: listeners, canRead: CallNotesWriter.canRead,
                                 log: log) { [weak self] in self?.heard($0, from: .me) }
        track.onHearing = { [weak self] in self?.hearing($0, $1, from: .me) }
        let heard = startEchoRemoval().map { $0.cleaning(mine.output) } ?? mine.output
        track.begin(picked, format: format, offset: offset, input: gate.silencing(heard))
        me = track

        // Their side, once a sleeping Bluetooth headset is awake.
        theirs = MeetingInput()
        theirsSince = nil
        tapWatch = CallTapWatch(silentBetweenWords: CallTapWatch.silentBetweenWords(call.bundleID))
        callTapStartedAt = nil
        theirFormat = format
        wordsHeard = [:]
        heldLines = [:]
        sidesLoggedAt = Date()
        log(await OutputWake.wakeIfBluetooth())
        startThem(call, picked: picked, listeners: listeners, format: format, attempt: 0)
    }

    /// A meeting in the room: the Mac's microphone is the only side, and
    /// everybody on it is "them", told apart by voice. No call app to tap,
    /// no mute button to follow, and nothing the Mac plays to take back out.
    /// The Mac is kept awake until the notes end.
    private func beginInPerson(picked: [CallLanguageFollow.Listener], format: AVAudioFormat,
                               listeners: CallListeners, offset: TimeInterval) {
        let room = MeetingInput()
        mine = room
        mineSince = Date()
        micFormat = format
        micRestart = MicRestart()
        wordsHeard = [:]
        heldLines = [:]
        startMicrophone(into: room, format: format)
        let track = MeetingTrack(speaker: .them, listeners: listeners, canRead: CallNotesWriter.canRead,
                                 log: log) { [weak self] in self?.heard($0, from: .them) }
        track.onHearing = { [weak self] in self?.hearing($0, $1, from: .them) }
        track.begin(picked, format: format, offset: offset, input: room.output)
        them = track
        holdAwake()
        listenForVoices(on: track)
        log("notes: in person, from the Mac's microphone")
    }

    private func holdAwake() {
        guard awake == nil else { return }
        var assertion = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Airlock — taking notes of a meeting" as CFString, &assertion)
        awake = result == kIOReturnSuccess ? assertion : nil
        log(result == kIOReturnSuccess ? "awake: held" : "awake: FAILED (\(result))")
    }

    private func releaseAwake() {
        guard let awake else { return }
        IOPMAssertionRelease(awake)
        self.awake = nil
        log("awake: released")
    }

    /// Starts the microphone on whichever device the Mac is set to now, and
    /// joins its sound onto `input`.
    ///
    /// Named rather than left to "the default": an engine that kept running
    /// through a change of microphone could otherwise stay on the old one.
    private func startMicrophone(into input: MeetingInput, format: AVAudioFormat) {
        let device = SystemMicrophone.currentID()
        micDevice = device
        let mic = mic ?? AudioCapture(log: { MeetingDiagnostics.log("mic: \($0)") })
        self.mic = mic
        do {
            let uid = device.flatMap(SystemMicrophone.uid(of:)) ?? ""
            input.feed(try mic.start(analyzerFormat: format, deviceUID: uid))
            micStartedAt = Date()
        } catch {
            micStartedAt = nil
            log("mic FAILED: \(error.localizedDescription)")
        }
    }

    /// Listens to everything the Mac plays, so your side can have it taken
    /// back out. Nil when switched off (`echoRemovalKey`). A tap that will
    /// not start still returns the stage: with nothing played to go on, it
    /// hands your side on as it was heard.
    private func startEchoRemoval() -> SpeakerEcho? {
        guard UserDefaults.standard.object(forKey: Self.echoRemovalKey) as? Bool ?? true else {
            log("echo: off")
            return nil
        }
        let echo = SpeakerEcho()
        let speakers = speakers ?? SpeakersTap(log: log)
        self.speakers = speakers
        do {
            try speakers.start(into: echo)
        } catch {
            log("echo: speakers tap FAILED: \(error.localizedDescription)")
        }
        self.echo = echo
        echoLoggedAt = Date()
        return echo
    }

    /// What the echo stage did so far: numbers only, never a sound.
    private func echoLine(_ echo: SpeakerEcho) -> String {
        let report = echo.report
        var line = "echo: "
        line += report.delayMilliseconds.map { String(format: "delay %.0f ms", $0) } ?? "no delay found"
        line += String(format: " (clarity %.1f, %d found, moved %d)",
                       report.strength, report.estimates, report.realigned)
        line += String(format: "; speakers played %.0fs of %.0fs, mic quieter by %.1f dB (filter %.1f)",
                       report.speakersSeconds, report.micSeconds, report.totalDB, report.filterDB)
        line += "; unmatched \(report.unmatchedBlocks); filter wiped \(report.wipes), passed \(report.passedThrough)"
        if let speakers {
            line += String(format: "; tap %llu buffers, peak %.3f", speakers.callbackCount, speakers.peakLevel)
        }
        if let format = echo.unusableFormat { line += "; not cleaned, format \(format)" }
        return line
    }

    /// The call tap gone dead while the call goes on (`CallTapWatch`):
    /// started again, then, if the speakers hear the other side, replaced by
    /// everything the Mac plays for the rest of the notes, and if they do
    /// not, both taps started again for as long as the call app plays on.
    /// Only once the call tap has started. Without the speakers tap (echo
    /// removal off, or it would not start) only the call app playing can
    /// give a dead call tap away.
    private func watchCallTap(_ call: OngoingCall, now: Date) {
        guard let theirs, let tap, let callTapStartedAt, let theirFormat else { return }
        let speaking = speakers?.lastSpeech.map { now.timeIntervalSince($0) < Self.speakingWithin } ?? false
        let action = tapWatch.look(now: now, callTapSince: callTapStartedAt,
                                   callTapLastSound: theirs.reading.lastSound, speakersSpeaking: speaking,
                                   callAppPlaying: { Self.isPlaying(callApp: call.bundleID) },
                                   othersPlaying: { Self.othersPlaying(besides: call.bundleID) })
        switch action {
        case .none:
            return
        case .restartCallTap, .restartBoth:
            if action == .restartBoth {
                log("call tap and speakers tap hear nothing while the call app plays, starting both again"
                    + " (\(tapWatch.restarts)); playing: " + Self.playing(callApp: call.bundleID))
                if let speakers, let echo {
                    do { try speakers.start(into: echo) } catch {
                        log("echo: speakers tap restart FAILED: \(error.localizedDescription)")
                    }
                }
            } else {
                log("call tap quiet while the Mac plays a voice, starting it again; playing: "
                    + Self.playing(callApp: call.bundleID))
            }
            self.callTapStartedAt = now
            do {
                theirs.feed(try tap.start(bundleID: call.bundleID, analyzerFormat: theirFormat))
            } catch {
                log("call tap restart FAILED: \(error.localizedDescription)")
            }
        case .useSpeakers:
            guard let speakers, let stream = speakers.otherSide(format: theirFormat) else {
                log("call tap still quiet, and the speakers cannot stand in (format \(theirFormat))")
                return
            }
            tap.stop()
            theirs.feed(stream)
            log("call tap still quiet, the other side now comes from everything the Mac plays; playing: "
                + Self.playing(callApp: call.bundleID))
        }
    }

    /// Whether any of the call app's processes is playing sound now.
    private static func isPlaying(callApp bundleID: String) -> Bool {
        CallMonitor.audioProcesses(ofCallApp: bundleID)
            .contains { AudioProcesses.bool($0, kAudioProcessPropertyIsRunningOutput) }
    }

    /// Whether a process outside the call app (and outside Airlock) is
    /// playing sound now: then a voice on the speakers may be its own.
    private static func othersPlaying(besides bundleID: String) -> Bool {
        let callApp = Set(CallMonitor.audioProcesses(ofCallApp: bundleID))
        let me = ProcessInfo.processInfo.processIdentifier
        return AudioProcesses.objects().contains { object in
            !callApp.contains(object) && AudioProcesses.pid(object) != me
                && AudioProcesses.bool(object, kAudioProcessPropertyIsRunningOutput)
        }
    }

    /// The processes playing sound now, the call app's marked: what tells a
    /// call tap that lost the call from a call that moved to a process
    /// nobody named.
    private static func playing(callApp bundleID: String) -> String {
        let callApp = Set(CallMonitor.audioProcesses(ofCallApp: bundleID))
        let names = AudioProcesses.objects()
            .filter { AudioProcesses.bool($0, kAudioProcessPropertyIsRunningOutput) }
            .map { object in
                let name = AudioProcesses.string(object, kAudioProcessPropertyBundleID)
                    ?? "pid \(AudioProcesses.pid(object).map(String.init) ?? "?")"
                return callApp.contains(object) ? "\(name) (the call)" : name
            }
        return names.isEmpty ? "nothing" : names.joined(separator: ", ")
    }

    /// Both sides at a glance, once a minute and at the end: when each last
    /// had sound and speech, where the other side comes from, and how many
    /// words each has had written down. Numbers only, never a word said.
    private func sidesLine(now: Date) -> String {
        func ago(_ date: Date?) -> String {
            date.map { String(format: "%.0fs ago", now.timeIntervalSince($0)) } ?? "never"
        }
        let yours = mine?.reading ?? MeetingInput.Reading()
        let theirs = self.theirs?.reading ?? MeetingInput.Reading()
        var line = "sides: yours sound \(ago(yours.lastSound)), speech \(ago(yours.lastSpeech))"
        line += "; theirs from the \(tapWatch.usingSpeakers ? "speakers" : "call tap")"
        line += " sound \(ago(theirs.lastSound)), speech \(ago(theirs.lastSpeech))"
        if let tap, !tapWatch.usingSpeakers {
            line += String(format: ", call tap peak %.3f", tap.peakLevel)
        }
        if tapWatch.restarts > 0 { line += ", restarted \(tapWatch.restarts)" }
        if let speakers {
            line += "; Mac played a voice \(ago(speakers.lastSpeech))"
            line += String(format: ", peak %.3f", speakers.peakLevel)
        }
        line += "; words you \(wordsHeard[.me, default: 0]), them \(wordsHeard[.them, default: 0])"
        return line
    }

    /// Switching headsets or AirPods changes the Mac's microphone mid-call,
    /// and the audio engine stops itself when it does, leaving its stream
    /// quiet but never ended (`AudioCapture.configurationChanged`). Started
    /// again here, on the new device, into the same track.
    private func keepMicrophoneGoing(now: Date) {
        guard let mine, let micFormat else { return }
        let device = SystemMicrophone.currentID()
        let changed = device != micDevice
        guard micRestart.shouldRestart(now: now, startedAt: micStartedAt,
                                       lastInput: mine.reading.lastBuffer,
                                       deviceChanged: changed) else { return }
        log(changed ? "mic: the Mac's microphone changed, starting again"
                    : "mic: no sound coming through, starting again")
        startMicrophone(into: mine, format: micFormat)
    }

    /// The call app often has no sound process until the first person
    /// speaks, so a refusal here is tried again for a while.
    private func startThem(_ call: OngoingCall, picked: [CallLanguageFollow.Listener], listeners: CallListeners,
                           format: AVAudioFormat, attempt: Int) {
        themRetry?.cancel()
        themRetry = nil
        guard case .recording = flow.phase, let theirs else { return }
        do {
            let tap = tap ?? CallAudioTap(log: { MeetingDiagnostics.log($0) })
            self.tap = tap
            theirs.feed(try tap.start(bundleID: call.bundleID, analyzerFormat: format))
            theirsSince = theirsSince ?? Date()
            callTapStartedAt = Date()
            if them == nil {
                let offset = record.map { Date().timeIntervalSince($0.startedAt) } ?? 0
                let track = MeetingTrack(speaker: .them, listeners: listeners, canRead: CallNotesWriter.canRead,
                                         log: log) { [weak self] in self?.heard($0, from: .them) }
                track.onHearing = { [weak self] in self?.hearing($0, $1, from: .them) }
                track.begin(picked, format: format, offset: offset, input: theirs.output)
                them = track
                listenForVoices(on: track)
            }
        } catch {
            log("call tap attempt \(attempt + 1): \(error.localizedDescription)")
            guard attempt < 40 else { return }
            themRetry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.startThem(call, picked: picked, listeners: listeners, format: format, attempt: attempt + 1)
            }
        }
    }

    /// Starts the voice model on the other side's audio, unless this call
    /// is a one-to-one with a known name or the other side was named as one
    /// person (nothing to tell apart), the model is off or not here, or the
    /// call runs on Free (`PlanLimits.tellsVoicesApart`).
    private func listenForVoices(on track: MeetingTrack) {
        guard voices == nil, let record,
              CallVoiceModel.isOn(for: PlanSnapshot.kept(startedOn: record.startedOn,
                                                         now: CloudNotesService.shared.plan())),
              record.otherName == nil, !CallVoices.isNamedAsOne(record) else { return }
        let (stream, offset) = track.voiceInput()
        let listener = CallVoiceListener(offset: offset)
        voices = listener
        voicesFrom = offset
        voicesNumbering = CallVoices.Numbering()
        voicesThrough = offset
        splittingVoices = true
        Task { await listener.start(stream) }
        voicesLooking?.cancel()
        voicesLooking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.voicesEvery)
                guard !Task.isCancelled else { return }
                await self?.numberVoicesSoFar(listener)
            }
        }
        log("voices: listening from \(Int(offset))s")
    }

    /// The other side was named while its voices were being told apart: it
    /// is one person now (`CallVoices.isNamedAsOne`), so the voice model
    /// stops for the rest of the call and the call's last pass is not made.
    /// A look still out finds the listener gone and numbers nothing.
    private func stopTellingVoicesApart() {
        guard let listener = voices else { return }
        voicesLooking?.cancel()
        voicesLooking = nil
        voices = nil
        splittingVoices = false
        Task { await listener.cancel() }
        log("voices: stopped, the other side was named")
    }

    /// How often the voices heard so far are laid over the lines. The model
    /// hears in steps of ten seconds, so a line is numbered ten to twenty
    /// seconds after it is said.
    private static let voicesEvery: Duration = .seconds(4)

    /// Numbers the lines the voice model has heard so far, while the call
    /// goes on, so the side window tells people apart as they talk. Each
    /// look goes over the whole call again, and keeps each voice's number
    /// and name (`CallVoices.Numbering`).
    private func numberVoicesSoFar(_ listener: CallVoiceListener) async {
        // A look still out when the call ends leaves it to the last pass.
        guard let heard = await listener.soFar(), !Task.isCancelled, heard.through > voicesThrough,
              voices === listener, var record, let them else { return }
        voicesThrough = heard.through
        let before = record
        let people = voicesNumbering.people.count
        let outcome = CallVoices.number(&record, from: voicesFrom, through: heard.through, spans: heard.spans,
                                        words: them.words, numbering: &voicesNumbering)
        guard record != before else { return }
        if outcome.people != people {
            log("voices so far: \(outcome.people) people by \(Int(heard.through))s"
                + (outcome.reason.map { " (\($0))" } ?? ""))
        }
        self.record = record
        saveSoon()
    }

    /// Numbers the other side's lines by voice, from what the voice model
    /// heard, and logs what that cost. Nothing of what was heard is kept.
    private func numberVoices(_ report: CallVoiceListener.Report, words: [CallLanguageFollow.Timed],
                              in record: inout MeetingRecord) {
        let outcome = CallVoices.number(&record, from: voicesFrom, spans: report.spans, words: words,
                                        numbering: &voicesNumbering)
        let rtf = report.audioSeconds > 0 ? report.computeSeconds / report.audioSeconds : 0
        var line = "voices: \(outcome.people) people from \(outcome.heard) heard"
        line += ", \(outcome.folded) folded, \(outcome.split) line(s) cut"
        if !outcome.talk.isEmpty {
            line += ", talk " + outcome.talk.map { String(format: "%.1f", $0) }.joined(separator: "/") + "s"
        }
        if let reason = outcome.reason { line += " (\(reason))" }
        line += String(format: "; audio %.0fs, model %.1fs (%.3fx), load %.1fs",
                       report.audioSeconds, report.computeSeconds, rtf, report.loadSeconds)
        line += ", thermal \(ProcessInfo.processInfo.thermalState.rawValue)"
        if let stopped = report.stopped { line += "; stopped: \(stopped)" }
        log(line)
    }

    private func heard(_ event: MeetingTrack.Event, from speaker: MeetingSpeaker) {
        switch event {
        case .line(let segment):
            heard(segment)
        case .listening(let from, let language):
            record?.listen(speaker, from: from, in: language)
            saveSoon()
        case .switched(let seam, let language, let lines, let keptAs):
            guard var record else { return }
            // Said during a pause: left out, as when the line first came.
            let kept = lines.filter { !said(during: $0, in: record) }
            if let sealer {
                record.switchLanguage(of: speaker, at: seam, to: language, lines: kept, keptAs: keptAs,
                                      sealing: sealer)
            } else {
                record.switchLanguage(of: speaker, at: seam, to: language, lines: kept, keptAs: keptAs)
            }
            self.record = record
            saveSoon()
        case .shadow(let line):
            guard let record, !said(during: line.segment, in: record) else { return }
            self.record?.addShadow(line)
            saveSoon()
        }
    }

    /// What a side is saying before it is a line, for the transcript to
    /// show as it comes, and the lines it holds back while its language is
    /// decided, to show where they were said. Nothing said while paused is
    /// shown, as nothing said then is written down, and nothing past a lock,
    /// as nothing from there can be read.
    private func hearing(_ held: [MeetingSegment], _ text: String, from speaker: MeetingSpeaker) {
        let lockedFrom = record?.locked?.from
        let shown = record.map { record in
            held.filter { line in
                !said(during: line, in: record) && line.start < lockedFrom ?? .infinity
            }
        } ?? []
        if shown != heldLines[speaker, default: []] {
            heldLines[speaker] = shown.isEmpty ? nil : shown
            live.hold(shown, from: speaker)
        }
        live.hear(isPaused || lockedFrom != nil ? "" : text, from: speaker)
    }

    /// Said during a pause, by its middle.
    private func said(during segment: MeetingSegment, in record: MeetingRecord) -> Bool {
        wasPaused(at: record.startedAt.addingTimeInterval((segment.start + segment.end) / 2))
    }

    private func heard(_ segment: MeetingSegment) {
        // Said during a pause, by its middle: left out, whenever it arrives.
        if let record, said(during: segment, in: record) {
            return
        }
        if let sealer { record?.add(segment, sealing: sealer) } else { record?.add(segment) }
        wordsHeard[segment.speaker, default: 0] += segment.text.split(whereSeparator: \.isWhitespace).count
        if let record {
            let spoken = record.startedAt.addingTimeInterval(segment.end)
            lastWords = max(lastWords ?? spoken, spoken)
        }
        if record?.site == nil, let record, let site = current(nil, bundleID: record.bundleID)?.site {
            self.record?.site = site
        }
        saveSoon()
    }

    /// The server's key a Free call's locked part is sealed to, put in at
    /// packaging. Without it Free's notes stop at the limit, as before.
    private static let callLockKey = CallLock.publicKey(
        Bundle.main.object(forInfoDictionaryKey: "ALCallLockPublicKey") as? String)
    private static var locks: Bool { callLockKey != nil }

    /// Once the flow has locked the notes and they write to their record:
    /// from now on what is heard is sealed, and only the server can open the
    /// key. A call that carries on keeps the lock it had.
    private func lockIfDue() {
        guard flow.locked, recordIsLive, var record, record.locked == nil, let key = Self.callLockKey else { return }
        let from = Date().timeIntervalSince(record.startedAt)
        do {
            let sealer = try CallLock.Sealer(publicKey: key, machine: MachineIdentity.current,
                                             keptUntil: CallLock.keptUntil(startedAt: record.startedAt), from: from)
            self.sealer = sealer
            record.locked = sealer.part
            self.record = record
            saveNow()
        } catch {
            // Nothing past the limit can be kept unsealed: the notes stop
            // there, as they would without the key.
            log("notes: lock FAILED (\(error.localizedDescription)), stopping")
            Task { @MainActor [weak self] in self?.send(.stop) }
        }
    }

    /// Saves a second after the last change: a burst of lines or notes is
    /// one write, and a crash loses at most that second.
    private func saveSoon() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let folder, let record else { return }
        do {
            try store.saveTranscript(record, in: folder)
        } catch {
            log("save FAILED: \(error.localizedDescription)")
        }
    }

    /// `keeping` false: the call ended too short to keep. Nothing is
    /// written up, and the folder goes once the call has had its chance to
    /// come back (`discardSoon`).
    /// `stoppedAtLimit` is how long the plan let the notes listen, when that
    /// is what stopped them (`MeetingRecord.stoppedAtLimit`).
    private func finish(keeping: Bool = true, stoppedAtLimit: TimeInterval? = nil) async {
        themRetry?.cancel()
        themRetry = nil
        voicesLooking?.cancel()
        voicesLooking = nil
        // Let go of everything the looks read first, so a look while the
        // recognisers finish neither starts the microphone again nor says a
        // side is missing.
        if theirs != nil { log(sidesLine(now: Date())) }
        let (mine, theirs, me, them) = (self.mine, self.theirs, self.me, self.them)
        let voices = self.voices
        let echo = self.echo
        self.echo = nil
        echoLoggedAt = nil
        self.mine = nil
        self.theirs = nil
        self.me = nil
        self.them = nil
        self.voices = nil
        mineSince = nil
        theirsSince = nil
        callTapStartedAt = nil
        theirFormat = nil
        sidesLoggedAt = nil
        micStartedAt = nil
        micDevice = nil
        micFormat = nil
        if health != CallChannelHealth() { health = CallChannelHealth() }
        startCheck = nil
        releaseAwake()
        // Streams next: each recogniser's last sentence waits on its stream
        // ending (`SpeechSession.finish`), and each side's stream ends once
        // its sound has stopped and been passed on.
        mic?.stop()
        tap?.stop()
        // The other side's stream, when it came from the speakers; the tap
        // itself keeps going until your side has ended.
        speakers?.endOtherSide()
        mine?.close()
        theirs?.close()
        async let myLast: Void = me?.finish() ?? ()
        async let theirLast: Void = them?.finish() ?? ()
        _ = await (myLast, theirLast)
        // After your side has ended, so the speakers' sound covers its end.
        speakers?.stop()
        if let echo { log(echoLine(echo)) }
        mute?.stop()
        let languages = (me?.languages ?? []) + (them?.languages ?? [])

        guard let folder, var record else {
            splittingVoices = false
            return
        }
        record.endedAt = Date()
        if let stoppedAtLimit { record.stoppedAtLimit = stoppedAtLimit }
        if !languages.isEmpty {
            record.languages = languages.reduce(into: []) { kept, language in
                if !kept.contains(language) { kept.append(language) }
            }
        }
        if !keeping { record.droppedAt = Date() }
        // Names given in the side window while the call was ending are on
        // the lines as they were numbered then.
        var numberedAs: [Int: Int]?
        if let voices {
            if keeping {
                let report = await voices.finish()
                if let held = named(in: folder) { record.replaceNames(with: held) }
                numberedAs = voicesNumbering.people
                numberVoices(report, words: them?.words ?? [], in: &record)
            } else {
                await voices.cancel()
            }
        }
        let namedBefore = named(in: folder)
        // Once the voices have their lines: they are matched to the words
        // as the recogniser wrote them.
        if keeping { await Self.respell(&record, store: store, log: log) }
        if let held = named(in: folder), held != namedBefore {
            record.replaceNames(with: numberedAs.map { voicesNumbering.carry(held, numberedAs: $0) } ?? held)
        }
        self.record = record
        splittingVoices = false
        saveNow()
        guard keeping else {
            log("notes: short call (\(Int(record.duration(at: Date())))s), not kept")
            discardSoon(folder)
            return
        }
        log("notes: \(record.segments.count) line(s), \(Int(record.duration(at: Date()) / 60)) min")
        summarise(record, in: folder, announce: true)
    }

    /// The names the call in `folder` holds in memory now, given while it
    /// was being ended.
    private func named(in folder: URL) -> [MeetingVoiceName]? {
        folder == self.folder ? self.record?.names : nil
    }

    /// Removes a short call's folder once `sameMeetingWindow` has passed,
    /// unless it came back and carried on. Held where a summary would be, so
    /// carrying on cancels it the same way.
    private func discardSoon(_ folder: URL) {
        summaries[folder]?.cancel()
        summaries[folder] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MeetingNotesFlow.sameMeetingWindow + 5))
            guard !Task.isCancelled, let self else { return }
            self.summaries[folder] = nil
            self.enqueue { self.discard(folder) }
        }
    }

    private func discard(_ folder: URL) {
        if folder == self.folder {
            // Carried on: these are live notes now.
            guard record?.droppedAt != nil else { return }
            pendingSave?.cancel()
            pendingSave = nil
            self.folder = nil
            record = nil
            sealer = nil
        }
        remove(folder)
    }

    private func remove(_ folder: URL) {
        do {
            try store.remove(folder)
            log("notes: short call removed")
        } catch {
            log("notes: short call remove FAILED: \(error.localizedDescription)")
        }
        madeCallsPage?.refreshIfOpen()
        recentCalls.refresh()
    }

    /// `call` as the detector knows it now, when it is still the same app's.
    private func current(_ call: OngoingCall) -> OngoingCall {
        current(call, bundleID: call.bundleID) ?? call
    }

    private func current(_ call: OngoingCall?, bundleID: String) -> OngoingCall? {
        guard let latest = latestCall?(), latest.bundleID == bundleID else { return call }
        return latest
    }

    /// Writes `Notes.md` beside the transcript, off the listening chain so a
    /// call that comes straight back is not kept waiting for the model.
    private func summarise(_ record: MeetingRecord, in folder: URL, announce: Bool) {
        summaries[folder]?.cancel()
        let store = store
        summaries[folder] = Task { [weak self, log] in
            let started = Date()
            let page = await Self.notesPage(for: record, log: log)
            let written = page.notes
            guard !Task.isCancelled else { return }
            do {
                try store.saveNotes(page.page, in: folder)
                log(String(format: "summary: saved in %.1fs", Date().timeIntervalSince(started)))
                if let writer = page.writer {
                    do {
                        try store.saveNotesWriter(writer, in: folder)
                        // Waits for a date: the service looks again then.
                        if writer.waitsForOnline, writer.notBefore != nil {
                            Task { await CloudNotesService.shared.planNextLook() }
                        }
                    } catch {
                        log("summary: writer not saved: \(error.localizedDescription)")
                    }
                }
                do {
                    try store.saveTopic(written?.title, in: folder)
                } catch {
                    log("summary: title not saved: \(error.localizedDescription)")
                }
                if announce, let self {
                    // Counted before the line goes up, so it can say them.
                    self.savedTodos = written?.todos.count ?? 0
                    self.readyOutcome = CallNotesPanel.ready(of: record, notes: written, writer: page.writer)
                    // How long, and where its notes were written. Nothing
                    // anybody said, no names, no title.
                    let notesWritten: UsageEvent.NotesWritten = switch self.readyOutcome {
                    case .notes: page.writer?.place == .online ? .online : .mac
                    case .later: .later
                    case .tooLittleSaid: .none
                    }
                    let seconds = (record.endedAt ?? Date()).timeIntervalSince(record.startedAt)
                    UsageCounts.shared.record(.callEnded(minutes: Int((seconds / 60).rounded()),
                                                         notes: notesWritten,
                                                         inPerson: record.isInPerson))
                    self.live.settle(folder, as: .saved(self.readyOutcome, todos: self.savedTodos),
                                     title: written?.title)
                    self.send(.saved(folder: folder.lastPathComponent))
                    // The notch says so for a few seconds; the Mac's own
                    // notification stays in its list, since nobody watches
                    // a call's notes being written.
                    if let notice = CallNotesPanel.readyNotice(of: record, ready: self.readyOutcome,
                                                               todos: self.savedTodos) {
                        Notifications.post(title: notice.title, body: notice.body,
                                           identifier: Notifications.ID.notesReady(folder.lastPathComponent),
                                           opensCall: folder.lastPathComponent)
                    }
                    if case let .ready(name, _) = self.flow.phase, name == folder.lastPathComponent {
                        self.readyNotes = written
                        self.readyLocked = record.locked.flatMap { part in
                            record.lockedMinutes.map { ReadyLocked(minutes: $0, until: part.keptUntil) }
                        }
                        self.readyWaiting = page.writer.flatMap { writer in
                            writer.noNotesYet == nil || writer.noNotesYet == .allowanceUsed
                                ? nil : MeetingFiles.waitingLine(for: writer)
                        }
                        if let writer = page.writer, writer.noNotesYet == .allowanceUsed, let until = writer.notBefore {
                            // No notes at all until then: said every time.
                            self.readyAllowance = until
                            self.readyAllowanceMacWrites = false
                        } else {
                            // Once a month, where the notes say they are ready.
                            self.readyAllowance = page.allowanceUntil.flatMap {
                                CloudNotesService.shared.takeAllowanceNotice(until: $0)
                            }
                            self.readyAllowanceMacWrites = true
                        }
                    }
                }
                self?.madeCallsPage?.refreshIfOpen()
                self?.recentCalls.refresh()
            } catch {
                log("summary: save FAILED: \(error.localizedDescription)")
                if announce { self?.send(.failed(CallLive.Stopped.notSaved)) }
            }
            self?.summaries[folder] = nil
        }
    }

    /// The words typed in Settings (`MeetingKnownWords`).
    static func typedWords(in settings: UserDefaults = .standard) -> [String] {
        settings.stringArray(forKey: knownWordsKey) ?? []
    }

    /// `record` with the words typed in Settings, the people invited and the
    /// names given to voices lately spelled their way (`MeetingKnownWords`).
    /// The earlier meetings are read off the main thread.
    static func respell(_ record: inout MeetingRecord, settings: UserDefaults = .standard,
                        store: MeetingStore, log: (String) -> Void) async {
        let typed = typedWords(in: settings)
        let looked = namesLookedBack
        let earlier = await Task.detached(priority: .utility) {
            store.calls().prefix(looked).map(\.record)
        }.value
        let known = MeetingKnownWords.forMeeting(record, typed: typed, earlier: earlier)
        let changed = known.respell(&record)
        if !known.isEmpty {
            log("words: \(changed) line(s) respelled, \(typed.count) typed, \(known.spellings.count) known")
        }
    }

    /// The notes page for `record`, and the notes on it when there are any.
    /// Stretches in a language the notes writer can't read are written from
    /// the take kept beside them (`MeetingNotesSource`); the page says so in
    /// a line of its own.
    ///
    /// Written online first, for a subscriber who has notes online
    /// (`CloudNotesService`), and by the Mac whenever they aren't, a failure
    /// included, without a word.
    ///
    /// A Mac that can't write notes (no Apple Intelligence) keeps the call
    /// waiting instead, when waiting can bring notes: offline, a failure, or
    /// this month's online notes used. They are written online later
    /// (`CloudNotesRedo`), and the page says when.
    static func notesPage(for record: MeetingRecord, log: @escaping (String) -> Void) async -> WrittenNotes {
        var writer: MeetingNotesWriter?
        var allowanceUntil: Date?
        let missed: CloudNotesRedo.Missed
        // The plan the call is written under, kept with the notes: the page
        // and the window say what a better one would have written.
        let plan = PlanSnapshot.kept(startedOn: record.startedOn, now: CloudNotesService.shared.plan())
        switch await CloudNotesService.shared.write(record, log: log) {
        case .written(let notes, let model):
            let online = MeetingNotesWriter.online(model: model, at: Date(), plan: plan)
            return WrittenNotes(page: MeetingFiles.notesPage(for: record, notes: notes, writer: online),
                                notes: notes, writer: online)
        case .mac(.hiddenSwitchOff):
            // Today's notes, and today's record: no writer kept.
            writer = nil
            missed = .mac(.hiddenSwitchOff)
        case .mac(.offline):
            writer = .mac(at: Date(), waitsForOnline: true, why: .offline, plan: plan)
            missed = .mac(.offline)
        case .mac(.allowanceUsed(let until)):
            writer = .mac(at: Date(), why: .allowanceUsed, plan: plan, backOn: until)
            allowanceUntil = until
            missed = .mac(.allowanceUsed(until: until))
        case .mac(let reason):
            writer = .mac(at: Date(), why: MeetingNotesWriter.MacWhy(reason), plan: plan)
            missed = .mac(reason)
        case .failed:
            writer = .mac(at: Date(), why: .serviceDown, plan: plan)
            missed = .failed
        }

        let source = MeetingNotesSource(record, canRead: CallNotesWriter.canRead)
        if source.record.languages != record.languages || !source.unreadable.isEmpty {
            log("summary: written in \(source.record.languages.joined(separator: " + "))"
                + (source.unreadable.isEmpty ? "" : ", unreadable \(source.unreadable.joined(separator: " + "))"))
        }
        switch await MeetingSummarizer.notes(for: source.record, log: log) {
        case .notes(let notes):
            return WrittenNotes(page: MeetingFiles.notesPage(for: record, notes: notes, writtenFrom: source.line,
                                                             writer: writer),
                                notes: notes.isEmpty ? nil : notes, writer: writer, allowanceUntil: allowanceUntil)
        case .unavailable(let reason):
            log("summary: none — \(reason)")
            return WrittenNotes(page: MeetingFiles.notesPage(for: record, notes: nil, unavailableReason: reason,
                                                             writer: writer),
                                notes: nil, writer: writer, allowanceUntil: allowanceUntil)
        case .noModel(let availability):
            let reason = MeetingSummarizer.noModelReason(availability)
            log("summary: none — \(reason)")
            if var waiting = writer.flatMap({ _ in CloudNotesRedo.withoutNotes(missed, now: Date()) }) {
                waiting.plan = plan
                writer = waiting
                log("notes online: waiting, \(waiting.noNotesYet?.rawValue ?? "")"
                    + (waiting.notBefore.map { " until \($0.formatted(.iso8601))" } ?? ""))
            }
            return WrittenNotes(page: MeetingFiles.notesPage(for: record, notes: nil, unavailableReason: reason,
                                                             writer: writer, noModel: availability),
                                notes: nil, writer: writer, allowanceUntil: allowanceUntil)
        }
    }

    /// A meeting's notes page, and what came with it.
    struct WrittenNotes: Sendable {
        var page: String
        /// The notes on it, when there are any.
        var notes: MeetingNotes?
        /// Who wrote them, kept in the record while notes online are switched
        /// on; nil otherwise.
        var writer: MeetingNotesWriter?
        /// Until when this month's online notes are used, when the Mac wrote
        /// them for that reason.
        var allowanceUntil: Date?
    }

    // MARK: - Speech

    /// The call languages from Settings, or dictation's while none are
    /// picked (`CallLanguage.wanted`), each with the recogniser that knows it
    /// (`CallListening.resolved`: speech first, dictation for a language
    /// only it knows, Catalan among them), the one audio format that suits
    /// them all, and every language this Mac can follow the call into. Nil
    /// when no model can serve.
    private func speechSetup() async -> ([CallLanguageFollow.Listener], AVAudioFormat, CallListeners)? {
        await Self.speechSetup(settings: .standard, log: log)
    }

    /// `speechSetup`, from the languages in `settings`: the app's own, or
    /// the app's read from outside it (`RecordingReplay`).
    static func speechSetup(settings: UserDefaults, log: (String) -> Void) async
        -> ([CallLanguageFollow.Listener], AVAudioFormat, CallListeners)? {
        let wanted = CallLanguage.wanted(
            callPrimary: settings.string(forKey: CallLanguage.primaryKey) ?? "",
            callSecondary: settings.string(forKey: CallLanguage.secondaryKey) ?? "",
            dictationPrimary: settings.string(forKey: "dictation.locale") ?? "",
            dictationSecondary: settings.string(forKey: "dictation.locale.secondary") ?? "")
        let preferred = wanted.primary.isEmpty ? Locale.current : Locale(identifier: wanted.primary)
        // As dictation does (`SpeechSession.resolvedLocale`): English when
        // nothing knows the language asked for.
        var primary = await CallListening.resolved(preferred)
        if primary == nil { primary = await CallListening.resolved(Locale(identifier: "en_US")) }
        guard let primary else { return nil }
        var picked = [primary]
        if !wanted.secondary.isEmpty,
           let secondary = await CallListening.resolved(Locale(identifier: wanted.secondary)),
           secondary.identifier != primary.identifier {
            picked.append(secondary)
        }
        for listener in picked { await CallListening.prepare(listener) }
        let listeners = await CallListeners.current()
        if let format = await CallListening.format(for: picked) {
            log("speech: \(picked.map { "\($0.identifier) (\($0.module.rawValue))" }.joined(separator: " + ")), "
                + (wanted.fromDictation ? "dictation's languages" : "the call languages"))
            return (picked, format, listeners)
        }
        // A second language never takes the notes down with it.
        if picked.count > 1, let format = await CallListening.format(for: [primary]) {
            log("speech: no shared format, second language dropped")
            return ([primary], format, listeners)
        }
        log("speech: no model for \(primary.identifier)")
        return nil
    }
}

private extension MeetingNotesFlow.Phase {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    /// The call this phase is about, if any.
    var call: OngoingCall? {
        switch self {
        case let .offering(call), let .startingSoon(call, _), let .recording(call, _),
             let .writing(call), let .ready(_, call):
            return call
        case .idle, .failed:
            return nil
        }
    }
}

private extension MeetingNotesFlow.Event {
    /// A press of "Take notes", on a call or in the room.
    var asksToStart: Bool {
        switch self {
        case .accept, .acceptAlways, .takeNotesInPerson: true
        default: false
        }
    }
}

private extension MeetingNotesFlow.Effect {
    var startsNotes: Bool {
        if case .startNotes = self { return true }
        return false
    }
}
