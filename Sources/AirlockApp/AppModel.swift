import AppKit
import Observation
import AirlockCore

/// Central app state. Deliberately lean — it holds the reducer state and the
/// bridge lifecycle, and forwards user actions. It is NOT the reference's
/// 1,800-line god object: derivation lives in `SessionState`, transport in
/// `BridgeServer`, rendering in the views.
@MainActor
@Observable
final class AppModel {
    private(set) var state = SessionState()

    /// UI hook: fired on the main actor after every state mutation, so the
    /// notch controller can re-derive its presentation. Kept as a closure —
    /// AppModel stays presentation-agnostic.
    @ObservationIgnored var onStateChange: (() -> Void)?

    /// Fired when an action sends the user to ANOTHER app. The island collapses
    /// on navigation (you're leaving) but never on in-place interaction
    /// (approving, answering, skipping a track).
    @ObservationIgnored var onNavigateAway: (() -> Void)?

    @ObservationIgnored let bridge: BridgeServer

    init(bridge: BridgeServer = BridgeServer()) {
        self.bridge = bridge
    }

    func start() {
        let debug = ProcessInfo.processInfo.environment["AIRLOCK_DEBUG"] != nil

        gateLog = gateLogStore.load()

        // Restore before any live events, so the bridge lands on top.
        if let cached = sessionRegistry.load() {
            state = cached.preparedForRestore(now: Date())
            // `.debug` rather than a `debug` flag around a write: the unified
            // log has its own level filter, so this is off by default and
            // readable with `log stream --level debug` — no relaunch, and no
            // stderr that the packaged app throws away.
            let restored = state.sessions.count
            Log.session.debug("restored \(restored, privacy: .public) session(s) from cache")
        }

        // ONE task, in order, where there used to be three unordered ones.
        //
        // The handler was installed by a separate Task from the one that called
        // `start()`, and Tasks have no ordering between them — so a gate the
        // policy settled in the gap got no gate-log row. The window is small and
        // it is exactly app launch, which is when every already-running agent's
        // next hook fires. Two sequential `await`s cost nothing and remove it.
        bridgeTask = Task { [weak self] in
            guard let self else { return }
            await bridge.setAutoDecisionHandler { [weak self] gate in
                Task { @MainActor in self?.record(gate) }
            }
            do {
                try await bridge.start()
            } catch {
                // Was `NSLog("… \(error)")` — an INTERPOLATED string passed as
                // a printf format. Every other site here passes %@ for exactly
                // that reason: an error whose description contains a % makes
                // NSLog read arguments that were never pushed.
                Log.bridge.error("bridge failed to start — \(error.localizedDescription, privacy: .public)")
                return
            }
            for await event in bridge.events {
                // Private: an event kind carries the permission request, and
                // that carries the command.
                Log.bridge.debug("event ← \(event.sessionID, privacy: .private): \(String(describing: event.kind), privacy: .private)")
                // A session superseded by a sibling in the same terminal loses
                // its card and its queue here, and its hooks are still held on
                // the other side. Nothing else can answer them now, so they go
                // back to the agent — see `BridgeServer.releaseSession`.
                for superseded in self.state.apply(event) {
                    await bridge.releaseSession(superseded)
                }
                self.stateDidMutate()
            }
        }

        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.livenessInterval * 1_000_000_000))
                guard let self else { return }
                await self.reconcileLiveness()
            }
        }
    }

    /// Stop everything `start()` began.
    ///
    /// The payoff is TESTABILITY, not teardown — there is no quit bug to fix.
    /// Nothing called `BridgeServer.stop()` before, and the outcome was already
    /// correct: the process exits, the kernel closes the sockets, and a blocked
    /// hook sees EOF and fails open, which is what `deferToAgent` would have
    /// told it anyway. What was missing is that `start()` could not be undone,
    /// so no test could call it — `AppModel.start()` has no coverage at all,
    /// while `BridgeServer.start()` has four tests, purely because one of them
    /// can be stopped.
    ///
    /// Order matters. Liveness goes first: it mutates state, and a late
    /// `stateDidMutate()` would schedule a 1s debounce that never fires and
    /// loses the mutation it was scheduling for. The final save is immediate,
    /// not debounced, for the same reason.
    func stop() async {
        livenessTask?.cancel()
        livenessTask = nil
        await bridge.stop()          // finishes `events`, so the loop below ends
        bridgeTask?.cancel()
        bridgeTask = nil
        saveTask?.cancel()
        saveTask = nil
        gateSaveTask?.cancel()
        gateSaveTask = nil
        demoGateExpiry?.cancel()
        demoGateExpiry = nil
        persistNow()
    }

    // MARK: - Persistence

    @ObservationIgnored private let sessionRegistry = SessionRegistry()
    @ObservationIgnored private var demoIDs: Set<String> = []
    /// Cancelled when the gate is answered or the sessions are cleared, so a
    /// stale timer cannot resolve a later gate that reused the same slot.
    @ObservationIgnored private var demoGateExpiry: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Stored so `stop()` can end them. The liveness loop's
    /// `while !Task.isCancelled` was previously unreachable-by-design: nothing
    /// held the handle, so the condition could never become false and the code
    /// read as though teardown existed.
    @ObservationIgnored private var bridgeTask: Task<Void, Never>?
    @ObservationIgnored private var livenessTask: Task<Void, Never>?

    private func stateDidMutate() {
        scheduleSave()
        onStateChange?()
    }

    /// Trailing-debounced save: bursts of events cost one write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    /// Immediate save — called on quit and by the debounce.
    func persistNow() {
        saveTask?.cancel()
        do {
            try sessionRegistry.save(state, excluding: demoIDs)
        } catch {
            Log.session.error("session save failed — \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Liveness

    private static let livenessInterval: TimeInterval = 5
    /// Ended sessions stay visible this long, then vanish. Short on purpose:
    /// the compact ✓ pulse is the completion acknowledgment; a closed terminal
    /// should not leave a corpse in the panel (user expectation, found live).
    private static let doneRetention: TimeInterval = 30
    /// Inactivity TTL for sessions without an individually-checkable PID.
    private static let pidlessTTL: TimeInterval = 15 * 60
    /// A silent "running" session is an ended turn (desktop hosts never
    /// fire Stop). Long tool calls chatter via Pre/PostToolUse, so 10min of
    /// true silence is decisive.
    private static let idleAfter: TimeInterval = 10 * 60

    @ObservationIgnored private var liveness = LivenessTracker()
    @ObservationIgnored private let registry = AgentRegistry.shared

    /// Snapshot `ps` off the main actor, then end sessions whose agent process
    /// is gone (same PID must still look like the same agent — PID-reuse guard)
    /// and prune long-done rows. A failed snapshot is "no information": skip.
    private func reconcileLiveness() async {
        var changed = false
        let tracked = state.sessions.values.compactMap { session in
            session.jumpTarget?.agentPID.map { (session.id, session.agent, $0) }
        }

        if !tracked.isEmpty,
           let snapshot = await BlockingWork.run({ ProcessSnapshot.capture() }) {
            var observations: [String: Bool] = [:]
            for (sessionID, agentKind, pid) in tracked {
                guard state.sessions[sessionID]?.status != .done else { continue }
                let entry = snapshot.entry(pid)
                let alive = entry.map { entry in
                    registry.integration(kind: agentKind)?.matchesProcess(command: entry.command) ?? false
                } ?? false
                observations[sessionID] = alive
                let command = entry?.command ?? "-"
                Log.session.debug("liveness: \(sessionID, privacy: .private) pid=\(pid, privacy: .public) alive=\(alive, privacy: .public) cmd=\(command, privacy: .private)")
            }

            for sessionID in liveness.update(observations: observations) {
                guard let session = state.sessions[sessionID] else { continue }
                Log.session.info("liveness declared session \(sessionID, privacy: .private) dead (agent process gone)")
                state.apply(AgentEvent(
                    sessionID: sessionID,
                    agent: session.agent,
                    sequence: UInt64(Date().timeIntervalSince1970 * 1000),
                    timestamp: Date(),
                    kind: .sessionEnded
                ))
                changed = true
            }
        }

        // Silent "running" sessions ended their turn without a Stop hook.
        for session in state.idleDemotionCandidates(now: Date(), olderThan: Self.idleAfter) {
            state.apply(AgentEvent(
                sessionID: session.id,
                agent: session.agent,
                sequence: UInt64(Date().timeIntervalSince1970 * 1000),
                timestamp: session.lastActivity, // idle since then — don't fake freshness
                kind: .statusChanged(.idle)
            ))
            changed = true
        }

        // Sessions PID-liveness can't vouch for individually (no PID, or a
        // PID shared across sessions) retire after quiet inactivity instead
        // of living forever.
        for session in state.ttlEvictionCandidates(now: Date(), olderThan: Self.pidlessTTL) {
            Log.session.info("retiring quiet session \(session.id, privacy: .private) (no individual liveness signal)")
            state.apply(AgentEvent(
                sessionID: session.id,
                agent: session.agent,
                sequence: UInt64(Date().timeIntervalSince1970 * 1000),
                timestamp: Date(),
                kind: .sessionEnded
            ))
            changed = true
        }

        if state.prune(now: Date(), olderThan: Self.doneRetention) > 0 { changed = true }
        if changed { stateDidMutate() }
        refreshUsage()
        // A new limit notice brings the island up, the way a state change does.
        if usageAlerts.check(usage, agentsOn: agentsOn()) { onStateChange?() }
        resolveTitles()
    }

    // MARK: - Conversation titles

    @ObservationIgnored private var lastTranscriptScan: [String: Date] = [:]

    /// Upgrade first-prompt guess titles to real conversation names:
    /// 1. session_name from the status-line channel (authoritative — /rename
    ///    or the AI title), 2. summary lines scanned from the transcript.
    private func resolveTitles() {
        let names = SessionNameCache.load()
        let now = Date()
        for session in state.sessions.values {
            if let entry = names.names[session.id], entry.name != session.title {
                applyTitle(entry.name, to: session)
                continue
            }
            guard session.titleExplicit != true,
                  let path = session.transcriptPath,
                  now.timeIntervalSince(lastTranscriptScan[session.id] ?? .distantPast) > 30
            else { continue }
            lastTranscriptScan[session.id] = now
            Task { [weak self] in
                // The file walk blocks; the hop back does not. Only the first
                // half belongs off the pool.
                let summary = await BlockingWork.run { TranscriptTitles.latestSummary(atPath: path) }
                guard let summary else { return }
                await self?.applyTitleOnMain(summary, sessionID: session.id)
            }
        }
    }

    private func applyTitleOnMain(_ title: String, sessionID: String) {
        guard let session = state.sessions[sessionID] else { return }
        applyTitle(title, to: session)
    }

    private func applyTitle(_ title: String, to session: AgentSession) {
        guard title != session.title else { return }
        // Local: stamped with the clock, it dropped any hook event made a
        // moment before but delivered a moment after. See `SessionState.retitle`.
        state.retitle(sessionID: session.id, to: title, at: Date())
        stateDidMutate()
    }

    var sessions: [AgentSession] { state.ordered }
    var attentionCount: Int { state.attentionCount }
    /// The one card the keyboard answers — see `SessionState.focusedGate`.
    var focusedGate: SessionState.FocusedGate? { state.focusedGate }
    /// What each session is showing, for telling a promotion from a redraw.
    var shownCards: [String: String] { state.shownCards }
    func promotedGate(since previous: [String: String]) -> SessionState.FocusedGate? {
        state.promotedGate(since: previous)
    }

    /// Everything the compact island's two slots resolve against, gathered once
    /// so the halves cannot disagree about the same state — which is how the
    /// trailing slot ended up with a comment claiming music always won while the
    /// branch above it returned an attention dot first.
    ///
    /// **Switched-off widgets contribute nothing, and the folding happens here**
    /// so Core never sees a toggle. Media, calendar and battery need no gate —
    /// each nils its own state when it is switched off, which is the same fact
    /// said once instead of twice. Sound does need one: `AudioOutputModel` goes
    /// on tracking the default device whatever the card's switch says, because
    /// the switch is about the panel, not about CoreAudio. The shelf needs none
    /// either — `TrayWidget.isToggleable` is false.
    ///
    /// **Keep-awake is the one exception: switched off, it still contributes.**
    /// What reaches Core is `SystemControlsModel.isAwake`, the assertion being
    /// held, and nothing about the rail's switches is folded into it. Hiding
    /// the rail's `.awake` button, or switching the whole rail off, releases
    /// nothing — the Mac goes on being held awake — so a gate here would do
    /// the opposite of every other gate: instead of a switched-off widget
    /// going quiet, a still-running effect would lose the only sign of it left
    /// on screen.
    ///
    /// Only the agents switch has a derived default (`AgentsPresence`), and
    /// `CompactIslandInput.showsAgents` already handles it along with the rule
    /// that a gate overrides it; nothing else here is a tri-state, and making
    /// one would be cargo-culting.
    func compactIslandInput(media: MediaWidgetModel,
                            calendar: CalendarWidgetModel,
                            agents: AgentsWidgetModel,
                            battery: BatteryWidgetModel,
                            tray: TrayModel,
                            output: AudioOutputModel,
                            sound: SoundWidgetModel,
                            controls: SystemControlsModel,
                            ui: NotchUIState) -> CompactIslandInput {
        CompactIslandInput(
            agentsEnabled: agents.isEnabled,
            attentionCount: attentionCount,
            sessionCount: state.sessions.count,
            anyRunning: state.sessions.values.contains { $0.status == .running },
            completionTick: ui.completionTick,
            hasMedia: media.state != nil,
            mediaPlaying: media.islandPlaying,
            meetingSoon: calendar.glanceEvent != nil,
            // The island's clock, advanced by `NotchController.apply()`. Core
            // owns none, so this is the one it is handed.
            now: ui.islandNow,
            outputChangedAt: sound.isEnabled ? output.routeChangedAt : nil,
            // Level and mute are read LIVE rather than captured with the stamp,
            // so an acknowledgement follows the volume if it moves during its
            // own two seconds.
            outputLevel: output.volume,
            outputMuted: output.isMuted,
            outputDeviceName: output.currentDeviceName,
            // The glyph's half of the same device. Read from the transport
            // CoreAudio reports, never inferred from the name above.
            outputTransport: output.currentTransport,
            mediaPausedAt: media.islandPausedAt,
            batteryCritical: battery.state?.isCritical == true,
            batteryMinutesRemaining: battery.state?.minutesRemaining,
            // `items`, never `ingesting`: a tile still landing is not yet a file.
            shelfCount: tray.items.count,
            // Ungated — see the exception above.
            // Either hold: the switch's, or the one an agent at work asked for.
            keepingAwake: controls.isAwake || controls.isHeldForAgents,
            keepAwakeStoppedAt: controls.stoppedByCutoffAt,
            keepAwakeCutoff: controls.stoppedCutoff,
            // An agents feature, so it goes with the agents switch.
            usageNotice: agents.isEnabled ? usageAlerts.notice : nil,
            usageNoticeAt: agents.isEnabled ? usageAlerts.noticeAt : nil,
            guide: ui.guideCompact,
            call: calls.call)
    }

    /// Account-wide Claude rate-limit windows, fed by the status-line bridge.
    private(set) var usage: UsageSnapshot?

    /// The heads-up near the limit (card Agents 1), checked on every refresh.
    let usageAlerts = UsageAlertModel()

    /// Whether the user is on a call, for the island's call pill. Started by
    /// `NotchController`, so a model built for a test or a preview never polls.
    let calls = CallMonitor()
    /// Whether agents are switched on, set by the notch controller: the
    /// heads-up is part of them and stays quiet while they are off.
    @ObservationIgnored var agentsOn: () -> Bool = { false }

    private func refreshUsage() {
        let latest = UsageSnapshot.load()
        if latest != usage { usage = latest }
    }

    private let jumpService = TerminalJumpService()

    /// Why the last trip to a terminal did not happen, or nil. Drawn on the
    /// Agents tab and under the quick prompt (`TerminalTroubleCard`); cleared
    /// by the next attempt or by putting it away. Settable for the state
    /// gallery, which draws it on a model of its own.
    var terminalTrouble: TerminalTrouble?

    func dismissTerminalTrouble() { terminalTrouble = nil }

    /// Go to a terminal, and step out of the way only once that worked.
    ///
    /// The panel used to close the moment the button was pressed, so a refusal
    /// looked exactly like a jump: the panel went, and nothing came forward.
    /// Now a failure keeps it open with the reason on it. Returns whether it
    /// got there.
    @discardableResult
    private func goToTerminal(_ attempt: @escaping @MainActor () async -> TerminalTrouble?) async -> Bool {
        terminalTrouble = nil
        if let trouble = await attempt() {
            terminalTrouble = trouble
            return false
        }
        onNavigateAway?()
        return true
    }

    /// Restore focus to the terminal a session lives in.
    func jump(to session: AgentSession) {
        let service = jumpService
        Task { await goToTerminal { await service.jump(to: session) } }
    }

    /// One-click usage seeding: new terminal window, `claude` typed in.
    func openTerminalForClaudeLogin() {
        startClaudeSession()
    }

    /// Answer an agent's question from the notch.
    func answer(_ session: AgentSession, choice: String) {
        // Below the guard, not above it: the bridge call needs the request id
        // to address the gate the user actually answered, and it was already
        // one line away. Firing first also sent an answer when there was no
        // pending question at all.
        guard let (live, request) = liveGate(clickedIn: session) else { return }
        let isDemo = demoIDs.contains(live.id)
        // Counted once it has been delivered — see `resolve`.
        Task { [weak self, bridge] in
            let delivered = await bridge.answer(sessionID: live.id, requestID: request.id, choice: choice)
            if delivered || isDemo { self?.tally?.recordAnswer() }
        }
        state.resolveGate(sessionID: live.id, requestID: request.id, decision: .allowOnce, at: Date())
        stateDidMutate()
    }

    /// The card a click was aimed at, if it is still the one waiting — with the
    /// session as it is NOW.
    ///
    /// A view hands in the session it last drew. When a newer request in the
    /// same session took the card between that draw and the click, the click
    /// still carried the old request: it logged a decision that was never
    /// delivered (the bridge had already handed that gate back), and resolving
    /// it took the session out of "Needs you" with the new card waiting.
    private func liveGate(clickedIn session: AgentSession) -> (AgentSession, PermissionRequest)? {
        guard let clicked = session.pendingPermission,
              let live = state.sessions[session.id],
              let request = live.pendingPermission,
              request.id == clicked.id else { return nil }
        return (live, request)
    }

    /// Clear the record of a question that can no longer be answered.
    ///
    /// A local change, so it spends no sequence number — see
    /// `SessionState.dismissReceipt`.
    func dismissReceipt(_ session: AgentSession) {
        guard session.questionReceipt != nil else { return }
        state.dismissReceipt(sessionID: session.id, at: Date())
        stateDidMutate()
    }

    /// Hand a shell command to a new terminal window the user can see.
    ///
    /// Hands a command to a visible terminal. Deliberately not `Process()`: an app
    /// that installs software invisibly is one you cannot audit while it does
    /// it, and the command is the user's to run.
    func runInTerminal(_ command: String) {
        let service = jumpService
        Task {
            terminalTrouble = nil
            terminalTrouble = await service.openTerminal(running: command)
        }
    }

    /// AI-first quick prompt: fire a task at a fresh Claude Code session in a
    /// new terminal, straight from the notch.
    ///
    /// Returns whether the terminal opened, so the bar keeps the words when it
    /// did not — they were cleared before anything had been sent.
    @discardableResult
    func submitQuickPrompt(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let service = jumpService
        return await goToTerminal { await service.openTerminalRunningClaude(prompt: trimmed) }
    }

    /// A fresh `claude` in a new terminal, with no prompt.
    ///
    /// Separate from `submitQuickPrompt`, which ignores an empty prompt — the
    /// "Open a new one" button under a closed terminal called that with "" and
    /// did nothing at all.
    func startClaudeSession() {
        let service = jumpService
        Task { await goToTerminal { await service.openTerminalRunningClaude() } }
    }

    /// Lifetime counts for the trial's last-day card. Optional because the
    /// model is built before it in `AppDelegate` and because tests do not need
    /// one — a missing tally counts nothing rather than crashing.
    @ObservationIgnored var tally: UsageTallyStore?
    @ObservationIgnored private let policyStore = PolicyStore()
    @ObservationIgnored private let gateLogStore = GateLogStore()
    /// Every gate outcome, human or automatic. Read by Settings to suggest
    /// rules from what you actually answered, instead of asking you to author
    /// policy in the abstract.
    @ObservationIgnored private(set) var gateLog = GateLog()

    /// Rule ids the user has said "not this" to.
    ///
    /// **A declined suggestion must not come back on the next gate.** The
    /// evidence for a suggestion is the gate log, and the log keeps growing —
    /// so without a memory, saying no once means being asked again the third
    /// time, the fourth, and every time after. Persisted because the annoyance
    /// it prevents outlives a launch.
    @ObservationIgnored private var declinedSuggestions: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.declinedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.declinedKey) }
    }

    private static let declinedKey = "policy.declinedSuggestions"

    /// The one rule worth offering right now, or nil.
    ///
    /// One at a time and only the strongest: a stack of policy offers on the
    /// agents tab is a settings pane that followed you, and this is meant to be
    /// noticed rather than administered.
    var ruleSuggestion: PolicySuggestion? {
        let policy = policyStore.load(projectRoot: nil).policy
        let declined = declinedSuggestions
        return PolicySuggestions.from(gateLog, policy: policy)
            .filter { !declined.contains($0.id) }
            .max { $0.count < $1.count }
    }

    /// Write the rule the card is offering.
    func acceptSuggestion(_ suggestion: PolicySuggestion, candidate: RuleCandidate,
                          projectOnly: Bool) {
        // The project is the one the decisions behind the suggestion were made
        // in — never whichever session happens to be listed first, which with
        // two projects open wrote an allow rule into the one nobody chose. No
        // single project means nothing to scope to, and falling back to global
        // would be the opposite of what the button says.
        let root = projectOnly ? suggestion.projectRoot : nil
        if projectOnly, root == nil { return }
        try? policyStore.add(candidate.text, kind: suggestion.kind, projectRoot: root)
        declineSuggestion(suggestion)
    }

    /// Stop offering this one. Not the same as writing a rule, and not the same
    /// as forgetting the gates behind it — the decisions stay in the log where
    /// the settings pane can still act on them.
    func declineSuggestion(_ suggestion: PolicySuggestion) {
        declinedSuggestions.insert(suggestion.id)
    }
    @ObservationIgnored private var gateSaveTask: Task<Void, Never>?

    /// Resolve a pending permission. Routes the decision to the waiting hook and
    /// optimistically updates local state so the card dismisses immediately.
    /// "Always" also persists an exact allow rule — project policy when the
    /// session has a cwd, global otherwise — so the policy engine handles the
    /// next occurrence without asking.
    ///
    /// `atQuestion` is the step the card was showing, for an ask with several
    /// questions: dismissing on question three used to leave an account of
    /// question one. Only the card knows it — see `AgentEvent.questionStep`.
    func resolve(_ session: AgentSession, _ decision: PermissionDecision, atQuestion step: Int? = nil) {
        // Below the guard — see `answer`. The id that addresses the gate was
        // being fetched on the very next line and thrown away. The demo's
        // expiry is below it too: a click on a replaced card must not cancel
        // the timer of the card that replaced it.
        guard let (session, request) = liveGate(clickedIn: session) else { return }
        let isDemo = demoIDs.contains(session.id)
        if isDemo { demoGateExpiry?.cancel() }
        switch decision {
        case .allowOnce, .alwaysAllow: Moments.shared.announce(.approved, "\(decision)")
        case .deny: Moments.shared.announce(.denied)
        case .deferred: break
        }

        if decision == .alwaysAllow {
            // The generalisation, not the literal command. Writing the exact
            // text produced rules that could never match again — one Always
            // click, one permanently dead rule. The card shows which rule this
            // is before you press it, so nothing widens behind your back.
            //
            // Written BEFORE the bridge hears of the click: an Always makes it
            // re-check the other gates waiting in this session against the
            // policy files, and it has to find this rule there. The write is
            // synchronous and the bridge call below is created after it.
            //
            // So this one does NOT wait to hear that the decision landed, the
            // way the log below does. A rule is an instruction about what comes
            // next — "allow this kind of thing from now on" — and it stands
            // even if this particular gate had already ended; waiting would
            // mean the queue this Always was meant to settle never sees it.
            let rule = RuleGeneralizer.recommended(for: request).text
            do {
                try policyStore.appendAllowRule(rule, projectRoot: session.cwd)
            } catch {
                // The rule text is a command pattern off this machine.
                Log.policy.error("failed to persist policy rule '\(rule, privacy: .private)' — \(error.localizedDescription, privacy: .private)")
            }
        }
        // The log and the tally are records of something that HAPPENED, so
        // they wait to hear that it did. The card can be answered a moment
        // after its gate ended some other way — its `ask_timeout`, its hook
        // going away, a rule settling it — and the bridge then delivers
        // nothing, while the log said the agent had been told and the trial
        // card counted it as work done for you.
        //
        // The demo gate has no bridge and never had one; it is the one case
        // where nothing to deliver to is not a failure.
        Task { [weak self, bridge] in
            let delivered = await bridge.resolve(sessionID: session.id, requestID: request.id,
                                                 decision: decision)
            guard let self, delivered || isDemo else { return }
            // Approvals only. A deny is work YOU did, and the trial card's
            // argument is about work done for you — see `UsageTally`.
            if decision == .allowOnce || decision == .alwaysAllow { self.tally?.recordApproval() }
            self.record(GateRecord(request: request, outcome: GateOutcome(decision),
                                   agent: session.agent.rawValue, projectRoot: session.cwd,
                                   decidedAt: Date()))
        }
        state.resolveGate(sessionID: session.id, requestID: request.id, decision: decision,
                          at: Date(), questionStep: step)
        stateDidMutate()
    }

    // MARK: - Gate log

    /// Trailing-debounced, matching the session and clipboard caches.
    ///
    /// It used to write the whole log synchronously on every gate. Most gates
    /// are auto-decisions, which fire once per tool call — so an agent working
    /// through fifty calls meant fifty full JSON encodes and atomic writes on
    /// the main actor, in a burst, while the UI was trying to animate. The data
    /// is a history, and a history can afford to be a second behind.
    func record(_ gate: GateRecord) {
        gateLog.append(gate)
        scheduleGateSave()
    }

    private func scheduleGateSave() {
        gateSaveTask?.cancel()
        gateSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistGateLogNow()
        }
    }

    /// Immediate — called on quit, so a burst inside the debounce window is not
    /// lost to it.
    func persistGateLogNow() {
        gateSaveTask?.cancel()
        do {
            try gateLogStore.save(gateLog)
        } catch {
            Log.policy.error("could not save the gate log — \(error.localizedDescription, privacy: .private)")
        }
    }

    func clearGateLog() {
        gateSaveTask?.cancel()
        gateLog.clear()
        gateLogStore.delete()
    }

    /// Drop every session (island clutter escape hatch). Live agents
    /// re-register on their next hook event.
    ///
    /// The gates go back to their agents rather than waiting out a timeout
    /// nobody can see: clearing the list takes away the only surface that could
    /// have answered them, and with `ask_timeout: 0` — "never — it waits" —
    /// that wait is a day. See `BridgeServer.releaseSession`.
    func clearAllSessions() {
        demoGateExpiry?.cancel()
        let waiting = state.sessions.values.filter { !$0.waitingPermissions.isEmpty }.map(\.id)
        Task { [bridge] in
            for session in waiting { await bridge.releaseSession(session) }
        }
        state = SessionState()
        liveness = LivenessTracker()
        persistNow()
        onStateChange?()
    }

    /// How long a seeded demo gate waits before expiring itself.
    ///
    /// A real gate is held by `BridgeServer` and released by `ask_timeout`,
    /// which sends the hook `.deferToAgent` and clears the card. A demo gate has
    /// no connection and never went near the bridge, so nothing was ever going
    /// to release it — it sat pending, holding `attentionCount` above zero and
    /// the island amber, until somebody answered it or quit the app. **Seed
    /// Demo Session is a shipped menu item**, so that was a user-reachable way
    /// to get a permanently orange notch by clicking a menu and wandering off.
    ///
    /// Shorter than the 300s policy default on purpose: a demo is something you
    /// look at for a moment, and the point of it is to show the card, not to
    /// hold your island hostage for five minutes afterwards.
    /// 90 seconds is right for a demo and wrong for testing — long enough to
    /// look real, short enough that checking three things against one gate means
    /// relaunching between each. `AIRLOCK_DEMO_GATE_SECONDS` overrides it.
    static var demoGateTimeout: Duration {
        if let raw = ProcessInfo.processInfo.environment["AIRLOCK_DEMO_GATE_SECONDS"],
           let seconds = Int(raw) {
            return .seconds(seconds)
        }
        return .seconds(90)
    }

    /// Populate the notch with sample sessions so the UI is visible without a
    /// live agent. Triggered by the menu item or `AIRLOCK_DEMO=1`.
    ///
    /// `gateTimeout` is injectable for tests only; nothing in the app passes it.
    func seedDemo(gateTimeout: Duration = AppModel.demoGateTimeout) {
        demoIDs.formUnion(["demo-claude", "demo-codex"])
        let now = Date()
        var seq = UInt64(now.timeIntervalSince1970 * 1000)
        func next() -> UInt64 { seq += 1; return seq }

        state.apply(AgentEvent(sessionID: "demo-claude", agent: .claudeCode, sequence: next(),
            timestamp: now, kind: .sessionStarted(project: "storefront",
            cwd: "/Users/you/storefront",
            terminal: TerminalInfo(app: "iTerm.app", tty: "ttys002"))))
        state.apply(AgentEvent(sessionID: "demo-claude", agent: .claudeCode, sequence: next(),
            timestamp: now, kind: .permissionRequested(PermissionRequest(id: "req-1",
            toolName: "Bash", summary: "Run shell command",
            command: "rm -rf ./dist && npm run deploy:prod", createdAt: now))))

        state.apply(AgentEvent(sessionID: "demo-codex", agent: .codex, sequence: next(),
            timestamp: now, kind: .sessionStarted(project: "api-gateway",
            cwd: "/Users/you/api", terminal: TerminalInfo(app: "tmux"))))
        state.apply(AgentEvent(sessionID: "demo-codex", agent: .codex, sequence: next(),
            timestamp: now, kind: .activity(summary: "Editing 3 files")))
        stateDidMutate()

        // Same ending a real gate gets when ask_timeout fires: `.deferred`,
        // which clears the card without recording a decision the user never
        // made. Re-seeding restarts the clock rather than stacking timers.
        demoGateExpiry?.cancel()
        demoGateExpiry = Task { [weak self] in
            try? await Task.sleep(for: gateTimeout)
            guard !Task.isCancelled else { return }
            self?.expireDemoGate(sessionID: "demo-claude", requestID: "req-1")
        }
    }

    /// Clear a demo gate if it is still the one pending. Answering it first
    /// wins — this must not resolve a gate somebody already decided, nor one
    /// belonging to a real session that happens to share the slot.
    private func expireDemoGate(sessionID: String, requestID: String) {
        guard let session = state.sessions[sessionID],
              session.pendingPermission?.id == requestID else { return }
        // Matches the liveness line's style. Worth having: an island that goes
        // amber and stays there has no other trace, and the demo gate is
        // invisible in the saved state because demo IDs are excluded from it.
        Log.bridge.debug("demo gate \(requestID, privacy: .public) expired after \(String(describing: Self.demoGateTimeout), privacy: .public)")
        state.resolveGate(sessionID: sessionID, requestID: requestID, decision: .deferred, at: Date())
        stateDidMutate()
    }
}
