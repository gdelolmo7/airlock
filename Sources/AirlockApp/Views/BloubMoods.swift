import SwiftUI

/// The cloud while a dictation key is held, and in the beat after it.
///
/// **Why (owner, 2026-10-01): "is the cloud present enough… in the listening
/// for transcribing?"** It was not. The closed island turned attentive, but the
/// strip that opens over it — the thing you are actually looking at while you
/// talk — drew a level wave and a wand, and no character at all.
///
/// Listening, it cocks its head and looks up, swaying a little, and it rises
/// gently with your voice: a few percent taller from its base, eased and never
/// bouncing.
///
/// **It is the meter now** (owner's gallery walk, 2026-10-05: remove the wave,
/// make the cloud bigger and have it react to sound). The wave under it used
/// to be the meter, because a flat wave is how you learn the microphone
/// cannot hear you. That job moved onto the cloud.
///
/// **Light, not loud.** Build 722 stretched it 28% on an under-damped spring
/// and the owner found it "way too aggressive… too distracting" on the real
/// notch the same evening. So the stretch is small, the easing is slow and
/// critically damped, and the level is averaged over the last few readings
/// (`ListeningStrip.levelScale`) so single syllables do not jolt it.
///
/// Thinking, it glances left and right with the curve the guide's cloud uses
/// (`BloubEyes.glance`), so the two thinking clouds are one
/// character. A `TimelineView` drives it, and only while thinking — a second or
/// two after the key comes up — so nothing ticks while the strip is idle.
///
/// Under Reduce Motion the sway, blink, glance and spring go, but the stretch
/// with your voice stays: it is feedback rather than decoration, it is still
/// whenever the room is, and without it nothing on screen says the microphone
/// hears you.
struct ListeningBloub: View {
    var isThinking: Bool
    /// 0…1, the newest microphone reading, compressed by `MicLevel`.
    var level: CGFloat
    var tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far a loud reading stretches the body upward, and widens it, as a
    /// fraction of its size. Taller than wide so it reads as the cloud rising
    /// to meet you rather than inflating.
    static let stretch: CGFloat = 0.08
    static let widen: CGFloat = 0.03
    /// Points it lifts off its base at a loud reading.
    static let lift: CGFloat = 0.75

    var body: some View {
        Group {
            if isThinking {
                thinking
            } else {
                listening
            }
        }
        .accessibilityHidden(true)
    }

    /// Head cocked, eyes up and to the side — the pose of somebody listening
    /// to you — swaying gently, and swelling with your voice.
    @ViewBuilder
    private var listening: some View {
        if reduceMotion {
            BloubView(expression: .attentive, tint: tint)
                .modifier(VoiceStretch(level: level))
                .animation(.easeInOut(duration: 0.35), value: level)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let sway = sin(t * 2 * .pi / 2.6)
                let phase = t.truncatingRemainder(dividingBy: 4.2) / 4.2
                ZStack {
                    BloubBody().fill(tint)
                    BloubEyes(expression: .attentive, lid: Self.blink(phase, at: 0.85),
                              gaze: CGSize(width: -7, height: -6))
                        .fill(Theme.bloubEyes)
                }
                .aspectRatio(BloubBody.bounds.width / BloubBody.bounds.height, contentMode: .fit)
                .modifier(VoiceStretch(level: level))
                .rotationEffect(.degrees(-7 + 2.5 * sway), anchor: .bottom)
            }
            // Critically damped and slow: it breathes with the voice rather
            // than bouncing on every syllable.
            .animation(.spring(response: 0.5, dampingFraction: 1), value: level)
        }
    }

    /// The body answering one reading: up from its base, a little wider, a
    /// little lifted. Zero at silence, so a quiet room leaves it at rest.
    private struct VoiceStretch: ViewModifier {
        var level: CGFloat

        func body(content: Content) -> some View {
            content
                .scaleEffect(x: 1 + ListeningBloub.widen * level,
                             y: 1 + ListeningBloub.stretch * level, anchor: .bottom)
                .offset(y: -ListeningBloub.lift * level)
        }
    }

    /// A quick blink centred on `at`, as a fraction of the cycle.
    private static func blink(_ phase: Double, at: Double) -> CGFloat {
        let distance = abs(phase - at)
        guard distance < 0.02 else { return 1 }
        return CGFloat(0.23 + 0.77 * (distance / 0.02))
    }

    @ViewBuilder
    private var thinking: some View {
        if reduceMotion {
            BloubView(expression: .curious, tint: tint)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let float = CGFloat(sin(t * 2 * .pi / 2.0))
                let phase = t.truncatingRemainder(dividingBy: 3.6) / 3.6
                ZStack {
                    BloubBody().fill(tint)
                    BloubEyes(expression: .curious, gaze: BloubEyes.glance(phase))
                        .fill(Theme.bloubEyes)
                }
                .aspectRatio(BloubBody.bounds.width / BloubBody.bounds.height, contentMode: .fit)
                .offset(y: float * 1.5)
            }
        }
    }
}

/// A happy hop, played once when `celebrating` turns on — a finished guide, an
/// agent's ✓, a practice that got there.
///
/// **Once, and then still.** A success that keeps bouncing turns into a thing
/// that wants attention, which is the opposite of done. Two hops, the second
/// smaller, squashing at take-off and landing so it reads as the body jumping
/// rather than the view sliding.
///
/// `lift` is in points and kept small where the cloud sits against the top of
/// the screen; most of the hop there is the squash. Nothing under Reduce Motion:
/// the happy face is the whole signal.
struct BloubHop: ViewModifier {
    var celebrating: Bool
    var lift: CGFloat
    /// Hop on arrival too, for a cloud that is drawn already celebrating.
    var onAppear: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hops = 0

    struct Pose {
        var lift: CGFloat = 0
        var squash: CGFloat = 0
    }

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: Pose(), trigger: hops) { view, pose in
                view
                    .scaleEffect(x: 1 + pose.squash, y: 1 - pose.squash, anchor: .bottom)
                    .offset(y: -pose.lift)
            } keyframes: { _ in
                KeyframeTrack(\.lift) {
                    CubicKeyframe(0, duration: 0.08)
                    CubicKeyframe(lift, duration: 0.17)
                    CubicKeyframe(0, duration: 0.15)
                    CubicKeyframe(lift * 0.45, duration: 0.13)
                    CubicKeyframe(0, duration: 0.12)
                }
                KeyframeTrack(\.squash) {
                    CubicKeyframe(0.12, duration: 0.08)
                    CubicKeyframe(-0.07, duration: 0.17)
                    CubicKeyframe(0.09, duration: 0.15)
                    CubicKeyframe(-0.03, duration: 0.13)
                    CubicKeyframe(0, duration: 0.18)
                }
            }
            .onChange(of: celebrating) { was, now in
                if now, !was { hop() }
            }
            .onAppear {
                if onAppear, celebrating { hop() }
            }
    }

    private func hop() {
        guard !reduceMotion else { return }
        hops += 1
    }
}

extension View {
    func bloubHop(when celebrating: Bool, lift: CGFloat = 6, onAppear: Bool = false) -> some View {
        modifier(BloubHop(celebrating: celebrating, lift: lift, onAppear: onAppear))
    }
}

extension BloubFace {
    /// The faces a hop belongs to: something just finished, and well.
    var celebrates: Bool { expression == .happy && tint == .done }
}

extension BloubEyes {
    /// Centre, left, right, centre, eased between. Source units.
    static func glance(_ phase: Double) -> CGSize {
        let keys: [(Double, CGFloat, CGFloat)] = [
            (0, 0, 0), (0.12, 0, 0), (0.24, -13, -3), (0.44, -13, -3),
            (0.58, 13, -2), (0.78, 13, -2), (0.9, 0, 0), (1, 0, 0),
        ]
        for index in 1..<keys.count where phase <= keys[index].0 {
            let (t0, x0, y0) = keys[index - 1]
            let (t1, x1, y1) = keys[index]
            let u = CGFloat(smoothstep((phase - t0) / max(t1 - t0, 0.0001)))
            return CGSize(width: x0 + (x1 - x0) * u, height: y0 + (y1 - y0) * u)
        }
        return .zero
    }

    private static func smoothstep(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
}
