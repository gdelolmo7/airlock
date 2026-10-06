import AirlockCore
import AppKit
import CoreAudio
import Observation

/// Per-app volume: what macOS still has no mixer for.
///
/// **Off by default and behind a switch**, because unlike everything else in the
/// media card this one takes over the audio path. Switched off, not a single tap
/// exists and nothing here runs but the enumeration, which is a property read.
///
/// The levels are the model's, the audio is `AppVolumeTap`'s, and the rules
/// about when a tap is worth having are `AppMix`'s (Core, pure, tested).
@MainActor
@Observable
final class AppVolumeModel {

    /// Rough slice. This is here to be looked at and judged, not shipped: there
    /// is no limiter above unity, levels are per bundle ID with no per-device
    /// memory, and a device change rebuilds every tap rather than following it.
    @ObservationIgnored private let toggle = WidgetToggle(key: "widget.sound.appLevels",
                                                          defaultValue: false)
    var isEnabled: Bool = WidgetToggle.stored("widget.sound.appLevels", default: false) {
        didSet {
            guard isEnabled != oldValue else { return }
            toggle.value = isEnabled
            // `start()`/`stop()` rather than `refresh()`/`stopAll()`: the poll
            // task returns for good the moment it sees this switched off, so a
            // plain refresh on the way back left the mixer running with no
            // supervision — no rebuild on a device change, no watchdog on a tap
            // that died. Unreachable until this got a settings switch, and
            // reachable the moment it did.
            if isEnabled { start() } else { stop() }
        }
    }

    private(set) var apps: [AudibleApp] = []

    /// Apps that stopped making sound within the linger window, newest last.
    ///
    /// They keep their place in the card so it does not renumber under a
    /// pointer already reaching for a slider — see `AppMix.slots`. Kept here
    /// rather than in the view because the *timing* is state, and a view that
    /// remembered things across redraws would forget them on the first rebuild.
    private(set) var recentlyQuiet: [AudibleApp] = []

    /// How long a departed app keeps its place.
    ///
    /// Long enough to cover the reach — a video ending while your hand is on
    /// the way to a slider — and short enough that the card is not a museum
    /// of everything that played this afternoon.
    private static let lingerWindow: TimeInterval = 30

    /// bundleID → when it was last heard. Only for apps no longer in `apps`.
    @ObservationIgnored private var quietSince: [String: Date] = [:]

    /// bundle ID → level. Persisted, because a level somebody set for Spotify
    /// has to survive Spotify — and us — restarting.
    private(set) var gains: [String: Float] = [:]
    private(set) var muted: Set<String> = []

    /// Apps whose level has stopped reaching their audio, with the sentence
    /// their row shows about it (`LevelRow`) — so a slider that stopped working
    /// says so rather than just not working.
    ///
    /// Set in four places and drawn in none from 032a099, which deleted the
    /// view that showed it, until 2026-09-28 — the console had nowhere to put a
    /// sentence. A reason added here needs a reader, or it is a diagnosis
    /// nobody gets; and it needs to be in `failureSentences`, or it is a
    /// sentence nobody measured.
    private(set) var failures: [String: String] = [:]

    /// What a row says when its level has stopped reaching the app, whichever
    /// of the four ways that happened.
    ///
    /// **Written for the person listening.** The four sentences it replaced
    /// were the tap's own account, in the first person: "This app's audio
    /// stopped coming through, so we let go of it", "macOS wouldn't let us take
    /// this app's audio", and two versions of "Took this app's audio… so we
    /// gave it up". Unread from 032a099 until the rows form drew them again on
    /// 2026-09-28, and the first person to read one could fairly take "audio
    /// stopped coming through" to mean their sound was broken — when the one
    /// thing certain in all four cases is that it is not.
    ///
    /// What IS certain in all four is what this says:
    ///
    /// - **What you hear: the app, at its normal volume.** Every path that
    ///   records a failure either never took the audio or has just handed it
    ///   back — `AppVolumeTap.stop` destroying the tap is what unmutes the app.
    ///   So the level on the slider is not being applied, and neither is a mute
    ///   set here. That is the half most worth saying: a row drawn muted can be
    ///   audible.
    /// - **What to do: move the slider.** `setGain` clears the verdict and calls
    ///   `sync`, which builds a fresh tap whenever the new level still needs
    ///   one; the mute button goes the same way through `toggleMute`. "Try
    ///   again", not "fix it": what refused once can refuse again, and then this
    ///   comes back. `reset` clears it too and is not what this names, because
    ///   nothing has called it since 032a099 deleted the context menu that did.
    ///   Pausing and playing again, or switching output, retries unasked
    ///   (`refresh`, `outputDeviceChanged`) — true, and nothing anyone needs to
    ///   know in order to act.
    ///
    /// One sentence for four causes, because the difference changes neither
    /// half. It is kept where it is useful: each path still writes its own line
    /// to `AppVolumeDiagnostics`.
    ///
    /// Short on purpose — two lines at the default text size in the narrowest
    /// panel, whose side column leaves the caption ~164pt. Measured there by
    /// `LevelFailureCaptionTests`, not counted in characters.
    static let levelNotApplied = "Playing at its normal volume. Move the slider to try again."

    /// Every sentence `failures` can hold. Listed, and listed here, so that
    /// `LevelFailureCaptionTests` lays each one out in the narrowest card: a
    /// reason written inline at the line that records it would reach the row
    /// without ever having been measured.
    static let failureSentences = [levelNotApplied, AppVolumeTap.multiOutputRefusal]

    /// Said once under the levels while any row's level is not reaching its
    /// app. The row's own caption says "move the slider", and when the cause
    /// is the recording permission that advice loops forever — macOS offers
    /// no way to read that permission, so this says "may" and opens the page.
    static let permissionHint = "Levels not sticking? Airlock may need to record system audio."

    /// What a ROW says, given what `failures` holds for it. The Multi-Output
    /// refusal is about the output, not the app, so the same sentence under
    /// every row was one fact said four times; the card says it once instead
    /// (`cardNotice`).
    static func rowFailure(_ failure: String?) -> String? {
        failure == AppVolumeTap.multiOutputRefusal ? nil : failure
    }

    /// The one line the card says under its rows, if any.
    enum CardNotice: Equatable {
        /// The output is a Multi-Output Device; no app's level can apply.
        case multiOutput
        /// Some app's level is not reaching it; the permission may be why.
        case mayNeedPermission
    }

    /// The output's problem outranks the permission hint: while it stands,
    /// no tap is even attempted, so the permission is not yet the question.
    static func cardNotice(failures: [String]) -> CardNotice? {
        if failures.contains(AppVolumeTap.multiOutputRefusal) { return .multiOutput }
        if failures.contains(levelNotApplied) { return .mayNeedPermission }
        return nil
    }

    /// How many rows the card has space for before it stops looking like a
    /// media card and starts looking like a mixer.
    static let visibleLimit = 4

    @ObservationIgnored private var taps: [String: AppVolumeTap] = [:]
    @ObservationIgnored private var poll: Task<Void, Never>?

    private static let gainsKey = "widget.sound.appLevels.gains"
    private static let mutedKey = "widget.sound.appLevels.muted"
    /// A muted player's level to come back to. Saved beside `muted`, or a
    /// restart turned an unmute into 50% whatever it had been.
    private static let beforeMuteKey = "widget.sound.appLevels.beforeMute"
    /// Players whose mixer-era level has been carried over (`playerRead`).
    /// Saved, so "once" means once and not once per launch.
    private static let carriedOverKey = "widget.sound.appLevels.playersCarriedOver"
    /// Where these lived while this was a tail on the media card. Same rule as
    /// `IdentityMigration`: read the old name when the new one is absent, write
    /// only the new one, and never clobber. Somebody's levels are not worth
    /// losing to a rename.
    private static let legacyGainsKey = "widget.media.appVolume.gains"
    private static let legacyMutedKey = "widget.media.appVolume.muted"

    init() {
        let defaults = UserDefaults.standard
        let storedGains = defaults.dictionary(forKey: Self.gainsKey)
            ?? defaults.dictionary(forKey: Self.legacyGainsKey)
        gains = (storedGains as? [String: Double])?.mapValues { Float($0) } ?? [:]
        muted = Set(defaults.stringArray(forKey: Self.mutedKey)
            ?? defaults.stringArray(forKey: Self.legacyMutedKey) ?? [])
        levelBeforeMute = (defaults.dictionary(forKey: Self.beforeMuteKey) as? [String: Double])?
            .mapValues { Float($0) } ?? [:]
        seenPlayers = Set(defaults.stringArray(forKey: Self.carriedOverKey) ?? [])
    }

    /// Audible apps, plus the now-playing app even when it has fallen silent.
    ///
    /// Without the pin, the panel contradicted itself: the media card named
    /// *Get Free — Major Lazer* while the sound card below listed only Chrome,
    /// because Spotify was paused and therefore not audible. The app you are
    /// looking at has to be the app you can turn down.
    ///
    /// A pinned-but-silent app gets a row and keeps its level; it gets no tap,
    /// because there is nothing to tap — see the audibility guard in `sync`.
    var rows: (shown: [AudibleApp], hidden: Int) {
        var listed = apps
        if let playing = playingBundleID,
           !listed.contains(where: { $0.bundleID == playing }),
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: playing).first {
            listed.append(AudibleApp(bundleID: playing, pids: [],
                                     name: app.localizedName ?? playing))
        }
        return AppMix.rows(listed, playing: playingBundleID, limit: Self.visibleLimit)
    }

    /// Move apps that have just gone quiet into the linger list, and retire the
    /// ones whose window has run out.
    ///
    /// An app that comes back is forgotten from here immediately — live always
    /// wins, and a place cannot be both live and holding.
    private func rememberQuiet(previous: [AudibleApp], found: [AudibleApp], now: Date) {
        let live = Set(found.map(\.bundleID))
        for app in previous where !live.contains(app.bundleID) {
            // First time it went missing. A second poll while still missing must
            // not restamp it, or the window never closes.
            if quietSince[app.bundleID] == nil { quietSince[app.bundleID] = now }
        }
        for bundleID in quietSince.keys where live.contains(bundleID) {
            quietSince[bundleID] = nil
        }
        var kept: [AudibleApp] = []
        for app in recentlyQuiet + previous where !live.contains(app.bundleID) {
            guard let since = quietSince[app.bundleID],
                  now.timeIntervalSince(since) < Self.lingerWindow,
                  !kept.contains(where: { $0.bundleID == app.bundleID }) else { continue }
            kept.append(app)
        }
        recentlyQuiet = kept
        for bundleID in quietSince.keys
        where !kept.contains(where: { $0.bundleID == bundleID }) {
            quietSince[bundleID] = nil
        }
    }

    /// The card's places: live apps, plus recently-quiet ones in the exact
    /// places they held while playing.
    var slots: (shown: [AppMix.MixSlot], hidden: Int) {
        let (shown, _) = rows
        return AppMix.slots(live: shown, idle: recentlyQuiet,
                            playing: playingBundleID, limit: Self.visibleLimit)
    }

    /// Whether this app is making sound right now, as opposed to being pinned
    /// into the list because it is the now-playing one.
    func isAudible(_ bundleID: String) -> Bool {
        apps.contains { $0.bundleID == bundleID }
    }

    /// The app's own icon. Cached: `runningApplications(withBundleIdentifier:)`
    /// on every row on every redraw is a lot of work for a 16pt image.
    func icon(for bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.icon
        iconCache[bundleID] = icon
        return icon
    }

    @ObservationIgnored private var iconCache: [String: NSImage?] = [:]

    /// Set by the media model so the app you are already looking at pins to the
    /// top of the list instead of sorting alphabetically into the middle.
    ///
    /// Written from ONE place — `MediaWidgetModel.onNowPlayingChanged`, wired in
    /// `AppDelegate` — and named here because for months it was written from no
    /// place at all. Declared, read three times, assigned never: the pin below
    /// and the cap in `AppMix.rows` both looked implemented, both compiled, and
    /// neither ever ran with anything but nil.
    var playingBundleID: String?

    func start() {
        guard isEnabled else { return }
        refresh()
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isEnabled else { return }
                self.supervise()
                self.refresh()
            }
        }
        // Immediate, because two seconds of an app playing out of the device you
        // just switched AWAY from is two seconds too many — and it cannot be
        // heard anywhere else while it happens. The poll is the safety net; this
        // is the reflex. Same listener `AudioOutputModel` uses.
        knownOutputUID = AudioDevices.currentOutputUID()
        deviceListeners = AudioDevices.observeChanges { [weak self] in
            Task { @MainActor [weak self] in self?.outputDeviceChanged() }
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
        deviceListeners = []
        stopAll()
    }

    @ObservationIgnored private var deviceListeners: [AudioObjectPropertyListenerBlock] = []
    /// Last callback count seen per app, for spotting a tap that has stopped.
    @ObservationIgnored private var lastCallbacks: [String: UInt64] = [:]
    /// The default output we last reacted to. See `outputDeviceChanged`.
    @ObservationIgnored private var knownOutputUID: String?

    // MARK: - Keeping a running tap honest

    /// The default output moved. Any tap still pointing at the old device is
    /// rendering into somewhere nobody is listening.
    ///
    /// Deliberately does NOT check for stalls: this fires on every device
    /// appearing or disappearing, including the private aggregates we create
    /// ourselves, so it can arrive microseconds after a tap starts — long before
    /// its first buffer. Judging liveness here would tear down healthy taps.
    private func outputDeviceChanged() {
        guard isEnabled else { return }
        let current = AudioDevices.currentOutputUID()
        // **The listener fires on every device appearing or disappearing —
        // INCLUDING the private aggregates this class creates and destroys.**
        // Without this guard the first version built a hard loop: back out of a
        // bad tap → destroying its aggregate fires this → clear failures and
        // retry → creating an aggregate fires this → back out again. Twenty-six
        // taps in six seconds, measured, on somebody's live audio path.
        //
        // Comparing the default output against the last one we acted on makes
        // our own churn invisible here, because creating a private aggregate
        // does not change which device is default.
        guard current != knownOutputUID else { return }
        knownOutputUID = current

        // Cleared BEFORE anything is rebuilt, and the order is the whole point.
        // A failure recorded against the OLD device says nothing about this one
        // — the common shape is exactly an output we could not write to followed
        // by a switch to one we can — so it must not survive the change. Doing
        // it afterwards wiped the verdict the rebuild had just reached and ran
        // the whole attempt a second time: two taps per switch, both refused.
        failures.removeAll()

        for (bundleID, tap) in taps where tap.isRunning && tap.outputUID != current {
            AppVolumeDiagnostics.log(
                "\(bundleID): output moved \(tap.outputUID ?? "?") → \(current ?? "none"), rebuilding")
            rebuild(bundleID)
        }
        // Apps that had no tap at all get their one attempt on the new device.
        for app in apps where taps[app.bundleID] == nil { sync(app) }
    }

    /// The timed check. Only this one judges liveness, and only against a
    /// previous sample taken at least one interval ago.
    private func supervise() {
        let current = AudioDevices.currentOutputUID()
        for (bundleID, tap) in taps where tap.isRunning {
            let count = tap.callbackCount
            let previous = lastCallbacks[bundleID]
            lastCallbacks[bundleID] = count
            // No previous sample means this tap was born during the last
            // interval; it gets one free round rather than a verdict.
            let delivering = previous.map { count > $0 } ?? true
            let processes = apps.first { $0.bundleID == bundleID }?.pids

            switch AppMix.supervise(outputChanged: tap.outputUID != current,
                                    processesChanged: processes.map { $0 != tap.tappedPIDs } ?? false,
                                    callbacksAdvancing: delivering,
                                    hasSomewhereToWrite: tap.deliversOutput) {
            case .keep:
                continue
            case .rebuild:
                AppVolumeDiagnostics.log("\(bundleID): supervise → rebuild")
                rebuild(bundleID)
            case .abandon:
                // Stopped for a reason we cannot name, and the app is muted while
                // it does. Getting out of the path is the only safe move.
                AppVolumeDiagnostics.log(
                    "\(bundleID): supervise → abandon (calls=\(count) advancing=\(delivering) "
                    + "output=\(tap.deliversOutput))")
                taps.removeValue(forKey: bundleID)?.stop()
                lastCallbacks[bundleID] = nil
                failures[bundleID] = Self.levelNotApplied
            }
        }
    }

    private func rebuild(_ bundleID: String) {
        taps.removeValue(forKey: bundleID)?.stop()
        lastCallbacks[bundleID] = nil
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else { return }
        sync(app)
    }

    // MARK: - Levels

    func gain(for bundleID: String) -> Float {
        // A muted player is at zero; its bar shows the level it comes back to.
        if player(bundleID) != nil, muted.contains(bundleID), let back = levelBeforeMute[bundleID] { return back }
        if player(bundleID) != nil, let level = playerLevels[bundleID] { return level }
        return AppMix.clamp(gains[bundleID] ?? AppMix.unity)
    }

    func isMuted(_ bundleID: String) -> Bool { muted.contains(bundleID) }

    func setGain(_ value: Float, for app: AudibleApp) {
        if player(app.bundleID) != nil {
            // Muted, a press sets the level to come back to, as the mixer's
            // rows do; it used to unmute, so one stray click on a muted
            // Spotify started the music out loud.
            if muted.contains(app.bundleID) {
                levelBeforeMute[app.bundleID] = AppMix.clamp(value)
                persist()
                return
            }
            setPlayerLevel(AppMix.clamp(value), for: app.bundleID)
            return
        }
        gains[app.bundleID] = AppMix.clamp(value)
        // Dragging the slider is somebody asking for this app again, so it
        // clears a recorded failure and lets `sync` retry. Without that the row
        // would stay dead until the app was restarted.
        failures[app.bundleID] = nil
        persist()
        sync(app)
    }

    func toggleMute(_ app: AudibleApp) {
        if player(app.bundleID) != nil {
            togglePlayerMute(app.bundleID)
            return
        }
        if muted.contains(app.bundleID) { muted.remove(app.bundleID) } else { muted.insert(app.bundleID) }
        failures[app.bundleID] = nil
        persist()
        sync(app)
    }

    /// Back to unity and unmuted, which also tears the tap down — the only way
    /// to be certain we are out of somebody's audio path.
    func reset(_ app: AudibleApp) {
        if player(app.bundleID) != nil {
            if muted.contains(app.bundleID) { togglePlayerMute(app.bundleID) }
            return
        }
        gains[app.bundleID] = AppMix.unity
        muted.remove(app.bundleID)
        failures[app.bundleID] = nil
        persist()
        sync(app)
    }

    private func persist() {
        UserDefaults.standard.set(gains.mapValues { Double($0) }, forKey: Self.gainsKey)
        UserDefaults.standard.set(Array(muted), forKey: Self.mutedKey)
        UserDefaults.standard.set(levelBeforeMute.mapValues { Double($0) }, forKey: Self.beforeMuteKey)
        UserDefaults.standard.set(Array(seenPlayers), forKey: Self.carriedOverKey)
    }

    // MARK: - Taps

    /// Bring the audio path in line with the level. The rule for whether a tap
    /// should exist at all is `AppMix.needsTap`, deliberately not inlined here:
    /// "unity means do nothing" is the whole safety story and belongs somewhere
    /// tested.
    private func sync(_ app: AudibleApp) {
        // Spotify and Music turn themselves down; nothing of ours goes in
        // their audio path. See "Players with their own volume".
        if player(app.bundleID) != nil {
            taps.removeValue(forKey: app.bundleID)?.stop()
            failures[app.bundleID] = nil
            return
        }
        let wanted = AppMix.needsTap(gain: gain(for: app.bundleID),
                                     isMuted: isMuted(app.bundleID))
        let multiplier = AppMix.multiplier(gain: gain(for: app.bundleID),
                                           isMuted: isMuted(app.bundleID))

        guard wanted else {
            taps.removeValue(forKey: app.bundleID)?.stop()
            failures[app.bundleID] = nil
            return
        }

        // A pinned-but-silent app can be dragged — its level is remembered — but
        // it must not get a tap. There is nothing to carry, so the tap would
        // deliver no buffers, the watchdog would back it out 400ms later, and
        // the row would sprout a failure message for an app that is simply
        // paused. The tap arrives with the audio, from `refresh`.
        guard isAudible(app.bundleID) else {
            taps.removeValue(forKey: app.bundleID)?.stop()
            return
        }

        // A tap we already gave up on is not retried every two seconds. It was:
        // `failures` was written and then ignored, so a browser that refused
        // once got a fresh tap, a fresh watchdog and a fresh failure line
        // thirty times a minute. Retrying is now a deliberate act — dragging
        // the slider, or the app going quiet and starting again.
        guard failures[app.bundleID] == nil else { return }

        if let existing = taps[app.bundleID], existing.isRunning {
            // A level change is one relaxed store and no rebuild. A CHANGE OF
            // PROCESSES is a rebuild and has to be: the tap named its processes
            // when it was created, so a second tab that started playing since
            // then is not on it, and its audio would go out at full volume
            // beside the one being attenuated.
            if existing.tappedPIDs == app.pids {
                existing.setMultiplier(multiplier)
                return
            }
            AppVolumeDiagnostics.log(
                "\(app.bundleID): processes changed \(existing.tappedPIDs) → \(app.pids), rebuilding")
            taps.removeValue(forKey: app.bundleID)?.stop()
        }

        let tap = AppVolumeTap(bundleID: app.bundleID, multiplier: multiplier)
        guard tap.start(pids: app.pids) else {
            // The tap's own reason when it has one — it knows things the model
            // does not, like the output being a Multi-Output Device.
            failures[app.bundleID] = tap.failureReason ?? Self.levelNotApplied
            return
        }
        taps[app.bundleID] = tap
        failures[app.bundleID] = nil
        watchdog(for: app)
    }

    /// The measured failure this exists for: every creation call returns
    /// `noErr`, the tap reports a correct format, and then no buffer ever
    /// arrives — while the app is muted, because that is what `.mutedWhenTapped`
    /// did on the way in. Silence with no error anywhere is the worst outcome
    /// this feature can produce, so it is the one thing actively checked.
    ///
    /// 400ms: a working tap delivers roughly ninety buffers a second, so this is
    /// two orders of magnitude of slack, and short enough that a person dragging
    /// a slider reads the recovery as the slider not taking rather than as their
    /// music cutting out.
    private func watchdog(for app: AudibleApp) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, let tap = self.taps[app.bundleID] else { return }
            // Being called is not the same as having anywhere to write. A tap
            // with an empty output buffer list mutes the app and drops every
            // sample, and it does it while looking busy.
            guard tap.deliversOutput else {
                AppVolumeDiagnostics.log(
                    "\(app.bundleID): callbacks but NO output buffer — backing out \(tap.shape)")
                self.taps.removeValue(forKey: app.bundleID)?.stop()
                self.failures[app.bundleID] = Self.levelNotApplied
                return
            }
            guard !tap.hasFired else {
                // The positive case is worth a line too. "A tap exists" and "the
                // audio is coming back out" are different claims, and only the
                // second one means the person can still hear their music.
                AppVolumeDiagnostics.log("\(app.bundleID): delivering \(tap.shape)")
                // Sampled again a beat later: a track that has just resumed can
                // legitimately be silent for the first buffers, and reporting
                // that as "no audio" would be the same mistake `tapStatus` made.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let tap = self?.taps[app.bundleID] else { return }
                    AppVolumeDiagnostics.log("\(app.bundleID): +2s \(tap.shape)")
                }
                return
            }
            AppVolumeDiagnostics.log("\(app.bundleID): no buffers after 400ms — backing out")
            self.taps.removeValue(forKey: app.bundleID)?.stop()
            self.failures[app.bundleID] = Self.levelNotApplied
            // The level stays where they put it; only the tap goes. Resetting it
            // for them would erase what they asked for to hide our failure.
        }
    }

    private func stopAll() {
        for tap in taps.values { tap.stop() }
        taps.removeAll()
        failures.removeAll()
    }

    // MARK: - Who is making noise

    func refresh() {
        guard isEnabled else { return }
        let found = Self.audibleApps()
        if found != apps {
            // What the mixer can SEE, logged whenever it changes.
            //
            // "It is playing but there is no row" has three completely separate
            // causes — Core Audio never reported the process, we reported it and
            // filtered it, or the row is there and the card around it is not —
            // and without this line all three look identical from outside. It
            // costs one write per change, and the set changes when playback
            // starts or stops, not continuously.
            AppVolumeDiagnostics.log("audible: "
                + (found.isEmpty ? "(nothing)"
                   : found.map { "\($0.name)[\($0.bundleID)] pids=\($0.pids)" }
                       .sorted().joined(separator: ", ")))
            rememberQuiet(previous: apps, found: found, now: Date())
            apps = found
        }

        // An app that stopped playing keeps its level but loses its tap: holding
        // an aggregate device open for something that is not making sound is the
        // cost `AppMix.needsTap` exists to avoid.
        let live = Set(found.map(\.bundleID))
        for (bundleID, tap) in taps where !live.contains(bundleID) {
            tap.stop()
            taps.removeValue(forKey: bundleID)
        }
        // Going quiet clears the slate: whatever went wrong last time was about
        // a stream that no longer exists, and holding the verdict against the
        // app forever would mean one bad moment disabled its row for good.
        for bundleID in failures.keys where !live.contains(bundleID) {
            failures[bundleID] = nil
            lastCallbacks[bundleID] = nil
        }
        // And one that started playing while muted needs its tap back.
        for app in found { sync(app) }
        readPlayerLevels()
    }

    // MARK: - Players with their own volume

    /// **Spotify and Music move their OWN slider** (owner, 2026-10-01: "it's not
    /// changing the volume I can see in Spotify itself"). For them the row sets
    /// the player's `sound volume` over AppleScript — the same channel the media
    /// card already uses for play and pause, so the same Automation grant —
    /// instead of putting a tap in their audio path. The two sliders then agree,
    /// and a change made inside Spotify shows up here on the next poll.
    ///
    /// Everything else keeps the mixer: browsers, calls and games have no
    /// volume a script can reach. A player whose Automation is refused falls
    /// back to the mixer too (`refusedPlayers`), so the row never goes dead.
    ///
    /// Mute is the player's volume at zero, with the level it had kept here to
    /// come back to. Neither player has a mute both share.
    private(set) var playerLevels: [String: Float] = [:]
    @ObservationIgnored private var refusedPlayers: Set<String> = []
    @ObservationIgnored private var levelBeforeMute: [String: Float] = [:]
    @ObservationIgnored private var playerWriters: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingPlayerLevels: [String: Float] = [:]
    @ObservationIgnored private var lastPlayerWrite: [String: Date] = [:]
    @ObservationIgnored private var readingPlayers: Set<String> = []
    @ObservationIgnored private var seenPlayers: Set<String> = []

    /// A read this soon after a write can return the level from before it and
    /// throw the slider back under the finger.
    private static let readQuietAfterWrite: TimeInterval = 1.5

    private func player(_ bundleID: String) -> MediaPlayerKind? {
        guard !refusedPlayers.contains(bundleID) else { return nil }
        return MediaPlayerKind.allCases.first { $0.bundleID == bundleID }
    }

    /// Coalesced: a drag sends dozens of values, and only the newest matters.
    /// One script in flight per player; whatever arrived meanwhile goes next.
    private func setPlayerLevel(_ level: Float, for bundleID: String) {
        guard let kind = player(bundleID) else { return }
        playerLevels[bundleID] = level
        pendingPlayerLevels[bundleID] = level
        lastPlayerWrite[bundleID] = Date()
        guard playerWriters[bundleID] == nil else { return }
        playerWriters[bundleID] = Task { [weak self] in
            while let self, let next = self.pendingPlayerLevels.removeValue(forKey: bundleID) {
                // Never script a player that is not running: AppleScript
                // would launch it.
                guard MediaPlayerController(kind: kind).isRunning else { break }
                let outcome = await AppleScriptClient.perform(
                    MediaPlayerController.setVolumeScript(next, for: kind))
                self.lastPlayerWrite[bundleID] = Date()
                if outcome.isNotPermitted {
                    self.refusePlayer(bundleID)
                    break
                }
            }
            self?.playerWriters[bundleID] = nil
        }
    }

    private func togglePlayerMute(_ bundleID: String) {
        if muted.contains(bundleID) {
            muted.remove(bundleID)
            let back = levelBeforeMute.removeValue(forKey: bundleID) ?? 0.5
            setPlayerLevel(back > 0.01 ? back : 0.5, for: bundleID)
        } else {
            levelBeforeMute[bundleID] = gain(for: bundleID)
            muted.insert(bundleID)
            setPlayerLevel(0, for: bundleID)
        }
        failures[bundleID] = nil
        persist()
    }

    /// Picks up a change made inside the player, on the mixer's own poll.
    private func readPlayerLevels() {
        for app in rows.shown {
            let bundleID = app.bundleID
            guard let kind = player(bundleID),
                  MediaPlayerController(kind: kind).isRunning,
                  playerWriters[bundleID] == nil,
                  !readingPlayers.contains(bundleID),
                  Date().timeIntervalSince(lastPlayerWrite[bundleID] ?? .distantPast)
                      > Self.readQuietAfterWrite
            else { continue }
            readingPlayers.insert(bundleID)
            Task { [weak self] in
                let outcome = await AppleScriptClient.perform(MediaPlayerController.volumeScript(for: kind))
                guard let self else { return }
                self.readingPlayers.remove(bundleID)
                switch outcome {
                case .ok(let raw):
                    guard let level = MediaPlayerController.parseVolume(raw),
                          self.playerWriters[bundleID] == nil else { return }
                    self.playerRead(level, for: bundleID)
                case .failed:
                    if outcome.isNotPermitted { self.refusePlayer(bundleID) }
                }
            }
        }
    }

    private func playerRead(_ level: Float, for bundleID: String) {
        if seenPlayers.insert(bundleID).inserted {
            // Carried over from the mixer, once: a level set while this player
            // went through a tap becomes the same loudness on its own slider,
            // rather than the music jumping back to full the day this shipped.
            let stored = gains.removeValue(forKey: bundleID)
            persist()
            if muted.contains(bundleID), level > 0 {
                levelBeforeMute[bundleID] = level * (stored ?? 1)
                setPlayerLevel(0, for: bundleID)
                return
            }
            if let stored, stored < AppMix.unity - 0.001 {
                setPlayerLevel(level * stored, for: bundleID)
                return
            }
        }
        // Turned up inside the player while muted here: it is not muted any more.
        if muted.contains(bundleID), level > 0.01 {
            muted.remove(bundleID)
            levelBeforeMute[bundleID] = nil
            persist()
        }
        playerLevels[bundleID] = level
    }

    /// Automation refused: this player goes back to the mixer, at whatever
    /// level its slider showed.
    private func refusePlayer(_ bundleID: String) {
        guard refusedPlayers.insert(bundleID).inserted else { return }
        AppVolumeDiagnostics.log("\(bundleID): not allowed to script its volume, using the mixer")
        if let level = playerLevels.removeValue(forKey: bundleID) { gains[bundleID] = level }
        pendingPlayerLevels[bundleID] = nil
        persist()
        if let app = apps.first(where: { $0.bundleID == bundleID }) { sync(app) }
    }

    private static func audibleApps() -> [AudibleApp] {
        let objects = AudioProcesses.objects()
        guard !objects.isEmpty else { return [] }

        let running = NSWorkspace.shared.runningApplications
        let bundleIDs = running.compactMap(\.bundleIdentifier)

        // Grouped, because one app can be several sound-making processes: a
        // browser with two tabs playing is two helpers and must still be one
        // row with one slider.
        var grouped: [String: (name: String, pids: [pid_t])] = [:]
        for object in objects {
            guard AudioProcesses.bool(object, kAudioProcessPropertyIsRunningOutput) else { continue }
            guard let pid = AudioProcesses.pid(object) else { continue }
            guard let app = AudioProcesses.owner(of: pid,
                                                 bundleID: AudioProcesses.string(object, kAudioProcessPropertyBundleID),
                                                 running: running,
                                                 bundleIDs: bundleIDs),
                  // A real, user-facing application, which is the better filter.
                  // `isSystemProcess` then catches the daemons that still get
                  // through — a menu-bar-only app is `.accessory` and has no
                  // window to have turned the sound on from.
                  app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  !AppMix.isSystemProcess(bundleID: bundleID) else { continue }
            grouped[bundleID, default: (app.localizedName ?? bundleID, [])].pids.append(pid)
        }
        return grouped.map { AudibleApp(bundleID: $0.key, pids: $0.value.pids, name: $0.value.name) }
    }
}
