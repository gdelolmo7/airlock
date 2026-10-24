import SwiftUI
import AirlockCore

/// The rail: round system toggles, and a strip that opens inside the same card.
///
/// **The disclosure is the design decision worth keeping.** A button with detail
/// behind it opens a strip *in place* — a bright ring says which one is open,
/// the row above never moves, and it costs no window, so the panel can still
/// collapse on its own timer. An `NSMenu` would take the run loop and strand a
/// half-open notch, which is why the handoff forbids one everywhere.
struct SystemControlsSectionView: View {
    @Environment(SystemControlsModel.self) private var controls
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ControlRail(shown: controls.shown,
                        isOn: { controls.isOn($0) },
                        openStrip: controls.openStrip,
                        press: press,
                        openMenu: toggleStrip)

            if let open = controls.openStrip {
                strip(open)
                    .transition(Motion.swap.transition(reduceMotion: reduceMotion))
            }

            // State, not news, so it shows beside a failure line rather than
            // giving way to one: a refused Wi-Fi press says nothing about how
            // long the Mac stays up.
            if controls.isAwake, let end = controls.awakeUntil {
                KeepAwakeCountdownLine(deadline: end, add: { controls.addAwakeTime() })
                    .transition(Motion.swap.transition(reduceMotion: reduceMotion))
            }

            // A press that did nothing says why. Wi-Fi can be refused by the
            // system and the appearance script needs Automation — neither is
            // visible from a button that simply fails to light.
            if let failure = controls.failure {
                ControlFailureLine(problem: failure)
            } else if controls.isHeldForAgents && !controls.isAwake {
                // The cup in the notch says held; the unlit button says off.
                // Both are true — the switch is off, an agent is holding it —
                // and this line is what says so.
                ControlNoteLine(symbol: "cup.and.saucer.fill", text: SystemControlsModel.heldForAgentsNote)
            }
        }
        .modifier(HomeCardBackground())
        // Re-read on every open, because the rail is not the only way to
        // change any of this. Wi-Fi has Control Center and the appearance has
        // System Settings, and the model was seeded once at launch — so a
        // switch flipped anywhere else left the button drawing the old state
        // AND made the next press compute the wrong target.
        //
        // Cheap enough to do unconditionally: two property reads. The panel
        // drops these sections while collapsed, so this runs per expansion.
        .onAppear {
            controls.refresh()
            controls.railShown()
        }
        // A strip left open is a question left half asked: the next time the
        // panel opens it starts from the rail, not from a menu nobody
        // remembers opening.
        .onDisappear { controls.openStrip = nil }
    }

    /// Momentary controls act and never open. The rest toggle on a plain press;
    /// the strip is a separate gesture so a press cannot both switch the radio
    /// off and open a list of what it was connected to.
    private func press(_ control: SystemControlsModel.Control) {
        guard !control.isMomentary else {
            controls.activate(control)
            return
        }
        controls.activate(control)
    }

    /// The menu button beside a tile, or a right-click on it: opens that
    /// control's strip, or closes it when it is the one already open.
    private func toggleStrip(_ control: SystemControlsModel.Control) {
        withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) {
            controls.openStrip = controls.openStrip == control ? nil : control
        }
    }

    /// A choice from the awake strip. The strip closes with it: the countdown
    /// line that appears is the answer, and a menu still open over it would
    /// read as a question still waiting.
    private func keepAwake(_ choice: KeepAwakeTimer.Choice) {
        withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) {
            controls.keepAwake(choice)
            controls.openStrip = nil
        }
    }

    // MARK: - The strip

    /// Detail for the open control, inside the card.
    ///
    /// Awake's is a menu: how long to stay up (`KeepAwakeStrip`). Wi-Fi's is
    /// where the route goes. The drawn rail opens a device
    /// list under Bluetooth and a mode list under Focus; neither radio nor Focus
    /// can be driven from a sandbox-free public API, so neither button is on the
    /// rail and neither strip is drawn — see `SystemControlsModel`.
    ///
    /// **What it says changed, because what it said was already on screen.** It
    /// read "Wi-Fi is on" underneath a button that is lit when Wi-Fi is on — a
    /// disclosure repeating its own control, which is the one thing a
    /// disclosure must not do. The route is the part the rail cannot show: a
    /// radio that is on with nothing reachable behind it, a hotspot that costs
    /// money, an Ethernet cable quietly carrying everything. See
    /// `NetworkStatus`, where the sentences are chosen and tested.
    @ViewBuilder
    private func strip(_ control: SystemControlsModel.Control) -> some View {
        switch control {
        case .wifi:
            HStack(spacing: 6) {
                Image(systemName: controls.network.symbol(radioOn: controls.isWiFiOn,
                                                          hasResolved: controls.hasResolvedNetwork))
                    .font(.system(size: 10))
                Text(controls.network.line(radioOn: controls.isWiFiOn,
                                           hasResolved: controls.hasResolvedNetwork))
                    .font(Theme.chrome(11))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.05)))
        case .awake:
            KeepAwakeStrip(suggested: controls.lastUntil
                               ?? KeepAwakeTimer.suggestedUntil(now: Date(), calendar: .current),
                           pick: keepAwake)
        case .dark, .capture, .record, .sleepDisplay:
            EmptyView()
        }
    }
}

/// Why the last press did nothing, under the rail, with the button to the
/// permission when one is the cause. Values in, so a snapshot draws exactly
/// this.
struct ControlFailureLine: View {
    let problem: SystemControlsModel.Problem

    var body: some View {
        if problem.isNote {
            // Keep awake reaching its end: it did what it was asked, so it is
            // news in the calm tone, with the cup it used to show.
            ProblemCard(icon: "cup.and.saucer", sentence: problem.sentence, tone: .note)
        } else if let pane = problem.pane {
            ProblemCard(sentence: problem.sentence, button: PermissionPage.button, action: { pane.open() })
        } else {
            ProblemCard(sentence: problem.sentence)
        }
    }
}

// MARK: - Keep awake for a set time

/// The awake button's strip: how long to keep the Mac up. The four lengths,
/// "Until…" a time, and "Until I turn it off", as a row of chips that wraps
/// in a half-width card. "Until…" swaps the chips for a small clock to set.
///
/// Values in, so the state gallery draws exactly this; the picked choice goes
/// out through `pick`.
struct KeepAwakeStrip: View {
    /// Where "Until…" starts: the last time picked, or a suggestion.
    let suggested: KeepAwakeTimer.TimeOfDay
    /// Set by the state gallery to draw one moment still.
    var frozenNow: Date?
    var pick: (KeepAwakeTimer.Choice) -> Void

    /// The time being set while "Until…" is open; nil shows the chips.
    @State private var until: KeepAwakeTimer.TimeOfDay?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(suggested: KeepAwakeTimer.TimeOfDay, settingUntil: KeepAwakeTimer.TimeOfDay? = nil,
         frozenNow: Date? = nil, pick: @escaping (KeepAwakeTimer.Choice) -> Void) {
        self.suggested = suggested
        self.frozenNow = frozenNow
        self.pick = pick
        _until = State(initialValue: settingUntil)
    }

    var body: some View {
        Group {
            if let until {
                untilRow(until)
            } else {
                choices
            }
        }
        // The Wi-Fi strip's box, so the two read as one kind of thing.
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }

    private var choices: some View {
        ChipFlow(spacing: 6, rowSpacing: 6) {
            ForEach(KeepAwakeTimer.lengths, id: \.self) { minutes in
                KeepAwakeChip(title: KeepAwakeTimer.title(minutes: minutes),
                              spoken: KeepAwakeTimer.spokenTitle(minutes: minutes)) {
                    pick(.lasting(minutes: minutes))
                }
            }
            KeepAwakeChip(title: KeepAwakeTimer.untilTitle, spoken: KeepAwakeTimer.spokenUntilTitle) {
                withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) { until = suggested }
            }
            KeepAwakeChip(title: KeepAwakeTimer.untilTurnedOffTitle,
                          spoken: KeepAwakeTimer.spokenUntilTurnedOffTitle) {
                pick(.untilTurnedOff)
            }
        }
    }

    /// Back, the time with a step either side, and Start. The line says
    /// "tomorrow" once the time has gone by today, so 08:00 set at night
    /// reads as the morning it means. Start drops under the clock when a
    /// half-width card has no room beside it.
    private func untilRow(_ time: KeepAwakeTimer.TimeOfDay) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                clock(time)
                Spacer(minLength: 4)
                start(time)
            }
            VStack(alignment: .leading, spacing: 6) {
                clock(time)
                HStack {
                    Spacer(minLength: 0)
                    start(time)
                }
            }
        }
    }

    private func clock(_ time: KeepAwakeTimer.TimeOfDay) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) { until = nil }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickable()
            .help("Back to the lengths")
            .accessibilityLabel("Back to the lengths")

            step(time, by: -1, symbol: "minus", spoken: String(localized: "\(KeepAwakeTimer.untilStep) minutes earlier"))
            // A minute's tick is enough: the only thing that changes on its
            // own is "tomorrow", when the clock passes the time being set.
            TimelineView(.everyMinute) { context in
                Text(KeepAwakeTimer.untilLine(time, now: frozenNow ?? context.date,
                                              calendar: .current, locale: .current))
                    .font(Theme.chrome(11, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
            step(time, by: 1, symbol: "plus", spoken: String(localized: "\(KeepAwakeTimer.untilStep) minutes later"))
        }
    }

    /// Held down, it keeps stepping, so the evening-to-morning trip is one
    /// press held rather than forty.
    private func step(_ time: KeepAwakeTimer.TimeOfDay, by steps: Int, symbol: String,
                      spoken: String) -> some View {
        Button {
            until = time.stepped(steps)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.textPrimary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .clickable()
        .help(spoken)
        .accessibilityLabel(spoken)
    }

    private func start(_ time: KeepAwakeTimer.TimeOfDay) -> some View {
        KeepAwakeChip(title: String(localized: "Start"), spoken: String(localized: "Start keeping this Mac awake"),
                      isPrimary: true) {

            pick(.until(time))
        }
    }
}

/// One choice in the awake strip: the island's capsule button, lit a little
/// under the pointer so a row of them reads as a menu.
struct KeepAwakeChip: View {
    let title: String
    /// What VoiceOver says. The visible words lean on the strip around them.
    let spoken: String
    var isPrimary = false
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(isPrimary ? Theme.running : Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill((isPrimary ? Theme.running : Theme.textPrimary)
                    .opacity(isHovering ? 0.2 : 0.12)))
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { isHovering = $0 }
        .animation(MotionEffect.pointer, value: isHovering)
        .accessibilityLabel(spoken)
    }
}

/// "Awake · 42 min left", with "+30 min" beside it, under the rail while a
/// hold with an end runs. Gone for a hold with no end: there is nothing to
/// count, and the lit button already says it is on.
///
/// Redraws only when its words change (`KeepAwakeTimer.nextWordingChange`):
/// about once a minute, and not at all in the last one, where it reads "less
/// than a minute" until the hold lets go and the line goes with it.
struct KeepAwakeCountdownLine: View {
    let deadline: Date
    /// Set by the state gallery to draw one moment still.
    var frozenNow: Date?
    var add: () -> Void

    var body: some View {
        TimelineView(KeepAwakeCountdownSchedule(deadline: deadline)) { context in
            line(at: frozenNow ?? context.date)
        }
        // "+30 min" moves the end, and a schedule is read once; a new one
        // starts from the new end.
        .id(deadline)
    }

    private func line(at now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 10))
                Text(KeepAwakeTimer.countdownLine(until: deadline, now: now))
                    .font(Theme.chrome(11))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(KeepAwakeTimer.spokenCountdown(until: deadline, now: now))
            .help(endsAt(now: now))
            Spacer(minLength: 4)
            Button(action: add) {
                Text(KeepAwakeTimer.addedTimeTitle)
                    .font(Theme.chrome(11, .semibold))
                    .foregroundStyle(Theme.running)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.running.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .clickable()
            .help(KeepAwakeTimer.spokenAddedTime)
            .accessibilityLabel(KeepAwakeTimer.spokenAddedTime)
        }
        .foregroundStyle(Theme.textSecondary)
    }

    /// The clock time it lets go at, for the pointer resting on the line:
    /// "Until 9:42", or "Until 9:42 tomorrow".
    private func endsAt(now: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: deadline)
        return KeepAwakeTimer.untilLine(.init(hour: parts.hour ?? 0, minute: parts.minute ?? 0),
                                        now: now, calendar: .current, locale: .current)
    }
}

/// The countdown's redraws: now, then each moment its words change, then the
/// end. Nothing in between.
struct KeepAwakeCountdownSchedule: TimelineSchedule {
    let deadline: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> UnfoldFirstSequence<Date> {
        let deadline = deadline
        return sequence(first: startDate) { KeepAwakeTimer.nextWordingChange(until: deadline, after: $0) }
    }
}

/// Takes a right-click (or a Control-click) on a tile and nothing else, so it
/// can open the tile's strip the way a right-click opens a menu elsewhere on
/// the Mac, without an `NSMenu`.
///
/// Every other event hit-tests through to the SwiftUI button underneath:
/// the press, the hover that sets the pointer, the tooltip. The same shape as
/// the Shelf's drag layer, the other way round.
private struct SecondaryClickCatcher: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> SecondaryClickView {
        let view = SecondaryClickView()
        view.action = action
        return view
    }

    func updateNSView(_ view: SecondaryClickView, context: Context) {
        view.action = action
    }
}

private final class SecondaryClickView: NSView {
    var action: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, Self.isSecondary(event) else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// The panel is usually not the key window, and a view that refused the
    /// first click there would spend the right-click on bringing it forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) { action() }

    /// Reached only for a Control-click: a plain click never hit-tests here.
    override func mouseDown(with event: NSEvent) { action() }

    private static func isSecondary(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }
}

/// A calm line under the rail: not a problem, just what the buttons cannot
/// show. Values in, like the failure line.
struct ControlNoteLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
            Text(text)
                .font(Theme.chrome(11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textSecondary)
        .accessibilityElement(children: .combine)
    }
}

/// The buttons themselves: one rail when the card has the width, two rows of
/// three beside the Sound card (2026-10-01). The rail's 12pt gaps are what make
/// it refuse a half-width card rather than squeeze six buttons edge to edge.
/// Values in, so a snapshot draws exactly this.
struct ControlRail: View {
    let shown: [SystemControlsModel.Control]
    let isOn: (SystemControlsModel.Control) -> Bool
    let openStrip: SystemControlsModel.Control?
    var press: (SystemControlsModel.Control) -> Void = { _ in }
    /// Opens a tile's strip, from its menu button or a right-click. Nil in a
    /// picture, which still draws the menu button but has nothing to click.
    var openMenu: ((SystemControlsModel.Control) -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(shown) { control in
                    tile(control).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                      spacing: 12) {
                ForEach(shown) { control in tile(control) }
            }
        }
    }

    private func tile(_ control: SystemControlsModel.Control) -> some View {
        ControlTile(symbol: control.symbol,
                    title: control.title,
                    accessibilityLabel: control.accessibilityLabel,
                    isOn: isOn(control),
                    isOpen: openStrip == control,
                    action: { press(control) },
                    menuLabel: control.menuLabel,
                    menu: openMenu.map { open in { open(control) } })
    }
}

/// One rail button: a round tile, filled when its switch is on, with a short
/// caption under it. Takes values rather than the model so a snapshot test can
/// draw exactly what ships.
struct ControlTile: View {
    let symbol: String
    let title: String
    let accessibilityLabel: String
    let isOn: Bool
    /// Its detail strip is open under the rail.
    let isOpen: Bool
    var action: () -> Void
    /// What the small menu button beside the circle is called; nil draws
    /// none. See `SystemControlsModel.Control.menuLabel`.
    var menuLabel: String?
    /// Opens or closes the strip. Nil in a picture.
    var menu: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the menu button's centre sits from the top of the tile, beside
    /// the circle at about four o'clock: clear of the open ring (radius 24)
    /// and of the caption under the circle.
    private static let menuBadgeCentre = CGPoint(x: 27, y: 38)
    private static let menuBadgeSide: CGFloat = 16

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    // A small hop when it switches, so the press visibly took.
                    .symbolEffect(.bounce, options: .nonRepeating, value: isOn)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isOn ? Color.white : Theme.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(isOn ? Theme.running : Theme.textPrimary.opacity(0.08)))
                    // The ring, and the only thing that says which strip below
                    // belongs to which button.
                    .overlay(Circle().strokeBorder(Theme.running.opacity(isOpen ? 0.6 : 0), lineWidth: 2)
                        .padding(-4))
                Text(title)
                    .font(Theme.chrome(10.5, .medium))
                    .foregroundStyle(isOn ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            // The fill and the ring ease in rather than snapping (2026-10-04).
            .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: isOn)
            .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: isOpen)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
        .help(accessibilityLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : [.isButton])
        // A right-click opens the menu too, for anyone who reaches for one.
        // Only when there is a menu to open: a picture has none, and an
        // AppKit view in one draws as a placeholder.
        .overlay {
            if menuLabel != nil, let menu {
                SecondaryClickCatcher(action: menu)
            }
        }
        // After the tile's own modifiers, so it is its own button to the
        // pointer and to VoiceOver rather than part of the switch.
        .overlay(alignment: .top) {
            if let menuLabel {
                menuBadge(menuLabel)
            }
        }
    }

    /// The small round button beside the circle that says "there is more
    /// here" without a right-click: a chevron that turns up while the strip is
    /// open. A sibling of the switch, never inside it, so a press on one can
    /// never be a press on the other.
    private func menuBadge(_ label: String) -> some View {
        Button {
            menu?()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .foregroundStyle(isOpen ? Theme.running : Theme.textSecondary)
                .frame(width: Self.menuBadgeSide, height: Self.menuBadgeSide)
                .background(Circle().fill(Theme.textPrimary.opacity(0.08)))
                // A little more to hit than to see.
                .padding(3)
                .contentShape(Circle())
                .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: isOpen)
        }
        .buttonStyle(.plain)
        .clickable()
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : [.isButton])
        .offset(x: Self.menuBadgeCentre.x,
                y: Self.menuBadgeCentre.y - Self.menuBadgeSide / 2 - 3)
    }
}
