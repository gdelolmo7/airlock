import SwiftUI
import AirlockCore

/// First run, taught on the surface being taught.
///
/// The window version (`OnboardingView`) exists because an `LSUIElement` app
/// shows a first-timer nothing. But a 640×560 window explaining a notch panel is
/// still explaining it somewhere else, and step one's whole job is "it's up
/// there" — a sentence that answers itself the moment the wizard runs *in* the
/// panel. The tab strip is right there above this view; the hotkeys in
/// `features` can be pressed while it is open.
///
/// Two costs, both paid deliberately:
///
/// 1. **The prose is a third the length.** The panel's height budget is ~420pt
///    against the window's 560, and the widget stack is not competing for it
///    only because this view replaces it outright. Every string here is shorter
///    than its window counterpart on purpose — this is not the same copy
///    reflowed.
/// 2. **It must pin the panel open.** `IslandPresentation.Holds.onboarding` is
///    that pin, and `NotchController` owns setting and clearing it. Without it
///    the collapse timer eats the wizard mid-sentence.
///
/// Everything else is shared: this drives the *same* `OnboardingModel` the
/// window does, so hooks installed here are installed there, and the completion
/// flag is settled in one place. No second copy of the logic, and no second copy
/// of its bugs.
struct PanelOnboardingView: View {
    @Environment(OnboardingModel.self) private var model
    @Environment(NotchUIState.self) private var uiState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The same budget the widget stack gets. Passed rather than measured so a
    /// long agents list scrolls inside the wizard instead of growing the panel
    /// past the bottom of the screen.
    let maxContentHeight: CGFloat
    /// The tabs the strip above is showing right now, so the welcome step
    /// describes exactly those — it used to say "Four tabs" over five.
    let tabs: [NotchTab]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    if model.isResuming {
                        // A setup left halfway, back after a quit: say why it
                        // did not start at the welcome. Gone after one move.
                        Label("Picking up where you left off.", systemImage: "arrow.uturn.forward")
                            .font(Theme.chrome(10.5))
                            .foregroundStyle(Theme.textTertiary)
                    }

                    heading

                    stepContent
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: maxContentHeight)

            // Outside the scroll, so it is on screen however long the list
            // of tabs above it: leaving this step counts as having been
            // asked, so the question must not be below the fold.
            if model.step == .welcome, model.offersUsageCounts {
                UsageCountsSetupRow(isOn: Binding(get: { model.sharesUsageCounts },
                                                  set: { model.sharesUsageCounts = $0 }))
            }

            footer
        }
        .padding(.horizontal, 10)
        .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: model.stepIndex)
    }

    // MARK: - Chrome

    /// "setup · 2 of 5", and the way out.
    ///
    /// The counter is `OnboardingPlan.position` rather than arithmetic here —
    /// the window prints the same number, and an off-by-one in only one of them
    /// is the kind of thing nobody notices twice.
    private var header: some View {
        HStack(spacing: 6) {
            Text("setup · \(model.plan.position) of \(model.stepCount)")
                .font(Theme.label)
                .foregroundStyle(Theme.textTertiary)

            Spacer(minLength: 8)

            // Always available, on every step. A wizard you cannot leave is a
            // panel that does nothing until you finish it, and this one is
            // standing where the app itself normally is.
            Button { model.finish() } label: {
                Text("Skip setup")
                    .font(Theme.chrome(11, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .clickable()
            .help("Leave setup — the Agents tab and Settings can finish it later")
        }
    }

    /// The teaser plus the primary action.
    ///
    /// The teaser names what the next step is *for*, because the reason to press
    /// Next is the only thing a step cannot tell you about itself.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let teaser {
                Text(teaser)
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                if !model.isFirst {
                    Button { model.retreat() } label: {
                        Text("Back")
                            .font(Theme.chrome(12, .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .clickable()
                }

                Spacer(minLength: 0)

                primaryButton
            }
        }
    }

    /// `↩` is printed only when the panel actually holds the keyboard.
    ///
    /// The same rule every keycap in the panel follows: a `.keyboardShortcut`
    /// on a panel that is not key never fires, so printing the key when it is
    /// not held would be advertising something that does nothing.
    private var primaryButton: some View {
        Button { model.advance() } label: {
            Text(model.isLast ? "Done" : (uiState.keyboardHeld ? "Next ↩" : "Next"))
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                        )
                )
                // Inside the label, not outside the Button — `.buttonStyle(.plain)`
                // hit-tests the label's content and a `.background` does not
                // extend it. See `PermissionCardView.actionButton`.
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
        .keyboardShortcut(.defaultAction)
    }

    /// The title and the blurb, with the cloud beside them on the pages that
    /// have one. Beside rather than above, so the pages that gain a face
    /// spend none of the height budget on it.
    @ViewBuilder private var heading: some View {
        let words = VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.chrome(13, .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text(blurb)
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let face = Self.face(for: model.step) {
            HStack(spacing: 12) {
                BloubView(expression: face, motion: .breathing, tint: BloubTint.working.color)
                    .frame(width: 34, height: 34)
                words
            }
        } else {
            words
        }
    }

    /// Only the two pages that open and close setup get the cloud: pleased to
    /// meet you, and pleased with how it went. The three between are lists of
    /// things to do, where a face would sit beside work it has no part in.
    static func face(for step: OnboardingPlan.Step) -> BloubExpression? {
        switch step {
        case .welcome: .excited
        case .finish: .proud
        case .agents, .features, .permissions: nil
        }
    }

    // MARK: - Copy

    private var title: String {
        switch model.step {
        case .welcome: "This is Airlock"
        case .agents: "Connect your agents"
        case .features: "The keys that reach it"
        case .permissions: "What macOS will ask"
        case .finish: "That's setup"
        }
    }

    /// A third the length of the window's, and written for someone already
    /// looking at the thing being described — so no locator, no "up there".
    private var blurb: String {
        switch model.step {
        case .welcome:
            "You're looking at it. What each tab above is for:"
        case .agents:
            "Connect them and the Agents tab starts filling in. Skip, and the clipboard, files, "
                + "dictation and call notes all work without them."
        case .features:
            "These reach the notch while it's closed."
        case .permissions:
            "Each one is optional, and macOS asks, not Airlock."
        case .finish:
            "Everything here can be changed in Settings, behind the gear above. "
                + "This guide is in the menu bar if you want it again."
        }
    }

    private var teaser: String? {
        switch model.step {
        case .welcome: "Next: connecting your agents, so they can stop and ask you something."
        case .agents: "Next: the keys that reach the notch when it's closed — clipboard, hold to talk, typing a question."
        case .features: "Next: your calendar, and the question macOS asks the first time you jump to a terminal."
        case .permissions: "Next: the last step."
        case .finish: nil
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .welcome: WelcomePanelStep(tabs: tabs)
        case .agents: AgentsPanelStep()
        case .features: FeaturesPanelStep()
        case .permissions: PermissionsPanelStep()
        case .finish: FinishPanelStep()
        }
    }
}

// MARK: - Welcome

/// What each tab is, one line each. The window's version has to draw a
/// picture of the notch; here the picture is the frame around it.
///
/// From the tabs actually on show, with each tab's own symbol and name, so
/// the list cannot drift from the strip: no count to go stale, and a tab
/// switched off is not described.
struct WelcomePanelStep: View {
    let tabs: [NotchTab]

    /// Exhaustive on purpose: a new tab does not compile until it says what
    /// it is for.
    static func detail(_ tab: NotchTab) -> String {
        switch tab {
        case .home: "Music, sound, battery and the Mac's quick switches"
        case .dashboard: "Your next meetings, and how busy the Mac is"
        case .tray: "Drop files here to move them somewhere else"
        case .clipboard: "Everything you copied, searchable"
        case .calls: "Your last calls, and the notes from each"
        case .agents: "Approve, deny and answer your coding agents"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(tabs) { tab in
                HStack(spacing: 9) {
                    // Home is the cloud in the strip (`NotchTopBar`), so it is
                    // the cloud here too: a house would describe a tab nobody
                    // can find. Still and grey, as the strip draws it when it
                    // is not the one open.
                    if tab == .home {
                        BloubView(expression: .attentive, tint: Theme.textSecondary)
                            .frame(width: 16, height: 14)
                    } else {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 16)
                    }
                    Text(tab.label)
                        .font(Theme.chrome(12, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 74, alignment: .leading)
                    Text(Self.detail(tab))
                        .font(Theme.chrome(11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.rowFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.rowStroke, lineWidth: 1)
                )
            }
        }
    }
}

/// "Share usage counts?" on the first screen, off unless switched on. The
/// crash reports row's shape, at panel density.
struct UsageCountsSetupRow: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "chart.bar")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Share usage counts?")
                    .font(Theme.chrome(12, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(UsageCountsSection.subtitle)
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Share usage counts")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.rowFill))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.rowStroke, lineWidth: 1)
        )
    }
}

// MARK: - Agents

private struct AgentsPanelStep: View {
    @Environment(OnboardingModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.hasDeclinedAgents {
                declined
            } else {
                ForEach(model.agents) { row in
                    PanelAgentRow(row: row)
                }

                HStack(spacing: 10) {
                    if model.installableCount > 1 {
                        Button("Connect all \(model.installableCount)") { model.installAll() }
                            .buttonStyle(.plain)
                            .font(Theme.chrome(11, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .clickable()
                    }

                    // The answer the step would otherwise have no way to give.
                    // Skip postpones; this one answers, and leaves no Agents tab
                    // sitting permanently empty.
                    Button("I don't use coding agents") { model.declineAgents() }
                        .buttonStyle(.plain)
                        .font(Theme.chrome(11))
                        .foregroundStyle(Theme.textTertiary)
                        .clickable()

                    Spacer(minLength: 0)
                }
                .padding(.top, 1)

                Label("With Airlock closed, your agents behave exactly as they do now.",
                      systemImage: "checkmark.shield")
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var declined: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Agents are off.")
                .font(Theme.chrome(12, .medium))
                .foregroundStyle(Theme.textPrimary)
            Text("The Agents tab, the session icons beside the notch and the usage figures are hidden. "
                 + "Clipboard, shelf, dictation, calendar and media work as before.")
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Actually, I do use them") { model.reconsiderAgents() }
                .buttonStyle(.plain)
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .clickable()
                .padding(.top, 1)
        }
        // Full width, like the agent rows it replaces — it used to shrink to
        // its text and sit narrower than everything else in the step.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.rowFill))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.rowStroke, lineWidth: 1)
        )
    }
}

/// One agent, at panel density. The window's card is 13pt padding and a 19pt
/// glyph; this is the same three states in about half the height.
private struct PanelAgentRow: View {
    @Environment(OnboardingModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let row: SettingsModel.AgentRow

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 13))
                .foregroundStyle(installed ? Theme.done
                                 : (conflictReason == nil ? Theme.textTertiary : Theme.needs))
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(Theme.chrome(12, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.chrome(10))
                    .foregroundStyle(conflictReason == nil ? Theme.textTertiary : Theme.needs)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            switch row.status {
            case .installed:
                Text("Connected")
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textTertiary)
            case .notInstalled:
                chip("Connect") { model.install(row) }
            case .conflict:
                // Both answers, same as the window: showing the file is only
                // half of it. Without a re-read the row goes on saying
                // "conflict" after the user has already fixed it — until the
                // next launch, which is the worst moment to find out it worked.
                HStack(spacing: 5) {
                    chip("Check again") { model.settings.refresh() }
                    chip("Show the file") { model.settings.revealConfig(row) }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.rowFill))
        .overlay(
            // A conflict is the one row that blocks the step — it is why
            // `OnboardingPlan.shouldPresent` refuses to suppress first run — so
            // it is tinted rather than left looking untouched.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(conflictReason != nil ? Theme.needs.opacity(0.45)
                              : (installed ? Theme.done.opacity(0.32) : Theme.rowStroke),
                              lineWidth: 1)
        )
        // Installing is something done: a Confirm.
        .animation(Motion.confirm.animation(reduceMotion: reduceMotion), value: installed)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
    }

    private var installed: Bool { row.status == .installed }

    private var conflictReason: String? {
        if case .conflict(let reason) = row.status { return reason }
        return nil
    }

    /// A failed install's error outranks everything — it is the only text here
    /// that says why nothing happened when the button was pressed.
    private var detail: String {
        if let error = row.actionError { return error }
        return OnboardingAgentText.detail(row.status)
    }
}

// MARK: - Features

/// The three that are off, invisible, or both — and the keys that reach them.
///
/// Every binding is read through to the live model rather than mirrored: these
/// are user-configurable, and a guide that prints the default while the app
/// listens for something else is worse than one that stays quiet.
private struct FeaturesPanelStep: View {
    @Environment(OnboardingModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 5) {
            row(symbol: "mic", name: "Hold to talk", key: model.holdKeyName,
                detail: model.dictationEnabled ? "On" : "Off — turning it on starts the model download") {
                Toggle("", isOn: Binding(get: { model.dictationEnabled },
                                         set: { model.setDictationEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            // Asked here as well as in the window, because either wizard can be
            // the only one somebody sees — and dictation that hears one language
            // fails silently in the other. See `SecondLanguageRow` in
            // OnboardingView for the whole reason.
            row(symbol: "globe", name: "Second language", key: nil, detail: secondLanguageDetail) {
                Picker("", selection: $model.secondDictationLanguage) {
                    Text("Off").tag("")
                    if let suggestion = model.suggestedSecondLanguage {
                        Divider()
                        Text(suggestion.name).tag(suggestion.id)
                    }
                    Divider()
                    ForEach(otherLanguages) { language in
                        Text(language.name).tag(language.id)
                    }
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(maxWidth: 132)
                .disabled(!model.dictationEnabled)
            }

            if let ask = model.askKeyName {
                row(symbol: "sparkles", name: "Ask", key: ask, detail: "Ask about what's on your screen")
            }

            row(symbol: "doc.on.clipboard", name: "Clipboard",
                key: model.clipboardHotkeyEnabled ? model.clipboardHotkeyName : nil,
                detail: model.clipboardHotkeyEnabled ? "Opens the history from anywhere"
                                                     : "Hotkey off — the tab still works")
        }
    }

    /// Listed once: two entries with the same tag leave the selection ambiguous.
    private var otherLanguages: [OnboardingModel.SpokenLanguage] {
        let suggested = model.suggestedSecondLanguage?.id
        return model.dictationLanguages.filter { $0.id != suggested }
    }

    /// One line, because the row truncates at one — so the state comes first and
    /// the reasoning is left to the window wizard.
    private var secondLanguageDetail: String {
        guard model.dictationEnabled else { return "Turn dictation on first" }
        guard !model.secondDictationLanguage.isEmpty else {
            if let suggestion = model.suggestedSecondLanguage {
                return "Off — this Mac also uses \(suggestion.name)"
            }
            return "Off — hears \(model.dictationPrimaryName) only"
        }
        let chosen = model.dictationLanguages.first { $0.id == model.secondDictationLanguage }
        // The installed list can be empty (no speech assets yet, or the gallery),
        // and a raw code like `es_ES` is not a language anyone speaks.
        let id = model.secondDictationLanguage
        return "Also hears \(chosen?.name ?? SpokenLanguages.name(id) ?? id)"
    }

    @ViewBuilder
    private func row<Accessory: View>(symbol: String, name: String, key: String?, detail: String,
                                      @ViewBuilder accessory: () -> Accessory = { EmptyView() })
    -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(name)
                        .font(Theme.chrome(12, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    if let key { Keycap(key) }
                }
                Text(detail)
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)
            accessory()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.rowFill))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.rowStroke, lineWidth: 1)
        )
    }
}

/// 10pt bold **rounded** — deliberately not `Theme.chrome`, per the handoff.
private struct Keycap: View {
    private let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
    }
}

// MARK: - Permissions

/// The one step the handoff argued belongs in the window, because both rows
/// raise a dialog of macOS's own.
///
/// It stays here, and the reason it can is `Holds.onboarding`: the pin does not
/// depend on focus, so the panel is still open behind the system prompt and
/// still open after it. What the step does NOT do is pretend to be that prompt —
/// each row says who is about to ask, so a dialog appearing over the panel reads
/// as the consequence of the button rather than as something the app did.
private struct PermissionsPanelStep: View {
    @Environment(OnboardingModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let problem = model.calendarCard, problem.isProblem {
                // Refused (or otherwise stuck): the same card and button the
                // calendar widget and Settings show, so "Ask macOS" no longer
                // sits there doing nothing after a no. Next carries on.
                ProblemCard(icon: "calendar", sentence: problem.sentence,
                            button: problem.remedy.button,
                            action: problem.remedy == .nothing ? nil : { model.performCalendarRemedy() })
                Text(OnboardingAgentText.calendarLater(next: "Next"))
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                card(symbol: "calendar", name: "Calendar",
                     detail: model.calendarGranted ? "Granted — the next meeting shows beside the notch"
                                                   : "Shows what's next, and nothing leaves the Mac",
                     granted: model.calendarGranted,
                     action: model.calendarGranted ? nil : ("Ask macOS", { model.performCalendarRemedy() }))
            }

            // Not a prompt we can raise — it appears on the first jump, from
            // whichever terminal you jump into. Saying so now is the whole
            // point: it is otherwise a dialog out of nowhere, weeks later. No
            // button: there is nothing to do until then.
            card(symbol: "terminal", name: "Automation",
                 detail: OnboardingAgentText.automation,
                 granted: false,
                 action: nil)

            // Not a permission, but asked about here for the same reason: it
            // is a switch in System Settings that something here depends on.
            // Call notes are written by it on Free, so a Mac with it off finds
            // out now rather than after a call comes back with no notes.
            let ai = model.appleIntelligence
            card(symbol: "apple.intelligence", name: "Apple Intelligence", tag: ai.tag,
                 detail: ai.detail, granted: ai.isOn,
                 action: ai.button.map { button in (button.title, { model.performAppleIntelligenceButton() }) })
        }
        // A Calendar switch flipped in System Settings ticks here without a
        // click back into the panel.
        .watchingPermissions { _ in model.calendar.recheckAuthorization() }
        // Apple Intelligence changes nothing `watchingPermissions` reads, and
        // finishing a download is not a switch at all, so it is looked at
        // again on its own, every two seconds while this step shows.
        .task {
            model.recheckAppleIntelligence()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                model.recheckAppleIntelligence()
            }
        }
    }

    @ViewBuilder
    private func card(symbol: String, name: String, tag: String? = nil, detail: String, granted: Bool,
                      action: (String, () -> Void)?) -> some View {
        HStack(spacing: 9) {
            Image(systemName: granted ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 13))
                .foregroundStyle(granted ? Theme.done : Theme.textSecondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name)
                        .font(Theme.chrome(12, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    if let tag {
                        Text(tag)
                            .font(Theme.chrome(10.5, .semibold))
                            .foregroundStyle(Theme.needs)
                    }
                }
                Text(detail)
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            if let (title, run) = action {
                Button(action: run) {
                    Text(title)
                        .font(Theme.chrome(11, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.10)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .clickable()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.rowFill))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(granted ? Theme.done.opacity(0.32)
                                  : tag != nil ? Theme.needs.opacity(0.45) : Theme.rowStroke, lineWidth: 1)
        )
    }
}

// MARK: - Finish

private struct FinishPanelStep: View {
    @Environment(OnboardingModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Only for a bundled copy. Offering it from a debug build writes a
            // login item pointing at a path that will not exist tomorrow.
            if model.isBundled {
                HStack(spacing: 9) {
                    Image(systemName: "power")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Open at login")
                            .font(Theme.chrome(12, .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text("An agent can only interrupt you if Airlock is running.")
                            .font(Theme.chrome(10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 6)
                    Toggle("", isOn: Binding(get: { model.launchAtLogin },
                                             set: { model.setLaunchAtLogin($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.rowFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.rowStroke, lineWidth: 1)
                )
            }

            // Asked once, here, and off unless switched on. Only in a build
            // that could send a report: the switch is a promise about where
            // a crash goes, and a build without a DSN sends nothing anywhere.
            if model.offersCrashReports {
                HStack(spacing: 9) {
                    Image(systemName: "ladybug")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Send crash reports?")
                            .font(Theme.chrome(12, .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text("When Airlock crashes, a report helps us fix it. Nothing personal is included.")
                            .font(Theme.chrome(10))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Toggle("", isOn: Binding(get: { model.sendsCrashReports },
                                             set: { model.sendsCrashReports = $0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .accessibilityLabel("Send crash reports")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.rowFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.rowStroke, lineWidth: 1)
                )
            }

            // The same words the window's finish step uses, at panel
            // density. It has to be in BOTH: first run goes through the panel,
            // and the window is only reached from the menu bar afterwards — so
            // the panel is the one most people will actually read. There is no
            // trial to announce: a new copy starts on Free.
            VStack(alignment: .leading, spacing: 3) {
                Text(PlanSetupNote.title)
                    .font(Theme.chrome(12, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(PlanSetupNote.detail)
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.rowFill))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.rowStroke, lineWidth: 1)
            )
        }
    }
}

/// The words both wizards share for an agent row and the permissions step,
/// so the window and the panel cannot drift apart.
enum OnboardingAgentText {
    /// Plain words for an agent's state. The row used to show the agent's
    /// settings file path, and a conflict as "Something else owns its notify
    /// entry" — words for whoever wrote the installer, not for the reader.
    static func detail(_ status: HookInstallStatus) -> String {
        switch status {
        case .installed: "Shows up in the notch while it works."
        case .notInstalled: "Not connected yet."
        case .conflict:
            "Its settings file already has Airlock lines that Airlock didn't write. "
                + "Delete them, then check again."
        }
    }

    static let automation =
        "macOS asks the first time you jump to a terminal. Say yes, and the jump works from then on."

    /// Under a refused Calendar: the step is not a dead end.
    static func calendarLater(next: String) -> String {
        "Or press \(next) and turn it on later in Settings › \(SettingsPane.permissions.title)."
    }
}
