import Foundation

/// The in-app bridge. Owns all interactive-session routing state as an `actor`,
/// so the compiler proves data-race freedom — no `@unchecked Sendable`, no
/// hand-rolled re-entrancy guards. The blocking socket I/O lives in
/// `UnixSocketServer`; this actor only sees decoded envelopes and clean events.
///
/// Permission gates flow through the policy engine first:
///   deny rule → auto-deny · risk floor → ask · allow rule → auto-approve.
/// Gates that ask are held until the user decides or `ask_timeout` expires,
/// at which point the hook is told to defer to the agent's own prompt. Several
/// can wait in one session; they queue, oldest first, one card at a time.
public actor BridgeServer {
    /// Domain events, ready for `SessionState.apply`. Consumed by the app.
    public nonisolated let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation

    private let server: UnixSocketServer
    private let registry: AgentRegistry
    private let policy: PolicyEngine
    /// Called for gates the policy settled without a human. The app writes them
    /// to the gate log; the actor stays off the filesystem.
    private var onAutoDecision: (@Sendable (GateRecord) -> Void)?

    /// One held permission gate: the blocked hook connection, the request it
    /// is waiting on, and enough to end it on its own — its clock, a rule
    /// written while it waited, its hook going away.
    private struct Gate {
        let connection: ClientConnection
        let request: PermissionRequest
        let agent: AgentKind
        /// The hook's working directory: where its policy was read on arrival,
        /// and where it is read again if "Always" re-checks the queue.
        let projectRoot: String?
        let arrivedAt: Date
        /// The policy's `ask_timeout` on arrival. Zero holds until answered.
        let askTimeout: TimeInterval
        var timeout: Task<Void, Never>?

        var requestID: String { request.id }
    }

    /// Held gates by session, oldest first — the order the app shows them in,
    /// one card at a time.
    ///
    /// A newer gate used to take its session's slot and hand the older one back
    /// to the agent's own prompt. Parallel calls are not rare — Claude reads
    /// files in batches, and helpers run side by side — so what the user saw
    /// depended on which hook had reached the socket last, and the rest were
    /// answered in a window they were not looking at. Now each waits its turn,
    /// and each ends only by its own exit: an answer given for it, its
    /// `ask_timeout`, a rule, or its hook going away. Every one of those is
    /// addressed by request id, which is why the decoder makes ids unique.
    private var gates: [String: [Gate]] = [:]

    /// How long any gate may be held, from its arrival: a minute short of the
    /// hook's own wait (`HookDirective.blockingWait`, which is also what the
    /// installer writes as the hook's timeout). A gate behind a long queue — or
    /// under `ask_timeout: 0` — would otherwise outlive its hook, and the agent
    /// would kill the hook rather than hear from us. The minute is for the reply
    /// to get there.
    public static let longestHold: TimeInterval = HookDirective.blockingWait - 60

    /// `longestHold`, except in tests, which cannot wait a day to see it work.
    private let holdLimit: TimeInterval

    /// The newest sequence emitted for each session, so an event the bridge
    /// makes up itself can be stamped after everything already sent — see
    /// `stamp`. One entry per session seen, a few bytes each.
    private var emittedUpTo: [String: UInt64] = [:]

    /// The single drain of the transport stream. Stored so `stop()` can end it
    /// — and so there is exactly one, which is what makes ingest ordered.
    private var ingestTask: Task<Void, Never>?

    public init(
        registry: AgentRegistry = .shared,
        path: String = SocketPath.default(),
        policy: PolicyEngine = PolicyEngine(),
        holdLimit: TimeInterval = BridgeServer.longestHold
    ) {
        (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
        self.registry = registry
        self.policy = policy
        self.holdLimit = holdLimit
        self.server = UnixSocketServer(path: path)
    }

    public func start() throws {
        // Drained by ONE task, so ingest is ordered. It used to be two
        // callbacks each spawning their own `Task`, and actors make no
        // cross-task FIFO promise — so a disconnect could be handled before the
        // payload that physically arrived first, registering a gate on a
        // connection already gone. The reducer's sequence guard absorbs most
        // reordering by design, but not that: `hold` would create a card for a
        // hook nobody is waiting on, and it would sit there until `ask_timeout`
        // — or forever, if the user set `ask_timeout: 0`, where no timer exists.
        //
        // Serialising costs nothing. `handle` and `ingest` contain no `await`,
        // so the actor already ran them one at a time; this only removes the
        // freedom to run them in the wrong order.
        //
        // Started BEFORE the listener, though the `.unbounded` buffer means the
        // reverse would also be safe. Cheap to be obvious about it.
        ingestTask = Task { [weak self, events = server.events] in
            for await event in events {
                guard let self else { return }
                switch event {
                case let .envelope(envelope, connection):
                    await self.handle(envelope, from: connection)
                case let .disconnected(connection):
                    await self.forget(connection)
                }
            }
        }
        try server.start()
    }

    public func stop() {
        for (sessionID, queue) in gates {
            for gate in queue { deferGate(gate, sessionID: sessionID) }
        }
        gates.removeAll()
        // Before cancelling ingest: `server.stop()` closes the connections and
        // finishes the transport stream, which ends the `for await` on its own.
        // Cancelling first would abandon disconnects still in the buffer.
        server.stop()
        ingestTask?.cancel()
        ingestTask = nil
        continuation.finish()
    }

    /// Answer a question the agent asked. Delivered as a deny + reason: the
    /// documented PreToolUse contract feeds `permissionDecisionReason` back to
    /// the agent, so the choice reaches it as explicit user input instead of
    /// the tool prompting again in the terminal.
    /// `requestID` for the same reason as `resolve` — an answer is a decision
    /// too, and one delivered to another waiting question is worse than none.
    /// Returns whether the answer reached a waiting hook. False means the gate
    /// had already ended — its `ask_timeout`, its hook going away, a rule
    /// settling it — and nothing was delivered, which the caller needs to know
    /// before it writes down that the agent was answered.
    @discardableResult
    public func answer(sessionID: String, requestID: String, choice: String) -> Bool {
        guard let gate = release(sessionID: sessionID, requestID: requestID) else { return false }
        gate.connection.send(.directive(HookDirective(
            action: .deny,
            reason: "The user answered from Airlock: \(choice)"
        )))
        gate.connection.close()
        return true
    }

    /// Resolve a pending permission from the UI: route the decision to the
    /// waiting hook.
    ///
    /// **`requestID` is not optional and not decoration.** A session can hold
    /// several gates, so a decision addressed by session alone lands on
    /// whichever gate happens to be first when it reaches the actor, not the one
    /// the user was looking at. The click travels through an unstructured Task,
    /// so the window is real: approve gate A, it ends some other way on the
    /// way here, and the allow arrives at gate B — a command nobody ever saw,
    /// approved by a click meant for something else. On the surface this product
    /// exists to provide, that is the worst thing it could do.
    ///
    /// `expireGate` has always carried this guard. `resolve` and `answer` did
    /// not, and the asymmetry was the bug.
    ///
    /// A mismatch sends nothing, deliberately: that gate has already ended by
    /// its own exit, and every other one is still waiting for its own answer.
    ///
    /// **"Always" re-checks the queue.** The app writes the rule before it calls
    /// this, so any other gate waiting in the session that the rule now covers
    /// is settled as though it had just arrived under it — see
    /// `settleByPolicy`.
    /// Returns whether the decision reached a waiting hook — see `answer`. A
    /// mismatch sends nothing and answers `false`: that gate has already ended
    /// by its own exit, and the agent will never hear this.
    @discardableResult
    public func resolve(sessionID: String, requestID: String, decision: PermissionDecision) -> Bool {
        guard let gate = release(sessionID: sessionID, requestID: requestID) else { return false }
        gate.connection.send(.directive(.from(decision)))
        gate.connection.close()
        if decision == .alwaysAllow { settleByPolicy(sessionID: sessionID) }
        return true
    }

    /// Set once at startup. Separate from `init` because the app builds the
    /// bridge before it has anywhere to put the records.
    public func setAutoDecisionHandler(_ handler: @escaping @Sendable (GateRecord) -> Void) {
        onAutoDecision = handler
    }

    // MARK: - Ingest

    /// The one way an event leaves the bridge, so `emittedUpTo` cannot miss one.
    private func emit(_ event: AgentEvent) {
        emittedUpTo[event.sessionID] = max(emittedUpTo[event.sessionID] ?? 0, event.sequence)
        continuation.yield(event)
    }

    private func handle(_ envelope: BridgeEnvelope, from connection: ClientConnection) {
        switch envelope {
        case .hookPayload(let payload):
            ingest(payload, from: connection)
        case .hello, .directive, .ack:
            break // the app is the server; it does not act on these
        }
    }

    private func ingest(_ payload: HookPayload, from connection: ClientConnection) {
        guard let integration = registry.integration(source: payload.source) else {
            connection.send(.ack)
            connection.close()
            return
        }

        let context = HookContext(
            source: payload.source,
            cwd: payload.cwd,
            terminal: payload.terminal,
            agentPID: payload.agentPID,
            receivedAt: payload.receivedAt
        )
        var decoded = (try? integration.decodeEvents(from: payload.payload, context: context)) ?? []

        // Transport-level enrichment: every hook invocation refreshes the
        // session's jump/liveness handle (TTY + agent PID), whatever the agent.
        // Idempotent under the reducer's merge; agent decoders stay vendor-only.
        if let first = decoded.first, payload.agentPID != nil || payload.terminal?.tty != nil {
            decoded.insert(AgentEvent(
                sessionID: first.sessionID,
                agent: first.agent,
                sequence: first.sequence &- 1,
                timestamp: payload.receivedAt,
                kind: .jumpTargetUpdated(JumpTarget(
                    terminalApp: payload.terminal?.app,
                    tty: payload.terminal?.tty,
                    agentPID: payload.agentPID
                ))
            ), at: 0)
        }

        // Fast path: nothing is blocked on us.
        guard payload.wantsDirective,
              let gateEvent = decoded.last,
              case let .permissionRequested(request) = gateEvent.kind else {
            for event in decoded { emit(event) }
            // A session that has ended can answer nothing, and the reducer has
            // just taken its card away — so anything of its still held here
            // goes back to the agent now rather than in `ask_timeout`'s own
            // time. See `releaseSession`.
            for event in decoded where event.kind.endsTheSession {
                releaseSession(event.sessionID)
            }
            connection.send(.ack)
            connection.close()
            return
        }

        for event in decoded.dropLast() { emit(event) }

        let decision = policy.plan(for: request, projectRoot: payload.cwd)
        // The call in words, not the card's headline: nobody was asked, so
        // "Auto-approved · Allow Trello: write card?" would be a question
        // answered in the same breath. Not the raw command either — that is
        // shell text, and the row has Claude's description of it.
        let subject = request.activity ?? request.command ?? request.summary
        switch decision.verdict {
        case .allow(let rule):
            connection.send(.directive(.approved(byRule: rule)))
            connection.close()
            emit(gateEvent.replacing(kind: .activity(summary: "Auto-approved · \(subject)")))
            onAutoDecision?(GateRecord(request: request, outcome: .autoAllowed,
                                       agent: payload.source, projectRoot: payload.cwd,
                                       decidedAt: Date()))

        case .deny(let rule):
            connection.send(.directive(.denied(byRule: rule)))
            connection.close()
            // NOT `subject`: that is the running phrase, and "Auto-denied ·
            // Running: rm -rf ./dist" says the blocked command is under way.
            // See `PermissionRequest.refusal`.
            let refused = request.refusal ?? request.command ?? request.summary
            emit(gateEvent.replacing(kind: .activity(summary: "Auto-denied · \(refused)")))
            onAutoDecision?(GateRecord(request: request, outcome: .autoDenied,
                                       agent: payload.source, projectRoot: payload.cwd,
                                       decidedAt: Date()))

        case .ask:
            emit(gateEvent)
            hold(request: request, event: gateEvent, connection: connection,
                 askTimeout: decision.askTimeout, projectRoot: payload.cwd)
        }
    }

    // MARK: - Gates

    /// Behind whatever is already waiting in the session — never instead of it.
    private func hold(request: PermissionRequest, event: AgentEvent, connection: ClientConnection,
                      askTimeout: TimeInterval, projectRoot: String?) {
        let sessionID = event.sessionID
        gates[sessionID, default: []].append(Gate(
            connection: connection, request: request, agent: event.agent,
            projectRoot: projectRoot, arrivedAt: Date(), askTimeout: askTimeout, timeout: nil))
        startClock(sessionID: sessionID, requestID: request.id)
    }

    /// (Re)start one gate's clock.
    ///
    /// **`ask_timeout` runs from when a gate is shown, not from when it
    /// arrived.** It is how long a question waits on screen for an answer, and a
    /// gate behind others has not been asked yet: timed from arrival, three
    /// requests behind a card the user was still reading would all go back to
    /// the agent's prompt unseen — the very hand-back queueing exists to stop.
    /// So only the first gate in a session runs it, and the next starts its own
    /// the moment it takes the card.
    ///
    /// Every gate, shown or not, is also held no longer than `longestHold`
    /// from its arrival, so none can outlive its hook.
    private func startClock(sessionID: String, requestID: String) {
        guard var queue = gates[sessionID],
              let index = queue.firstIndex(where: { $0.requestID == requestID }) else { return }
        queue[index].timeout?.cancel()
        let gate = queue[index]
        let now = Date()
        var deadline = gate.arrivedAt.addingTimeInterval(holdLimit)
        if index == 0, gate.askTimeout > 0 {
            deadline = min(deadline, now.addingTimeInterval(gate.askTimeout))
        }
        let delay = max(0, deadline.timeIntervalSince(now))
        queue[index].timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.expireGate(sessionID: sessionID, requestID: requestID)
        }
        gates[sessionID] = queue
    }

    /// Take ONE gate out of its session's queue and stop its clock — and, if it
    /// was the one on the card, start the clock of the one taking its place.
    /// Every exit comes through here, which is what keeps them per gate.
    private func release(sessionID: String, requestID: String) -> Gate? {
        guard var queue = gates[sessionID],
              let index = queue.firstIndex(where: { $0.requestID == requestID }) else { return nil }
        let gate = queue.remove(at: index)
        gate.timeout?.cancel()
        gates[sessionID] = queue.isEmpty ? nil : queue
        if index == 0, let next = queue.first {
            startClock(sessionID: sessionID, requestID: next.requestID)
        }
        return gate
    }

    /// Hand back every gate a session is holding.
    ///
    /// A card and its queue can leave the screen without anybody answering
    /// them: the session ends, a sibling in the same terminal supersedes it,
    /// or the user clears the list. The reducer drops them in all three cases —
    /// and the hooks went on waiting here, answerable by nobody, until
    /// `ask_timeout`. With `ask_timeout: 0`, which Settings offers as
    /// "never — it waits", that is the hook's own 24-hour limit: an agent
    /// blocked for a day over a card nothing can show. A queue the UI has
    /// stopped showing must not outlive the card.
    public func releaseSession(_ sessionID: String) {
        guard let queue = gates.removeValue(forKey: sessionID) else { return }
        for gate in queue { deferGate(gate, sessionID: sessionID) }
    }

    private func expireGate(sessionID: String, requestID: String) {
        guard let gate = release(sessionID: sessionID, requestID: requestID) else { return }
        deferGate(gate, sessionID: sessionID)
    }

    /// "Always" has just written an allow rule. Every other gate waiting in the
    /// session is checked against the policy again, exactly as on arrival, and
    /// one the rule now allows is settled the way it would have been had it
    /// arrived under it: approved, logged as a rule's decision, off the queue.
    ///
    /// Only an allow settles anything. A deny rule or the risk floor leaves the
    /// gate waiting — deny rules and the floor still win over the new rule, and
    /// "Always" is a yes; it must never turn into a no nobody gave.
    private func settleByPolicy(sessionID: String) {
        for gate in gates[sessionID] ?? [] {
            guard case let .allow(rule) = policy.plan(for: gate.request, projectRoot: gate.projectRoot).verdict,
                  let settled = release(sessionID: sessionID, requestID: gate.requestID) else { continue }
            settled.connection.send(.directive(.approved(byRule: rule)))
            settled.connection.close()
            emit(AgentEvent(sessionID: sessionID, agent: settled.agent, sequence: stamp(sessionID),
                            timestamp: Date(),
                            kind: .permissionResolved(requestID: settled.requestID, decision: .allowOnce)))
            onAutoDecision?(GateRecord(request: settled.request, outcome: .autoAllowed,
                                       agent: settled.agent.rawValue, projectRoot: settled.projectRoot,
                                       decidedAt: Date()))
        }
    }

    /// A sequence for an event the bridge makes up itself: now, or just after
    /// everything already emitted for the session, whichever is later.
    ///
    /// NOT just the clock. Two made in one millisecond — a gate ending and its
    /// neighbour's hook dying straight after — would share a reading; the
    /// reducer no longer drops a gate's end for that, but a stream whose
    /// numbers only ever rise is one every reader can trust.
    private func stamp(_ sessionID: String) -> UInt64 {
        max(UInt64(Date().timeIntervalSince1970 * 1000), (emittedUpTo[sessionID] ?? 0) &+ 1)
    }

    /// Release a held hook back to the agent's own permission flow and tell
    /// the UI the card is no longer pending.
    private func deferGate(_ gate: Gate, sessionID: String) {
        gate.timeout?.cancel()
        gate.connection.send(.directive(HookDirective(action: .deferToAgent)))
        gate.connection.close()
        emit(AgentEvent(
            sessionID: sessionID,
            agent: gate.agent,
            sequence: stamp(sessionID),
            timestamp: Date(),
            kind: .permissionResolved(requestID: gate.requestID, decision: .deferred)
        ))
    }

    /// A hook went away while we were still holding its gate.
    ///
    /// This used to cancel the ask_timeout and drop the gate in silence — the
    /// ONE removal path that never told the UI, where `deferGate` and
    /// `expireGate` both yield `.permissionResolved(.deferred)`. The reducer
    /// therefore never learned the card was over: `pendingPermission` stayed
    /// set and the status stayed `.needsAttention` PERMANENTLY, because the
    /// timer that would eventually have cleared it was the thing we had just
    /// cancelled, idle demotion only covers running sessions, and TTL eviction
    /// deliberately skips anything wanting attention. Clicking the stale card
    /// did nothing, since `resolve` finds no gate. Ctrl-C an agent sitting at a
    /// prompt, or just close its terminal window, and the island stayed amber
    /// until the agent's process itself died.
    ///
    /// It also falsified `SessionState`'s note that attention states are exempt
    /// from eviction *because* a held gate resolves via ask_timeout first. This
    /// was the path where that was not true.
    ///
    /// Sending on the dead connection is free: the reader closes it before
    /// signalling the disconnect, so `send` and `close` are already no-ops. What
    /// we are actually here for is the event.
    private func forget(_ connection: ClientConnection) {
        for (sessionID, queue) in gates {
            for gate in queue where gate.connection == connection {
                guard let released = release(sessionID: sessionID, requestID: gate.requestID) else { continue }
                deferGate(released, sessionID: sessionID)
            }
        }
    }
}

private extension AgentEvent {
    func replacing(kind: Kind) -> AgentEvent {
        AgentEvent(sessionID: sessionID, agent: agent, sequence: sequence, timestamp: timestamp, kind: kind)
    }
}
