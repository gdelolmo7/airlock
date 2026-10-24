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
    /// switched off is not offered. See `WidgetRegistry.visibleTabs`. Split
    /// between the two gutters by `NotchTab.topBarSides`: Agents on the right,
    /// the rest on the left.
    let tabs: [NotchTab]
    var onClear: (() -> Void)?
    var onCollapse: () -> Void
    var onOpenSettings: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(BatteryWidgetModel.self) private var battery
    @Environment(NotchUIState.self) private var uiState
    @Environment(NotchAppearanceModel.self) private var appearance
    @Environment(DictationModel.self) private var dictation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A mode has the band: dictating. There is no tab on screen then, so
    /// nothing that acts on one is offered.
    private var inAMode: Bool {
        dictation.isActive
    }

    /// The selected tab's capsule is ONE shape that slides from tab to tab
    /// (owner, 2026-10-04), not five that blink on and off. That holds across
    /// the camera too: to Agents on the right it slides over, as it does
    /// along the strip.
    @Namespace private var tabHighlight

    var body: some View {
        let sides = NotchTab.topBarSides(tabs)
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
                } else {
                    ForEach(sides.leading) { tab in
                        tabButton(tab)
                    }
                    // Scoped to the tabs: the stack below has its own fade
                    // (`NotchRootView`), and the panel's resize is the kit's.
                    .animation(Motion.swap.animation(reduceMotion: reduceMotion),
                               value: uiState.selectedTab)
                    iconButton("chevron.up", tint: Theme.textSecondary, label: String(localized: "Collapse"), action: onCollapse)
                }
                Spacer(minLength: 0)
            }
            .frame(width: gutterWidth, alignment: .leading)
            .padding(.leading, 8)

            Color.clear.frame(width: reservedWidth)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // Agents sits here, beside the gear, so Calls has its place in
                // the strip and the strip still fits beside the camera. Its
                // "clear all" stays next to it, on the inner side, where it
                // was next to the tab in the strip.
                if !inAMode {
                    if let onClear, uiState.selectedTab == .agents {
                        iconButton("xmark.circle", tint: Theme.textTertiary, label: String(localized: "Clear all sessions"), action: onClear)
                    }
                    ForEach(sides.trailing) { tab in
                        tabButton(tab)
                    }
                    // The strip's animation, so the capsule slides over to
                    // here in the same Swap rather than appearing.
                    .animation(Motion.swap.animation(reduceMotion: reduceMotion),
                               value: uiState.selectedTab)
                }
                // Arrange lives beside the gear, not inside it: it acts on
                // this tab, and the tab is what you are looking at. Not while
                // typing, dictating or guiding: there is no tab on screen then.
                if !inAMode {
                iconButton(uiState.isArranging ? "checkmark" : "rectangle.on.rectangle",
                           tint: uiState.isArranging ? Theme.running : Theme.textSecondary,
                           label: uiState.isArranging ? String(localized: "Done arranging") : String(localized: "Arrange this tab")) {
                    withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) { uiState.isArranging.toggle() }
                }
                }
                iconButton("gear", tint: Theme.textSecondary, label: String(localized: "Settings"), action: onOpenSettings)
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
        .accessibilityLabel(badge.map { $0 == 1 ? String(localized: "\(tab.label), 1 session") : String(localized: "\(tab.label), \($0) sessions") } ?? tab.label)
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
