import Foundation

/// What each half of the compact island shows, and in what order of precedence.
///
/// Extracted from the two views because the rule had already gone wrong in the
/// way an unwritten rule does: the trailing slot's comment claimed "playing
/// music always reads as the wave, whatever else is going on", while the branch
/// above it returned an attention dot first — so anyone with an agent waiting
/// lost their music indicator, and the comment said otherwise. A precedence
/// list spread across two SwiftUI `if`-chains cannot be checked; this can.
///
/// **Attention takes both halves, deliberately.** It is the one state the
/// island exists to interrupt for, and a single lamp is easy to miss at the top
/// of a 16-inch screen — so it is worth costing music its slot for as long as
/// something is genuinely waiting. The word doing the work there is *genuinely*:
/// this is only defensible while nothing sets the attention state spuriously.
///
/// **One item per side, always; the ladder is a total order, never a stack.**
/// The compact island is a floating panel drawn OVER the menu bar, so every
/// extra point of width covers one more point of somebody's menu-bar extras —
/// on a 14-inch (1512pt wide, 185pt of cutout) the system status items begin
/// immediately right of the notch. A future claimant that cannot be drawn as one
/// glyph, or a glyph plus three characters or so, does not belong here; and the
/// widest thing in the ladder had better also be the shortest-lived, which is
/// why `.outputRoute` is the one that is allowed to be widest.
public enum CompactSlot: Equatable, Sendable {
    case empty
    /// Nothing to report, but the island is there.
    ///
    /// **The resting state, and it exists because the alternative was reported
    /// as a crash four times.** With no driver, `hasContent` was false and
    /// `IslandPresentation` hid the island outright — correct by its own rule,
    /// and indistinguishable from the app quitting. The worst version of it is
    /// self-inflicted: "pause the music" removes the artwork that was the
    /// island's only content, so a command that worked perfectly made the notch
    /// vanish, and the vanishing read as the failure.
    ///
    /// One dim glyph, narrower than anything else in the ladder, and always
    /// last — a driver that has something to say still takes the slot.
    case idle
    /// The agent chamber. Amber when something needs answering, blue otherwise;
    /// breathing only while a session is actually working.
    case agentLamp(attention: Bool, working: Bool)
    /// The amber dot beside the lamp. Attention only.
    case attentionDot
    /// A session just finished. Transient, and it outranks the lamp so the tick
    /// is actually seen.
    case completionTick
    case artwork
    case wave
    /// Minutes until a meeting that is close enough to matter.
    case meetingCountdown
    case meetingIcon
    /// Sound just moved to another output. Transient — see
    /// `CompactIsland.routeAcknowledgement` — and drawn as a glyph plus a short
    /// level bar, never a percentage: a number is wider, it repeats what the
    /// expanded card says, and nobody reads one in two seconds. `level == nil`
    /// is a device with no software volume (HDMI, many DACs) and draws the glyph
    /// alone; `muted` draws the slashed glyph and an empty bar, never "0%".
    ///
    /// `transport` is what picks the glyph — see `outputRouteSymbol`. The name
    /// is spoken and never drawn here, so the glyph is the ONLY thing on screen
    /// saying which device sound just moved to, which is why it had better not
    /// be derived from that name.
    case outputRoute(name: String?, transport: AudioOutputDevice.Transport,
                     level: Float?, muted: Bool)
    /// Battery low enough that the machine is about to stop. Critical only —
    /// see the ladder's note on why `isLow` is not admitted.
    case batteryCritical(minutes: Int?)
    /// Keep-awake let go because the battery went below the cutoff the user
    /// chose. Transient — see `CompactIsland.keepAwakeStopNotice` — and a
    /// driver, because the point is that somebody nearby sees the Mac is about
    /// to be allowed to sleep.
    case keepAwakeStopped(cutoff: Int)
    /// Claude's 5-hour or weekly limit crossed the level chosen in Settings,
    /// or, when asked for, reset after a warning (card Agents 1). Transient —
    /// see `CompactIsland.usageNoticeDuration` — and a driver: the point is
    /// that it is seen before Claude stops, not after.
    case usageNotice(UsageAlert.Notice)
    /// This Mac is being held awake, drawn as the cup the rail's keep-awake
    /// button wears. One rung above the shelf count and a passenger like it:
    /// it fills a slot, it never summons the island — see `hasContent`.
    case keepingAwake
    /// How many files are sitting on the shelf. The lowest rung there is, and a
    /// passenger: it fills a slot, it never summons the island.
    case shelfCount(Int)
    /// A guide is running: the eye while it looks, one dot per step while it
    /// points, the countdown before a no-progress end, the tick when done.
    /// A driver, ranked below attention only — a gate still wins both halves,
    /// and a guide the user started outranks every ambient signal.
    case guide(GuidePresentation.Compact)
    /// The user is on a call: the calling app's icon and a running timer, in
    /// the green macOS uses for a microphone in use. A driver — it brings the
    /// island up — and clicking it brings the call's window forward.
    case call(OngoingCall)
}

public extension CompactSlot {
    /// The one word beside the cup when keep awake has just stopped. Without
    /// it the glyph was the same cup as `.keepingAwake` plus a battery picture,
    /// and the meaning lived only in the spoken label.
    static let keepAwakeStoppedWord = "off"

    /// What VoiceOver says for this slot, or nil when the slot renders text that
    /// already speaks for itself.
    ///
    /// Here rather than in the view for the reason the precedence rule is: the
    /// island is a lamp, a dot and a bare number, so every one of these states
    /// is invisible to a screen reader unless something names it, and a name
    /// that drifts from the state it describes is the kind of bug nobody sees.
    /// The lamp had exactly that bug — see `agentLamp` below.
    var accessibilityLabel: String? {
        switch self {
        case .empty:
            return nil

        case .guide(let state):
            switch state {
            case .listening: return "Guide listening"
            case .looking(let app): return "Guide looking at \(app)"
            case let .guiding(step, count, offTrack, practice):
                let name = practice ? "Practice" : "Guide"
                return offTrack ? "\(name), off track, step \(step) of \(count)" : "\(name), step \(step) of \(count)"
            case .noProgress(let seconds): return "Guide ending in \(seconds) seconds"
            case .done(let message, _): return "Guide done: \(message)"
            }

        // Silent to VoiceOver on purpose. It is the island at rest, saying
        // nothing — announcing "Airlock" on every focus would be chrome read
        // aloud, which is exactly the noise `accessibilityLabel` returning nil
        // exists to avoid.
        case .idle:
            return nil

        case let .agentLamp(attention, working):
            // ATTENTION FIRST, and this is the whole point of putting the label
            // here. The view derived it from `working` alone, so a session
            // blocked on a gate — the one state this island exists to interrupt
            // for — announced itself as "Idle" whenever nothing else happened to
            // be running. The lamp is already amber and still in that state; the
            // label just never agreed with the colour.
            if attention { return "Agent needs an answer" }
            return working ? "Agent working" : "Agent idle"

        case .attentionDot:
            // Usually said twice, because attention takes both halves and the
            // lamp says it too. Kept anyway: when a session finishes while
            // another is blocked the leading slot is the completion tick, and
            // then this dot is the ONLY thing carrying the gate.
            return "Needs an answer"

        case .completionTick:
            return "Session finished"

        case .artwork:
            // `hasMedia` means a track is loaded. It says nothing about whether
            // it is playing — the wave is what says that — so this must not
            // claim either.
            return "Media"

        case .wave:
            return "Playing"

        case .meetingCountdown:
            // The view owns this one: the minutes come from a `TimelineView`
            // clock that does not exist here, and "Meeting soon" would throw
            // away the number that makes it useful.
            return nil

        case .meetingIcon:
            return "Meeting soon"

        case let .outputRoute(name, _, level, muted):
            // The label MAY say the percentage the view deliberately does not
            // draw. That asymmetry is the reason labels live here: what fits in
            // 30 points over the menu bar and what is useful to hear are not the
            // same question, and only one of them is about width.
            guard let name, !name.isEmpty else {
                // CoreAudio can name a current device that is not in the list
                // yet. Better to say the route moved than to invent a device.
                return "Output changed"
            }
            if muted { return "Output: \(name), muted" }
            guard let level else { return "Output: \(name)" }
            return "Output: \(name), \(Int((level * 100).rounded()))%"

        case let .batteryCritical(minutes):
            // The clause comes from `BatteryReading`, which is also what the
            // gutter indicator's label is built from — the same battery reaches a
            // screen reader through two different views, and phrasing it twice by
            // hand is how they start disagreeing.
            guard let left = BatteryReading.remaining(minutes: minutes) else { return "Battery critical" }
            return "Battery critical, \(left)"

        case let .keepAwakeStopped(cutoff):
            return "Keep awake stopped, battery below \(cutoff)%"

        case .usageNotice(let notice):
            // The percentage is drawn nowhere in the island, only the window;
            // this is where the number lives.
            return notice.sentence

        case .keepingAwake:
            // Said as what is happening, never as the button that did it. The
            // rail's "Keep this Mac awake" is an instruction; this is a report,
            // and a cup read aloud as an instruction would sound like a prompt
            // to go and press something.
            return "Keeping this Mac awake"

        case let .shelfCount(count):
            // Drawn as a tray and a bare numeral, and a numeral read aloud says
            // nothing about what it counts — true and useless.
            return count == 1 ? "1 file on the shelf" : "\(count) files on the shelf"

        case .call(let call):
            // The timer is drawn by a `TimelineView` and read with it; the
            // app is the part only this label can say, since the icon is a
            // picture.
            return "On a call in \(call.appName)"
        }
    }

    /// The glyph the route acknowledgement draws, or nil for every other slot.
    ///
    /// Here rather than in the view for the same reason `accessibilityLabel` is:
    /// the precedence has a rule in it, and a rule left in a view body is a rule
    /// nothing tests. **Silence outranks identity.** A muted output keeps the
    /// slashed speaker whatever it is plugged into — the acknowledgement's job
    /// in those two seconds is to say sound is going nowhere, and no other glyph
    /// in the set has a slashed variant to say it with.
    var outputRouteSymbol: String? {
        guard case let .outputRoute(_, transport, _, muted) = self else { return nil }
        return muted ? "speaker.slash.fill" : transport.symbol
    }
}

/// The inputs both slots resolve against. One value so the two sides cannot
/// drift into disagreeing about the same state.
public struct CompactIslandInput: Equatable, Sendable {
    public var agentsEnabled: Bool
    public var attentionCount: Int
    /// Open agent sessions. What it decides now is whether the leading lamp is
    /// lit — and through the lamp, whether open sessions summon the island. The
    /// closed island stopped drawing the number itself on 2026-09-30; see the
    /// trailing ladder for why, and the Agents tab's badge for where it went.
    public var sessionCount: Int
    public var anyRunning: Bool
    public var completionTick: Bool
    /// There is a track loaded — enough for artwork, not enough for the wave.
    public var hasMedia: Bool
    public var mediaPlaying: Bool
    public var meetingSoon: Bool

    /// The instant the two transient rules below are read against, supplied by
    /// the caller. Core owns no clock: "how long ago" is arithmetic on values
    /// handed in, which is what makes every case in this file a one-line test
    /// with no sleeping.
    ///
    /// **The initialiser gives this no default, deliberately.** A `= Date()`
    /// would put a live wall clock inside the one file whose doc comment says
    /// Core owns none, and it would do it silently: the transient rules would
    /// start reading the real clock, the value type would stop being a pure
    /// function of its inputs, and no test would go red — every existing caller
    /// passes an instant, so the default would only ever be reached by a future
    /// one that forgot to. Making it required means that caller has to answer
    /// "against which instant?" at the point where it actually knows.
    ///
    /// **Never use this value, or the whole input, as a SwiftUI
    /// `.animation(value:)` or `.onChange(of:)` key.** Two inputs built a
    /// millisecond apart are unequal, so any such key fires on every redraw. Key
    /// off the resolved `CompactSlot` instead — that is the thing that actually
    /// changed.
    public var now: Date
    /// When the default OUTPUT DEVICE last changed. Only a real move counts: a
    /// device merely appearing, or the first read at launch, is not a route
    /// change and must not stamp this, or the island blinks at every launch and
    /// every time a USB device is plugged in.
    public var outputChangedAt: Date?
    /// Read live rather than captured with the stamp, so an acknowledgement
    /// follows the level if it moves during its own two seconds. nil is a device
    /// with no software volume.
    public var outputLevel: Float?
    public var outputMuted: Bool
    /// For the VoiceOver label. Optional because CoreAudio's current-device UID
    /// can legitimately name a device that is not in the enumerated list for a
    /// beat — better nil than an invented name.
    public var outputDeviceName: String?
    /// For the GLYPH, and the reason it is a separate field from the name: the
    /// island draws the glyph and speaks the name, so the two carry different
    /// halves of the same device and neither is derived from the other.
    /// `.unknown` when CoreAudio's current device is not in the list yet — the
    /// same beat that leaves the name nil — and it draws the neutral speaker.
    public var outputTransport: AudioOutputDevice.Transport
    /// When the loaded track went from playing to paused, or nil while it is
    /// playing. Cleared on resume; re-stamped when the paused track's identity
    /// changes, because touching the player is intent.
    public var mediaPausedAt: Date?
    public var batteryCritical: Bool
    public var batteryMinutesRemaining: Int?
    /// Files on the shelf. Landed ones only — a tile still being ingested is not
    /// yet a file.
    public var shelfCount: Int
    /// The running guide's compact state, nil when no guide runs.
    public var guide: GuidePresentation.Compact?
    /// The keep-awake assertion is HELD. The fact, never a switch: hiding the
    /// rail's button or switching the rail off releases nothing, so neither may
    /// hide the one sign that it is still held — see
    /// `AppModel.compactIslandInput`.
    public var keepingAwake: Bool
    /// When the battery cutoff ended keep-awake, and at which level. Nil when
    /// it never has, or when it was last switched off by hand.
    public var keepAwakeStoppedAt: Date?
    public var keepAwakeCutoff: Int
    /// The limit notice raised most recently and when, nil when none has been
    /// or when agents are switched off. Read against `now` like the other
    /// transients, so a dropped redraw leaves it stale, never stuck.
    public var usageNotice: UsageAlert.Notice?
    public var usageNoticeAt: Date?
    /// The call the user is on, nil when none — see `CallDetector`.
    public var call: OngoingCall?

    public init(agentsEnabled: Bool = false, attentionCount: Int = 0,
                sessionCount: Int = 0, anyRunning: Bool = false,
                completionTick: Bool = false, hasMedia: Bool = false,
                mediaPlaying: Bool = false, meetingSoon: Bool = false,
                now: Date, outputChangedAt: Date? = nil,
                outputLevel: Float? = nil, outputMuted: Bool = false,
                outputDeviceName: String? = nil,
                outputTransport: AudioOutputDevice.Transport = .unknown,
                mediaPausedAt: Date? = nil,
                batteryCritical: Bool = false, batteryMinutesRemaining: Int? = nil,
                shelfCount: Int = 0, keepingAwake: Bool = false,
                keepAwakeStoppedAt: Date? = nil, keepAwakeCutoff: Int = 0,
                usageNotice: UsageAlert.Notice? = nil, usageNoticeAt: Date? = nil,
                guide: GuidePresentation.Compact? = nil,
                call: OngoingCall? = nil) {
        self.agentsEnabled = agentsEnabled
        self.attentionCount = attentionCount
        self.sessionCount = sessionCount
        self.anyRunning = anyRunning
        self.completionTick = completionTick
        self.hasMedia = hasMedia
        self.mediaPlaying = mediaPlaying
        self.meetingSoon = meetingSoon
        self.now = now
        self.outputChangedAt = outputChangedAt
        self.outputLevel = outputLevel
        self.outputMuted = outputMuted
        self.outputDeviceName = outputDeviceName
        self.outputTransport = outputTransport
        self.mediaPausedAt = mediaPausedAt
        self.batteryCritical = batteryCritical
        self.batteryMinutesRemaining = batteryMinutesRemaining
        self.shelfCount = shelfCount
        self.keepingAwake = keepingAwake
        self.keepAwakeStoppedAt = keepAwakeStoppedAt
        self.keepAwakeCutoff = keepAwakeCutoff
        self.usageNotice = usageNotice
        self.usageNoticeAt = usageNoticeAt
        self.guide = guide
        self.call = call
    }

    /// Agents own the leading slot unless switched off — then sessions are not
    /// something this Mac shows at all. **A gate is the exception, as
    /// everywhere else:** it still needs answering, so it overrides the switch.
    public var showsAgents: Bool { agentsEnabled || attentionCount > 0 }

    /// Sound moved recently enough to still be worth saying so.
    public var acknowledgingRoute: Bool {
        guard let at = outputChangedAt else { return false }
        let elapsed = now.timeIntervalSince(at)
        // `elapsed >= 0` is load-bearing, not defensive noise. A wall clock that
        // steps BACKWARDS — sleep/wake, an NTP correction — would otherwise
        // leave the acknowledgement lit for as long as the clock is behind the
        // stamp, and a two-second glyph that becomes a forever glyph is the
        // exact failure this whole cluster exists to avoid.
        return elapsed >= 0 && elapsed < CompactIsland.routeAcknowledgement
    }

    /// The battery cutoff ended keep-awake recently enough to still say so.
    /// The same backwards-clock guard as `acknowledgingRoute`, for the same
    /// reason.
    public var acknowledgingKeepAwakeStop: Bool {
        guard let at = keepAwakeStoppedAt else { return false }
        let elapsed = now.timeIntervalSince(at)
        return elapsed >= 0 && elapsed < CompactIsland.keepAwakeStopNotice
    }

    /// The limit notice is recent enough to still be on screen. The same
    /// backwards-clock guard again.
    public var showingUsageNotice: UsageAlert.Notice? {
        guard let notice = usageNotice, let at = usageNoticeAt else { return nil }
        let elapsed = now.timeIntervalSince(at)
        return elapsed >= 0 && elapsed < CompactIsland.usageNoticeDuration ? notice : nil
    }

    /// A track paused long enough that the island has better uses for the slot.
    ///
    /// Says NOTHING about the media model's state, which the expanded card still
    /// needs: this is about a 16pt slot, not about forgetting what is loaded.
    /// Open the panel and the track is still there.
    public var mediaRetired: Bool {
        guard let at = mediaPausedAt else { return false }
        return now.timeIntervalSince(at) >= CompactIsland.mediaRetirement
    }

    /// A track loaded and recent enough to keep its slot.
    public var showsMedia: Bool { hasMedia && !mediaRetired }
}

public enum CompactIsland {
    /// How long an output-route change is acknowledged. Two seconds, because
    /// this is the widest thing the island ever draws and it is covering
    /// somebody's menu-bar extras while it is up.
    public static let routeAcknowledgement: TimeInterval = 2

    /// How long a paused track keeps its compact slot.
    ///
    /// Fifteen minutes, not an hour, because the costs are asymmetric: retiring
    /// too early is free — pressing play clears the stamp and the artwork is
    /// back instantly, and the expanded card never stopped showing the track —
    /// while retiring too late is a dead slot. One constant, changed in one
    /// place; never a literal at a call site.
    public static let mediaRetirement: TimeInterval = 15 * 60

    /// How long the island says keep-awake stopped. Thirty seconds: longer
    /// than the route's two, because this one is news somebody walking back to
    /// the Mac should still catch, and short because the panel keeps the same
    /// line until it has been seen (`KeepAwakePolicy.keepsStoppedNotice`).
    public static let keepAwakeStopNotice: TimeInterval = 30

    /// How long the island shows a limit notice. Thirty seconds, like the
    /// keep-awake one and for its reason: news, not something waiting on you,
    /// and the open island's usage tiles keep the figure afterwards.
    public static let usageNoticeDuration: TimeInterval = 30

    public static func leading(_ i: CompactIslandInput) -> CompactSlot {
        if i.showsAgents, i.completionTick { return .completionTick }
        if i.showsAgents, i.attentionCount > 0 || i.sessionCount > 0 {
            return .agentLamp(attention: i.attentionCount > 0, working: i.anyRunning)
        }
        // **This side belongs to the mark, and yields only when yielding is the
        // only way a signal survives.**
        //
        // It used to yield unconditionally, and the cost was the mark
        // disappearing: `showsAgents` gates both rungs
        // above, so a user who declined agents reached neither, and any music
        // or upcoming meeting then replaced the only Airlock mark they ever saw
        // with somebody else's album cover. The app looked absent for whole
        // stretches of their day — the same failure `.idle` was added to fix,
        // arriving by a different route.
        //
        // Little is lost by moving them off, because the trailing ladder
        // already carries both, and carries the meeting BETTER: it shows a
        // countdown in minutes where this drew a static calendar glyph. Media
        // keeps `.wave` there while it plays.
        //
        // What IS given up is the album cover — the richest thing this slot
        // ever drew, and the only place a paused track showed compactly. The
        // expanded media card still has both. If that trade reads wrong later,
        // the move is `.artwork` REPLACING `.wave` on the trailing side, not
        // returning it here: this side belongs to the mark now.
        //
        // A PAUSED track has no trailing representation — `.wave` requires
        // `mediaPlaying` — so this side is the only place it can appear, and
        // `mediaRetirement` exists precisely to keep it there for fifteen
        // minutes. Playing music needs no such help: the wave already says so
        // opposite, which is why the common case (music on, mark gone) is the
        // one this fixes.
        // A guide puts the mark back whatever else wants this side: bloub is
        // the one walking the user through it, and his face carries the
        // guide's state (`BloubFace` reads it from the ambient facts).
        if i.guide != nil { return .idle }
        if i.showsMedia, !i.mediaPlaying { return .artwork }

        // Likewise a meeting whose countdown has been suppressed by a critical
        // battery. `testAMeetingKeepsTheLeadingSlotUnderACriticalBattery` states
        // the rule this preserves: "losing both at once would be a different,
        // worse trade than the one that was made."
        if i.meetingSoon, i.batteryCritical { return .meetingIcon }

        // The resting rung is no longer merely last — it is the only rung a
        // non-agent user can reach, which is why it had to stop being a
        // fallback and start being the default. See `CompactSlot.idle`.
        return .idle
    }

    /// **The trailing ladder is ordered by urgency ÷ dwell time, with a tie
    /// broken toward the signal macOS does not already give you.** Write that
    /// down or the order collapses into "whoever lives longest wins", which is
    /// how a permanent shelf count would come to eat the wave.
    ///
    /// - Attention first — see the type's note on why it is worth both halves.
    ///   A two-second acknowledgement is not worth weakening the one invariant
    ///   this file exists to protect. The cost is that a route change during a
    ///   gate goes unacknowledged; the person just pressed a control and can see
    ///   the result in the panel, and a gate has no other surface at all.
    /// - The route acknowledgement then outranks every steady state, for the
    ///   same reason the completion tick outranks the lamp: a two-second signal
    ///   that yields to a permanent one is never seen, so ranking it low is the
    ///   same as not building it. It borrows the slot and gives it straight back.
    /// - **A critical battery outranks the meeting countdown. This REVERSES an
    ///   earlier deliberate choice, so the argument it overturns is recorded
    ///   here rather than deleted.** That argument was: macOS already interrupts
    ///   for a dying battery with its own alert and never for a meeting, so
    ///   prefer the signal we are the only source of. It is still true as far as
    ///   it goes; what failed is the arithmetic underneath it. The glance window
    ///   is `CalendarWidgetModel.glanceEvent`: from ten minutes BEFORE an event
    ///   to five minutes AFTER it — fifteen minutes, not ten — and it re-arms
    ///   for each successive event, so a day of back-to-back half-hourly
    ///   meetings keeps the countdown lit fifteen minutes in every thirty. A
    ///   critical battery's ENTIRE dwell is fifteen to twenty-five minutes.
    ///   Under the old order the battery rung was therefore not *delayed* on a
    ///   busy calendar, it was never reached at all — and a rung that can never
    ///   render is not a ranking, it is dead code with a comment on it.
    /// - **The price of the reversal, accepted rather than overlooked:** the
    ///   countdown is suppressed for the fifteen to twenty-five minutes before
    ///   the machine stops. That is the smaller loss in both directions — a Mac
    ///   that dies misses the meeting anyway, and the battery rung clears the
    ///   instant power is plugged in, which is exactly the moment the countdown
    ///   becomes worth showing again. The meeting also keeps its claim on the
    ///   LEADING slot as `.meetingIcon`, which this decision does not touch:
    ///   what a critical battery suppresses is the count of minutes, never the
    ///   only mark that says a meeting is coming.
    /// - A critical battery outranks music: fifteen to twenty-five minutes
    ///   against a whole afternoon, and one of the two means the machine is
    ///   about to stop.
    /// - **No session count on this side, since 2026-09-30 — the owner's
    ///   decision.** The number of open agent sessions sat between the wave and
    ///   the cup, and it repeated what the other half already says: the leading
    ///   side lights the lamp (or the ✓ that briefly outranks it) for every
    ///   input that ever drew the count, so "agents are here" never needed a
    ///   second glyph. HOW MANY is a question for the open island, where the
    ///   Agents tab's badge carries the number. A place on this side is worth
    ///   more to a signal nothing else on screen gives — keep-awake first, then
    ///   the shelf — so that is who it went to. Summoning did not move with it:
    ///   the lamp was always a driver on its own, see `hasContent`.
    /// - **A call sits just under a critical battery** and over the meeting
    ///   countdown and the wave. It dwells as long as the call, but it is the
    ///   thing the user is doing this minute, which is the opposite of
    ///   background; see the rung itself for each neighbour.
    /// - **Keep-awake sits below the wave and above the shelf.** It can be held
    ///   from morning to night, so urgency ÷ dwell time puts it near the bottom,
    ///   under everything with more to say in less time. It outranks the shelf
    ///   because forgetting it has a real cost — a display that never sleeps, a
    ///   battery run down at an empty desk — and nothing on screen says it is
    ///   on: macOS keeps a held assertion out of the menu bar entirely, while a
    ///   forgotten file costs nothing until somebody wants it. That is this
    ///   ladder's tie-break doing its job.
    /// - **What that position costs, stated rather than discovered:** music
    ///   playing holds the slot, and the cup waits for the track to stop. The
    ///   2026-09-30 decision kept that order on purpose — a track is a stretch
    ///   of the afternoon where the assertion can be the whole day, and pausing
    ///   hands the slot straight back. The rungs above the wave outrank the cup
    ///   too, and each of them is short-lived by construction, which is why they
    ///   are up there. Open sessions no longer cost it anything: with agents on
    ///   and a session working, the lamp says so on the leading side and the cup
    ///   keeps this one.
    /// - The shelf count is last. A shelf with files on it is a state that lasts
    ///   days, and anything ranked below "days" is `.empty`.
    public static func trailing(_ i: CompactIslandInput) -> CompactSlot {
        if i.attentionCount > 0 { return .attentionDot }
        // Below attention (an agent waiting on an answer outranks a guide the
        // user can pause), above everything ambient: the user asked for this
        // one, and the eye is the promise that a look is visible.
        if let guide = i.guide { return .guide(guide) }
        if i.acknowledgingRoute {
            return .outputRoute(name: i.outputDeviceName,
                                transport: i.outputTransport,
                                level: i.outputLevel,
                                muted: i.outputMuted)
        }
        // Above the critical battery it is usually the cause of: that rung
        // lasts for the rest of the charge, and this one has thirty seconds to
        // say why the cup went out.
        if i.acknowledgingKeepAwakeStop { return .keepAwakeStopped(cutoff: i.keepAwakeCutoff) }
        // Thirty seconds, so above everything that lasts longer: below it, a
        // critical battery or a meeting would hold the slot for the whole of
        // the notice and it would never be seen.
        if let notice = i.showingUsageNotice { return .usageNotice(notice) }
        if i.batteryCritical { return .batteryCritical(minutes: i.batteryMinutesRemaining) }
        // Below a dying battery, which is the one thing likely to END the
        // call. Above the meeting countdown, because a call during the
        // meeting's window is usually that meeting, and the countdown has
        // nothing left to say; above the wave, because a call is what the
        // user is doing right now and the music is background to it.
        if let call = i.call { return .call(call) }
        if i.meetingSoon { return .meetingCountdown }
        if i.mediaPlaying { return .wave }
        if i.keepingAwake { return .keepingAwake }
        if i.shelfCount > 0 { return .shelfCount(i.shelfCount) }
        return .empty
    }

    /// Whether the island is on screen at all, as `IslandPresentation.resolve`'s
    /// `hasContent`. Here rather than hand-written at the controller because two
    /// copies of this reasoning is precisely how the trailing slot's comment
    /// came to disagree with its own code — and because a claimant the slots
    /// know about but this does not is simply invisible.
    ///
    /// Compact only. Nothing in here is ever a reason to EXPAND; that rule lives
    /// in `IslandPresentation` and is guarded by `testContentAloneNeverExpands`.
    ///
    /// **`.shelfCount` is excluded on purpose, and the exclusion is the rule
    /// rather than an optimisation.** Drivers summon the island; passengers only
    /// fill a slot that is already there. A shelf holding two files for a
    /// fortnight would otherwise pin a glyph over the menu bar for a fortnight —
    /// permanent chrome nobody asked for and which cannot be dismissed without
    /// emptying a folder. Do not simplify this to `trailing(i) != .empty`.
    ///
    /// `.keepingAwake` rides with it for the same reason at a different scale:
    /// an assertion held from morning to night would otherwise be enough, on
    /// its own, to hold the island up from morning to night.
    public static func hasContent(_ i: CompactIslandInput) -> Bool {
        // **A recent track is a driver even when nothing draws it**, and reading
        // that off the slots was a bug the moment the leading ladder stopped
        // showing album art. A PAUSED track used to summon the island through
        // `.artwork` on this side; once the mark took that slot unconditionally,
        // a dormant track became `.idle` here and `.empty` opposite, and the
        // island vanished — taking with it the whole point of `mediaRetirement`,
        // which is that a paused track keeps its place for fifteen minutes.
        //
        // Stated directly rather than inferred, because "what summons the
        // island" and "what occupies a slot" are different questions and had
        // been the same answer only by coincidence.
        if i.showsMedia { return true }

        // `.idle` is a PASSENGER, exactly like `.shelfCount`, and for the same
        // reason: it fills a slot, it does not summon anything. Counting it
        // would make this always true and quietly delete the driver/passenger
        // distinction the rest of this comment is about. Whether the island is
        // on screen at all is `IslandPresentation`'s question, not this one.
        //
        // **Open agent sessions summon the island here, through the lamp.** They
        // never depended on the session count the trailing side used to draw:
        // that rung needed `showsAgents && sessionCount > 0`, which is exactly
        // what lights the lamp (or the ✓ outranking it), and this side is read
        // first. So the count leaving the island on 2026-09-30 moved nothing
        // about when it comes up — pinned by
        // `testOpenSessionsStillSummonTheIslandThroughTheLamp`.
        switch leading(i) {
        case .empty, .idle: break
        default: return true
        }
        switch trailing(i) {
        case .empty, .shelfCount, .keepingAwake: return false
        default: return true
        }
    }
}
