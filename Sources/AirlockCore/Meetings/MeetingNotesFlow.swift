import Foundation

/// When notes are offered, taken, stopped and handed over. Pure, so every
/// path through a call can be tested without a call.
///
/// The rules, as the owner chose them (2026-10-08):
/// - **Asked on every call**, with one tap in the notch, unless the owner has
///   said "Always" once, after which notes start on their own after a short
///   countdown (`countdown`). Tapping the countdown skips it: not now, for
///   this call, but the offer stays.
/// - **The ask never opens the island.** It is waiting in the panel, and the
///   call pill says "Notes?" for `askWiden`, then settles to a dot, but only
///   a gate or a question may expand the island by itself (the expansion
///   contract), and this is neither.
/// - **Notes can be paused.** What is said meanwhile is not written down, and
///   a pause is not silence: the notes never stop on their own for it.
/// - **A call that drops and comes straight back is the same meeting.** A
///   browser that lets go of the microphone while muted ends the call as far
///   as the detector can tell; the notes carry on into the same folder
///   rather than asking again and splitting one meeting in two.
/// - **Notes stop only when the call really ends**: the call app has let go
///   of the microphone for `micHold`, or quit `quitHold` ago, or nobody has
///   said anything for `silenceLimit`, or the Mac is going to sleep. Never
///   on a guess while people are still talking: a headset switch makes the
///   call app drop the microphone for a moment, and losing the rest of the
///   meeting to that is the worst mistake notes can make.
/// - **A call shorter than `shortestKept` leaves nothing behind** when it
///   ends on its own: no notes, no transcript, no "Writing notes…". A voice
///   message in a chat app holds the microphone and plays sound just as a
///   call does, and the detector cannot tell them apart. Notes stopped by
///   hand are written however short: somebody asked for them.
/// - **A meeting in the room is taken by hand** ("Take notes", with no call
///   on): the Mac's own microphone, until "Stop", the Mac sleeping, or
///   `silenceLimit` of nothing heard. No call comes and goes under it, so
///   the call detector's starts and ends pass it by, and it is always kept,
///   however short: somebody asked for it.
/// - **On a plan that caps them, notes stop listening at the cap** (Free:
///   the first 30 minutes, `PlanLimits.notesListenFor`), the call itself
///   untouched, and what was heard is written. Stopping and starting again
///   carries on the same count (`NotesListening`), so no restart, dropped
///   call or "Take notes" in the room buys more; a call whose notes are used
///   up is not offered notes at all.
///
/// **No clock in here, and none that pauses.** Every time arrives as a date
/// from the model, and the waits are compared on its ticks. A date keeps
/// counting while the Mac sleeps; a duration timer (`DispatchTime`, a
/// suspending clock) does not, and would wake up believing a minute had
/// passed when an hour had. The one exception is the cap, which counts the
/// Mac's running time (`RunningTime`), handed in with every event, because a
/// date can be set back.
public struct MeetingNotesFlow: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// A call is on and nobody has said yes or no.
        case offering(OngoingCall)
        /// "Always" is on and the notes start at `startsAt` unless skipped.
        case startingSoon(OngoingCall, startsAt: Date)
        /// Listening. `since` is when the notes started, not the call: the
        /// latest start, so notes carried on after the call dropped start
        /// again here (`firstStarted` is the first).
        case recording(OngoingCall, since: Date)
        /// The call is over (or notes were stopped) and the summary is being
        /// written.
        case writing(OngoingCall)
        /// Notes are saved. `folder` is the folder's name.
        case ready(folder: String, call: OngoingCall)
        /// Something went wrong; said once, in plain words.
        case failed(String)
    }

    public enum Event: Equatable, Sendable {
        case callStarted(OngoingCall, at: Date)
        /// The call detector's end. `at` is the moment the call app let go of
        /// the microphone, not the moment the detector gave up waiting.
        case callEnded(at: Date)
        /// "Take notes", or the countdown running out.
        case accept(at: Date)
        /// "Always": take notes now, and on every call from now on.
        case acceptAlways(at: Date)
        /// "Not now", or the countdown skipped.
        case decline
        /// "Take notes" with no call: a meeting in the room, heard through
        /// the Mac's microphone.
        case takeNotesInPerson(at: Date)
        /// "Stop" while recording.
        case stop
        /// "Pause" and "Resume" while recording.
        case pause(at: Date)
        case resume(at: Date)
        case saved(folder: String)
        case failed(String)
        /// The ready or failed line was closed, or has been up long enough.
        case dismiss
        /// An app quit. Only the call's own app counts.
        case appQuit(bundleID: String, at: Date)
        /// The Mac is about to sleep.
        case sleep(at: Date)
        /// The model's look, about once a second while notes are taken: the
        /// only way time passes in here.
        case tick(Tick)
    }

    /// What the model sees on each look.
    public struct Tick: Equatable, Sendable {
        public var now: Date
        /// Whether the call's app holds the microphone right now. Looked at
        /// only while the call seems over (`isWaitingForCallBack`); nil when
        /// not looked at.
        public var callOnMic: Bool?
        /// The last time anyone on the call said something, either side.
        /// What you say while muted does not count: that is not the call.
        public var lastSpeech: Date?
        /// The last time the other side said something.
        public var theirLastSpeech: Date?

        public init(now: Date, callOnMic: Bool? = nil, lastSpeech: Date? = nil,
                    theirLastSpeech: Date? = nil) {
            self.now = now
            self.callOnMic = callOnMic
            self.lastSpeech = lastSpeech
            self.theirLastSpeech = theirLastSpeech
        }
    }

    public enum Effect: Equatable, Sendable {
        /// Begin listening. `continuing` means append to the last call's
        /// folder rather than starting a new one.
        case startNotes(OngoingCall, continuing: Bool)
        /// Stop listening and write the notes.
        case finishNotes
        /// Stop listening and keep nothing: the call ended before
        /// `shortestKept`. What was saved goes once `sameMeetingWindow` has
        /// passed, not at once, so a call that comes straight back carries on
        /// into it like any other.
        case dropNotes
        /// Remember "Always".
        case rememberAlways
        /// Stop writing down what is heard, and start again. The listening
        /// itself carries on, so a resume loses no words to a restart.
        case pauseNotes
        case resumeNotes
    }

    /// How long "Always" waits before the notes start: long enough to read
    /// "Notes in 3" and tap it away, short enough that the start of the call
    /// is not lost.
    public static let countdown: TimeInterval = 3
    /// How long the ask says "Notes?" in the compact island before it settles
    /// to a dot. A call's first seconds are when the question is wanted; after
    /// that, a word sitting beside the call is noise.
    public static let askWiden: TimeInterval = 10
    /// How soon a call from the same app must come back to count as the same
    /// meeting.
    public static let sameMeetingWindow: TimeInterval = 120
    /// How long the call app must have let go of the microphone before the
    /// notes stop, counted from the moment it let go. The detector has
    /// already waited out its own `CallDetector.grace` by the time it says so;
    /// this is the confirmation on top, long enough for a headset switch.
    public static let micHold: TimeInterval = 5
    /// How long after the call app quits the notes stop, unless it is back on
    /// the microphone by then: enough for an app that crashed to be reopened
    /// and rejoin.
    public static let quitHold: TimeInterval = 10
    /// Notes never stop on their own before they have run this long: an end
    /// that comes earlier is held to this mark and applies then, if the call
    /// is still gone. A call that wobbles as it connects is not a call that
    /// ended.
    public static let shortestNotes: TimeInterval = 30
    /// Nobody on either side has said anything for this long: the call was
    /// left open, and the notes stop.
    public static let silenceLimit: TimeInterval = 15 * 60
    /// The other side spoke this recently: the call is still going whatever
    /// the microphone says, so the stop waits. A browser can let go of the
    /// microphone while you are muted and listening.
    public static let stillTalking: TimeInterval = 5
    /// How long the other side's talking may hold a stop off once the call
    /// app has let go. A browser also plays whatever another tab plays, and
    /// a video after the call must not keep the notes going forever.
    public static let talkingLimit: TimeInterval = 15 * 60
    /// Notes that end on their own before they have run this long are not
    /// kept (the owner's call, 2026-10-08, after a WhatsApp voice message
    /// was saved as a call). Counted from when notes on the call first
    /// started, so a call that dropped and came back counts as one.
    public static let shortestKept: TimeInterval = 5 * 60

    /// `shortestKept`, or another length for a test about something else.
    private let keepsFrom: TimeInterval

    public private(set) var phase: Phase = .idle {
        didSet {
            switch phase {
            case .recording:
                endedBySleep = false
                stoppedAtLimit = false
                return
            case .writing, .ready:
                break
            default:
                endedBySleep = false
                stoppedAtLimit = false
            }
            // A pause belongs to the notes it paused: whatever ends them, the
            // next notes start unpaused.
            pausedSince = nil
            resumedAt = nil
            firstStarted = nil
        }
    }
    /// The notes being written, or ready, were stopped by the Mac going to
    /// sleep rather than by anyone: the lid closed on a meeting in the
    /// room, say. The ready line says so, or the notes would seem to have
    /// stopped by themselves.
    public private(set) var endedBySleep = false
    /// The notes being written, or ready, stopped because they had listened
    /// as long as the plan lets them.
    public private(set) var stoppedAtLimit = false
    /// How long notes have listened, on a plan that caps it; kept between
    /// notes, so a restart carries on the count. Nil until notes first start
    /// with a running time handed in.
    public private(set) var listening: NotesListening?
    /// When the notes were paused; nil while they are written down.
    public private(set) var pausedSince: Date?
    /// When notes on this call FIRST started: `since` for notes started
    /// fresh, the first start's for notes carried on into the same folder
    /// after the call dropped or the Mac slept (`sameMeetingWindow`). A
    /// pause leaves it alone. The heads-up counts from it, so carrying on
    /// never offers it again to people who were already told. Nil unless
    /// notes are being taken.
    public private(set) var firstStarted: Date?
    /// The last resume, so the silence that ends a forgotten call is counted
    /// from it: a long pause is not a long silence.
    private var resumedAt: Date?
    /// When the current offer started asking, for `askWiden`; nil when it
    /// settled without asking (the countdown was skipped).
    private var askedAt: Date?
    /// The last call notes were taken on, and when it ended — for
    /// `sameMeetingWindow`.
    private var lastNotes: LastNotes?
    /// Set while notes are being taken and the call seems over, until it is
    /// confirmed (the notes stop) or the call is back (forgotten).
    private var ending: Ending?

    private struct LastNotes: Equatable, Sendable {
        var bundleID: String
        var endedAt: Date
        /// Their `firstStarted`, handed on if the same call carries on.
        var firstStarted: Date?
    }

    private struct Ending: Equatable, Sendable {
        /// When the call app let go of the microphone; nil while it holds it
        /// again but the detector has not yet said the call is back.
        var micLetGo: Date?
        /// When the call app quit; nil unless it did.
        var quitAt: Date?
    }

    /// `keepingFrom` is for tests: the shortest notes kept.
    public init(keepingFrom shortest: TimeInterval = MeetingNotesFlow.shortestKept) {
        keepsFrom = shortest
    }

    /// A flow standing in one phase, for drawing it (the state gallery):
    /// nothing has been asked, no call has ended, and nothing follows from
    /// it until an event arrives. `pausedSince` counts only while recording,
    /// the one phase that can be paused.
    public init(previewing phase: Phase, pausedSince: Date? = nil, endedBySleep: Bool = false,
                listening: NotesListening? = nil, stoppedAtLimit: Bool = false) {
        keepsFrom = Self.shortestKept
        self.phase = phase
        if case let .recording(_, since) = phase {
            self.pausedSince = pausedSince
            firstStarted = since
        }
        self.endedBySleep = endedBySleep
        self.listening = listening
        self.stoppedAtLimit = stoppedAtLimit
    }

    /// The call seems over and the notes are waiting to be sure. The model
    /// looks at the microphone itself meanwhile (`Tick.callOnMic`), which is
    /// sooner than the detector can say a call is back.
    public var isWaitingForCallBack: Bool { ending != nil }

    /// The count kept from before a quit, taken back at launch. Ignored once
    /// notes have started here. Its call is taken as over when it was kept:
    /// the detector starts afresh and would never say it ended, so notes
    /// carry the count on only within `NotesListening.carriesOnFor` of the
    /// quit, never into a call in the same app days later.
    public mutating func restore(_ kept: NotesListening) {
        guard listening == nil else { return }
        var count = kept
        count.callIsOver(at: kept.lastSeen)
        listening = count
    }

    /// What the cap is counted with: the Mac's running time (`RunningTime`)
    /// and the plan, as they are at this event.
    private struct Reading {
        let running: TimeInterval
        let plan: PlanSnapshot
    }

    /// `enabled` is the hidden switch; `autoStart` is "Always". `running` is
    /// the Mac's running time now and `plan` the plan now; without both,
    /// nothing is counted and notes listen for as long as the call lasts.
    public mutating func apply(_ event: Event, enabled: Bool, autoStart: Bool,
                               running: TimeInterval? = nil, plan: PlanSnapshot? = nil) -> [Effect] {
        let reading = running.flatMap { running in plan.map { Reading(running: running, plan: $0) } }
        let wasListening = isListening
        let effects = step(event, enabled: enabled, autoStart: autoStart, reading: reading)
        if let reading {
            if wasListening, !isListening { listening?.close(at: reading.running) }
            if !wasListening, isListening { listening?.open(at: reading.running) }
        }
        return effects
    }

    /// Notes on a call (not in the room) are being taken.
    private var isRecordingACall: Bool {
        if case let .recording(call, _) = phase { return !call.isInPerson }
        return false
    }

    /// Recording and not paused: what the cap counts.
    private var isListening: Bool {
        guard case .recording = phase else { return false }
        return pausedSince == nil
    }

    /// Whether notes on `call` may start now, and if so, the count they add
    /// to: the one before if they carry it on, a new one otherwise.
    private mutating func mayListen(to call: OngoingCall, _ reading: Reading?) -> Bool {
        guard let reading else { return true }
        if var count = listening, count.carriesOn(into: call, at: reading.running) {
            guard !count.isSpent(at: reading.running, plan: reading.plan) else { return false }
            count.close(at: reading.running)
            count.carryOn(into: call, at: reading.running)
            listening = count
        } else {
            listening = NotesListening(startedOn: reading.plan, call: call, at: reading.running)
        }
        return true
    }

    /// Whether notes on `call` would carry on a count that is used up.
    private func isSpent(for call: OngoingCall, _ reading: Reading?) -> Bool {
        guard let reading, let count = listening else { return false }
        return count.carriesOn(into: call, at: reading.running)
            && count.isSpent(at: reading.running, plan: reading.plan)
    }

    private mutating func step(_ event: Event, enabled: Bool, autoStart: Bool, reading: Reading?) -> [Effect] {
        switch event {
        case let .callStarted(call, at):
            guard enabled else { return [] }
            var finished: [Effect] = []
            if case let .recording(current, _) = phase {
                // A call joined from the room is heard by the same
                // microphone: the notes in person carry on, and say it all.
                if current.isInPerson { return [] }
                // The same call, back before the notes stopped: nothing changes.
                if current.bundleID == call.bundleID {
                    ending = nil
                    return []
                }
                // The detector follows one call at a time, so another app's
                // call means this one is over.
                finished = finishAutomatically(current, endedAt: ending?.micLetGo ?? at, reading)
            }
            // Its notes are used up: no offer, and nothing starts.
            if isSpent(for: call, reading) {
                switch phase {
                case .offering, .startingSoon: phase = .idle
                default: break
                }
                return finished
            }
            if let last = lastNotes, last.bundleID == call.bundleID,
               at.timeIntervalSince(last.endedAt) <= Self.sameMeetingWindow,
               mayListen(to: call, reading) {
                phase = .recording(call, since: at)
                firstStarted = last.firstStarted ?? at
                return finished + [.startNotes(call, continuing: true)]
            }
            if autoStart {
                // The same call said twice keeps its countdown.
                if case let .startingSoon(current, _) = phase, current.bundleID == call.bundleID {
                    return finished
                }
                phase = .startingSoon(call, startsAt: at.addingTimeInterval(Self.countdown))
                return finished
            }
            phase = .offering(call)
            askedAt = at
            return finished

        case let .callEnded(at):
            // The count's call is over. Notes on it wait for the looks to
            // confirm the end first (`finishAutomatically`).
            if let reading, !isRecordingACall { listening?.callIsOver(at: reading.running) }
            switch phase {
            case .offering, .startingSoon:
                phase = .idle
                return []
            case let .recording(call, _):
                // Not the notes' call: the room has none to end.
                if call.isInPerson { return [] }
                // Not yet: the ticks decide once the wait is over.
                var waiting = ending ?? Ending()
                waiting.micLetGo = waiting.micLetGo ?? at
                ending = waiting
                return []
            default:
                return []
            }

        case let .accept(at), let .acceptAlways(at):
            let always: [Effect] = {
                if case .acceptAlways = event { return [.rememberAlways] }
                return []
            }()
            switch phase {
            case let .offering(call), let .startingSoon(call, _):
                guard mayListen(to: call, reading) else {
                    phase = .idle
                    return always
                }
                phase = .recording(call, since: at)
                firstStarted = at
                return always + [.startNotes(call, continuing: false)]
            default:
                return always
            }

        case .decline:
            switch phase {
            case .offering:
                phase = .idle
            case let .startingSoon(call, _):
                // Skipped: not now, but the offer stays, settled, for a
                // change of mind later in the call.
                phase = .offering(call)
                askedAt = nil
            default:
                break
            }
            return []

        case let .takeNotesInPerson(at):
            guard enabled else { return [] }
            switch phase {
            case .idle, .ready, .failed:
                let room = OngoingCall.inPerson(at: at)
                guard mayListen(to: room, reading) else { return [] }
                // A new meeting: whatever call came before is not carried on.
                lastNotes = nil
                ending = nil
                phase = .recording(room, since: at)
                firstStarted = at
                return [.startNotes(room, continuing: false)]
            default:
                // A call is on, or notes are already taken or being written:
                // the button says so (`handButton`) and does that instead.
                return []
            }

        case .stop:
            guard case let .recording(call, _) = phase else { return [] }
            // Stopped by hand: a call that drops and returns afterwards is
            // asked about again, not quietly resumed.
            lastNotes = nil
            ending = nil
            phase = .writing(call)
            return [.finishNotes]

        case let .pause(at):
            guard case .recording = phase, pausedSince == nil else { return [] }
            pausedSince = at
            return [.pauseNotes]

        case let .resume(at):
            guard case .recording = phase, pausedSince != nil else { return [] }
            pausedSince = nil
            resumedAt = at
            return [.resumeNotes]

        case let .saved(folder):
            // A new call may already be on; its ask outranks old news.
            if case let .writing(call) = phase { phase = .ready(folder: folder, call: call) }
            return []

        case let .failed(reason):
            switch phase {
            case .recording, .writing:
                phase = .failed(reason)
                lastNotes = nil
                ending = nil
            default:
                break
            }
            return []

        case .dismiss:
            switch phase {
            case .ready, .failed: phase = .idle
            default: break
            }
            return []

        case let .appQuit(bundleID, at):
            if case let .startingSoon(call, _) = phase, call.bundleID == bundleID {
                phase = .idle
                return []
            }
            guard case let .recording(call, _) = phase, call.bundleID == bundleID else { return [] }
            // A quit app has let go of the microphone too, whether or not the
            // detector has said so yet.
            var waiting = ending ?? Ending()
            waiting.micLetGo = waiting.micLetGo ?? at
            waiting.quitAt = at
            ending = waiting
            return []

        case let .sleep(at):
            // Asleep, nothing can be heard: what was heard is written now.
            // Not held to `shortestNotes`, because nothing is left to wait on.
            if case .startingSoon = phase {
                phase = .idle
                return []
            }
            guard case let .recording(call, _) = phase else { return [] }
            let effects = finishAutomatically(call, endedAt: at, reading)
            if case .writing = phase { endedBySleep = true }
            return effects

        case let .tick(tick):
            guard case let .recording(call, since) = phase else { return [] }
            return look(tick, call: call, since: since, reading)
        }
    }

    /// One look while recording: is the call back, over, gone quiet, or has
    /// it been listened to for as long as the plan lets it?
    private mutating func look(_ tick: Tick, call: OngoingCall, since: Date, _ reading: Reading?) -> [Effect] {
        let now = tick.now
        if var waiting = ending, let onMic = tick.callOnMic {
            if onMic {
                // Back on the microphone: the end is off. Kept as "waiting"
                // until the detector agrees, because it is the detector that
                // would say when it ends again, and it believes it has.
                waiting.micLetGo = nil
                waiting.quitAt = nil
            } else if waiting.micLetGo == nil {
                waiting.micLetGo = now
            }
            ending = waiting
        }

        if let waiting = ending, let letGo = waiting.micLetGo {
            var stopAt = waiting.quitAt.map { $0.addingTimeInterval(Self.quitHold) }
                ?? letGo.addingTimeInterval(Self.micHold)
            stopAt = max(stopAt, since.addingTimeInterval(Self.shortestNotes))
            let theyAreTalking = tick.theirLastSpeech.map {
                now.timeIntervalSince($0) < Self.stillTalking
            } ?? false
            let talkingMayHold = now.timeIntervalSince(letGo) < Self.talkingLimit
            if now >= stopAt, !(theyAreTalking && talkingMayHold) {
                return finishAutomatically(call, endedAt: letGo, reading)
            }
        }

        // Listened as long as the plan lets it: the listening stops and what
        // was heard is written. The call goes on, so it stays the count's
        // call, and nothing carries these notes on by itself.
        if let reading, let count = listening, count.isSpent(at: reading.running, plan: reading.plan) {
            ending = nil
            lastNotes = nil
            phase = .writing(call)
            stoppedAtLimit = true
            return [.finishNotes]
        }

        // Paused, nothing is meant to be heard, so quiet proves nothing.
        guard pausedSince == nil else { return [] }
        let lastHeard = max(since, resumedAt ?? since, tick.lastSpeech ?? since)
        if now.timeIntervalSince(lastHeard) >= Self.silenceLimit {
            return finishAutomatically(call, endedAt: now, reading)
        }
        return []
    }

    /// The notes stop on their own. A call from the same app soon after is
    /// still the same meeting (`sameMeetingWindow`), unlike a stop by hand,
    /// and that holds for one too short to keep: it can still grow.
    ///
    /// Notes in person are the exception on both counts: they were asked for,
    /// so they are kept however short, and no call can carry them on.
    private mutating func finishAutomatically(_ call: OngoingCall, endedAt: Date, _ reading: Reading?) -> [Effect] {
        if let reading, !call.isInPerson { listening?.callIsOver(at: reading.running) }
        if call.isInPerson {
            ending = nil
            phase = .writing(call)
            return [.finishNotes]
        }
        lastNotes = LastNotes(bundleID: call.bundleID, endedAt: endedAt, firstStarted: firstStarted)
        ending = nil
        if let first = firstStarted, endedAt.timeIntervalSince(first) < keepsFrom {
            phase = .idle
            return [.dropNotes]
        }
        phase = .writing(call)
        return [.finishNotes]
    }

    /// What the one "Take notes" button does right now, wherever it is drawn
    /// (the Calls tab, the menu bar).
    public var handButton: HandButton {
        switch phase {
        case .idle, .ready, .failed: return .takeNotes
        case .offering, .startingSoon: return .takeNotesOfCall
        case .recording: return .stop
        case .writing: return .busy
        }
    }

    public enum HandButton: Equatable, Sendable {
        /// Start notes in person (`Event.takeNotesInPerson`).
        case takeNotes
        /// A call is on and its notes are not taken yet: start those
        /// (`Event.accept`), not a meeting in the room beside it.
        case takeNotesOfCall
        /// Notes are being taken, of a call or in person: stop them.
        case stop
        /// The last notes are still being written; nothing to start yet.
        case busy
    }

    /// The call pill's mark at `now`. `muted` is the call app's own mute
    /// button, which the model watches; a pause outranks it, because a pause
    /// is the notes' own state and the one to undo first.
    public func pillMark(now: Date, muted: Bool) -> PillMark {
        switch phase {
        case .offering:
            guard let askedAt else { return .offer }
            let elapsed = now.timeIntervalSince(askedAt)
            return elapsed >= 0 && elapsed < Self.askWiden ? .ask : .offer
        case let .startingSoon(_, startsAt):
            return .startingSoon(startsAt)
        case .recording:
            if pausedSince != nil { return .paused }
            return muted ? .muted : .recording
        case .idle, .writing, .ready, .failed:
            return .none
        }
    }

    /// What the call pill and the notes card say about the plan's limit, if
    /// anything: a heads-up in the last `LimitWord.headsUp` before the notes
    /// stop, then that they stopped, for as long as those notes are on show.
    /// Nil on a plan with no limit, so only Free ever sees either.
    public func limitWord(running: TimeInterval, plan: PlanSnapshot) -> LimitWord? {
        if stoppedAtLimit { return .stopped }
        guard case .recording = phase, let left = listening?.left(at: running, plan: plan) else { return nil }
        return left > 0 && left <= LimitWord.headsUp ? .stopsSoon : nil
    }

    /// Free's notes stop at `PlanLimits.freeNotesListen`; the call goes on.
    public enum LimitWord: Equatable, Sendable {
        /// Within `headsUp` of the limit.
        case stopsSoon
        /// The limit stopped them.
        case stopped

        /// How long before the limit the heads-up starts.
        public static let headsUp: TimeInterval = 5 * 60
        /// How long the closed notch says it. The open card says it for as
        /// long as it is true; the closed notch sits over the menu bar, so a
        /// wider pill is allowed for this long only (`CompactSlot`'s ladder).
        public static let pillFor: TimeInterval = 30

        /// In the call pill, in place of the call's timer.
        public var pillWord: String {
            switch self {
            case .stopsSoon: "Notes stop at \(Self.minutes) min"
            case .stopped: "Notes stopped"
            }
        }

        /// On the notes card in the open notch.
        public var line: String {
            switch self {
            case .stopsSoon:
                "Notes stop at \(Self.minutes) minutes on Free. The call itself goes on."
            case .stopped:
                "The first \(Self.minutes) minutes are saved. Plus takes notes of the whole call."
            }
        }

        static var minutes: Int { Int(PlanLimits.freeNotesListen / 60) }
    }

    public enum PillMark: Equatable, Sendable {
        case none
        /// "Notes?", the call's first `askWiden`.
        case ask
        /// The offer, settled: a dot to tap.
        case offer
        /// "Notes in 3", counting down to the date.
        case startingSoon(Date)
        case recording
        /// Notes are taken but the call app's mute is on: your side is not
        /// on the call.
        case muted
        case paused
    }
}
