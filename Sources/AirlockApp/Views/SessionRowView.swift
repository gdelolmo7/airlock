import SwiftUI
import AirlockCore

/// One session card:
///   [tile]  title                                   (● Needs you)
///           You: last prompt
///           current activity (accent while working)
///           iTerm · 27m · 6 replies                            ⌄
/// The permission card appears below only when attention is needed.
///
/// **Redrawn 2026-10-01** (owner: "I don't love it"). The state was a 3pt rail
/// plus a word in the monospaced label face, beside a terminal chip, an age and
/// a chevron, all crammed into a right-hand column; a finished turn then said
/// it a second time in green underneath. Now the state is said once, as a
/// tinted pill, and the agent's tile carries the same colour — so the colour
/// channel the rail gave is still there, legible before a word is read — and
/// the where-and-how-long goes to a quiet footer line.
struct SessionRowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: AgentSession
    @Environment(AppModel.self) private var model
    /// Only to fold this session's branch into it — see
    /// `RepositoryWidgetModel.repository(for:)`.
    @Environment(RepositoryWidgetModel.self) private var repositories
    @State private var isHovered = false
    /// Opened in place. Deliberately not a second window: the card's contract
    /// is one card, tap anywhere to jump, gate stays a sibling — and a window
    /// would take focus from a panel that collapses when it loses it.
    @State private var isExpanded = false
    /// Drawn in the panel an agent opened to ask something: the title says who
    /// is asking and the card under it says what, so the preview lines go.
    @Environment(\.showsOnlyWaitingSessions) private var brief

    /// `startsExpanded` is for the state gallery, whose pictures cannot click
    /// the chevron. The panel never passes it.
    init(session: AgentSession, startsExpanded: Bool = false) {
        self.session = session
        _isExpanded = State(initialValue: startsExpanded)
    }

    private var accent: Color { Theme.accent(for: session.status) }

    /// A finished turn under the pointer shows prompt + reply together.
    private var showsFullExchange: Bool {
        !brief && isHovered && session.lastResponse != nil && session.lastPrompt != nil
    }

    var body: some View {
        if Self.isRetired(session) {
            // The list folds these into one `FinishedSessionsCard`; a lone one
            // drawn anywhere else still gets the same compact line.
            FinishedSessionsCard(sessions: [session])
        } else {
            liveCard
        }
    }

    /// What the row already knows and never had room to say.
    ///
    /// The account-wide usage figures appear here as well as in the top bar
    /// deliberately: the strip has room for two numbers and no room for what
    /// they mean.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                usageTile(Self.fiveHourLabel, window: model.usage?.fiveHour)
                usageTile(Self.weeklyLabel, window: model.usage?.sevenDay)
                tile(Self.repliesLabel, value: "\(session.turns)", note: Self.repliesNote)
            }

            if let repo = repositories.repository(for: session.cwd) {
                HStack(spacing: 6) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                    Text(repo.status.headLabel)
                        .font(Theme.chrome(10.5, .medium))
                        .foregroundStyle(repo.status.isDetached || repo.status.operation != nil
                                         ? Theme.needs : Theme.running)
                    // The repository rows' own words (`GitStatus.factsLine`),
                    // so the two never describe one checkout differently.
                    Text(repo.status.factsLine)
                        .font(Theme.chrome(10))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                }
            }

            jumpControl
        }
        // Under the text column: the tile (30) and its gap (10).
        .padding(.leading, 40)
    }

    /// A usage window, or the reason there is no number.
    ///
    /// **Past its own reset a reading is void, not stale** — the window rolled
    /// and the percentage describes a period that has ended. `RateLimitWindow`
    /// says so in its own doc comment because it was seen live: the panel read
    /// 0% while the real figure was 90%. An em-dash and the reason is the only
    /// honest thing to print.
    private func usageTile(_ label: String, window: RateLimitWindow?) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let window, !window.hasRolled(at: context.date) {
                tile(label, value: "\(Int(window.usedPercentage.rounded()))%")
            } else if window != nil {
                tile(label, value: "—", note: Self.rolledNote)
            } else {
                tile(label, value: "—", note: Self.noReadingNote)
            }
        }
    }

    /// The detail tiles' words, shared with the state gallery. The labels are
    /// what the limits are, not the "5h" / "7d" shorthand the top bar has to
    /// use for lack of room — the detail is where there is room to say it.
    static let fiveHourLabel = "Last 5 hours"
    static let weeklyLabel = "Last 7 days"
    static let repliesLabel = "Replies"
    static let repliesNote = "in this session"
    /// The limit's period ended after the reading — see `usageTile`.
    static let rolledNote = "limit has reset"
    static let noReadingNote = "not read yet"

    /// Every tile takes a note line, empty or not, so the three are one
    /// height: the replies tile used to stand shorter than its neighbours.
    private func tile(_ label: String, value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(Theme.chrome(10, .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(Theme.chrome(13, .semibold))
                .foregroundStyle(value == "—" ? Theme.textTertiary : Theme.textPrimary)
                .monospacedDigit()
            Text(note ?? " ")
                .font(Theme.chrome(9))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .accessibilityHidden(note == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }

    /// Jump, or the reason it cannot.
    ///
    /// `TerminalJumpPlanner` cannot reach a window that closed, and a button
    /// that silently does nothing is worse than one that says why — so the
    /// control states it and offers the thing that does still work.
    @ViewBuilder
    private var jumpControl: some View {
        if session.jumpTarget == nil {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 9))
                Text("That terminal has closed")
                    .font(Theme.chrome(10.5))
                Spacer(minLength: 4)
                Button { model.startClaudeSession() } label: {
                    Text("Open a new one")
                        .font(Theme.chrome(10.5, .semibold))
                        .foregroundStyle(Theme.running)
                }
                .buttonStyle(.plain)
                .clickable()
            }
            .foregroundStyle(Theme.textTertiary)
        } else {
            Button { model.jump(to: session) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 9))
                    Text("Jump to terminal")
                        .font(Theme.chrome(10.5, .semibold))
                }
                .foregroundStyle(Theme.running)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickable()
        }
    }

    /// Finished, and nothing is waiting on it.
    ///
    /// The gate check is not redundant with the status: a session can end while
    /// a question is still on screen, and collapsing THAT would hide the card
    /// somebody has to dismiss.
    static func isRetired(_ session: AgentSession) -> Bool {
        session.status == .done
            && session.pendingPermission == nil
            && session.questionReceipt == nil
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                AgentTile(agent: session.agent, tint: accent)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 8) {
                        // Rendered, not printed: a prompt-derived title keeps the
                        // prompt's `**bold**`, and the line under it already
                        // drew it bold while the title showed the asterisks.
                        Text(InlineMarkdown.render(SessionCardText.title(of: session), size: 13.5))
                            .font(Theme.chrome(13.5, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        // The state, said in a word, for anyone who cannot use
                        // the tile's colour as the only channel.
                        SessionStatusPill(text: session.status.word, tint: accent)
                    }
                    // Resting: ONE message line — the latest turn (the agent's
                    // reply once it answered, your prompt while it hasn't).
                    // Hovering a finished turn reveals the full exchange:
                    // your prompt above the reply, since the prompt is context
                    // for the answer. Richness on intent, never at rest.
                    if showsFullExchange, let prompt = session.lastPrompt {
                        (Text("You: ") + Text(InlineMarkdown.render(prompt, size: 10.5)))
                            .font(Theme.chrome(10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                    }
                    if !brief, let message = lastMessage {
                        (Text("\(message.label) ").foregroundStyle(Theme.textTertiary)
                            + Text(InlineMarkdown.render(message.body, size: 11.5)))
                            .font(Theme.chrome(11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(showsFullExchange ? 5 : 2)
                    }
                    if !brief, let activity = activityLine {
                        Text(activity)
                            .font(Theme.chrome(11.5, .medium))
                            .foregroundStyle(session.status == .running ? Theme.running : Theme.textTertiary)
                            .lineLimit(1)
                    }
                    footer
                        .padding(.top, 3)
                }
            }
            // Grouped HERE and not on the outer stack, which is where the tap
            // gesture lives — because the outer stack also contains the gate,
            // and combining its children would fold Approve, Deny and Always
            // into this one element and leave the gate unactivatable. The row
            // summary is one button; the gate stays a sibling with its own
            // controls.
            //
            // `.accessibilityAction` rather than relying on the gesture: the
            // gesture is on the parent, and an element VoiceOver reports as a
            // button has to actually do something when activated.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Jumps to this session's terminal")
            .accessibilityAction { model.jump(to: session) }

            if isExpanded {
                // The SAME guard the gate below has, and for the same reason:
                // the whole card carries "any click that isn't a control means
                // take me there", so without this every press inside the detail
                // — the Jump button included — collapsed the panel and switched
                // app instead of doing what it said.
                detail
                    .contentShape(Rectangle())
                    .onTapGesture {}
            }

            if let request = session.pendingPermission {
                // The gate owns every click inside it — deciding must never
                // navigate away mid-decision.
                PermissionCardView(session: session, request: request)
                    .contentShape(Rectangle())
                    .onTapGesture {}
            } else if let ask = SessionCardText.terminalAsk(of: session) {
                // Codex asking in its own terminal. Drawn in the waiting view
                // too, which is the panel this ask opened: it hid the only line
                // that said what was wanted.
                TerminalAskCard(ask: ask) { model.jump(to: session) }
                    .contentShape(Rectangle())
                    .onTapGesture {}
            } else if let receipt = session.questionReceipt {
                // Where the card was, so the eye lands on the account of it in
                // the place it last saw the question.
                QuestionReceiptView(session: session, receipt: receipt)
                    .contentShape(Rectangle())
                    .onTapGesture {}
            }
        }
        .padding(12)
        // …and put it on the WHOLE card, padding included: any click that
        // isn't a control means "take me there".
        .contentShape(Rectangle())
        .onTapGesture { model.jump(to: session) }
        .clickable()
        .help("Click to jump to this session")
        .onHover { hovering in
            withAnimation(MotionEffect.pointer) { isHovered = hovering }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.055) : Theme.rowFill)
                .overlay(
                    // A session waiting on you is ringed in its own colour, so
                    // the card holding a gate stands out from its neighbours
                    // even before the gate inside it is read.
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(session.status.wantsAttention ? accent.opacity(0.45) : Theme.rowStroke,
                                      lineWidth: 1)
                )
        )
    }

    /// Where and how long, in one quiet line — and on the right the way in:
    /// "Open" while the pointer is on the card, and the detail chevron.
    private var footer: some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(meta(at: context.date))
                    .font(Theme.chrome(10.5, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isHovered, session.jumpTarget != nil {
                HStack(spacing: 3) {
                    Text(prettyTerminal.map { "Open in \($0)" } ?? "Open terminal")
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(Theme.chrome(10.5, .semibold))
                .foregroundStyle(Theme.running)
                .transition(.opacity)
            }
            Button {
                withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 20, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickable()
            .accessibilityLabel(isExpanded ? "Hide session detail" : "Show session detail")
        }
    }

    /// "iTerm · 27m · 6 replies".
    private func meta(at now: Date) -> String {
        var parts: [String] = []
        if let terminal = prettyTerminal { parts.append(terminal) }
        parts.append(age(at: now))
        if session.turns > 0 { parts.append(session.turns == 1 ? "1 reply" : "\(session.turns) replies") }
        return parts.joined(separator: " · ")
    }

    /// The latest thing said, from either side. `lastResponse` is cleared when
    /// a new prompt arrives, so this reads: your prompt while Claude works →
    /// Claude's reply when the turn ends.
    private var lastMessage: (label: String, body: String)? {
        if let reply = session.lastResponse { return ("\(Self.shortName(session.agent)):", reply) }
        if let prompt = session.lastPrompt { return ("You:", prompt) }
        return nil
    }

    /// Only present while there is something to narrate — and never the
    /// pill's own word again. See `SessionCardText.activity`.
    private var activityLine: String? { SessionCardText.activity(of: session) }

    /// "Claude", "Codex" — the reply's speaker, without "Code".
    static func shortName(_ agent: AgentKind) -> String {
        agent.displayName.split(separator: " ").first.map(String.init) ?? agent.displayName
    }

    private var prettyTerminal: String? { TerminalName.pretty(session.terminal?.app) }

    /// "4h1m", "23m", "6d1h" — the tightest honest form. Moved here from the
    /// usage strip, which was deleted; this was the only part of it still alive.
    static func compactDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(max(minutes, 1))m" }
        let hours = minutes / 60
        if hours < 24 {
            let rem = minutes % 60
            return rem == 0 ? "\(hours)h" : "\(hours)h\(rem)m"
        }
        let days = hours / 24
        let remHours = hours % 24
        return remHours == 0 ? "\(days)d" : "\(days)d\(remHours)h"
    }

    private func age(at now: Date) -> String {
        let since = session.startedAt ?? session.lastActivity
        return Self.compactDuration(max(now.timeIntervalSince(since), 60))
    }
}

/// An agent waiting on its own terminal's prompt: what it is asking, where,
/// and the one thing to do about it. No Approve or Deny — none would reach it.
struct TerminalAskCard: View {
    let ask: SessionCardText.TerminalAsk
    var onJump: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .bold))
                Text(ask.heading)
                    .font(Theme.chrome(11, .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.needs)

            Text(ask.subject)
                .font(Theme.code)
                .foregroundStyle(Theme.codeText)
                .lineLimit(4)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)

            Text(SessionCardText.answerThere)
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onJump) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("Jump to terminal")
                        .font(Theme.chrome(12, .semibold))
                }
                .foregroundStyle(Color(red: 0.14, green: 0.09, blue: 0.01))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.needs))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .clickable()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.needs.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.needs.opacity(0.30), lineWidth: 1))
        )
    }
}

/// The state in a word, tinted. One shape for every state, so the colour and
/// the word do the work rather than a different treatment per state.
struct SessionStatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(text)
                .font(Theme.chrome(10.5, .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(tint.opacity(0.14)))
    }
}

/// The agent's mark on a square tinted with the session's state.
struct AgentTile: View {
    let agent: AgentKind
    let tint: Color

    var body: some View {
        AgentGlyphView(agent: agent)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.13))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(tint.opacity(0.3), lineWidth: 1))
            )
            .accessibilityHidden(true)
    }
}

/// Sessions that have ended with nothing waiting on them, one line each, in
/// one card.
///
/// **A line, not a card each.** A finished session used to keep a card the
/// same size as a blocked one, so a tab holding three done sessions and one
/// gate gave equal weight to the three that need nothing. Together under one
/// heading they carry what still matters afterwards — which project, which
/// branch — and get out of the way of whatever does.
struct FinishedSessionsCard: View {
    let sessions: [AgentSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Finished")
                .font(Theme.chrome(10.5, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
            ForEach(sessions) { session in
                FinishedSessionRow(session: session)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.rowFill.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.rowStroke, lineWidth: 1))
        )
    }
}

private struct FinishedSessionRow: View {
    let session: AgentSession
    @Environment(AppModel.self) private var model
    @Environment(RepositoryWidgetModel.self) private var repositories
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            AgentGlyphView(agent: session.agent)
                .scaleEffect(0.8)
                .frame(width: 16, height: 16)
                .opacity(0.75)

            Text(InlineMarkdown.render(SessionCardText.title(of: session), size: 11.5))
                .font(Theme.chrome(11.5, .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            if let repo = repositories.repository(for: session.cwd),
               let branch = repo.status.branch {
                Text(branch)
                    .font(Theme.chrome(10.5))
                    .foregroundStyle(Theme.codeText)
                    .lineLimit(1)
                    .truncationMode(.head)
                if !repo.status.isClean {
                    Text("\(repo.status.changed) changed")
                        .font(Theme.chrome(10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Spacer(minLength: 4)

            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(SessionRowView.compactDuration(max(context.date.timeIntervalSince(session.lastActivity), 60)) + " ago")
                    .font(Theme.chrome(10, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
            Image(systemName: "checkmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Theme.done.opacity(0.8))
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.jump(to: session) }
        .clickable()
        .onHover { hovering in
            withAnimation(MotionEffect.pointer) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(SessionCardText.title(of: session)), finished")
        .accessibilityAction { model.jump(to: session) }
    }
}

/// Per-agent brand glyph. Claude gets an original 8-ray coral spark (drawn
/// here, no embedded assets — evokes the mark, copies nothing); others use
/// SF Symbols until they earn bespoke glyphs.
struct AgentGlyphView: View {
    let agent: AgentKind

    var body: some View {
        switch agent {
        case .claudeCode:
            ClaudeMarkView(size: 15)
        case .codex:
            CodexMarkView(size: 15)
        case .cursor:
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        case .unknown:
            Image(systemName: "circle.dotted")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

