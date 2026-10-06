import SwiftUI

/// An agent is working: the lamp on the chamber, breathing.
///
/// This is the app's own mark alive. The icon, the menu bar item and this glyph
/// are now the same object in three sizes — a sealed chamber with one light on
/// it — so the thing you see while an agent works is the thing you clicked to
/// start it.
///
/// It replaced three breathing bars, which stopped working the day the media
/// wave became five bars beside them: two members of the same visual family, in
/// the same island, meaning entirely unrelated things. An equalizer is what
/// every music player on the machine already uses, so the agent side was the one
/// that had to move.
///
/// One moving element, deliberately. At fifteen points that is roughly the
/// budget — an orbiting dot was tried first and read as fussy at size, where
/// this is legible as a pulse before you have focused on it.
struct AgentLampView: View {
    var color: Color
    /// False when sessions exist but none is working: the lamp holds steady,
    /// which reads as "here, idle" rather than "here, busy".
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    /// Matched to `MediaWaveView` so the compact slot keeps its height when a
    /// session ends and music is what is left in the island.
    private static let size = CGSize(width: 17, height: 15)
    private static let corner: CGFloat = 4
    private static let lampHeight: CGFloat = 2.3

    var body: some View {
        ZStack {
            // The chamber, dim: it is the housing, not the subject.
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(color.opacity(0.26), lineWidth: 1.1)

            GeometryReader { geometry in
                let lamp = CGRect(
                    x: geometry.size.width * 0.22,
                    // Sits high in the chamber, as it does in the icon — a bar
                    // through the middle reads as a slot rather than a light.
                    y: geometry.size.height * 0.30,
                    width: geometry.size.width * 0.56,
                    height: Self.lampHeight)

                Capsule()
                    .fill(color)
                    .frame(width: lamp.width, height: lamp.height)
                    .position(x: lamp.midX, y: lamp.midY)
                    // Brightness AND height: opacity alone reads as a fade,
                    // scale alone as a twitch. Together it is a light coming up.
                    //
                    // Under Reduce Motion a WORKING lamp holds at the lit end
                    // rather than the dim one. Stopping the breath wherever it
                    // rests would leave working and idle looking identical —
                    // idle is exactly "dim and steady" — so the state would be
                    // lost along with the motion.
                    .opacity(litAppearance ? 1 : 0.34)
                    .scaleEffect(y: litAppearance ? 1 : 0.68, anchor: .center)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(Theme.perpetual(MotionEffect.breathe, reduceMotion: reduceMotion), value: lit)
        // Identity, and this is a fix rather than a flourish. The guard below
        // only prevents the breath STARTING; it cannot stop one already
        // running, because `.animation(_:value:)` opens a transaction when the
        // value changes and `lit` does not change when the setting flips. A
        // `repeatForever` already attached keeps driving its property —
        // `MediaWaveView` documents that exact mechanism and solves it the same
        // way. The island stays mounted for a whole session, so without this,
        // turning Reduce Motion on left the lamp breathing until relaunch.
        .id(reduceMotion)
        .onAppear {
            guard animated, !reduceMotion else { return }
            lit = true
        }
        // No label here, deliberately. It used to carry `animated ? "Working" :
        // "Idle"` — and `animated` is `anyRunning`, which knows nothing about
        // attention, so a session blocked on a gate announced itself as "Idle"
        // whenever nothing else was running. The lamp cannot say what it means
        // because it is not told: it gets a colour and a boolean. The slot that
        // chose it does know, so the label lives there
        // (`CompactSlot.accessibilityLabel`, tested), and the containing element
        // ignores its children.
        .accessibilityHidden(true)
    }

    /// Lit whenever the breath would have it lit, and unconditionally lit when
    /// the breath is switched off but the agent IS working.
    private var litAppearance: Bool {
        (reduceMotion && animated) || lit
    }
}
