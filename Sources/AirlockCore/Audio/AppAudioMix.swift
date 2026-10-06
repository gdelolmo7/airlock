import Foundation

/// An app that is currently putting sound out.
///
/// Keyed by bundle ID rather than pid for the same reason `AudioOutputDevice`
/// is keyed by UID: a pid is whatever the app got this launch, and a level the
/// person set for Spotify has to survive Spotify restarting.
///
/// **`pids` is a list, and that is the whole reason YouTube works.** A browser
/// does not play audio from the process you can see. Chrome renders each tab in
/// a helper, and it is the helper that shows up in Core Audio's process list —
/// under `com.google.Chrome.helper`, with a pid that is not in
/// `NSWorkspace.runningApplications` at all. Matching audio processes to apps
/// one-to-one finds Spotify and silently loses every browser, every Electron
/// app, and anything else that puts its media in a child. So the processes are
/// resolved to an owner and grouped, and one row taps all of them at once.
public struct AudibleApp: Equatable, Sendable, Identifiable {
    public let bundleID: String
    /// Every process of this app that is currently making sound. Sorted, so two
    /// enumerations of an unchanged app compare equal and do not churn the tap.
    public let pids: [pid_t]
    public let name: String

    public var id: String { bundleID }

    public init(bundleID: String, pids: [pid_t], name: String) {
        self.bundleID = bundleID
        self.pids = pids.sorted()
        self.name = name
    }
}

/// What to do with a tap that is already running.
public enum TapAction: Equatable, Sendable {
    /// Leave it alone.
    case keep
    /// Tear it down and build a new one; the app is still worth taking over.
    case rebuild
    /// Tear it down and do NOT rebuild. Destroying the tap is what unmutes the
    /// app, so this is the fail-open path, not merely a cleanup.
    case abandon
}

/// What a per-app level means, and when it is worth taking over the audio.
///
/// Pure and separate because every rule here is one that is invisible when
/// wrong. The one that matters most is `needsTap`: taking over an app's audio
/// costs a process tap, an aggregate device and a realtime thread, and — far
/// more importantly — it puts this app in the path of somebody's music. At unity
/// and unmuted there is nothing to do, so nothing should be done.
public enum AppMix {
    /// Unity, i.e. leave it alone.
    public static let unity: Float = 1

    /// **Unity. There is no boost, on purpose.**
    ///
    /// It was 2×, and that was wrong twice over. Above unity this is plain gain
    /// into a hard clamp with no limiter, so the top half of the track was not
    /// loudness, it was distortion — a control that makes things sound worse the
    /// further you push it. And a 0–200 app slider beside a 0–100 output slider
    /// meant a row reading 90 sat visibly LEFT of one reading 62: same card,
    /// same shape, incomparable numbers.
    ///
    /// Capping at unity fixes both at once and costs a feature that did not
    /// work. Raise it when there is a real limiter underneath, not before.
    public static let maxGain: Float = 1

    public static func clamp(_ gain: Float) -> Float {
        guard gain.isFinite else { return unity }
        return min(max(gain, 0), maxGain)
    }

    /// Whether this app's audio has to be routed through us at all.
    ///
    /// False at unity and unmuted, which is the state every app is in until
    /// somebody drags something. A tap that exists only to multiply by 1.0 is
    /// all of the risk and none of the point.
    public static func needsTap(gain: Float, isMuted: Bool) -> Bool {
        isMuted || abs(clamp(gain) - unity) > 0.001
    }

    /// The linear multiplier to apply to samples.
    public static func multiplier(gain: Float, isMuted: Bool) -> Float {
        isMuted ? 0 : clamp(gain)
    }

    /// Which apps get a row, in what order, when the card is only so tall.
    ///
    /// Two rules, both learned from `AudioOutputMenu`:
    ///
    /// - **The player you are looking at is never the one the cap hides.** The
    ///   media card is already showing Spotify's artwork; a volume list under it
    ///   that omits Spotify reads as a bug.
    /// - **Order does not depend on who is loudest.** Sorting by anything that
    ///   moves makes the rows swap places under the pointer mid-drag. After the
    ///   pinned player it is alphabetical, which is boring and holds still.
    public static func rows(_ apps: [AudibleApp],
                            playing: String?,
                            limit: Int) -> (shown: [AudibleApp], hidden: Int) {
        let sorted = apps.sorted { a, b in
            if a.bundleID == playing { return true }
            if b.bundleID == playing { return false }
            let byName = a.name.localizedCaseInsensitiveCompare(b.name)
            return byName == .orderedSame ? a.bundleID < b.bundleID : byName == .orderedAscending
        }
        guard limit > 0, sorted.count > limit else { return (sorted, 0) }
        return (Array(sorted.prefix(limit)), sorted.count - limit)
    }

    /// One place in the levels card: an app, and whether it is still making
    /// sound.
    public struct MixSlot: Equatable, Sendable, Identifiable {
        public let app: AudibleApp
        /// Went quiet recently. It keeps its place but not its control: a row
        /// drawn inert, or in the console an empty well where its fader stood.
        public let isIdle: Bool

        public var id: String { app.bundleID }

        public init(app: AudibleApp, isIdle: Bool) {
            self.app = app
            self.isIdle = isIdle
        }
    }

    /// The levels card's places, with recently-quiet apps holding theirs.
    ///
    /// **An app that stops making sound used to vanish from the card**, and
    /// every control after it moved into the gap — under a pointer that was
    /// already on its way to one of them. A video ending mid-drag is not a rare
    /// event, and "the slider I was reaching for became a different app" is the
    /// worst outcome a volume control has. It is the same hazard in either form:
    /// rows move up where faders slid left.
    ///
    /// So a departed app keeps its place for a while, drawn inert.
    /// Position is preserved exactly rather than approximately: the merged list
    /// goes through `rows` unchanged, so the pinned player and the alphabetical
    /// order below it are decided in ONE place and an idle app sits precisely
    /// where it sat while playing.
    ///
    /// `idle` entries that have started making sound again are ignored — live
    /// always wins, and an app cannot be both.
    public static func slots(live: [AudibleApp], idle: [AudibleApp],
                             playing: String?, limit: Int) -> (shown: [MixSlot], hidden: Int) {
        let liveIDs = Set(live.map(\.bundleID))
        let stillIdle = idle.filter { !liveIDs.contains($0.bundleID) }
        let (shown, hidden) = rows(live + stillIdle, playing: playing, limit: limit)
        let idleIDs = Set(stillIdle.map(\.bundleID))
        return (shown.map { MixSlot(app: $0, isIdle: idleIDs.contains($0.bundleID)) }, hidden)
    }

    /// Whether a tap that is already running should stay that way.
    ///
    /// Checked on a timer and again whenever the default output moves, because a
    /// tap is built against ONE output device and then keeps rendering to it. Two
    /// ways that goes wrong, and both are silent:
    ///
    /// - **The output device changed.** Switch to AirPods and the tapped app is
    ///   still being written to the speakers — and it cannot be heard anywhere
    ///   else, because `.mutedWhenTapped` took its own path away. One app keeps
    ///   playing out of the laptop while everything else moved.
    /// - **The IOProc stopped being called.** The aggregate is clock-driven, so
    ///   it fires whether or not the app is making noise; a counter that stops
    ///   advancing means the tap is dead, and a dead tap holds an app muted.
    /// - **The IOProc is called but has nowhere to put the audio.** Measured
    ///   while rebuilding onto an aggregate output device: callbacks arrived at
    ///   the usual rate with an output buffer list of ZERO buffers. Counting
    ///   callbacks says healthy; the app is silent. Liveness has to mean both
    ///   "we are being called" and "there is somewhere to write".
    ///
    /// Precedence matters and is the reason this is a function rather than three
    /// `if`s at the call site: when the output has just changed, a stalled
    /// counter is EXPLAINED by that change, and the answer is to rebuild against
    /// the new device — not to give up on an app that is about to work again.
    /// `abandon` is reserved for a tap that is broken in a way we cannot name,
    /// where the only safe move is to get out of the audio path.
    public static func supervise(outputChanged: Bool,
                                 processesChanged: Bool,
                                 callbacksAdvancing: Bool,
                                 hasSomewhereToWrite: Bool) -> TapAction {
        if outputChanged || processesChanged { return .rebuild }
        return callbacksAdvancing && hasSomewhereToWrite ? .keep : .abandon
    }

    /// Which running app a helper process belongs to, by name alone.
    ///
    /// The last resort, after asking the OS. Resolution order in the caller is
    /// (1) the pid IS an application, (2) walk up the parent chain until one is
    /// — which is what catches Chrome, whose helpers are children of the main
    /// process — and only then this, for helpers that were reparented and no
    /// longer have their app above them.
    ///
    /// Longest match wins, so `com.brave.Browser.helper` prefers
    /// `com.brave.Browser` over a hypothetical `com.brave`. Returns nil rather
    /// than guessing: a wrong answer here puts one app's slider on another
    /// app's audio, which is worse than a missing row.
    public static func owningBundleID(forHelper helper: String,
                                      among running: [String]) -> String? {
        if running.contains(helper) { return helper }
        let candidates = running.filter { owner in
            owner != helper && helper.hasPrefix(owner + ".")
        }
        return candidates.max { $0.count < $1.count }
    }

    /// Processes that make sound but are not something a person would recognise
    /// as "an app playing audio".
    ///
    /// Core Audio's process list is every client of the HAL, which on an idle Mac
    /// is a dozen daemons: the speech server, the ringer, Control Center. A
    /// volume mixer listing `com.apple.controlcenter` beside Spotify is noise,
    /// and offering to mute `coreaudiod`'s helpers is worse than noise.
    ///
    /// A prefix test is a heuristic and deliberately the SECOND line of defence
    /// — the caller filters to processes that have a real application behind
    /// them first. This catches the ones that do.
    public static func isSystemProcess(bundleID: String) -> Bool {
        systemPrefixes.contains { bundleID.hasPrefix($0) }
    }

    private static let systemPrefixes = [
        "com.apple.controlcenter",
        "com.apple.corespeechd",
        "com.apple.CoreSpeech",
        "com.apple.assistantd",
        "com.apple.Siri",
        "com.apple.TelephonyUtilities",
        "com.apple.audio",
        "com.apple.avconferenced",
        "com.apple.accessibility",
        "com.apple.universalaccessd",
        "com.apple.loginwindow",
        "com.apple.mediaremote",
        "systemsoundserverd",
        // Ours. Tapping ourselves to change our own level is a feedback loop.
        "com.airlock.",
        "com.agenticnotch.",
    ]
}

public extension AppMix {
    /// Which shape the levels card takes: horizontal rows — glyph, name, slider,
    /// number, one source per line — or the console, vertical faders standing
    /// side by side on one baseline.
    ///
    /// **This has been decided three times, and the history is the argument.**
    ///
    /// 1. **Rows below three sources, the console from three** (5cfcc96,
    ///    2026-08-19). Faders are for COMPARING — tracks on one baseline, read
    ///    against each other at a glance — and with one or two sources there is
    ///    nothing to compare. The console spent a whole card saying so: one
    ///    fader in a ~277pt box, the rest of it `Spacer`.
    /// 2. **The console, always** (ecefc5c, 2026-08-21). A card that is an
    ///    instrument one day and a settings list the next has to be re-read
    ///    every time it opens, and the latch in `SoundWidgetModel.form` only
    ///    protected a single session from that. One shape every time was judged
    ///    worth the empty half-card.
    /// 3. **Rows, always** (2026-09-28, the owner's call). The second decision
    ///    was right that the card must be one shape and wrong about which one.
    ///    The common case is one or two sources, and for that the console was
    ///    mostly empty: ~200pt of card, most of its width padding, around a
    ///    fader or two. Rows are ALSO one shape every time — consistency never
    ///    required faders — and they spend the card's width instead of padding
    ///    it: the slider takes the width it is handed, and the card is as tall
    ///    as its sources rather than always as tall as a fader — 64pt for one,
    ///    91pt for the output and an app, ~150pt for the output and four apps,
    ///    which is the most it ever shows. Measured with real sliders by
    ///    `LevelsRowsSnapshot`.
    ///
    /// What rows give up is decision 1's point: four or five sources read as a
    /// list of labels rather than as one instrument you compare at a glance.
    /// That is the argument to reread before moving the knob again.
    ///
    /// `console` stays in the tree rather than being deleted —
    /// `FaderConsoleView.faderRow` still draws it, and the latch still guards
    /// it — because keeping the fork alive is what makes each of these decisions
    /// one line to reverse. See `formThreshold`.
    enum Form: String, Sendable, Equatable, CaseIterable {
        case rows, console
    }

    /// The fewest sources that get the console — or `nil`, the shipped value,
    /// for none: every card is rows. See `Form` for why.
    ///
    /// **This is the whole knob, and reversing any of the three decisions is
    /// this one line.** `1` puts every drawable card back in the console
    /// (ecefc5c); `3` restores the original split (5cfcc96). Nothing else has to
    /// change with it: the view draws either form, and the latch stops a split
    /// threshold from restyling a card somebody is looking at.
    /// `LevelsFormTests` pins `nil`, so moving it is an edit that fails there
    /// first rather than one that slips through.
    ///
    /// Optional rather than a sentinel like `Int.max`, because "no count reaches
    /// the console" is a decision, and a very large number reads as a limit that
    /// a busy afternoon might one day exceed.
    static let formThreshold: Int? = nil

    /// Pure on purpose. The view layer of this card is out of reach of any
    /// assertion — `PanelSnapshot` renders only `ActionCardView`, and
    /// `LevelsRowsSnapshot` draws a picture to look at rather than a check — so
    /// the one decision worth protecting is extracted to where `swift test`
    /// can see it.
    ///
    /// `sourceCount` counts every level the card would draw: the output, when
    /// it has a software volume, plus each shown app slot. Idle slots count —
    /// they hold their place for 30s (see `slots`), so under a split threshold
    /// a form that ignored them would flip the card the moment a track paused.
    ///
    /// `threshold` is a seam for tests and for nothing else. At the shipped
    /// `nil` no count reaches the console, and a fork no input can reach is a
    /// fork nobody can show still works; the tests pass a threshold to prove
    /// it does. Callers leave it defaulted.
    static func form(sourceCount: Int, threshold: Int? = AppMix.formThreshold) -> Form {
        guard let threshold, sourceCount >= threshold else { return .rows }
        return .console
    }
}
