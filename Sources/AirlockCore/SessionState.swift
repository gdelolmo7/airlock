import Foundation

/// The single source of truth for all session data.
///
/// A pure value type with one entry point — `apply(_:)`. Deterministic and
/// mock-free, so the entire domain is testable without a socket, a UI, or a
/// running agent. This is the design decision worth carrying over verbatim
/// from the reference; everything else is a rewrite.
public struct SessionState: Codable, Sendable, Equatable {
    public private(set) var sessions: [String: AgentSession]

    public init(sessions: [String: AgentSession] = [:]) {
        self.sessions = sessions
    }

    /// Sessions ordered for display: attention first, then most-recently
    /// active, then by id.
    ///
    /// The id is not decoration. `sorted` is not stable, and two sessions can
    /// easily share a rank and a timestamp — parallel hooks arrive in the same
    /// millisecond, and a restored state carries identical dates. Without a
    /// final tiebreak the panel could draw them in either order from one update
    /// to the next, and the things read off the top of that list — which card
    /// the keyboard answers, which one is announced — would move with it.
    public var ordered: [AgentSession] {
        sessions.values.sorted { a, b in
            if a.status.sortRank != b.status.sortRank {
                return a.status.sortRank < b.status.sortRank
            }
            if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
            return a.id < b.id
        }
    }

    /// The one waiting card the keyboard answers: the first in display order,
    /// which is the one at the top of the panel.
    ///
    /// **There has to be exactly one.** Every card on screen used to bind Esc,
    /// ⌘Y, ⌘N and ⌘1–9, and a key equivalent goes to whichever bound view
    /// SwiftUI finds first — so with two sessions waiting, ⌘Y answered a card
    /// the user was not looking at. Naming the card here, once, is what lets
    /// the view bind the keys on that one and print the keycaps only there.
    public var focusedGate: FocusedGate? {
        guard let session = ordered.first(where: { $0.pendingPermission != nil }),
              let request = session.pendingPermission else { return nil }
        return FocusedGate(sessionID: session.id, requestID: request.id)
    }

    /// The card to tell a listener about when a queued gate takes a session's
    /// place: the first in display order whose card is not the one `previous`
    /// recorded for it.
    ///
    /// **In display order, and from the sessions rather than from a
    /// dictionary.** The controller used to ask a `Dictionary` for its first
    /// match, which is whatever the hashing put there — so with two sessions
    /// promoting a card in the same update, the one announced was chosen by
    /// nothing at all. It is now the same card the keyboard answers when there
    /// is a choice: the one at the top.
    ///
    /// `previous` is the request id each session was showing, by session id.
    public func promotedGate(since previous: [String: String]) -> FocusedGate? {
        for session in ordered {
            guard let card = session.pendingPermission,
                  let before = previous[session.id], before != card.id else { continue }
            return FocusedGate(sessionID: session.id, requestID: card.id)
        }
        return nil
    }

    /// What every session is showing now, for the next call to `promotedGate`.
    public var shownCards: [String: String] {
        Dictionary(uniqueKeysWithValues: sessions.values.compactMap { session in
            session.pendingPermission.map { (session.id, $0.id) }
        })
    }

    /// Which session's card, and which request on it — the id, because the card
    /// under a session changes as its queue moves.
    public struct FocusedGate: Sendable, Equatable {
        public let sessionID: String
        public let requestID: String

        public init(sessionID: String, requestID: String) {
            self.sessionID = sessionID
            self.requestID = requestID
        }
    }

    public var attentionCount: Int {
        sessions.values.filter { $0.status.wantsAttention }.count
    }

    /// Apply one event. Out-of-order and duplicate events are dropped by the
    /// monotonic `sequence` guard, so an at-least-once transport is safe.
    ///
    /// Returns the sessions this event SUPERSEDED — the ones whose card and
    /// queue it took off screen without anybody answering them. Their hooks are
    /// still held by the bridge, so whoever owns one has to hand them back; see
    /// `BridgeServer.releaseSession`. Discardable, because most callers are
    /// replaying into a value and have no bridge to tell.
    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> [String] {
        // Bootstrap: a brand-new session is created by any first event —
        // except a gate ENDING, which is not news of a session, it is news
        // about one that is not here. Clearing the list hands every held gate
        // back (see `BridgeServer.releaseSession`), and those replies used to
        // arrive a moment later and re-create the very sessions that had just
        // been cleared, as empty rows nobody asked for.
        guard var session = sessions[event.sessionID] else {
            if case .permissionResolved = event.kind { return [] }
            var created = AgentSession(
                id: event.sessionID,
                agent: event.agent,
                projectName: Self.unknownProject,
                status: .starting,
                startedAt: event.timestamp,
                lastActivity: event.timestamp,
                lastSequence: event.sequence
            )
            mutate(&created, with: event)
            sessions[event.sessionID] = created
            return supersedeTerminalSiblings(of: event.sessionID)
        }

        // Monotonicity: ignore anything not strictly newer than what we've seen
        // — except a gate opening or ending, which names its gate by a unique
        // id and so cannot be stale. Dropping one is what goes wrong instead:
        // parallel hooks reach the bridge out of the order their clocks say,
        // and an answer given here is stamped from this side, so a gate's
        // request could be dropped (a hook waiting behind no card) or its end
        // (a card for a hook already answered). Applied late, both are exact;
        // applied twice, both are no-ops.
        guard event.sequence > session.lastSequence || event.kind.namesAGate else { return [] }
        session.lastSequence = max(session.lastSequence, event.sequence)
        mutate(&session, with: event)
        sessions[event.sessionID] = session
        return supersedeTerminalSiblings(of: event.sessionID)
    }

    // MARK: - Local changes

    /// Clear the record of a question that can no longer be answered.
    ///
    /// Local: the user did this here, and the agent never hears of it. See
    /// `applyLocally` for why that keeps it off the sequence.
    @discardableResult
    public mutating func dismissReceipt(sessionID: String, at time: Date) -> [String] {
        applyLocally(.questionReceiptDismissed, to: sessionID, at: time)
    }

    /// End a gate from this side — answered on the card, or a demo gate run
    /// out — with the same transition the bridge's own `permissionResolved`
    /// makes: the next gate waiting takes the card, an ignored question leaves
    /// its receipt.
    @discardableResult
    public mutating func resolveGate(sessionID: String, requestID: String,
                                     decision: PermissionDecision, at time: Date,
                                     questionStep: Int? = nil) -> [String] {
        let superseded = applyLocally(.permissionResolved(requestID: requestID, decision: decision),
                                      to: sessionID, at: time, questionStep: questionStep)
        // Deferring hands the card back to the terminal: nobody answered.
        if decision != .deferred { sessions[sessionID]?.answeredAt = time }
        return superseded
    }

    /// Name a conversation from what the app found on this side — the
    /// session-name cache, or a summary in its transcript. The agent's own
    /// `titleChanged` still comes through `apply`.
    @discardableResult
    public mutating func retitle(sessionID: String, to title: String, at time: Date) -> [String] {
        applyLocally(.titleChanged(title: title), to: sessionID, at: time)
    }

    /// The transition table, without the sequence.
    ///
    /// Sequence numbers belong to the agent's stream: the hook stamps its own,
    /// and the reducer drops anything not newer than the last it saw. A change
    /// made here used to ride in as a synthetic event stamped
    /// `lastSequence + 1`, which spent a number the agent's next event could
    /// carry — and that event was then dropped as a duplicate: a row that
    /// stopped updating, a status change that never landed. So `lastSequence`
    /// is left alone, and a session that is not here is not created — there is
    /// nothing local to say about one.
    private mutating func applyLocally(_ kind: AgentEvent.Kind, to sessionID: String,
                                       at time: Date, questionStep: Int? = nil) -> [String] {
        guard var session = sessions[sessionID] else { return [] }
        mutate(&session, with: AgentEvent(sessionID: sessionID, agent: session.agent,
                                          sequence: session.lastSequence, timestamp: time,
                                          kind: kind, questionStep: questionStep))
        sessions[sessionID] = session
        return supersedeTerminalSiblings(of: sessionID)
    }

    /// One terminal tty hosts exactly one live conversation: /login, /clear,
    /// resume, and compact all mint a fresh session_id in the SAME terminal,
    /// orphaning the old id (no SessionEnd fires). When a session shares both
    /// agent PID and tty with a live sibling, the stalest one is superseded
    /// immediately instead of lingering until the inactivity TTL. PID-only
    /// matches never supersede — the desktop host runs many concurrent
    /// conversations under one PID (and no tty).
    ///
    /// Returns the ones it superseded: each may have had a card and a queue,
    /// and those gates are still held on the other side of the bridge.
    private mutating func supersedeTerminalSiblings(of sessionID: String) -> [String] {
        guard let current = sessions[sessionID],
              let pid = current.jumpTarget?.agentPID,
              let tty = current.jumpTarget?.tty else { return [] }

        var superseded: [String] = []
        for (id, var other) in sessions {
            guard id != sessionID,
                  other.status != .done,
                  other.jumpTarget?.agentPID == pid,
                  other.jumpTarget?.tty == tty,
                  other.lastActivity <= current.lastActivity else { continue }
            other.pendingPermission = nil
            other.queuedPermissions = nil
            other.pendingQuestion = nil
            other.status = .done
            sessions[id] = other
            superseded.append(id)
        }
        return superseded.sorted()
    }

    /// Remove sessions that ended more than `olderThan` seconds ago.
    /// Returns how many were removed (callers persist only on change).
    @discardableResult
    public mutating func prune(now: Date, olderThan seconds: TimeInterval) -> Int {
        let before = sessions.count
        sessions = sessions.filter { _, s in
            !(s.status == .done && now.timeIntervalSince(s.lastActivity) > seconds)
        }
        return before - sessions.count
    }

    /// Sessions that PID-liveness cannot vouch for individually — no agent PID,
    /// or a PID *shared* with other sessions (one host process serving many
    /// sessions over time, e.g. the Claude desktop app: the process outlives
    /// each session, so old ones would be immortal). Quiet ones past `ttl` are
    /// eviction candidates. Attention states are exempt (a held gate resolves
    /// via ask_timeout first) and `.done` is prune's job.
    public func ttlEvictionCandidates(now: Date, olderThan ttl: TimeInterval) -> [AgentSession] {
        var pidCounts: [Int32: Int] = [:]
        for session in sessions.values {
            if let pid = session.jumpTarget?.agentPID {
                pidCounts[pid, default: 0] += 1
            }
        }
        return sessions.values.filter { s in
            guard s.status != .done, !s.status.wantsAttention,
                  now.timeIntervalSince(s.lastActivity) > ttl else { return false }
            // A PID vouches for a session only when it's a terminal-bound agent
            // process — i.e. it has a tty. No tty → the PID is a GUI host app
            // (Claude.app / Codex.app), immortal and shared across every desktop
            // conversation, so it can't vouch for any of them. No PID / shared
            // PID are likewise unvouchable. In all of these, inactivity is the
            // only honest signal.
            guard let pid = s.jumpTarget?.agentPID, s.jumpTarget?.tty != nil else { return true }
            return pidCounts[pid, default: 0] > 1
        }
    }

    /// Running/starting sessions that have emitted nothing for `olderThan`
    /// seconds. Real work chatters (every tool call fires hooks); silence
    /// means the turn ended. The safety net for hosts that never fire Stop —
    /// observed live: desktop sessions stayed "Running" for an hour after
    /// their turn finished (host PID immortal, no tty, no Stop hook).
    public func idleDemotionCandidates(now: Date, olderThan seconds: TimeInterval) -> [AgentSession] {
        sessions.values.filter { s in
            (s.status == .running || s.status == .starting)
                && now.timeIntervalSince(s.lastActivity) > seconds
        }
    }

    /// Sanitize a state loaded from disk for a fresh app launch.
    ///
    /// A blocked permission gate cannot survive a restart — the hook's socket
    /// connection died with the app (the hook failed open; the agent used its
    /// own prompt). So pending gates/questions clear, attention states demote
    /// to idle, mid-start states settle to idle, and long-done sessions drop.
    /// `.running` survives as-is: liveness verifies it within seconds.
    public func preparedForRestore(now: Date, retention: TimeInterval = 120) -> SessionState {
        var restored: [String: AgentSession] = [:]
        for (id, session) in sessions {
            var s = session
            if s.status == .done, now.timeIntervalSince(s.lastActivity) > retention { continue }
            s.pendingPermission = nil
            s.queuedPermissions = nil
            s.pendingQuestion = nil
            // A receipt is an account of something that happened while you were
            // watching. Restored across a restart it is an account of something
            // you cannot place, timestamped before the app was even running.
            s.questionReceipt = nil
            if s.status.wantsAttention || s.status == .starting { s.status = .idle }
            // A cache written before `SubmittedPrompt` existed can hold the
            // host's messages as though they were typed — a task notification
            // after "You:", or as the conversation's name — and nothing else
            // would clear them before the next real prompt.
            if let prompt = s.lastPrompt, SubmittedPrompt.needsCleaning(prompt) {
                if case let .typed(text) = SubmittedPrompt.classify(prompt) {
                    s.lastPrompt = Self.displayLine(text)
                } else {
                    s.lastPrompt = nil
                }
            }
            // No typed text to recover from 60 characters of tags, and the
            // project name is a better name than half a command.
            if s.titleExplicit != true, let title = s.title, SubmittedPrompt.needsCleaning(title) {
                s.title = nil
            }
            restored[id] = s
        }
        return SessionState(sessions: restored)
    }

    /// Turn an agent's markdown reply into ONE line fit for a session row.
    ///
    /// Block structure can't render in a two-line row, so it is removed rather
    /// than flattened: tables become `| A | B ||---|---|` noise, fenced code
    /// becomes a wall. Prose survives, list items become `·` separators, and
    /// inline emphasis (`**b**`, `` `code` ``, links) is preserved for the
    /// renderer to style.
    public static func displayLine(_ raw: String, limit: Int = 200) -> String {
        var kept: [String] = []
        var insideFence = false
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { insideFence.toggle(); continue }
            if insideFence { continue }
            if trimmed.hasPrefix("|") { continue }          // table row or separator
            if trimmed.allSatisfy({ $0 == "-" || $0 == "=" }), trimmed.count >= 3 {
                continue                                     // setext rule / hr
            }
            kept.append(trimmed)
        }

        // A reply that is ONLY a table or code block would vanish — never
        // render nothing; fall back to the raw text in that case.
        var text = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if text.isEmpty { text = raw }

        text = text.replacingOccurrences(
            of: "(^|\\s)#{1,6}\\s+", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "(^|\\s)[-*+]\\s+", with: "$1· ", options: .regularExpression)
        text = text.replacingOccurrences(of: "```", with: "")
        return oneLine(text, limit: limit)
    }

    /// Collapse whitespace runs (newlines included) and cap the length.
    static func oneLine(_ text: String, limit: Int = 200) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit)) + "…"
    }

    /// A conversation's name taken from its first prompt, until a real one
    /// arrives: one line, and shortened between words with "…".
    ///
    /// It was the first 60 characters, which stopped wherever the 60th fell —
    /// "plan the tap-home change and the website update, ask me what" — and,
    /// with no ellipsis, read as the whole of what was typed. Only the
    /// derived title comes through here; a real one is shown as it arrived.
    static func promptTitle(_ prompt: String, limit: Int = 60) -> String {
        let flat = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        // Back up to the last space, so no word is split — unless that would
        // throw away most of it: "fix https://github.com/…" is one long token
        // after its first word, and "fix…" says less than half an address.
        let space = cut.lastIndex(of: " ")
        var stem = space.flatMap { cut.distance(from: cut.startIndex, to: $0) >= limit / 2 ? cut[..<$0] : nil } ?? cut
        // "…update," + "…" reads as a typo. The end only: a prompt may well
        // start with a dash.
        while let last = stem.last, " ,;:-–—".contains(last) { stem = stem.dropLast() }
        return (stem.isEmpty ? cut : stem) + "…"
    }

    /// The row's line while a gate is on the card: the card's own line —
    /// Claude's description of a command, "Waiting for your answer" for a
    /// question the card spells out — and how many more wait behind it.
    static func waitingLine(card: PermissionRequest, behind: Int) -> String {
        let line = card.waitingLine ?? card.summary
        return behind > 0 ? "\(line) · \(behind) more after this" : line
    }

    /// The project a session has before the agent says where it runs — a
    /// placeholder, which the card swaps for a name (`SessionCardText.place`).
    public static let unknownProject = "session"

    /// The row's line once a gate is over, until the agent says anything else.
    ///
    /// Without it the line went on reading the card that had just gone — the
    /// question, cut short, after it was answered, or "Allow …?" over a tool
    /// that was already running.
    private static func lineAfter(_ request: PermissionRequest, _ decision: PermissionDecision) -> String {
        switch decision {
        case .deferred:
            // Handed back, so the agent asks in its own prompt. The line says
            // that rather than repeating the request, which read as the agent
            // still being busy with it — see `SessionCardText.handedBack`.
            return SessionCardText.handedBack
        case .allowOnce, .alwaysAllow:
            // An answered question sends the agent back to work; an approved
            // call runs.
            return request.question != nil ? "Working…" : (request.activity ?? request.summary)
        case .deny:
            return "Working…"
        }
    }

    // MARK: - Transition table

    private func mutate(_ s: inout AgentSession, with event: AgentEvent) {
        // Never backwards: a gate event may be applied after newer ones.
        s.lastActivity = max(s.lastActivity, event.timestamp)
        switch event.kind {
        case let .sessionStarted(project, cwd, terminal):
            s.projectName = project
            s.cwd = cwd
            s.terminal = terminal
            // A session that just STARTED is waiting, not working. "Running"
            // is earned by real activity (a prompt or a tool call) and given
            // up on Stop. Otherwise a desktop conversation resumed on wake
            // shows a phantom "Running" until the idle timeout.
            if !s.status.wantsAttention { s.status = .idle }
            if s.startedAt == nil { s.startedAt = event.timestamp }

        case let .promptSubmitted(prompt):
            switch SubmittedPrompt.classify(prompt) {
            case let .typed(text):
                s.lastPrompt = Self.displayLine(text)
                s.lastResponse = nil // the new turn hasn't answered yet
                // First prompt names the conversation until a real title arrives.
                if s.title == nil { s.title = Self.promptTitle(text) }
                s.lastSummary = "Working…"
            case let .taskNotification(outcome):
                // The host talking, not the person: it never goes after "You:"
                // and never names the conversation. The agent still answers it,
                // so the session works — and the exchange on the card stays the
                // last one somebody actually had.
                s.lastSummary = outcome.activity
            case .injected:
                s.lastSummary = "Working…"
            }
            if !s.status.wantsAttention { s.status = .running }

        case let .titleChanged(title):
            s.title = title
            s.titleExplicit = true

        case let .metadata(transcriptPath):
            s.transcriptPath = transcriptPath

        case let .activity(summary):
            s.lastSummary = summary
            if !s.status.wantsAttention { s.status = .running }

        case let .statusChanged(status):
            s.status = status

        case let .turnEnded(assistantMessage):
            s.turns += 1
            if let message = assistantMessage.map({ Self.displayLine($0) }), !message.isEmpty {
                s.lastResponse = message
            }
            s.status = .idle

        case let .permissionRequested(request):
            if let card = s.pendingPermission, card.id != request.id {
                // Something already has the card: this one waits behind it. It
                // never takes the card, and nothing is handed back to the agent
                // for having arrived first — each hook waits for its own answer.
                if !s.waitingPermissions.contains(where: { $0.id == request.id }) {
                    s.queuedPermissions = (s.queuedPermissions ?? []) + [request]
                }
            } else {
                s.pendingPermission = request
            }
            // A live ask outranks the record of a dead one.
            s.questionReceipt = nil

        case let .permissionResolved(requestID, decision):
            if let card = s.pendingPermission, card.id == requestID {
                // Ignoring is a real answer — it hands the ask back to the
                // agent's own prompt — but it used to leave nothing behind, so a
                // question you dismissed and a question you never saw looked
                // identical a minute later. Only questions leave a receipt: a
                // command gate that was deferred is still visible in the gate
                // log, and the command itself is not something to re-read. With
                // more waiting, the next card covers it until they are done.
                if decision == .deferred, let question = card.question(at: event.questionStep) {
                    s.questionReceipt = QuestionReceipt(question: question.question,
                                                        header: question.header,
                                                        reason: .ignored,
                                                        at: event.timestamp)
                }
                s.pendingPermission = nil
                if let queued = s.queuedPermissions, let next = queued.first {
                    // The next oldest takes the card; the bridge starts its
                    // `ask_timeout` now, when it is shown.
                    s.pendingPermission = next
                    s.queuedPermissions = queued.count > 1 ? Array(queued.dropFirst()) : nil
                } else {
                    s.lastSummary = Self.lineAfter(card, decision)
                            s.status = s.pendingQuestion == nil ? .running : .waitingQuestion
                }
            } else if let queued = s.queuedPermissions,
                      let index = queued.firstIndex(where: { $0.id == requestID }) {
                // It ended while waiting behind the card — its own timeout, its
                // hook gone, or a rule "Always" had just written. The card is
                // untouched, and so is everything else waiting.
                var rest = queued
                rest.remove(at: index)
                s.queuedPermissions = rest.isEmpty ? nil : rest
            }
            // Anything else names a gate that is not waiting here — answered
            // already, or never shown — and ends nothing.

        case let .questionAsked(prompt):
            s.pendingQuestion = prompt
            s.status = .waitingQuestion
            s.lastSummary = prompt

        case .questionAnswered:
            s.pendingQuestion = nil
            s.status = s.pendingPermission == nil ? .running : .needsAttention

        case let .jumpTargetUpdated(target):
            // Preserve fields a transient resolver failure may have blanked.
            s.jumpTarget = merge(existing: s.jumpTarget, incoming: target)

        case .sessionEnded:
            // The agent died with a question on screen. The card cannot stay as
            // it is — every option would be delivered to a pid that is gone —
            // but it must not simply vanish either, or the answer you were
            // composing disappears with no account of why.
            if let question = s.pendingPermission?.question(at: event.questionStep) {
                s.questionReceipt = QuestionReceipt(question: question.question,
                                                    header: question.header,
                                                    reason: .agentExited,
                                                    at: event.timestamp)
            }
            s.pendingPermission = nil
            s.queuedPermissions = nil
            s.pendingQuestion = nil
            s.status = .done

        case .questionReceiptDismissed:
            s.questionReceipt = nil
        }

        // The card is always the oldest gate waiting — a queue with nothing on
        // the card cannot be answered, and would never end.
        if s.pendingPermission == nil, let queued = s.queuedPermissions, let next = queued.first {
            s.pendingPermission = next
            s.queuedPermissions = queued.count > 1 ? Array(queued.dropFirst()) : nil
        }

        // A card on screen is something only its own answer can end, so nothing
        // else that happens in the session may say otherwise — a turn ending
        // around it, a status nudge, whatever comes next. `attentionCount` is what keeps the island open
        // and its amber dot lit: a session that shows a card and counts as
        // "running" is a card nobody is told about. The line says what the
        // session is waiting for, and how much more is behind it.
        if let card = s.pendingPermission {
            s.status = .needsAttention
            s.lastSummary = Self.waitingLine(card: card, behind: s.queuedPermissions?.count ?? 0)
        }
    }

    private func merge(existing: JumpTarget?, incoming: JumpTarget) -> JumpTarget {
        guard let existing else { return incoming }
        return JumpTarget(
            terminalApp: incoming.terminalApp ?? existing.terminalApp,
            tty: incoming.tty ?? existing.tty,
            tmuxPane: incoming.tmuxPane ?? existing.tmuxPane,
            bundleID: incoming.bundleID ?? existing.bundleID,
            agentPID: incoming.agentPID ?? existing.agentPID
        )
    }
}
