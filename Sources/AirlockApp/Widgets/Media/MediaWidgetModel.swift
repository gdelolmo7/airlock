import AirlockCore
import AppKit
import Observation
import Foundation

/// Why the reactive wave is not moving, and therefore what to say about it.
///
/// Pure and separate from the model for the same reason `AudioOutputMenu` is:
/// the rule is easy to get wrong and invisible when you do. This one WAS wrong.
/// A tap that delivers nothing at all was reported as "reading silence — macOS
/// most likely denied audio capture", which sends somebody to a permission that
/// is already granted and leaves them there.
///
/// Two failures, opposite advice:
///
/// - **Buffers arrive, all zero** — capture denied. Answerable by the person.
/// - **No buffers at all** — the tapped process is putting nothing into the tap.
///   Measured cause: a player stranded on an output device it can no longer
///   reach, which goes on reporting itself as playing while producing silence.
///   Every Core Audio call still returned `noErr`. No permission is involved.
///
/// `SystemAudioTap.hasFired` is what tells them apart.
enum WaveTapDiagnosis: Equatable {
    /// Audio is arriving and the glyph is following it.
    case following
    /// Too early to judge. A tap is allowed a moment before its first buffer,
    /// and a verdict inside that window is just a race with the audio thread.
    case starting
    /// Buffers, but silence inside them.
    case deniedCapture
    /// Not one buffer, ever.
    case neverDelivered

    /// - Parameters:
    ///   - heardAudio: any band has been non-zero since this tap started.
    ///   - fired: the IOProc has been called at least once.
    ///   - settled: the tap has been alive long enough that "nothing yet" means
    ///     something. Before that the only honest answer is `.starting`.
    static func of(heardAudio: Bool, fired: Bool, settled: Bool) -> WaveTapDiagnosis {
        if heardAudio { return .following }
        guard settled else { return .starting }
        return fired ? .deniedCapture : .neverDelivered
    }

    /// Whether this is something to act on rather than progress to watch.
    ///
    /// Settings drew its icon and colour from `tapFailure`, which is only set
    /// when the tap refuses to START — and neither silent failure does that.
    /// Both returned `noErr` all the way through, so both rendered in grey with
    /// a `waveform` icon, indistinguishable from "Following Spotify." A sentence
    /// that reports a problem and looks like a status line gets scrolled past.
    var isProblem: Bool {
        switch self {
        case .following, .starting: return false
        case .deniedCapture, .neverDelivered: return true
        }
    }

    /// Deliberately does NOT name a System Settings sub-pane. The old string
    /// sent people to "Privacy & Security › Microphone", and macOS has since
    /// moved system-audio capture out of Microphone into its own entry whose
    /// name has changed across releases. A path that is wrong is worse than a
    /// permission named accurately — and the denied case carries a button to
    /// the page now (`needsPermission`), so the sentence need not be a map.
    ///
    /// No "tapped" and no "buffer": those are the audio path's words, and the
    /// person reading this asked for moving bars.
    func message(player: String) -> String {
        switch self {
        case .following:
            return "Following \(player)."
        case .starting:
            return "Listening to \(player)…"
        case .deniedCapture:
            return "The wave can't hear \(player): macOS is keeping its sound from Airlock. "
                + "Allow system audio recording in Privacy & Security."
        case .neverDelivered:
            return "No sound is reaching the wave from \(player), which usually means it is stuck on an "
                + "output device it can't reach. Switching output device, or reopening \(player), "
                + "brings it back."
        }
    }

    /// The one verdict a permission fixes. `neverDelivered` is a player
    /// problem, and a button to Privacy & Security there would send people to
    /// a page with nothing on it to change.
    var needsPermission: Bool { self == .deniedCapture }
}

/// When a paused track's fifteen minutes start running.
///
/// Pure, and out here rather than three lines inside `refresh()`, because the
/// way to get this wrong is invisible when you do. `MediaPlayerState` is
/// `Equatable` INCLUDING `fetchedAt`, which moves on every poll — so deriving
/// the stamp from any whole-value comparison restarts the window forever and
/// the track never retires. Nothing looks broken, no test goes red, and the
/// slot the retirement was supposed to free is simply never freed.
///
/// Identity is `(player, title, artist)` and nothing else. Position is not part
/// of it: a paused track's position does not move, and if it does — somebody
/// scrubbed — that is the same track, still paused.
enum MediaPauseStamp {
    /// What counts as "the same paused track". Deliberately not the whole value.
    static func identity(_ state: MediaPlayerState?) -> [String]? {
        guard let state else { return nil }
        return [state.player.rawValue, state.title, state.artist]
    }

    static func next(previous: MediaPlayerState?, next: MediaPlayerState?,
                     existing: Date?, now: Date) -> Date? {
        // Playing, or nothing loaded at all: there is no pause to time.
        guard let next, !next.isPlaying else { return nil }
        // ALREADY paused the first time we looked, so there is no pause time to
        // know: the app just launched, the widget was just switched on, or the
        // player was. "Unknown" is not "just now" — reading it that way hands a
        // track paused at midnight a fresh fifteen minutes at 09:00, and again
        // at every launch after that, which is the retirement rule inverted.
        //
        // The safe reading is the other one: a track we have never seen playing
        // has been paused at least as long as we have been away, so hand back a
        // window that has ALREADY closed rather than one that has not started.
        // Pressing play clears the stamp and the artwork is back instantly, so
        // retiring one track too early costs nothing; carrying a dead one costs
        // the slot.
        guard let previous else { return existing ?? .distantPast }
        // Playing → paused and a DIFFERENT track now paused are both news, and
        // both start the clock. The second is the subtle case: touching the
        // player is intent, so the island should carry the new track for its
        // full window even though both states are "paused".
        guard !previous.isPlaying,
              identity(previous) == identity(next) else { return now }
        // Same paused track as before: the clock keeps running.
        return existing ?? now
    }
}

/// Which app the media card is about, for anything downstream that has to
/// agree with it.
///
/// One line, and out here anyway, because the line is the whole bug. The sound
/// card below the media card lists apps that are AUDIBLE, and a paused Spotify
/// is not — so the panel named *Get Free — Major Lazer* over a list containing
/// only Chrome, and offered no way to turn down the one track it was naming.
/// `AppVolumeModel` pins this app into its list to close that gap.
///
/// **Playing is deliberately not part of it.** The card shows a paused track
/// exactly as it shows a playing one, and the paused case is the entire reason
/// anyone downstream asks. A `state?.isPlaying == true` here would compile,
/// pass, and restore the contradiction.
enum NowPlayingPin {
    static func bundleID(of state: MediaPlayerState?) -> String? {
        state?.player.bundleID
    }
}

/// Now-playing state across players. Push-driven (each player posts a
/// distributed notification on playback changes) plus a slow poll while
/// playing to correct drift. Ambient tier: this model can change what the
/// compact island shows, but never expands it.
@MainActor
@Observable
final class MediaWidgetModel {
    private(set) var state: MediaPlayerState? {
        didSet {
            // The APP, not the track: this fires on every poll that moves the
            // playhead, and the pin only cares which player it is. Both sides
            // of the comparison go through `NowPlayingPin` so the guard and the
            // value it guards cannot drift apart.
            let pinned = NowPlayingPin.bundleID(of: state)
            guard pinned != NowPlayingPin.bundleID(of: oldValue) else { return }
            onNowPlayingChanged?(pinned)
        }
    }

    /// The app the card is about, playing or paused — see `NowPlayingPin`.
    var nowPlayingBundleID: String? { NowPlayingPin.bundleID(of: state) }

    /// The last track a player reported, kept after every player has quit.
    ///
    /// The card goes **dormant** rather than disappearing. A banner that
    /// vanishes takes ~110pt with it and reflows the whole tab — the console
    /// jumps up under a pointer already reaching for it — which reads as the
    /// panel breaking rather than as the music stopping. Holding the shape and
    /// greying it says the same thing without moving anything.
    ///
    /// Persisted, but only honoured while it is FRESH.
    ///
    /// It was memory-only, on the grounds that "last played 2h ago" for a track
    /// from before a reboot is an account of a session nobody remembers. That
    /// was right about the tail and wrong about the common case: quit Spotify,
    /// reopen the panel, and the card was simply gone — because a dormant track
    /// is made by a TRANSITION, and a launch with the player already closed has
    /// no transition to see. The slot the banner is meant to hold sat empty,
    /// which is the exact reflow going dormant exists to prevent.
    ///
    /// So it survives a relaunch and dies of old age instead — see
    /// `DormantTrack.freshness`.
    private(set) var dormant: DormantTrack? {
        didSet {
            guard dormant != oldValue else { return }
            if let dormant, let data = try? JSONEncoder().encode(dormant) {
                UserDefaults.standard.set(data, forKey: Self.dormantKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.dormantKey)
            }
        }
    }

    private static let dormantKey = "media.dormant"

    /// What survives the player quitting. Position and duration do not — a
    /// progress bar for a track nothing is playing is a number pretending to
    /// still be true.
    struct DormantTrack: Equatable, Codable {
        var player: MediaPlayerKind
        var title: String
        var artist: String
        var artworkURL: URL?
        /// When we last saw it loaded, for "· 2h ago".
        var since: Date

        /// How long a memory is worth keeping.
        ///
        /// A day covers the case this exists for — closed the player last night,
        /// opened the panel this morning — and lets the genuinely stale ones go.
        /// "Last played three weeks ago" is not context; it is a dead card
        /// holding a slot something else could use.
        static let freshness: TimeInterval = 24 * 60 * 60

        func isFresh(at now: Date) -> Bool {
            now.timeIntervalSince(since) < Self.freshness
        }

        /// The whole rule, as a pure function of the transition.
        ///
        /// Split out for the same reason `MediaPauseStamp` is: it is four lines
        /// that would otherwise be verified by quitting Spotify and watching a
        /// panel, and the case that matters — a live card never showing a
        /// memory beside it — is the one nobody would think to check by hand.
        static func next(previous: MediaPlayerState?, next: MediaPlayerState?,
                         existing: DormantTrack?, now: Date) -> DormantTrack? {
            // Something is loaded again. Whatever it is outranks the memory,
            // including a DIFFERENT player — which is why this does not compare
            // them.
            if next != nil { return nil }
            // Nothing was loaded before either, so this is not a transition and
            // an older memory keeps standing.
            guard let previous else { return existing }
            return DormantTrack(player: previous.player,
                                title: previous.title,
                                artist: previous.artist,
                                artworkURL: previous.artworkURL,
                                since: now)
        }
    }

    /// When the loaded track went from playing to paused, or nil while it plays.
    /// `.distantPast` for a track that was already paused the first time we
    /// looked — see `MediaPauseStamp.next`; an unknown pause time is read as an
    /// old one, so it retires rather than claiming a fresh window at launch.
    ///
    /// Published for the compact island, which retires a long-paused track from
    /// its 16pt slot — see `CompactIsland.mediaRetirement`. It says NOTHING
    /// about `state`, which is deliberately left alone: the expanded card must
    /// still show what is loaded when you open the panel an hour later.
    private(set) var pausedAt: Date?

    /// When a player that says it is playing went quiet here, once the wave
    /// has heard nothing for `MediaQuiet.after`: Spotify sent to an iPad, or
    /// stuck on an output it cannot reach. Only known while the wave follows
    /// the audio; nil otherwise, and while there is sound.
    private(set) var silentSince: Date?

    /// Playing, as the compact island means it: the player says so and,
    /// when the wave can hear, there is something to hear. A wave drawn over
    /// silence is flat stubs, so a silent track shows as a paused one.
    var islandPlaying: Bool { state?.isPlaying == true && silentSince == nil }

    /// `pausedAt` as the compact island means it: a silent track's fifteen
    /// minutes run from when it went quiet.
    var islandPausedAt: Date? { pausedAt ?? (state?.isPlaying == true ? silentSince : nil) }

    /// Where the thumb is being held right now, or nil when nobody is dragging.
    /// It outranks the polled position for as long as it exists — a bar that
    /// fought the finger holding it would be unusable.
    private(set) var scrub: TimeInterval?

    /// A seek asked for and not yet confirmed by the player. While it stands,
    /// incoming positions are replaced with where the drop says the playhead
    /// should be — see `MediaSeek` (Core, tested) for the three ways it ends.
    private(set) var pendingSeek: MediaSeek?

    /// The track the pending seek was aimed at, so a `next` arriving mid-wait
    /// cannot have the previous track's position held over it.
    /// `MediaPauseStamp.identity` and not the whole value, for the same reason
    /// it exists: `fetchedAt` moves on every poll.
    @ObservationIgnored private var pendingSeekTrack: [String]?

    /// The one thing that makes `MediaSeek.patience` a timeout rather than a
    /// predicate: a single sleep, armed with every seek and cancelled by every
    /// way one can end.
    ///
    /// `verdict` is only consulted when a report arrives, and the only
    /// guaranteed source of reports is the drift poll below — which runs *only
    /// while something is playing*. So the whole of patience was dead code for a
    /// seek a PAUSED player refused: the settle refresh 200ms later says `.hold`
    /// (0.2s < 4s), the poll never runs again, no change notification is posted,
    /// and the bar sits at a position nothing is playing from until the user
    /// next touches the player.
    ///
    /// A timer rather than dropping the poll's `isPlaying` gate, deliberately.
    /// The gate route would leave the deadline quantised to the poll's own five
    /// seconds — longer than the four it is meant to enforce, so the abandon
    /// lands somewhere in a 0–5s window and never at `patience` — and it would
    /// spend an Apple event every five seconds on a paused player to interrogate
    /// exactly the scripting interface that has already shrugged once. This
    /// fires at `requestedAt + patience` and nowhere else.
    @ObservationIgnored private var seekPatience: Task<Void, Never>?

    @ObservationIgnored private let toggle = WidgetToggle(key: "widget.media.enabled", defaultValue: true)
    /// Stored, not computed over UserDefaults: `@Observable` cannot track a
    /// computed property reading `@ObservationIgnored` storage, so toggling this
    /// in settings wrote the value without invalidating anything that reads it.
    var isEnabled: Bool = WidgetToggle.stored("widget.media.enabled", default: true) {
        didSet {
            guard isEnabled != oldValue else { return }
            toggle.value = isEnabled
            if !isEnabled {
                state = nil; pausedAt = nil; dormant = nil
                cancelScrub(); clearPendingSeek()
            }
            onChange?()
            if isEnabled { Task { await refresh() } }
        }
    }

    /// Drive the wave from the audio the player is actually producing.
    ///
    /// Off by default and it has to be: it needs a system-audio permission the
    /// app otherwise never asks for, and it keeps an audio tap open for as long
    /// as music plays. Nobody should pay either of those for a glyph they did
    /// not ask to be reactive.
    var reactiveWave: Bool = WidgetToggle.stored("widget.media.reactiveWave", default: false) {
        didSet {
            guard reactiveWave != oldValue else { return }
            UserDefaults.standard.set(reactiveWave, forKey: "widget.media.reactiveWave")
            syncTap()
        }
    }

    /// Live bar heights, or empty when there is no live audio to draw — which is
    /// the signal `MediaWaveView` uses to fall back to the canned animation.
    /// Empty rather than a flat array on purpose: "no data" and "silence" are
    /// different, and only one of them should stop the glyph moving.
    private(set) var waveLevels: [Double] = []
    /// Non-nil once a tap has been attempted and failed, so Settings can say so
    /// rather than leaving a switch that looks on and does nothing.
    private(set) var tapFailure: String?

    /// What the tap is doing right now, in a sentence.
    ///
    /// Worth its own property because the interesting failure is not "it did
    /// not start" — that one is loud — but "it started, and reads silence".
    /// macOS can hand back a tap that produces nothing at all when audio
    /// capture is denied, and without this the symptom is a flat glyph and no
    /// way to tell that from music that happens to be quiet.
    /// Names the player, always. "Following the audio" was useless the one time
    /// it mattered: macOS asked for permission to record Apple Music while
    /// Spotify was playing, and nothing in the app could confirm or deny which
    /// process it had actually tapped.
    var tapStatus: String? {
        guard reactiveWave, isEnabled else { return nil }
        if let tapFailure { return tapFailure }
        guard let player = state?.player, state?.isPlaying == true else {
            return "Waiting for something to play."
        }
        guard tap != nil else { return "Starting…" }
        return tapDiagnosis.message(player: player.displayName)
    }

    /// Whether `tapStatus` is reporting something wrong. `tapFailure` alone was
    /// not enough: it covers only the tap that refused to start, and both of the
    /// failures that actually reach people happen with every Core Audio call
    /// having returned `noErr`.
    var tapStatusIsProblem: Bool {
        if tapFailure != nil { return true }
        return tap != nil && tapDiagnosis.isProblem
    }

    /// Whether the status deserves the button to the recording permission.
    var tapStatusNeedsPermission: Bool {
        if tapFailure != nil { return true }
        return tap != nil && tapDiagnosis.needsPermission
    }

    /// The tap would not start at all. Static so the gallery draws it.
    nonisolated static let tapRefused = "macOS didn't let Airlock hear the music, so the wave uses its own animation."

    /// Observable on purpose, unlike `hasHeardAudio` beneath it: this is the one
    /// the settings text reads, and the verdict legitimately changes a second
    /// after the tap starts. An `@ObservationIgnored` verdict would leave the
    /// first, deliberately non-committal sentence on screen for good.
    private(set) var tapDiagnosis: WaveTapDiagnosis = .starting

    /// Set once any band has been non-zero, and never cleared while the tap
    /// lives: a quiet passage must not read as a denied permission.
    @ObservationIgnored private var hasHeardAudio = false

    /// Pump ticks since this tap started, for `WaveTapDiagnosis.settled`.
    @ObservationIgnored private var tapTicks = 0

    /// 1.5s at the pump's 20Hz. A working tap delivers roughly ninety callbacks
    /// a second, so this is not sized for the callback rate — it is sized for
    /// the gap between "the player says it is playing" and the first buffer
    /// actually landing, which is the only window where silence is innocent.
    private static let settleTicks = 30
    @ObservationIgnored private var lifecycle = TapLifecycle()
    @ObservationIgnored private var pumpTicks = 0

    @ObservationIgnored private var tap: SystemAudioTap?
    @ObservationIgnored private var envelope = WaveEnvelope()
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var quiet: MediaQuiet?

    /// The card changed which APP it is about. The mixer pins that app so the
    /// panel can never name a track it gives you no way to turn down.
    ///
    /// A push rather than `AppVolumeModel` reaching in here: the mixer knows
    /// nothing about media and is worth keeping that way, and a closure holding
    /// its target weakly is the seam where neither model can keep the other
    /// alive. Fires only on a change of app — see `state`'s `didSet`.
    @ObservationIgnored var onNowPlayingChanged: ((String?) -> Void)?

    /// The controller re-derives island presentation on media flips
    /// (playing ↔ silent changes whether the island has ambient content).
    @ObservationIgnored var onChange: (() -> Void)?
    /// Fronting the player leaves the notch; play/pause/next never do.
    @ObservationIgnored var onNavigateAway: (() -> Void)?
    /// A timeline drag has started or finished. The controller turns this into
    /// an `IslandPresentation.Holds.scrubbing`: a drag that overshoots the
    /// panel's edge reports the pointer as gone, and the hover-out grace would
    /// otherwise collapse the panel out from under a gesture still in progress.
    @ObservationIgnored var onScrubbingChanged: ((Bool) -> Void)?

    @ObservationIgnored private let controllers = MediaPlayerKind.allCases.map(MediaPlayerController.init)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    func start() {
        restoreDormant(now: Date())
        for kind in MediaPlayerKind.allCases {
            let observer = DistributedNotificationCenter.default().addObserver(
                forName: kind.changeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refresh() }
            }
            observers.append(observer)
        }
        // Launch and quit, for `runningPlayers`. A player quitting posts its
        // own notification, but one launching with nothing loaded posts
        // nothing, and the dormant card would go on saying "Open Spotify".
        let bundleIDs = Set(MediaPlayerKind.allCases.map(\.bundleID))
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let id = app?.bundleIdentifier, bundleIDs.contains(id) else { return }
                Task { @MainActor [weak self] in await self?.refresh() }
            }
            observers.append(observer)
        }

        // Drift-correction poll, only while something plays.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                if self.isEnabled, self.state?.isPlaying == true {
                    await self.refresh()
                }
            }
        }

        Task { await refresh() }
    }

    /// Query every RUNNING player (never launches one) and keep the most
    /// relevant state: playing beats paused, then most recent.
    func refresh() async {
        guard isEnabled else { return }
        var candidates: [MediaPlayerState] = []
        var refused: MediaPlayerKind?
        var running: Set<MediaPlayerKind> = []
        for controller in controllers where controller.isRunning {
            running.insert(controller.kind)
            switch await controller.fetch() {
            case .playing(let fetched): candidates.append(fetched)
            case .refused: refused = refused ?? controller.kind
            case .nothing: break
            }
        }
        if running != runningPlayers { runningPlayers = running }
        // Only while nothing else can be shown: a player that answers outranks
        // one that refuses, as playing outranks paused.
        let refusal = candidates.isEmpty ? refused : nil
        if refusal != refusedPlayer {
            refusedPlayer = refusal
            onChange?()
        }
        // Playing beats paused; otherwise most recent running player.
        var best = candidates.first { $0.isPlaying } ?? candidates.first
        best = reconcileSeek(with: best)
        if best != state {
            // BEFORE the assignment — the rule is about the transition, and the
            // old value is half of it.
            pausedAt = MediaPauseStamp.next(previous: state, next: best,
                                            existing: pausedAt, now: Date())
            updateDormant(previous: state, next: best, now: Date())
            state = best
            onChange?()
        }
        // After the state settles, so the tap follows what is actually playing
        // rather than what was playing a moment ago.
        syncTap()
    }

    /// Remember a track on its way out, forget it on anything's way in.
    ///
    /// Only the last player standing leaves one: while a player is running the
    /// live state is the truth, and a dormant card beside a playing one would be
    /// two answers to the same question.
    /// Bring back the last track, if it is recent enough to still mean
    /// something.
    ///
    /// Assigned through the property so a stale one is ERASED from disk rather
    /// than left to be re-read and re-rejected on every launch — a memory the
    /// app has already decided to ignore should not outlive the decision.
    ///
    /// `refresh()` overwrites this within a poll if a player is actually
    /// running, and `updateDormant` clears it the moment anything loads, so a
    /// restored card can never sit beside a live one.
    private func restoreDormant(now: Date) {
        guard let data = UserDefaults.standard.data(forKey: Self.dormantKey),
              let saved = try? JSONDecoder().decode(DormantTrack.self, from: data)
        else { return }
        dormant = saved.isFresh(at: now) ? saved : nil
    }

    private func updateDormant(previous: MediaPlayerState?, next: MediaPlayerState?, now: Date) {
        dormant = DormantTrack.next(previous: previous, next: next,
                                    existing: dormant, now: now)
    }

    /// The player macOS will not let Airlock read, while no other player has
    /// anything to show. The card says so and offers the Automation page,
    /// instead of disappearing as if nothing were playing.
    private(set) var refusedPlayer: MediaPlayerKind?

    /// Players open right now, read on every refresh and on launch and quit.
    /// The dormant card's wording depends on it: "Last played in Spotify" and
    /// "Open Spotify" were both wrong with Spotify sitting open.
    private(set) var runningPlayers: Set<MediaPlayerKind> = []

    static func refusedSentence(player: String) -> String {
        "Airlock isn't allowed to control \(player), so it can't show what's playing."
    }

    /// The dormant card's caption. Open but stopped is not "last played in" —
    /// the player is right there, it just has nothing loaded.
    static func dormantCaption(player: String, ago: String, isRunning: Bool) -> String {
        isRunning ? "Stopped in \(player) · \(ago)" : "Last played in \(player) · \(ago)"
    }

    /// The dormant card's button. The same action either way — opening a
    /// running app brings it forward — but "Open" for an open app reads as
    /// the card not knowing.
    static func dormantButton(player: String, isRunning: Bool) -> String {
        isRunning ? "Show \(player)" : "Open \(player)"
    }

    /// Bring the player that owned the dormant track back.
    func reopenDormantPlayer() {
        guard let dormant,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: dormant.player.bundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Nothing to remember once the widget is off — see `isEnabled`.
    func clearDormant() { dormant = nil }

    // MARK: - Reactive wave

    /// Open a tap exactly when there is something to tap, and close it the
    /// moment there isn't.
    ///
    /// The lifetime is deliberately tight. An always-open tap would sit on an
    /// aggregate device and a real-time thread for as long as the app is
    /// running, which is a lot to carry for a glyph nobody is looking at while
    /// the music is paused.
    private func syncTap() {
        // The when lives in `TapLifecycle` (Core, tested). It was wrong twice in
        // opposite directions — tearing the tap down on a single timed-out Apple
        // event, and the reverse failure of leaving one open on a paused player
        // — which is more than enough reason for it not to be three lines of
        // `if` in the middle of a model that also talks to AppleScript.
        switch lifecycle.evaluate(enabled: reactiveWave && isEnabled,
                                  isPlaying: state?.isPlaying == true,
                                  isRunning: tap != nil) {
        case .hold:
            return
        case .stop:
            return teardownTap()
        case .start:
            break
        }

        guard let player = state?.player else { return }

        let tap = SystemAudioTap()
        // EXACTLY the player that is playing, and nothing else.
        //
        // This used to pass both players "defensively", on the theory that we
        // might be reading metadata from one while the other was audible. That
        // theory was wrong — `refresh()` already picks the playing candidate —
        // and the cost was real: macOS raises its audio-capture prompt per
        // tapped process, so turning the wave on while Spotify played asked for
        // permission to record Apple Music. Being asked about an app you are
        // not using is how a permission request gets denied, and deserves to be.
        guard tap.start(bundleIDs: [player.bundleID]) else {
            // The overwhelmingly likely cause, and the only one the user can do
            // anything about.
            tapFailure = Self.tapRefused
            return
        }
        tapFailure = nil
        self.tap = tap
        quiet = MediaQuiet(startedAt: Date())
        tapTicks = 0
        tapDiagnosis = .starting
        startPump()
    }

    private func teardownTap() {
        guard tap != nil || pump != nil else { return }
        pump?.cancel()
        pump = nil
        tap?.stop()
        tap = nil
        quiet = nil
        if silentSince != nil {
            silentSince = nil
            onChange?()
        }
        hasHeardAudio = false
        tapTicks = 0
        tapDiagnosis = .starting
        envelope = WaveEnvelope()
        if !waveLevels.isEmpty { waveLevels = [] }
    }

    /// Reads the tap at the rate the glyph is drawn, not the rate audio arrives.
    /// `WaveEnvelope`'s smoothing constants are tuned for exactly this cadence.
    private func startPump() {
        pump?.cancel()
        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50)) // 20fps
                guard let self, let tap = self.tap else { return }
                // The audio thread publishes milestones as integers; this is
                // where they become log lines. It cannot write files itself —
                // `WaveDiagnostics.log` is `@MainActor` precisely so that
                // stays true.
                tap.drainDiagnostics()
                let bands = tap.latestBands
                if !self.hasHeardAudio, bands.contains(where: { $0 > 0 }) {
                    self.hasHeardAudio = true
                }
                self.envelope.ingest(bands)
                self.waveLevels = self.envelope.levels

                // Assigned only on a change, like the diagnosis below; and the
                // island hears of it, since it decides what the island shows.
                self.quiet?.hear(bands, at: Date())
                let silent = self.quiet?.silentSince(at: Date())
                if silent != self.silentSince {
                    WaveDiagnostics.log(silent == nil ? "  sound again" : "  silent: nothing to hear")
                    self.silentSince = silent
                    self.onChange?()
                }

                // Which of the two silent failures this is. Assigned only on a
                // change: `@Observable` notifies on every write, and this runs
                // twenty times a second for the whole life of the tap.
                self.tapTicks += 1
                let diagnosis = WaveTapDiagnosis.of(
                    heardAudio: self.hasHeardAudio,
                    fired: tap.hasFired,
                    settled: self.tapTicks >= Self.settleTicks)
                if diagnosis != self.tapDiagnosis {
                    self.tapDiagnosis = diagnosis
                    // The verdict is the one thing the existing milestones could
                    // not show: they record that callbacks happened, never what
                    // the app concluded from their absence. Packaged and signed
                    // there is no debugger and no stderr, and "it told me to fix
                    // a permission that was already granted" is a bug report
                    // nobody can act on without this line.
                    WaveDiagnostics.log("  diagnosis → \(diagnosis) "
                        + "(heard=\(self.hasHeardAudio) fired=\(tap.hasFired) tick=\(self.tapTicks))")
                }

                // Whether the VIEW is being handed changing numbers is the one
                // thing the tap's own log cannot answer.
                self.pumpTicks += 1
                if self.pumpTicks == 1 {
                    WaveDiagnostics.log("  pump #\(self.pumpTicks) levels="
                        + self.waveLevels.map { String(format: "%.2f", $0) }.joined(separator: " "))
                }
            }
        }
    }

    // MARK: - Seeking

    /// Whether the timeline is a control or just a readout.
    ///
    /// Two independent reasons it can be a readout. A player that cannot move
    /// its playhead (none today — see `MediaPlayerKind.canSeek`), and a track
    /// with no total: live radio and the podcast states that report zero. There
    /// is nothing to seek WITHIN a stream, so that row stays a plain rule and
    /// the drag never attaches to it.
    var canSeek: Bool {
        guard let state else { return false }
        return state.duration > 0 && state.player.canSeek
    }

    /// What the timeline should draw at `now`: the finger if there is one, and
    /// otherwise the player's own position carried forward.
    ///
    /// The pending seek needs no branch here — `reconcileSeek` has already put
    /// the expected position into `state`, so there is one number and one place
    /// it comes from.
    func displayPosition(at now: Date) -> TimeInterval {
        if let scrub { return scrub }
        guard let state else { return 0 }
        return state.interpolatedPosition(at: now)
    }

    func beginScrub(at position: TimeInterval) {
        guard canSeek else { return }
        scrub = clampedPosition(position)
        onScrubbingChanged?(true)
    }

    func moveScrub(to position: TimeInterval) {
        guard scrub != nil else { return }
        scrub = clampedPosition(position)
    }

    func endScrub(at position: TimeInterval) {
        guard scrub != nil else { return }
        // Released BEFORE the seek is issued, so the panel is never held open by
        // a gesture that has finished even if the seek itself goes nowhere.
        cancelScrub()
        seek(to: position)
    }

    /// Let go of the drag without committing it — and the only place the hold
    /// is released, so there is one path out of a scrub however it ends.
    ///
    /// Called on its own when the gesture went away without ending: the panel
    /// torn down under it, the view leaving the hierarchy mid-drag, the widget
    /// switched off. SwiftUI sends no `.onEnded` for any of those, and a hold
    /// nobody releases is a panel expanded forever. Nothing is committed —
    /// a seek to wherever the pointer last happened to be is not what was meant.
    func cancelScrub() {
        guard scrub != nil else { return }
        scrub = nil
        onScrubbingChanged?(false)
    }

    /// Move the playhead to an absolute second. Also the VoiceOver path, which
    /// has no drag to end.
    func seek(to position: TimeInterval) {
        guard canSeek, var current = state else { return }
        let target = clampedPosition(position)
        let now = Date()
        let seek = MediaSeek(target: target, requestedAt: now)
        pendingSeek = seek
        pendingSeekTrack = MediaPauseStamp.identity(current)
        armSeekPatience(for: seek, at: now)
        // Optimistic, for the same reason play/pause is: the confirming poll is
        // a quarter of a second out, and without this the thumb springs back to
        // where it was for that quarter second on every single drag — the exact
        // yank the suppression exists to prevent, just shorter.
        current.position = target
        current.fetchedAt = now
        state = current
        onChange?()
        send(.seek(target))
    }

    /// Whether an incoming reading may be believed yet, and what to show if not.
    ///
    /// The rule is `MediaSeek` (Core, pure, tested); this is the plumbing around
    /// it. Only the POSITION is suppressed — title, artwork and play state from
    /// the same reading are not in doubt and go through untouched, so a track
    /// that gets paused mid-wait still shows as paused.
    private func reconcileSeek(with reported: MediaPlayerState?) -> MediaPlayerState? {
        guard let pending = pendingSeek else { return reported }
        guard var candidate = reported else {
            // The player stopped or quit. There is nothing left to confirm
            // against, and holding a position for a card that is gone would
            // outlive the next track's arrival.
            clearPendingSeek()
            return reported
        }
        switch pending.verdict(reported: candidate.position,
                               reportedAt: candidate.fetchedAt,
                               isPlaying: candidate.isPlaying,
                               sameTrack: MediaPauseStamp.identity(candidate) == pendingSeekTrack) {
        case .hold:
            candidate.position = pending.expectedPosition(at: candidate.fetchedAt,
                                                          isPlaying: candidate.isPlaying)
            return candidate
        case .confirmed, .abandoned:
            clearPendingSeek()
            return reported
        }
    }

    /// Sleep out whatever is left of `patience`, then let go if nothing has.
    ///
    /// `[weak self]` and nothing captured but the seek's own value, so the task
    /// cannot keep the model alive; it also holds no tap, no player and no
    /// controller, so the worst a leaked one can do is wake once and find
    /// nothing. Every ordinary ending — confirmed, a different track, the player
    /// quitting, the widget switched off — runs through `clearPendingSeek()`,
    /// which cancels it, so it does not fire late for a seek that was answered.
    private func armSeekPatience(for seek: MediaSeek, at now: Date) {
        seekPatience?.cancel()
        seekPatience = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seek.patienceRemaining(at: now)))
            guard !Task.isCancelled, let self else { return }
            await self.abandonSeekIfUnanswered(seek)
        }
    }

    /// The no-report arm of the same verdict `reconcileSeek` applies — asked of
    /// `MediaSeek` rather than decided here, so "how long is long enough" stays
    /// in one pure, tested place.
    ///
    /// The identity check is not redundant with cancellation: a task that has
    /// already woken cannot be cancelled out of its own continuation, and
    /// abandoning a NEWER seek than the one it was armed for is precisely the
    /// jump-back this type exists to prevent.
    private func abandonSeekIfUnanswered(_ seek: MediaSeek) async {
        guard pendingSeek == seek else { return }
        guard seek.verdictWithoutReport(at: Date()) == .abandoned else { return }
        // Drop the handle BEFORE clearing: this is that task, and letting
        // `clearPendingSeek` cancel it would mark the refresh below as cancelled
        // work before it has run.
        seekPatience = nil
        clearPendingSeek()
        // Clearing alone only stops the LYING; it does not correct it. The
        // optimistic position written at the drop is still in `state`, and a
        // paused player will never volunteer another reading — so the one thing
        // that heals the bar is going and asking.
        await refresh()
    }

    private func clearPendingSeek() {
        pendingSeek = nil
        pendingSeekTrack = nil
        seekPatience?.cancel()
        seekPatience = nil
    }

    /// Inside the track, always. A drag can be released past either end of the
    /// bar, and both players treat an out-of-range `player position` as an
    /// error rather than a clamp.
    private func clampedPosition(_ position: TimeInterval) -> TimeInterval {
        guard let duration = state?.duration, duration > 0 else { return max(0, position) }
        return min(max(0, position), duration)
    }

    // MARK: - Controls

    func togglePlay() { send(.togglePlay) }
    func next() { send(.next) }
    func previous() { send(.previous) }

    func activatePlayer() {
        guard let player = state?.player,
              let app = NSWorkspace.shared.runningApplications
                  .first(where: { $0.bundleIdentifier == player.bundleID }) else { return }
        app.activate()
        onNavigateAway?()
    }

    private func send(_ command: MediaCommand) {
        guard let player = state?.player,
              let controller = controllers.first(where: { $0.kind == player }) else { return }
        // Optimistic: `command` is fire-and-forget AppleScript, and the real
        // confirmation below is ~200ms out. A caller that checks `state.isPlaying`
        // right after calling this — dictation's pause-for-the-hold resume guard,
        // notably — needs to see the flip immediately or it reads the old value
        // and thinks its own pause never happened.
        if command == .togglePlay {
            state?.isPlaying.toggle()
            onChange?()
        }
        Task {
            await controller.command(command)
            try? await Task.sleep(nanoseconds: 200_000_000) // let the player settle
            await refresh()
        }
    }
}
