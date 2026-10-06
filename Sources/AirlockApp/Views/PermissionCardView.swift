import SwiftUI
import AirlockCore

/// The approval card — shows the *actual* command or diff, not just a tool name,
/// so you approve with real context. Approve / Deny / Always route straight back
/// to the waiting agent.
struct PermissionCardView: View {
    let session: AgentSession
    let request: PermissionRequest
    @Environment(AppModel.self) private var model
    @Environment(NotchUIState.self) private var uiState
    /// Whether answering from here is paid up. The gate is drawn either way —
    /// only the buttons change.
    @Environment(LicenseModel.self) private var license

    /// The ask, one question at a time, and the answers so far — see
    /// `QuestionWalk`. Rebuilt for every new request; see the `onChange` in
    /// `body`.
    @State private var walk: QuestionWalk
    /// Which labels are ticked on a `multiSelect` question, by question, so
    /// stepping back finds them where they were left. Reset on every new
    /// request.
    @State private var picks: [Int: Set<String>] = [:]
    /// The typed answer, for the rung of the ladder that is a field.
    @State private var draft: String = ""
    @FocusState private var draftFocused: Bool
    /// True for a moment after a newer request took this card in place — see
    /// `settle()`.
    @State private var settling = false
    @State private var settleGeneration = 0

    init(session: AgentSession, request: PermissionRequest) {
        self.session = session
        self.request = request
        _walk = State(initialValue: QuestionWalk(request.questions))
    }

    /// One source of truth for "risky" — the same floor the policy engine uses.
    private var risk: RiskAssessor.Risk? { RiskAssessor.assess(request) }
    private var isRisky: Bool { risk != nil }

    /// Whether THIS card is the one the keys answer.
    ///
    /// **Two sessions waiting used to mean two cards bound to ⌘Y.** A key
    /// equivalent goes to whichever bound view SwiftUI finds first, which is
    /// view order rather than the card being read — so an approval could land
    /// on another session's command. Worse while a card was settling: a
    /// disabled button does not claim its shortcut, so ⌘Y aimed at the card
    /// that had just been promoted fell through to the other session's Approve.
    ///
    /// So exactly one card binds them, named once in `SessionState.focusedGate`
    /// — the first in display order, which is the card at the top of the panel.
    /// Every other card passes `nil` and claims nothing, and this one keeps its
    /// claim while it settles: the answers are swallowed there (see `answer`),
    /// never handed on.
    private var ownsKeys: Bool { model.focusedGate?.requestID == request.id }

    /// A shortcut this card is allowed to claim, or nothing.
    private func key(_ shortcut: KeyboardShortcut) -> KeyboardShortcut? {
        ownsKeys ? shortcut : nil
    }

    /// Whether to PRINT the key equivalents.
    ///
    /// A `.keyboardShortcut` on a panel that is not key never fires, and this
    /// card appears without the panel taking the keyboard (deliberately: see
    /// `NotchController.focusPendingGate`). Printing "⌘Y" while ⌘Y does nothing
    /// is worse than printing nothing, so the labels appear only once the keys
    /// are live — and only on the card that owns them, which is what tells the
    /// reader which card they answer.
    private var showsShortcuts: Bool { uiState.keyboardHeld && ownsKeys }

    var body: some View {
        Group {
            if request.question != nil, let question = liveWalk.current {
                questionCard(question)
            } else {
                permissionCard
            }
        }
        // The walk, the draft and the picks belong to ONE ask. Without this they
        // survive into the next one, and the agent gets an answer assembled
        // from questions nobody read. Out here rather than on the question
        // card, because a newer gate can replace a question with a command and
        // back again without the card ever leaving the screen.
        .onChange(of: request.id) {
            walk = QuestionWalk(request.questions)
            picks = [:]
            draft = ""
            settle()
        }
    }

    /// A newer request in the same session takes the card IN PLACE, under the
    /// pointer, and a click already on its way — aimed at the card you had been
    /// reading — lands on one you have not seen. Every id check agrees it was
    /// meant for the new one, because that is what it hit. So for a moment
    /// after the card changes, its answers answer nothing, and look it.
    ///
    /// Only a change in place: a card that appears where there was none has no
    /// click on its way to it. A generation, so that a third request inside the
    /// window restarts it rather than being cut short by the second's timer.
    private func settle() {
        settleGeneration += 1
        let generation = settleGeneration
        settling = true
        Task { @MainActor in
            try? await Task.sleep(for: Self.settleDelay)
            if settleGeneration == generation { settling = false }
        }
    }

    /// Longer than a click already in flight, shorter than anyone reading the
    /// new card would notice waiting.
    private static let settleDelay: Duration = .milliseconds(600)

    // MARK: - Question ("Claude asks")

    /// `walk`, as of THIS request.
    ///
    /// State outlives a change of request by one update — the `onChange` that
    /// rebuilds it runs after the body has already been drawn — and a card drawn
    /// from the previous ask's walk would show its question under this one's id.
    private var liveWalk: QuestionWalk {
        walk.questions == request.questions ? walk : QuestionWalk(request.questions)
    }

    /// The ticks on the question on screen.
    private var picked: Set<String> { picks[liveWalk.step] ?? [] }

    @ViewBuilder
    private func questionCard(_ question: QuestionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let counter = session.queueCounter {
                queueStrip(counter)
            }
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(question.header ?? "\(session.agent.displayName) asks")
                    .font(Theme.chrome(11, .semibold))
                if question.multiSelect {
                    // The one word that changes what every row below means. A
                    // checkbox is a weak signal on its own — it looks like a
                    // radio button at 12pt — so the mode is stated.
                    Text("Pick any")
                        .font(Theme.label)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if let position = liveWalk.position {
                    Text(position)
                        .font(Theme.label)
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                        .accessibilityLabel("Question \(position)")
                }
                dismissButton
            }
            .foregroundStyle(Theme.running)

            // One subtree per question, so moving on starts the next one clean
            // rather than morphing the last one's rows into it.
            VStack(alignment: .leading, spacing: 8) {
                if let earlier = liveWalk.earlierAnswers {
                    earlierAnswersRow(earlier)
                }

                Text(question.question)
                    .font(Theme.chrome(12, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Group {
                    // The same check the permission card makes. A question
                    // answered from here is answering from here, and it used
                    // to skip the ask the command card showed beside it.
                    if !license.entitlement.allowsUse {
                        subscriptionAsk
                    } else if question.multiSelect {
                        multiSelectOptions(question)
                    } else {
                        singleSelectOptions(question)
                    }
                }
                // Not `.disabled`: see `answer`. The answers are swallowed
                // while settling, so the keys stay claimed by this card.
                .opacity(settling ? 0.45 : 1)
            }
            .id(liveWalk.step)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.running.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.running.opacity(0.28), lineWidth: 1))
        )
    }

    /// What the earlier questions were answered with, and the way back to them.
    ///
    /// Moving on used to leave no trace: the next question replaced the last,
    /// and nothing said the first answer had registered. One quiet line, never
    /// more — a long answer is cut rather than pushing the question down.
    ///
    /// Back lives here, beside the answers it changes, and not in the header,
    /// where it sat against the counter and read as one phrase: "Back 2 of 2".
    private func earlierAnswersRow(_ earlier: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.running.opacity(0.8))
                Text(earlier)
                    .font(Theme.chrome(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Answered: \(earlier)")
            // The full line, for when it was cut.
            .help(earlier)

            Spacer(minLength: 0)

            Button(action: goBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .bold))
                    Text("Back")
                        .font(Theme.chrome(10.5, .semibold))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(minHeight: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.07)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickable()
            // The answers give way to it, never the other way round.
            .fixedSize()
            .keyboardShortcut(key(KeyboardShortcut("[", modifiers: .command)))
            // Said, because "back" usually means "undo", and this keeps every
            // answer already given.
            .help("Back to the previous question. Your other answers are kept.")
        }
    }

    /// Every answer comes through here — a click, a number key, the field,
    /// "None of them" — so each one steps the same way, and only the last one
    /// sends. A single-question ask is the degenerate case: its first answer is
    /// its last, and what is sent is exactly what always was.
    private func choose(_ answer: String) {
        guard !settling else { return }
        var next = liveWalk
        switch next.answer(answer) {
        case .next:
            walk = next
            restoreDraft(next)
        case let .finished(reply):
            walk = next
            model.answer(session, choice: reply)
        }
    }

    /// The card's own answers, guarded in one place.
    ///
    /// **A settling card swallows them rather than being disabled.** Disabling
    /// is what a click needs, and it is exactly wrong for the keys: a disabled
    /// button does not claim its shortcut, so ⌘Y meant for this card used to
    /// fall through to another session's Approve. The buttons still look
    /// unavailable — that is the opacity — and while they are, nothing they can
    /// say is delivered. See `settle()` and `ownsKeys`.
    private func answer(_ decision: PermissionDecision) {
        guard !settling else { return }
        // Which question is on screen, so that dismissing an ask of several
        // leaves an account of the one being read rather than the first.
        model.resolve(session, decision, atQuestion: request.question == nil ? nil : liveWalk.step)
    }

    private func goBack() {
        var previous = liveWalk
        previous.back()
        walk = previous
        restoreDraft(previous)
    }

    /// A typed answer comes back into the field it was typed in. A picked one
    /// needs nothing: its row shows it — see `optionRow`.
    private func restoreDraft(_ walk: QuestionWalk) {
        guard let question = walk.current, !question.multiSelect,
              let answer = walk.currentAnswer,
              !question.options.contains(where: { $0.label == answer }) else {
            draft = ""
            return
        }
        draft = answer
    }

    // MARK: - One answer

    /// Numbered, one-click answers — ⌘1…⌘9 pick without the mouse, once the
    /// panel actually holds the keyboard.
    @ViewBuilder
    private func singleSelectOptions(_ question: QuestionPrompt) -> some View {
        VStack(spacing: 4) {
            ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                let chosen = liveWalk.currentAnswer == option.label
                Button { choose(option.label) } label: {
                    optionRow(index: index, label: option.label, detail: option.detail, chosen: chosen)
                }
                .buttonStyle(.plain)
                .clickable()
                .keyboardShortcut(optionKey(index))
                .accessibilityAddTraits(chosen ? [.isSelected] : [])
            }

            // The last rung is a field, not a choice.
            //
            // Always offered since 2026-10-01. It used to wait for the gate
            // hotkey, on the reasoning that a panel without the keyboard cannot
            // type — but clicking the field TAKES the keyboard
            // (`takeKeyboardForAnswer`), so it was never a dead end.
            //
            // ONE row since B3. A "Neither — I'll say" row above the field
            // opened the field it sat on top of, so the card offered the same
            // answer twice. Its key survives, on a button with no face, so the
            // number after the last option still lands in the field. A
            // question with nothing to pick is this field alone.
            if question.options.count < 9 {
                freeTextRow(placeholder: question.options.isEmpty
                            ? Self.wordsOnlyPlaceholder : Self.wordsPlaceholder)
                    .background {
                        Button {
                            uiState.takeKeyboardForAnswer()
                            draftFocused = true
                        } label: { EmptyView() }
                        .buttonStyle(.plain)
                        .keyboardShortcut(optionKey(question.options.count))
                        .accessibilityHidden(true)
                    }
            }
        }
    }

    /// The field's words: an invitation beside options, the whole answer
    /// where there are none.
    static let wordsPlaceholder = "None of these? Answer in your own words…"
    static let wordsOnlyPlaceholder = "Answer in your own words…"

    private func freeTextRow(placeholder: String) -> some View {
        HStack(spacing: 6) {
            if showsShortcuts, Self.optionShortcut(index: liveWalk.current?.options.count ?? 9) != nil {
                Text("⌘\((liveWalk.current?.options.count ?? 0) + 1)")
                    .font(.system(size: 10 * Theme.textScale, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.running)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.running.opacity(0.16)))
            }
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textPrimary)
                .focused($draftFocused)
                .onSubmit(sendDraft)
                // Clicked straight into: the panel becomes key on its own for a
                // field, but this also marks the keyboard as the gate's, so it
                // is handed back once the card is answered.
                .onChange(of: draftFocused) { _, focused in
                    if focused { uiState.takeKeyboardForAnswer() }
                }

            Button(action: sendDraft) {
                Text("⌘↩")
                    .font(.system(size: 10 * Theme.textScale, weight: .bold, design: .rounded))
                    .foregroundStyle(draft.isEmpty ? Theme.textTertiary : Theme.running)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.running.opacity(draft.isEmpty ? 0 : 0.16)))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .clickable()
            .disabled(draft.isEmpty)
            .keyboardShortcut(key(KeyboardShortcut(.return, modifiers: .command)))
            .accessibilityLabel("Send answer")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        choose(text)
    }

    // MARK: - Several answers

    /// `QuestionPrompt.multiSelect` is parsed and stored by the decoder and has
    /// never been drawn: every ask rendered as one-shot buttons, so "unit tests
    /// and lint but not snapshots" could only be answered in the terminal.
    ///
    /// ⌘1…⌘9 TOGGLE here rather than answering — same keys, different verb,
    /// which is why the mode is spelled out at the top of the card.
    @ViewBuilder
    private func multiSelectOptions(_ question: QuestionPrompt) -> some View {
        VStack(spacing: 4) {
            ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                Button { toggle(option.label) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: picked.contains(option.label)
                              ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(picked.contains(option.label)
                                             ? Theme.running : Theme.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(Theme.chrome(12, .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = option.detail {
                                // Whole — see `optionRow`.
                                Text(detail)
                                    .font(Theme.chrome(10))
                                    .foregroundStyle(Theme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 4)
                        if showsShortcuts, Self.optionShortcut(index: index) != nil {
                            Text("⌘\(index + 1)")
                                .font(.system(size: 10 * Theme.textScale, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.running)
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Theme.running.opacity(0.16)))
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.05)))
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .clickable()
                .keyboardShortcut(optionKey(index))
                .accessibilityAddTraits(picked.contains(option.label) ? [.isSelected] : [])
            }

            HStack(spacing: 6) {
                Button { sendPicked(question) } label: {
                    // "Send" only on the last question, because only the last
                    // one sends — the others move on and keep the ticks.
                    // With nothing ticked it says what it is waiting for, in
                    // readable type. "Send 0" at 40% opacity was a button
                    // nobody could read, saying something nobody could send.
                    (Text(sendLabel)
                     + Text(showsShortcuts && !picked.isEmpty ? " ⌘↩" : "")
                        .foregroundStyle(Color(red: 0.02, green: 0.13, blue: 0.18).opacity(0.55)))
                        .font(Theme.chrome(12, .semibold))
                        .foregroundStyle(picked.isEmpty ? Theme.textSecondary
                                         : Color(red: 0.02, green: 0.13, blue: 0.18))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(picked.isEmpty ? Color.white.opacity(0.06) : Theme.running))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .clickable()
                .disabled(picked.isEmpty)
                .keyboardShortcut(key(KeyboardShortcut(.return, modifiers: .command)))

                // An explicit empty answer, and deliberately NOT Escape.
                // Escape ignores the question — it hands the ask back to the
                // agent's own prompt — and "run none of these" is a different
                // thing to say. Collapsing them would send silence where the
                // user meant no.
                Button { choose("None of them") } label: {
                    Text("None of them")
                        .font(Theme.chrome(12, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .clickable()
            }
            .padding(.top, 2)

            if showsShortcuts {
                Text("esc ignores")
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// "Send 2", "Next (1)" — or, with nothing ticked, what it needs.
    private var sendLabel: String {
        if picked.isEmpty { return Self.pickFirst }
        return liveWalk.isLast ? "Send \(picked.count)" : "Next (\(picked.count))"
    }

    static let pickFirst = "Tick at least one"

    private func toggle(_ label: String) {
        picks[liveWalk.step, default: []].formSymmetricDifference([label])
    }

    /// Joined in the question's own order, not the order they were clicked —
    /// the agent reads this back as prose, and "lint and unit tests" for a list
    /// it wrote as "unit tests, lint" reads like a different answer.
    private func sendPicked(_ question: QuestionPrompt) {
        let ordered = question.options.map(\.label).filter { picked.contains($0) }
        guard !ordered.isEmpty else { return }
        choose(ordered.joined(separator: ", "))
    }

    /// One row of the ladder, shared by the agent's options and the free-text
    /// rung so they cannot drift apart.
    ///
    /// `chosen` marks the answer already given, for a question somebody has
    /// stepped back to.
    private func optionRow(index: Int, label: String, detail: String?, chosen: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showsShortcuts, Self.optionShortcut(index: index) != nil {
                Text("⌘\(index + 1)")
                    // Scaled by hand rather than via `Theme.chrome`, which hardcodes
                    // `design: .default` — this keycap is deliberately rounded, and
                    // a straight conversion would have silently changed the face.
                    .font(.system(size: 10 * Theme.textScale, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.running)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.running.opacity(0.16)))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(Theme.chrome(12, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    // Whole, wrapping. It was cut to one line, and the
                    // description is where an option says what it will
                    // actually do — the part worth reading before picking it.
                    // The height it costs is what the widget region scrolls for.
                    Text(detail)
                        .font(Theme.chrome(10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if chosen {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.running)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(chosen ? Theme.running.opacity(0.12) : Color.white.opacity(0.05)))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// ⌘1…⌘9 for the first nine rows, and nothing at all past them.
    ///
    /// It used to clamp — `min(index + 1, 9)` — so every option from the ninth
    /// on was bound to ⌘9 as well, while the keycap printed for the first nine
    /// only. One key answered several rows, and picked whichever the view
    /// offered it first.
    ///
    /// **The same answer decides whether the keycap is drawn**, so the two
    /// cannot drift into disagreeing again: a row with a key says so, and a row
    /// that says so has one.
    static func optionShortcut(index: Int) -> KeyboardShortcut? {
        guard index < 9 else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
    }

    /// `optionShortcut`, claimed only by the card the keys belong to.
    private func optionKey(_ index: Int) -> KeyboardShortcut? {
        Self.optionShortcut(index: index).flatMap(key)
    }

    // MARK: - Permission

    /// "3 waiting": how many requests this session is holding, this card
    /// included, above everything else on it.
    ///
    /// Its own line, with its own mark, because a question with several parts
    /// counts its steps as "1 of 2" in its header — the same style, on purpose,
    /// and never in the same place, so that a queued question reads as "one of
    /// three requests" and "the first of its two parts" rather than as one
    /// number said twice. It counts down as each is answered, dismissed or
    /// ends; see `AgentSession.queueCounter` for why it no longer counts up.
    private func queueStrip(_ counter: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "square.stack")
                .font(.system(size: 9, weight: .semibold))
            Text(counter)
                .font(Theme.label)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(counter) — this card and the rest of the queue")
    }

    /// Ignoring is a legitimate answer: hand the decision back to the agent's
    /// own prompt (the same path the ask_timeout takes) instead of holding the
    /// island hostage until it expires.
    private var dismissButton: some View {
        Button { answer(.deferred) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                // 20×20 is the macOS minimum control size; this was 18. The
                // glyph stays 9pt — the target grew, not the drawing, so the
                // card looks the same and is easier to hit.
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .keyboardShortcut(key(KeyboardShortcut(.escape, modifiers: [])))
        .help("Ignore — the agent asks in its terminal instead")
        // An X with no name. "Ignore" is what it does; the hint is why that is
        // a real answer rather than a way of losing the request.
        .accessibilityLabel("Ignore")
        .accessibilityHint("Hands the decision back to the agent's own prompt")
        // Ignoring is an answer too — see `settle()` and `answer`.
        .opacity(settling ? 0.45 : 1)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let counter = session.queueCounter {
                queueStrip(counter)
            }
            HStack(alignment: .top, spacing: 6) {
                content
                Spacer(minLength: 4)
                dismissButton
            }

            if let risk {
                riskLine(risk)
            }

            if !license.entitlement.allowsUse {
                subscriptionAsk
            } else {
            HStack(spacing: 6) {
                // A risky request turns the weights round: Deny is the filled
                // button and Approve is outlined in the warning colour. The
                // keys and the order stay put, so a hand that knows ⌘Y is not
                // retrained — only the eye is told which one is the safe one.
                actionButton("Approve", shortcut: showsShortcuts ? "Y" : nil,
                             fg: isRisky ? Theme.danger : Color(red: 0.02, green: 0.15, blue: 0.06),
                             bg: isRisky ? Theme.danger.opacity(0.12) : Theme.done,
                             bordered: isRisky, border: Theme.danger.opacity(0.5)) { answer(.allowOnce) }
                    .keyboardShortcut(key(KeyboardShortcut("y", modifiers: .command)))
                actionButton("Deny", shortcut: showsShortcuts ? "N" : nil,
                             fg: isRisky ? Color(red: 0.08, green: 0.08, blue: 0.09) : Theme.textPrimary,
                             bg: isRisky ? Theme.textPrimary : Color.white.opacity(0.08)) { answer(.deny) }
                    .keyboardShortcut(key(KeyboardShortcut("n", modifiers: .command)))
                // Only where a rule would be honoured. The risk floor is read
                // before any allow rule, so on a risky card "Always" wrote a
                // rule that never fired and the card came back every time.
                if request.offersAlways {
                    actionButton("Always", shortcut: nil, fg: Theme.textSecondary,
                                 bg: .clear, bordered: true) { answer(.alwaysAllow) }
                        .help(rulesInWords
                              ? "Allows \(Self.lowercasedFirst(alwaysRule.summary)) from now on"
                              : "Writes the rule \(alwaysRule.text) — \(alwaysRule.summary.lowercased())")
                }
            }
            .opacity(settling ? 0.45 : 1)

            }

            // What Always is about to write, spelled out. It is broader than
            // the one command in front of you, and a rule you did not read is
            // the wrong way to fix dead rules.
            if let request = session.pendingPermission, request.offersAlways,
               license.entitlement.allowsUse {
                HStack(spacing: 5) {
                    Image(systemName: "text.badge.checkmark")
                        .font(.system(size: 9))
                    if rulesInWords {
                        Text("Always allows \(Self.lowercasedFirst(alwaysRule.summary))")
                    } else {
                        Text("Always writes ")
                            + Text(alwaysRule.text).font(Theme.code)
                    }
                    Spacer(minLength: 0)
                }
                .font(Theme.chrome(10))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(alwaysRule.summary)
                .id(request.id)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.needs.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.needs.opacity(0.30), lineWidth: 1)
                )
        )
    }

    /// Why this card is red, in full view: it was a tooltip on a six-point
    /// dot, and the dot was the only warning on the card that the floor fired.
    private func riskLine(_ risk: RiskAssessor.Risk) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(risk.cardLine)
                .font(Theme.chrome(10.5, .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.danger)
        .accessibilityElement(children: .combine)
    }

    /// The trial is over, an agent is waiting, and this is the moment the
    /// subscription is worth what it costs.
    ///
    /// **The request above stays fully legible, command included.** What is
    /// being sold is answering it FROM HERE, so hiding the thing being answered
    /// would hide the argument.
    ///
    /// The free way out is stated and deliberately unstyled: the request is
    /// still waiting in the agent's own terminal, and saying so costs a sale
    /// that was never going to happen while keeping one that might.
    ///
    /// **It used to promise what the app no longer does** — "Airlock still
    /// watches", "media, sound, calendar, clipboard and the shelf keep working
    /// for good" — beside a panel whose every other widget was locked, and its
    /// "I have a key" opened the purchase window. It now says only what is
    /// true, and the key goes where keys are entered.
    private var subscriptionAsk: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(Self.trialEndedTitle)
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(Self.trialEndedLine(freeWayOut))
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Button { license.showPurchase() } label: {
                    Text("Subscribe")
                        .font(Theme.chrome(12, .semibold))
                        .foregroundStyle(Color(red: 0.02, green: 0.15, blue: 0.06))
                        .padding(.horizontal, 11)
                        .frame(height: 27)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.done))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .clickable()

                Button { Notifications.openSettings?(.license, .licenceKey) } label: {
                    Text("Enter a key")
                        .font(Theme.chrome(12, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 11)
                        .frame(height: 27)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .clickable()

                Spacer(minLength: 4)

                Text("\(License.Period.yearly.price), or \(License.Period.monthly.price)")
                    .font(Theme.chrome(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    static let trialEndedTitle = "Your trial has ended"
    /// Where the request can still be answered for free, then the offer.
    static func trialEndedLine(_ terminal: String) -> String {
        "This is still waiting in \(terminal), and you can answer it there. To answer from the notch, subscribe."
    }

    /// Names the terminal where the request is still waiting, because "answer
    /// it elsewhere" only helps if you know where elsewhere is.
    private var freeWayOut: String {
        TerminalName.pretty(session.terminal?.app ?? session.jumpTarget?.terminalApp)
            .map { "\($0)" } ?? "its terminal"
    }

    @ViewBuilder private var content: some View {
        if let command = request.command {
            HStack(alignment: .top, spacing: 6) {
                if isRisky {
                    // Six points of colour beside the command, which is tinted
                    // the same hue. The reason is said in words under it
                    // (`riskLine`) — it was only this dot's tooltip, so the
                    // floor firing was legible only to people who can see red.
                    Circle().fill(Theme.danger).frame(width: 6, height: 6).padding(.top, 5)
                        .accessibilityHidden(true)
                }
                // Hard cap: agents pass entire documents inside commands
                // (heredocs, gh pr --body …). The island shows the head —
                // enough to decide — and must never become a wall of text.
                Text(command)
                    .font(Theme.code)
                    .foregroundStyle(isRisky ? Theme.danger : Theme.codeText)
                    .textSelection(.enabled)
                    .lineLimit(5)
                    .truncationMode(.tail)
            }
        } else if let diff = request.diff {
            Text(diff)
                .font(Theme.code)
                .foregroundStyle(Theme.codeText)
                .lineLimit(6)
                .truncationMode(.tail)
        } else {
            Text(request.summary)
                .font(Theme.chrome(12, .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    /// Whether Always is described rather than quoted.
    ///
    /// An MCP tool's rule is its machine name — for a claude.ai connector,
    /// `mcp__<uuid>__trelloWriteCard` — which is the text the policy file needs
    /// and says nothing to the person about to click. What the rule covers,
    /// "any use of Trello: write card", is the part worth reading, and it is
    /// the whole of it: a tool-wide rule has no pattern to hide.
    private var rulesInWords: Bool { ToolPhrase.isMCP(request.toolName) }

    private static func lowercasedFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }

    /// Exact when nothing safe generalises — see `RuleGeneralizer`.
    private var alwaysRule: RuleCandidate {
        guard let request = session.pendingPermission else {
            return RuleCandidate(text: "", summary: "", isExact: true)
        }
        return RuleGeneralizer.recommended(for: request)
    }

    private func actionButton(
        _ title: String, shortcut: String?, fg: Color, bg: Color, bordered: Bool = false,
        border: Color = Color.white.opacity(0.14), action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            (Text(title) + Text(shortcut.map { " ⌘\($0)" } ?? "").foregroundStyle(fg.opacity(0.55)))
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(fg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(bg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(bordered ? border : .clear, lineWidth: 1)
                        )
                )
                // INSIDE the label, not outside the Button. `.buttonStyle(.plain)`
                // hit-tests the label's content, and a `.background` does not
                // extend that — so Approve/Deny/Always only clicked on their
                // text, with the padded rectangle around it inert. The option
                // rows above always had this; these three never did, and the
                // pointing-hand cursor is what finally made the dead zone
                // visible.
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
    }
}
