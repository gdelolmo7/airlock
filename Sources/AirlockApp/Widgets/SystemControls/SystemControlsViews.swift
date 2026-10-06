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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ControlRail(shown: controls.shown,
                        isOn: { controls.isOn($0) },
                        openStrip: controls.openStrip,
                        press: press)

            if let open = controls.openStrip {
                strip(open)
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

    // MARK: - The strip

    /// Detail for the open control, inside the card.
    ///
    /// Only Wi-Fi has anything to disclose today. The drawn rail opens a device
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
        case .awake, .dark, .capture, .record, .sleepDisplay:
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
        if let pane = problem.pane {
            ProblemCard(sentence: problem.sentence, button: PermissionPage.button, action: { pane.open() })
        } else {
            ProblemCard(sentence: problem.sentence)
        }
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
                    action: { press(control) })
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    }
}
