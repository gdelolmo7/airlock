import SwiftUI
import AirlockCore

/// The band beside the camera housing: chrome in the two gutters, nothing in
/// the middle. Flanking the notch instead of spanning it means the top row can
/// sit at the physical screen top without anything hiding behind the housing.
///
/// The centre is reserved, not drawn — `reservedWidth` is the one number that
/// decides whether that holds. See `NotchAppearanceModel.reservedCentreWidth`.
struct NotchTopBar: View {
    let reservedWidth: CGFloat
    let gutterWidth: CGFloat
    /// From the registry, not `NotchTab.allCases` — a tab whose widgets are all
    /// switched off is not offered. See `WidgetRegistry.visibleTabs`.
    let tabs: [NotchTab]
    var onClear: (() -> Void)?
    var onCollapse: () -> Void
    var onOpenSettings: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(BatteryWidgetModel.self) private var battery
    @Environment(AgentsWidgetModel.self) private var agents
    @Environment(NotchUIState.self) private var uiState
    @Environment(NotchAppearanceModel.self) private var appearance
    @Environment(DictationModel.self) private var dictation
    #if AIRLOCK_GUIDE
    @Environment(GuideController.self) private var guide
    #endif
    @Environment(AssistantModel.self) private var assistant
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A guide has the panel. Never, without the guide.
    private var guiding: Bool {
        #if AIRLOCK_GUIDE
        guide.content != nil
        #else
        false
        #endif
    }
    /// The selected tab's capsule is ONE shape that slides from tab to tab
    /// (owner, 2026-10-04), not five that blink on and off.
    @Namespace private var tabHighlight

    var body: some View {
        HStack(spacing: 0) {
            // Tabs hug the OUTER edge. Nothing sits near the inner edge — that
            // is what the camera eats first, as the collapse chevron found out.
            HStack(spacing: 3) {
                if dictation.isActive {
                    // A mode, not a destination. While the key is held there is
                    // exactly one thing to look at, and navigation you cannot
                    // use without letting go is worse than no navigation —
                    // it invites a click that would end the recording.
                    RecordingBadge(isListening: dictation.isListening)
                } else if guiding {
                    // A guide is a mode too. The panel below is the task, and
                    // a highlighted Home tab above it said the opposite — live,
                    // it read as "the guide is on the home tab, and it's empty".
                    guideBadge
                    iconButton("chevron.up", tint: Theme.textSecondary, label: "Collapse", action: onCollapse)
                } else if assistant.isCommandBarOpen {
                    // The typing bar opens an empty notch, so there is no tab
                    // to be on — a highlighted Home over nothing would say the
                    // Home tab is empty. Same treatment as the guide's badge.
                    typingBadge
                    iconButton("chevron.up", tint: Theme.textSecondary, label: "Collapse", action: onCollapse)
                } else {
                    ForEach(tabs) { tab in
                        tabButton(tab)
                    }
                    // Scoped to the strip: the stack below has its own fade
                    // (`NotchRootView`), and the panel's resize is the kit's.
                    .animation(Motion.swap.animation(reduceMotion: reduceMotion),
                               value: uiState.selectedTab)
                    if let onClear, uiState.selectedTab == .agents {
                        iconButton("xmark.circle", tint: Theme.textTertiary, label: "Clear all sessions", action: onClear)
                    }
                    iconButton("chevron.up", tint: Theme.textSecondary, label: "Collapse", action: onCollapse)
                }
                Spacer(minLength: 0)
            }
            .frame(width: gutterWidth, alignment: .leading)
            .padding(.leading, 8)

            Color.clear.frame(width: reservedWidth)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // Two switches, and both have to be on. The rate-limit figures
                // are Claude's, so on a Mac with the agent surfaces off they are
                // a KPI for a product the user does not run — and the empty
                // state is worse than the numbers, being a "set up" pill
                // advertising it.
                // Not while typing: the typed notch is the plain one, and a
                // Claude rate-limit readout (or its "set up" pill) beside a
                // question field is developer chrome the owner called out.
                if appearance.showsUsageInGutter, agents.isEnabled, !assistant.isCommandBarOpen {
                    UsageGutterView(usage: model.usage)
                }
                // Arrange lives beside the gear, not inside it: it acts on
                // this tab, and the tab is what you are looking at. Not while
                // typing, dictating or guiding: there is no tab on screen then.
                if !assistant.isCommandBarOpen, !dictation.isActive, !guiding {
                iconButton(uiState.isArranging ? "checkmark" : "rectangle.on.rectangle",
                           tint: uiState.isArranging ? Theme.running : Theme.textSecondary,
                           label: uiState.isArranging ? "Done arranging" : "Arrange this tab") {
                    withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) { uiState.isArranging.toggle() }
                }
                }
                iconButton("gear", tint: Theme.textSecondary, label: "Settings", action: onOpenSettings)
                // Battery last, hard against the edge — it's the one item macOS
                // itself always parks at the far right of a menu bar.
                if battery.isEnabled, let state = battery.state {
                    BatteryGutterView(state: state, showsPercentage: appearance.showsBatteryPercentage)
                }
            }
            .frame(width: gutterWidth, alignment: .trailing)
            .padding(.trailing, 10)
        }
    }

    /// Stands where the tabs do, so the band never reflows between modes — the
    /// panel is already animating open, and chrome shifting sideways underneath
    /// that reads as a glitch rather than a state change.
    ///
    /// Both modes wear the cloud (2026-10-01): the owner never saw the logo,
    /// because the open panel never drew it. A keyboard icon and the word
    /// "Type" said what the field was for, which the field already says.
    private var guideBadge: some View {
        AirlockMark(title: "Guiding")
            .accessibilityLabel("Guide in progress")
    }

    private var typingBadge: some View {
        AirlockMark()
            .accessibilityLabel("Airlock, typing")
    }

    /// The agents pill carries the session count, so dropping the old "2 agents"
    /// title costs no information.
    ///
    /// 36 wide, down from 46, so the Dashboard tab fits in the room four tabs
    /// used to take: five tabs with a badge come to what four did.
    private func tabButton(_ tab: NotchTab) -> some View {
        let selected = uiState.selectedTab == tab
        let badge = tab == .agents && !model.sessions.isEmpty ? model.sessions.count : nil
        return Button {
            if !selected { Moments.shared.announce(.tabChanged, "\(tab)") }
            uiState.selectedTab = tab
        } label: {
            HStack(spacing: 3) {
                if tab == .home {
                    // Home is the cloud, so the logo is on screen every time
                    // the panel opens. Brand blue when you are on it, a quiet
                    // grey when you are not, and never blinking: it sits in
                    // the strip all day and the tabs beside it are still.
                    BloubView(expression: .attentive,
                              tint: selected ? Theme.running : Theme.textTertiary)
                        .frame(width: 18, height: 15)
                } else {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13, weight: .semibold))
                }
                if let badge {
                    Text("\(badge)")
                        .font(Theme.gutter(11, .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(badge)))
                }
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
            .frame(width: badge == nil ? 36 : 48, height: 26)
            .background {
                if selected {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .matchedGeometryEffect(id: "selectedTab", in: tabHighlight)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .clickable()
        .help(tab.label)
        // `.help` is the tooltip and ONLY the tooltip. Every tab is a bare SF
        // Symbol, so without a label VoiceOver reads the whole strip as four
        // unlabelled buttons — the same hole `CompactSlot.accessibilityLabel`
        // exists to close, and the phrasing follows it: a badge rendered as a
        // numeral is read as a numeral, true and useless.
        .accessibilityLabel(badge.map { "\(tab.label), \($0) session\($0 == 1 ? "" : "s")" } ?? tab.label)
        // Which tab you are on is carried by a capsule fill and nothing else.
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// `label` is the accessible name AND the tooltip, deliberately one string:
    /// these buttons are glyphs, so the tooltip is already the only wording that
    /// describes them, and a second one would be a second thing to drift.
    private func iconButton(_ symbol: String, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .help(label)
        .accessibilityLabel(label)
    }
}

/// "Recording" or "Tidying", with the live-microphone dot.
///
/// Its own view, taking the one fact it shows, so the state gallery can draw
/// it without a `DictationModel`. The pulse lives here because it only exists
/// while the badge does.
struct RecordingBadge: View {
    let isListening: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recordingPulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isListening ? Theme.danger : Theme.running)
                .frame(width: 7, height: 7)
                // Red, and blinking, because this is the universal language for
                // "a microphone is live" — the one state a user must never be
                // in without knowing.
                //
                // Under Reduce Motion the blink stops and the dot holds at FULL
                // opacity — brighter than the blink's own average, never dimmer
                // and never absent. Blinking is the decoration; being visible is
                // the message, and this is the one indicator where losing it
                // would mean a live microphone nobody knows about.
                //
                // The pulse STARTS at full and dips, never the other way round.
                // It rested at 0.35 and rose, so the first frame — the one that
                // has to say "recording" — was a dim dark red.
                .opacity(reduceMotion ? 1 : (recordingPulse ? 0.45 : 1))
                .animation(Theme.perpetual(MotionEffect.pulse,
                                           reduceMotion: reduceMotion),
                           value: recordingPulse)
                // Identity, so flipping the setting mid-recording tears the
                // running loop down. Swapping the animation alone would not:
                // `repeatForever` keeps driving the property it was attached to.
                .id(reduceMotion)
            // Stops claiming to record the moment the microphone is off —
            // a red dot that outlives the recording is exactly the lie this
            // indicator exists to prevent.
            Text(isListening ? "Recording" : "Tidying")
                .font(Theme.gutter(11, .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.danger.opacity(0.14), in: .capsule)
        .overlay { Capsule().strokeBorder(Theme.danger.opacity(0.35), lineWidth: 1) }
        .onAppear { recordingPulse = true }
        .onDisappear { recordingPulse = false }
        .accessibilityLabel("Recording. Release the key to insert the text.")
    }
}

/// Both rate-limit windows on one line — the gutter has the width for it, and
/// a KPI you have to wait for is not a KPI.
///
/// Numbers here are only refreshed by a TERMINAL Claude session rendering its
/// status line; the desktop app runs headless and never does. So the display
/// has to be honest about age or it quietly reports a window that has since
/// rolled — which is exactly what it did before this: 0% on screen against a
/// real 90%, from a snapshot eight hours old. How old is too old, and the
/// words, are `UsageReadout`'s.
///
/// Internal rather than private only so the state gallery can draw it.
struct UsageGutterView: View {
    let usage: UsageSnapshot?
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            switch UsageReadout.freshness(capturedAt: usage?.capturedAt, now: now) {
            case .none:
                // Nothing, where a "set up" pill used to teach where the numbers
                // come from. The owner read it as clutter on every tab
                // (2026-10-01): a minimal notch does not advertise a developer
                // setup step to everyone. The explanation lives in Settings.
                EmptyView()
            case .current:
                if let usage {
                    cluster(usage, now: now, age: nil)
                        .help(UsageReadout.currentHelp)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(spoken(usage, now: now, age: nil))
                }
            case .old(let age):
                // Only clickable while old. As an unconditional button, reading
                // a perfectly current number and clicking it launched a terminal
                // — a readout shouldn't do that. The age is DRAWN: grey numbers
                // and a refresh mark were all that said these were hours old,
                // and the why was in a tooltip.
                if let usage {
                    Button { model.openTerminalForClaudeLogin() } label: {
                        cluster(usage, now: now, age: age)
                    }
                    .buttonStyle(.plain)
                    .clickable()
                    .help(UsageReadout.oldHelp(age))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken(usage, now: now, age: age))
                }
            }
        }
    }

    /// A rolled window is spoken as unknown, as it is drawn.
    private func spoken(_ usage: UsageSnapshot, now: Date, age: String?) -> String {
        func percent(_ window: RateLimitWindow?) -> Int? {
            guard let window, !window.hasRolled(at: now) else { return nil }
            return Int(window.usedPercentage.rounded())
        }
        return UsageReadout.spoken(fiveHour: percent(usage.fiveHour), weekly: percent(usage.sevenDay), age: age)
    }

    private func cluster(_ usage: UsageSnapshot, now: Date, age: String?) -> some View {
        let stale = age != nil
        return HStack(spacing: 5) {
            Image(systemName: stale ? "arrow.clockwise" : "sparkle")
                .font(.system(size: stale ? 9 : 8, weight: .bold))
                .foregroundStyle(stale ? Theme.textTertiary : Theme.claudeCoral)
            if let window = usage.fiveHour { windowView("5h", window, now: now, stale: stale) }
            if usage.fiveHour != nil, usage.sevenDay != nil {
                Text("·").font(Theme.gutter(10)).foregroundStyle(Theme.textTertiary)
            }
            if let window = usage.sevenDay { windowView("7d", window, now: now, stale: stale) }
            if let age {
                Text(age)
                    .font(Theme.gutter(10, .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .fixedSize()
        .contentShape(Rectangle())
    }

    /// A rolled window shows a dash, not a number. Reporting 0% for a period
    /// that has ended is worse than admitting we don't know.
    private func windowView(_ label: String, _ window: RateLimitWindow, now: Date, stale: Bool) -> some View {
        let rolled = window.hasRolled(at: now)
        return HStack(spacing: 3) {
            Text(label)
                .font(Theme.gutter(10, .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(rolled ? "—" : "\(Int(window.usedPercentage.rounded()))%")
                .font(Theme.gutter(11, .bold))
                .foregroundStyle(rolled || stale ? Theme.textTertiary : colour(window.usedPercentage))
                .monospacedDigit()
        }
    }

    private func colour(_ percent: Double) -> Color {
        switch percent {
        case ..<70: return Theme.textPrimary
        case ..<90: return Theme.needs
        default: return Theme.danger
        }
    }
}

/// Glyph plus percentage — and nothing else *drawn*. Time remaining would not
/// survive the gutter: this sits hard against the screen edge beside the camera
/// housing, where every point spent is a point of the menu bar covered, and the
/// glyph already says charging.
///
/// It is still SAID, though, in both channels that cost no width. The tooltip is
/// for the pointer that stopped here wondering how long is left; the
/// accessibility label is the only channel a screen reader has, and without one
/// this element read as a bare "63%" — a number with no subject. The sentence
/// comes from `BatteryReading` in Core, which is also where the compact island's
/// critical rung gets its "n minutes left", so the two agree by construction
/// rather than by review.
///
/// Not private: the state gallery draws it from made-up readings.
struct BatteryGutterView: View {
    let state: BatteryState
    let showsPercentage: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            if showsPercentage {
                Text("\(state.percentage)%")
                    .font(Theme.gutter(11, .semibold))
                    .foregroundStyle(state.isLow ? Theme.needs : Theme.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(state.percentage)))
            }
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(state.isLow ? Theme.needs : Theme.done)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
            // The cable's mark sits beside the level rather than replacing it:
            // a full battery with a bolt at 5% said the opposite of the number.
            if let cable {
                Image(systemName: cable)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, -2)
                    .transition(.opacity)
            }
        }
        .animation(MotionEffect.reading(reduceMotion: reduceMotion), value: state.percentage)
        .animation(MotionEffect.reading(reduceMotion: reduceMotion), value: symbol)
        .animation(MotionEffect.reading(reduceMotion: reduceMotion), value: cable)
        .fixedSize()
        .help(state.spoken)
        // `.ignore`, not `.combine`: combining would read the drawn "63%" and
        // then the sentence that already contains it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.spoken)
    }

    private var symbol: String { BatteryReading.levelSymbol(percentage: state.percentage) }

    /// A bolt while charging; a plug while macOS holds the charge on purpose,
    /// so a Mac at its charge limit does not look like a broken charger.
    private var cable: String? {
        switch BatteryReading.mark(isCharging: state.isCharging, isPluggedIn: state.isPluggedIn,
                                   isCharged: state.isCharged) {
        case .charging: return "bolt.fill"
        case .holding: return "powerplug.fill"
        case .none: return nil
        }
    }
}
