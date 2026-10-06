import SwiftUI
import AirlockCore

/// The first-run window.
///
/// Native system appearance rather than the notch theme, for the same reason
/// Settings is: this is an ordinary macOS window and should read as one. The
/// notch's own palette belongs to the notch.
struct OnboardingView: View {
    @Environment(OnboardingModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// In a snapshot the whole step is drawn at its own height, since a
    /// picture cannot scroll to the part below the fold.
    @Environment(\.onboardingFlatGlass) private var snapshot

    var body: some View {
        VStack(spacing: 0) {
            if snapshot {
                page
            } else {
                ScrollView { page }
                    .scrollBounceBehavior(.basedOnSize)
            }

            Divider()
            controls
        }
        .frame(width: 640, height: snapshot ? nil : 560)
        // Steps cross-fade rather than slide: a wizard that slides implies more
        // ceremony than five screens deserve. A new step is a Swap.
        .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: model.stepIndex)
    }

    private var page: some View {
        VStack(spacing: 20) {
            hero
            content
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
        .padding(.top, 30)
        .padding(.bottom, 26)
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        VStack(spacing: 14) {
            if model.step == .welcome {
                NotchLocator()
                    .frame(width: 232, height: 132)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 76, height: 76)
                    .onboardingGlassCircle()
            }

            VStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
        }
        .id(model.step) // so the cross-fade actually has something to fade
        .transition(.opacity)
    }

    private var symbol: String {
        switch model.step {
        case .welcome: return "sparkles"
        case .agents: return "point.3.connected.trianglepath.dotted"
        case .features: return "keyboard"
        case .permissions: return "lock.shield"
        case .finish: return model.anyHookInstalled ? "checkmark.circle" : "hand.wave"
        }
    }

    private var title: String {
        switch model.step {
        case .welcome: return "Welcome to Airlock"
        case .agents: return "Connect your agents"
        case .features: return "The rest of it"
        case .permissions: return "Optional permissions"
        case .finish: return model.anyHookInstalled ? "You're set up" : "Almost there"
        }
    }

    private var subtitle: String {
        switch model.step {
        case .welcome:
            return "Your notch becomes a control surface for terminal coding agents — "
                + "approve what they want to run, see what they're doing, and jump back to the terminal."
        case .agents:
            return "Connect your coding agents so they can ask you from the notch. "
                + "Nothing else here matters until this is done."
        case .features:
            return "Three things the notch does that have nothing to do with agents — "
                + "and the keys that reach them."
        case .permissions:
            return "Each one is optional — the app works without them, and you can change "
                + "your mind any time in Settings › \(SettingsPane.permissions.title)."
        case .finish:
            return model.anyHookInstalled
                ? "Start an agent in your terminal and the notch will come alive on its own."
                : "You skipped connecting an agent, so the notch will show your widgets but no sessions. "
                    + "Settings › \(SettingsPane.agents.title) has the same buttons whenever you want them."
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .agents: AgentsStep()
        case .features: FeaturesStep()
        case .permissions: PermissionsStep()
        case .finish: FinishStep()
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            StepDots(count: model.stepCount, current: model.stepIndex)

            Spacer()

            if !model.isFirst {
                Button("Back") { model.retreat() }
                    .onboardingGlassButton()
            }
            if !model.isLast {
                // "Skip setup", not "Skip": this dismisses the whole thing, and
                // beside a Continue button the short label reads as "skip this
                // step". Setup is skippable at all because refusing to let
                // someone past would make a background utility hold the screen
                // hostage — the menu bar keeps the guide reachable afterwards.
                Button("Skip setup") { model.finish() }
                    .onboardingGlassButton()
            }
            Button(primaryLabel) { model.advance() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var primaryLabel: String {
        switch model.step {
        case .finish: return "Done"
        case .agents where model.anyHookInstalled: return "Continue"
        default: return "Continue"
        }
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 10) {
            Row(symbol: "bell.badge",
                title: "It asks before anything risky runs",
                detail: "Approve or deny from the notch, or set rules that decide for you.")
            Row(symbol: "arrow.uturn.backward",
                title: "It gets you back to the terminal",
                detail: "One click jumps to the exact iTerm tab or tmux pane a session is running in.")
            Row(symbol: "mic",
                title: "It types what you say",
                detail: "Hold a key anywhere, speak, let go. Transcribed and tidied up on this "
                    + "Mac, in any of 30 languages — two of them at once if you switch mid-sentence.")
            Row(symbol: "tray.full",
                title: "It holds your files and your day",
                detail: "A drop shelf, clipboard history, calendar and what's playing, all in the notch.")
        }
    }

    struct Row: View {
        let symbol: String, title: String, detail: String

        var body: some View {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        }
    }
}

/// A MacBook lid with its notch called out, because "it's in your notch" is
/// meaningless until you have looked at the right part of the screen once.
private struct NotchLocator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    /// Emphasised whenever the pulse would have it emphasised, and held there
    /// when the pulse is switched off — see the note at the glyph.
    private var emphasised: Bool { reduceMotion || pulse }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            let notchW = w * 0.23, notchH = h * 0.115

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.tertiary, lineWidth: 1)
                    }

                NotchGlyph()
                    .fill(.tint)
                    .frame(width: notchW, height: notchH)
                    // Reduce Motion gets a STATIC emphasised pose, not the
                    // resting one. This is the first screen a new user sees and
                    // the pulse is the only thing pointing at the notch — stop
                    // it at rest and the illustration no longer says "here".
                    // So it holds at the lit end: bright halo, enlarged glyph,
                    // simply not moving.
                    .shadow(color: .accentColor.opacity(emphasised ? 0.55 : 0.15),
                            radius: emphasised ? 13 : 4)
                    .scaleEffect(x: emphasised ? 1.5 : 1, y: emphasised ? 1.9 : 1, anchor: .top)
            }
            .frame(width: w, height: h)
        }
        .animation(Theme.perpetual(MotionEffect.breathe, reduceMotion: reduceMotion),
                   value: pulse)
        .id(reduceMotion)
        .onAppear { pulse = true }
        .accessibilityLabel("The notch at the top centre of your screen")
    }
}

/// Square on top where it meets the bezel, rounded below — the shape of the
/// housing, near enough at this size.
private struct NotchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect,
             cornerRadii: RectangleCornerRadii(bottomLeading: rect.height * 0.45,
                                               bottomTrailing: rect.height * 0.45))
    }
}

// MARK: - Agents

private struct AgentsStep: View {
    @Environment(OnboardingModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            if model.hasDeclinedAgents {
                declined
            } else {
                ForEach(model.agents) { row in
                    AgentCard(row: row)
                }

                if model.installableCount > 1 {
                    Button("Connect all \(model.installableCount)") { model.installAll() }
                        .onboardingGlassButton()
                }

                Label {
                    Text("If Airlock isn’t running, your agents behave exactly as they do today. "
                         + "Disconnecting is one button in Settings.")
                } icon: {
                    Image(systemName: "checkmark.shield")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

                // The answer the step never offered. Without it the only way
                // past was Skip, which postpones rather than answers — and
                // leaves an Agents tab that stays empty forever.
                Button("I don't use coding agents") { model.declineAgents() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    private var declined: some View {
        VStack(spacing: 9) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("Agents are off.")
                .font(.system(size: 13, weight: .medium))
            Text("The Agents tab, the session icons beside the notch and the Claude usage figures are hidden. "
                 + "Everything else — the clipboard, the shelf, dictation, calendar and media — works as before.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Actually, I do use them") { model.reconsiderAgents() }
                .onboardingGlassButton()
                .padding(.top, 2)
        }
        .padding(.vertical, 6)
    }
}

private struct AgentCard: View {
    @Environment(OnboardingModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let row: SettingsModel.AgentRow

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 19))
                .foregroundStyle(installed ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(conflictReason == nil ? AnyShapeStyle(.secondary)
                                                           : AnyShapeStyle(Color.orange))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            switch row.status {
            case .installed:
                Text("Connected").font(.system(size: 12)).foregroundStyle(.secondary)
            case .notInstalled:
                Button("Connect") { model.install(row) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            case .conflict:
                // BOTH real answers. Showing the file is only half of it: the
                // fix happens in another app, and without a way to re-read the
                // config the step goes on saying "conflict" after you have
                // already resolved it — until the next launch, which is the
                // worst possible moment to find out it worked.
                HStack(spacing: 8) {
                    Button("Check again") { model.settings.refresh() }
                    Button("Show the file") { model.settings.revealConfig(row) }
                        .onboardingGlassButton()
                }
            }
        }
        .padding(13)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .overlay {
            // A conflict is the one row that blocks the step — it is why
            // `OnboardingPlan.shouldPresent` refuses to suppress first run — so
            // it is tinted rather than left looking like a row nobody has got
            // to yet.
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(conflictReason != nil ? Color.orange.opacity(0.45)
                              : (installed ? Color.green.opacity(0.32) : .clear),
                              lineWidth: 1)
        }
        // Installing is something done: a Confirm.
        .animation(Motion.confirm.animation(reduceMotion: reduceMotion), value: installed)
    }

    private var installed: Bool { row.status == .installed }

    private var conflictReason: String? {
        if case .conflict(let reason) = row.status { return reason }
        return nil
    }

    /// The error from a failed install outranks everything: it is the only text
    /// here that tells you why nothing happened when you pressed the button.
    private var detail: String {
        if let error = row.actionError { return error }
        return OnboardingAgentText.detail(row.status)
    }
}

// MARK: - Features

/// Dictation, clipboard history and the approval policy — each with the keys
/// that reach it, because all three are otherwise invisible.
private struct FeaturesStep: View {
    @Environment(OnboardingModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            FeatureCard(symbol: "mic", title: "Dictate anywhere") {
                Toggle("", isOn: Binding(get: { model.dictationEnabled },
                                         set: { model.setDictationEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            } content: {
                // ONE literal, continued with `\`. That matters: only a literal
                // resolves to Text(LocalizedStringKey), which is what makes
                // `\(Text(…))` and markdown work. Build the same sentence with
                // `+` between strings and it resolves to Text(String) instead —
                // markdown goes dead and the interpolated view stringifies into
                // `Text(storage: SwiftUI.Text.Storage.verbatim("⌃ Control"), …)`,
                // printed in the middle of the paragraph.
                Text("""
                Hold \(Text(model.holdKeyName).fontWeight(.medium)) anywhere, speak, let go — \
                the words are typed at your cursor. Transcribed **and** tidied up entirely on \
                this Mac, so nothing leaves it. Settings › \(SettingsPane.voice.title) changes the \
                key and picks the microphone.
                """)
                KeyRow(keys: [model.holdKeyName], label: "hold to talk, release to insert")
                if let askKey = model.askKeyName {
                    KeyRow(keys: [askKey], label: "hold this one instead to ask a question")
                }
                SecondLanguageRow()
            }

            FeatureCard(symbol: "doc.on.clipboard", title: "Clipboard history") {
                EmptyView()
            } content: {
                Text("Everything you copy, kept and searchable. Pin what you reuse.")
                if model.clipboardHotkeyEnabled {
                    KeyRow(keys: [model.clipboardHotkeyName], label: "open it from anywhere")
                } else {
                    Text("The shortcut is off — turn it on in Settings › \(SettingsPane.clipboard.title).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                }
                KeyRow(keys: ["⌘1", "…", "⌘9"], label: "paste one of the most recent")
                KeyRow(keys: ["⌥1", "…", "⌥9"], label: "paste one of your pins")
                KeyRow(keys: ["⌥P"], label: "pin or unpin what's selected")
                KeyRow(keys: ["⌥⌫"], label: "delete what's selected")
            }

            FeatureCard(symbol: "checkmark.shield", title: "Decide once, not every time") {
                EmptyView()
            } content: {
                Text("""
                When you approve something from the notch, **Always** writes a rule so the same \
                command stops asking. Genuinely destructive commands are never approved on their \
                own, whatever the rules say. Settings › \(SettingsPane.agents.title) lists every \
                rule, and can suggest new ones from what you have already approved.
                """)
            }
        }
    }
}

/// The question that used to live only in Settings.
///
/// Dictation hears ONE language unless it is told about a second, and until it
/// is told, speaking the other one produces silence: nothing typed, no error,
/// nothing to search for. Reported from a clean install on 2026-09-18 — an
/// English Mac, Spanish spoken into it, no words. The wizard is where somebody
/// still has the question in mind, and a row here costs less than the only
/// first impression there is.
///
/// **Still off by default.** A second language downloads another model and
/// costs ~1.3× on every hold, so this offers rather than assumes; the offer
/// itself comes from `SpokenLanguages`, which reads the Mac's own language list.
private struct SecondLanguageRow: View {
    @Environment(OnboardingModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 4) {
            Picker("Also understand", selection: $model.secondDictationLanguage) {
                Text("Nothing else").tag("")
                // The Mac's own second language, lifted above the long list it
                // would otherwise be buried in — for most bilingual users this
                // is the answer, and scrolling past forty languages to find it
                // is how a question gets skipped.
                if let suggestion = model.suggestedSecondLanguage {
                    Divider()
                    Text(suggestion.name).tag(suggestion.id)
                }
                Divider()
                ForEach(others) { language in
                    Text(language.name).tag(language.id)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(!model.dictationEnabled)

            Text(note)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    /// The suggestion is listed once. Two entries carrying the same tag make
    /// the selection ambiguous, and SwiftUI resolves that by guessing.
    private var others: [OnboardingModel.SpokenLanguage] {
        let suggested = model.suggestedSecondLanguage?.id
        return model.dictationLanguages.filter { $0.id != suggested }
    }

    private var note: String {
        guard model.dictationEnabled else {
            return "Turn dictation on to choose the languages it listens for."
        }
        if model.secondDictationLanguage.isEmpty, let suggestion = model.suggestedSecondLanguage {
            return "This Mac also uses \(suggestion.name). Dictation hears "
                + "\(model.dictationPrimaryName) and nothing else until you add a second language."
        }
        return "Both are heard at once and whichever came out clearer is kept, so you can switch "
            + "language mid-sentence. The second one downloads the first time you pick it."
    }
}

private struct FeatureCard<Accessory: View, Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                content
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 8)
            accessory
        }
        .padding(13)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }
}

/// One binding and what it does. Keys render as keycaps rather than inline text
/// so they can be found by scanning the column instead of read as prose.
private struct KeyRow: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                if key == "…" {
                    Text(key).font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    Text(key)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(.quaternary.opacity(0.85), in: .rect(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5).strokeBorder(.tertiary, lineWidth: 0.5)
                        }
                        .foregroundStyle(.primary)
                }
            }
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(keys.filter { $0 != "…" }.joined(separator: " to ")): \(label)")
    }
}

// MARK: - Permissions

private struct PermissionsStep: View {
    @Environment(OnboardingModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            if let problem = model.calendarCard, problem.isProblem {
                // Refused, or otherwise stuck: the same sentence and button as
                // the calendar widget and Settings, in Settings' look because
                // this is a system window. "Grant Access" did nothing after a
                // no, because macOS will not ask twice.
                VStack(alignment: .leading, spacing: 6) {
                    Label("Calendar", systemImage: "calendar")
                        .font(.system(size: 13, weight: .medium))
                    ProblemCard(icon: "calendar", sentence: problem.sentence,
                                button: problem.remedy.button,
                                action: problem.remedy == .nothing ? nil : { model.performCalendarRemedy() })
                    Text(OnboardingAgentText.calendarLater(next: "Continue"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                .environment(\.problemCardLook, .settings)
            } else {
                PermissionCard(
                    symbol: "calendar",
                    title: "Calendar",
                    detail: "Shows today's agenda in the notch. Read-only, and only the calendars you pick.",
                    granted: model.calendarGranted,
                    grantedLabel: "Granted",
                    action: "Grant Access") { model.performCalendarRemedy() }

                // Under the problem card the card already says it.
                if let note = model.calendar.accessNote {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
            }

            // Not requestable up front: macOS only offers the Automation prompt
            // at the moment an app actually sends the Apple event. So this is a
            // heads-up rather than a button — an unexplained "wants to control
            // iTerm" dialog days later is the thing that makes people uninstall.
            // No button: there is nothing to do until macOS asks.
            PermissionCard(
                symbol: "terminal",
                title: "Automation",
                detail: "The first time you jump back to a terminal, macOS will ask to let Airlock control it. "
                    + "That question is expected — say yes and the jump works from then on.",
                granted: false,
                grantedLabel: "",
                action: nil) {}
        }
    }
}

private struct PermissionCard: View {
    let symbol: String, title: String, detail: String
    let granted: Bool, grantedLabel: String
    /// nil for a heads-up with nothing to press.
    let action: String?
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if granted {
                Label(grantedLabel, systemImage: "checkmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else if let action {
                Button(action, action: perform)
                    .onboardingGlassButton()
            }
        }
        .padding(13)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }
}

// MARK: - Finish

private struct FinishStep: View {
    @Environment(OnboardingModel.self) private var model
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 13) {
                Image(systemName: "power")
                    .font(.system(size: 16))
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at login").font(.system(size: 13, weight: .medium))
                    Text(model.isBundled
                         ? "It lives in the menu bar and uses nothing while idle."
                         : "Needs the packaged app — unavailable from a dev build.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { model.launchAtLogin },
                                         set: { model.setLaunchAtLogin($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!model.isBundled)
            }
            .padding(13)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))

            if let note = model.settings.launchAtLoginNote {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // **The trial, said out loud, once.**
            //
            // Nothing anywhere in first run mentioned the trial or the price:
            // the first signal was a banner on day 11 (`TrialClock.length` 14
            // less `LicenseNotice` warningWindow 3), and that banner is
            // suppressed while onboarding is up. Every trial user met the same
            // surprise, and the people most surprised are the ones who liked it
            // enough to still be here on day 11.
            //
            // Length and prices are read, never written: `TrialClock.length` is
            // the same constant the countdown uses, and `Period.price` is the
            // same string the purchase window quotes.
            // Not said at all while Airlock is free: there is no trial.
            if !Pricing.isFree {
                VStack(alignment: .leading, spacing: 6) {
                    Text("About the trial")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Everything is yours for \(TrialClock.length) days — the whole app, "
                         + "nothing held back. After that it needs a subscription: "
                         + "\(License.Period.yearly.price) or \(License.Period.monthly.price).")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Said in the same breath, because "everything stops" invites
                    // exactly one question and leaving it unanswered is what makes
                    // a trial feel like a trap.
                    Text("Nothing you have saved goes anywhere — your clipboard history and the "
                         + "shelf are still there if you subscribe later.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(13)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
            }

            VStack(spacing: 9) {
                Text("Where to find everything")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Hint(symbol: "cursorarrow", text: "Hover the notch to peek, click to keep it open.")
                Hint(symbol: "menubar.arrow.up.rectangle", text: "The ◐ in your menu bar opens Settings and this guide.")
                Hint(symbol: "square.and.arrow.down", text: "Drag any file onto the notch to drop it on the shelf.")
            }
            .padding(13)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))

            Button {
                model.revealNotch()
                revealed = true
            } label: {
                Label(revealed ? "Look up — that's it" : "Show me the notch",
                      systemImage: revealed ? "arrow.up" : "eye")
            }
            .onboardingGlassButton()
            .padding(.top, 2)
        }
    }

    struct Hint: View {
        let symbol: String, text: String
        var body: some View {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Bits

private struct StepDots: View {
    let count: Int, current: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: current)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

// MARK: - Glass, and a picture of it

extension EnvironmentValues {
    /// For the state gallery. Liquid Glass is composited by the window
    /// server, so an offscreen picture of this window came out as a blank
    /// white sheet; with this set it draws bordered buttons and a flat tint
    /// instead, which is enough to read every word on it.
    @Entry var onboardingFlatGlass = false
}

private struct OnboardingGlassButton: ViewModifier {
    @Environment(\.onboardingFlatGlass) private var flat

    func body(content: Content) -> some View {
        if flat { content.buttonStyle(.bordered) } else { content.buttonStyle(.glass) }
    }
}

private struct OnboardingGlassCircle: ViewModifier {
    @Environment(\.onboardingFlatGlass) private var flat

    func body(content: Content) -> some View {
        if flat {
            content.background(Circle().fill(Color.accentColor.opacity(0.16)))
        } else {
            content.glassEffect(.regular.tint(.accentColor.opacity(0.16)), in: .circle)
        }
    }
}

private extension View {
    func onboardingGlassButton() -> some View { modifier(OnboardingGlassButton()) }
    func onboardingGlassCircle() -> some View { modifier(OnboardingGlassCircle()) }
}
