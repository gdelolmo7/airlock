import AirlockCore
import AppKit
import SwiftUI

/// Where the sound is going and how loud — the whole of it, in one card.
///
/// Split out of the media card because it was never really part of it. Output
/// switching and per-app levels are about the machine's audio; now-playing is
/// about one app's transport. Keeping them together meant the sound controls
/// only existed while Spotify or Music was detected, which is precisely the
/// wrong condition: a browser playing a video is exactly when there is no
/// now-playing state and exactly when you want to turn it down.
///
/// **Redrawn 2026-10-01** (owner: "make it make sense"). The device used to be
/// named twice — a pill in the header on a one-output Mac, a row of chips under
/// the levels on any other — and the chips sat there permanently, taking a line
/// for a choice made once a week. Now the device is named ONCE, at the top
/// right, and it is the switcher: pressing it opens the list of outputs in
/// place, and picking one closes it.
struct SoundSectionView: View {
    @Environment(AudioOutputModel.self) private var output
    @Environment(AppVolumeModel.self) private var mixer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fillsPairedRow) private var fillsRow
    /// Whether the output list is open. In place rather than in a menu: an
    /// NSMenu is a window of its own, and this panel collapses ~450ms after the
    /// pointer leaves it (`NotchController.hoverChanged`), so a hover-opened
    /// notch would shut from under an open menu.
    @State private var choosing = false

    var body: some View {
        // Slots, not bare rows: an app that has just gone quiet keeps its
        // place, drawn inert, rather than the card closing up under the pointer.
        let rows = mixer.slots
        if output.hasRow || !rows.shown.isEmpty || output.currentDeviceName != nil {
            let devices = output.layout.shown + output.layout.overflow
            VStack(alignment: .leading, spacing: 10) {
                SoundCardHeader(device: output.currentDeviceName,
                                canSwitch: devices.count > 1,
                                isChoosing: choosing, stacked: fillsRow) { choosing.toggle() }
                // The flag AND the devices: unplug the second output with the
                // list open and there is nothing left to choose between.
                if choosing && devices.count > 1 {
                    OutputDeviceList(choices: devices.map {
                        OutputChoice(id: $0.uid, name: $0.name, isCurrent: $0.uid == output.currentUID)
                    }) { uid in
                        if let device = devices.first(where: { $0.uid == uid }) {
                            output.select(device)
                        }
                        choosing = false
                    }
                }
                // Stretched beside the controls: title, output and levels as
                // three rows, the levels at the foot of the card, level with
                // the bottom row of buttons.
                if fillsRow { Spacer(minLength: 0) }
                if output.volume == nil && rows.shown.isEmpty {
                    OwnVolumeNote()
                }
                FaderConsoleView()
            }
            .modifier(HomeCardBackground())
            .animation(Motion.swap.animation(reduceMotion: reduceMotion),
                       value: choosing)
            .onChange(of: devices.count) { _, count in
                if count <= 1 { choosing = false }
            }
            // Collapsing the panel tears this view down, so a list left open
            // would come back open on a panel the pointer merely crossed.
            .onDisappear { choosing = false }
        }
    }
}

/// In place of the levels when the output has no volume Airlock can set — an
/// HDMI display, most receivers — and nothing is playing. The header still
/// names the device; this says why there is no slider under it.
struct OwnVolumeNote: View {
    static let sentence = "This output's volume is set on the device itself."

    var body: some View {
        Text(Self.sentence)
            .font(Theme.chrome(11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Sound", and on the right the device it is playing through — a button that
/// opens the output list when there is more than one to choose from, plain
/// words when there is not. Values in, so a snapshot draws exactly this.
struct SoundCardHeader: View {
    let device: String?
    let canSwitch: Bool
    let isChoosing: Bool
    /// The device on a line of its own under the title, full width, rather
    /// than a chip beside it: for a card stretched beside the controls on
    /// Home, where the room is there and a long output name gets to show.
    var stacked = false
    var toggle: () -> Void = {}

    var body: some View {
        if stacked, let device {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "speaker.wave.2.fill", title: "Sound") { EmptyView() }
                control(device)
            }
        } else {
            CardHeader(symbol: "speaker.wave.2.fill", title: "Sound") {
                if let device { control(device) }
            }
        }
    }

    @ViewBuilder private func control(_ device: String) -> some View {
        if canSwitch {
            Button(action: toggle) { label(device) }
                .buttonStyle(.plain)
                .clickable()
                .help(isChoosing ? "Close the list of outputs" : "Choose where sound plays")
                .accessibilityLabel("Output: \(device)")
                .accessibilityHint(isChoosing ? "Closes the list of outputs" : "Opens the list of outputs")
        } else {
            label(device)
                .help("Playing through \(device)")
        }
    }

    @ViewBuilder private func label(_ device: String) -> some View {
        if stacked {
            HStack(spacing: 7) {
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                Text(device)
                    .font(Theme.chrome(12, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if canSwitch {
                    Image(systemName: isChoosing ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(isChoosing ? 0.12 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            HStack(spacing: 4) {
                Text(device)
                    .font(Theme.chrome(10.5, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if canSwitch {
                    Image(systemName: isChoosing ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, canSwitch ? 8 : 0)
            .frame(height: 20)
            .background {
                if canSwitch {
                    Capsule().fill(Color.white.opacity(isChoosing ? 0.12 : 0.06))
                }
            }
            .contentShape(Capsule())
        }
    }
}

/// One output, as the list draws it.
struct OutputChoice: Identifiable {
    let id: String
    let name: String
    let isCurrent: Bool
}

/// Every output, one per line, the current one ticked. These are the long
/// names — "LG UltraFine Display Audio" — so a line each rather than chips
/// fighting for the card's width.
struct OutputDeviceList: View {
    let choices: [OutputChoice]
    var choose: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(choices) { choice in
                Button { choose(choice.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.running)
                            .opacity(choice.isCurrent ? 1 : 0)
                            .frame(width: Theme.soundIconWidth)
                        Text(choice.name)
                            .font(Theme.chrome(11, choice.isCurrent ? .semibold : .regular))
                            .foregroundStyle(choice.isCurrent ? Theme.textPrimary : Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .padding(.trailing, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(choice.isCurrent ? Color.white.opacity(0.06) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()
                .help(choice.isCurrent ? "Playing through \(choice.name)" : "Switch to \(choice.name)")
                .accessibilityAddTraits(choice.isCurrent ? .isSelected : [])
            }
        }
        .padding(.bottom, 2)
    }
}
