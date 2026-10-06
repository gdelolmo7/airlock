import SwiftUI
import DynamicNotchKit

/// The panel's OWN expand and collapse, and the five named motions the rest
/// of the app moves by.
///
/// The panel growing out of the notch belongs to the vendored kit, which reads
/// `accessibilityReduceMotion` nowhere. It is set from the HOST, never by
/// editing the kit's animation values: the kit exposes
/// `DynamicNotchTransitionConfiguration` precisely as this override point, so
/// re-vendoring it stays a straight file copy.
enum NotchMotion {
    /// The three panel transitions, from the named motions: growing is Open,
    /// shrinking is Close.
    ///
    /// The kit uses ONE conversion animation for compact → expanded and back,
    /// so the controller says which way it is heading just before each
    /// transition (`growing`), and Close is quicker than Open in both of the
    /// places it happens: hiding, and folding back into the compact island.
    ///
    /// This replaced "nil with Reduce Motion off" — the kit's own `.bouncy`
    /// opening, `.smooth` closing and `.snappy` conversion, three springs
    /// nobody here chose. C1 is the decision to choose them: one Open, one
    /// Close, and the bounce on Open small enough that a gate's Approve is
    /// not still travelling under a pointer already on its way to it.
    ///
    /// Under Reduce Motion both are the calm version, so the panel arrives
    /// without overshoot. (The kit still scales the panel out of the notch:
    /// that geometry is the kit's, and re-vendoring stays a file copy.)
    static func transitionConfiguration(reduceMotion: Bool,
                                        growing: Bool = true) -> DynamicNotchTransitionConfiguration {
        let open = Motion.open.animation(reduceMotion: reduceMotion)
        let close = Motion.close.animation(reduceMotion: reduceMotion)
        return DynamicNotchTransitionConfiguration(
            openingAnimation: open,
            closingAnimation: close,
            conversionAnimation: growing ? open : close,
            // Not a motion preference: it stops compact ↔ expanded routing
            // through a hide and a 250ms sleep — the island blinking out and
            // back. Turning it off under Reduce Motion would ADD motion.
            skipIntermediateHides: true
        )
    }
}

// MARK: - The five named motions

/// Every movement the app makes is one of five, and each is defined here once
/// (card C1). A screen asks for a motion by name, never for a number, so the
/// island, the tabs, the guide and the cards all move the same way.
///
/// - **Open:** the island grows out of the notch.
/// - **Close:** it tucks back in, a little quicker than Open: leaving should
///   never feel slow.
/// - **Swap:** content changes inside a frame that stays still — a tab, a
///   guide step, a list making room. Only the content moves.
/// - **Confirm:** a small settle when something is approved, finishes or is
///   reached.
/// - **Nudge:** a gentle "look at me" when something needs you. A few beats,
///   then it rests and simply stays visible. Never a loop.
///
/// **Reduce Motion is decided here too**, so no screen needs its own check.
/// Each motion has a calm version: a plain fade over a short ease, nothing
/// growing, sliding or bouncing.
///
/// The bloub, the listening cloud and the guide ring keep their own
/// choreography; their timing is read from these (`SteppedSpring(_:motion:)`).
///
/// **Resting states, never keyframes** (build 628): a motion here moves a
/// value that already sits at its end, so a clock that never runs in the
/// panel costs the movement and never the picture.
enum Motion: String, CaseIterable, Sendable {
    case open, close, swap, confirm, nudge

    /// Seconds to settle, roughly — the spring's response.
    var response: Double {
        switch self {
        case .open: 0.4
        case .close: 0.32
        case .swap: 0.3
        case .confirm: 0.35
        case .nudge: 0.4
        }
    }

    /// 1 settles without overshoot; lower bounces. Only Open and Confirm are
    /// allowed any: the island arriving and a thing landing are the two
    /// moments with weight. Close and Swap never overshoot — a panel that
    /// bounces on its way out, or a tab that wobbles, is noise.
    var damping: Double {
        switch self {
        case .open: 0.8
        case .close, .nudge: 1
        case .swap: 0.9
        case .confirm: 0.55
        }
    }

    /// How long the calm version's fade takes.
    var calmDuration: Double {
        switch self {
        case .open: 0.3
        case .close: 0.25
        case .swap: 0.2
        case .confirm: 0.3
        case .nudge: 0.6
        }
    }

    /// The motion, or its calm version under Reduce Motion. Never nil: the
    /// calm version still moves opacity, because something that teleports
    /// loses what changed.
    func animation(reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: calmDuration) }
        switch self {
        case .nudge: return .easeInOut(duration: Self.nudgeHalfBeat)
        default: return .spring(response: response, dampingFraction: damping)
        }
    }

    /// How a view comes and goes with this motion. Calm: opacity alone.
    func transition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        switch self {
        case .open, .close: return .scale(scale: 0.92, anchor: .top).combined(with: .opacity)
        case .swap: return .offset(y: Self.swapLift).combined(with: .opacity)
        case .confirm: return .scale(scale: 1 - Self.confirmDip).combined(with: .opacity)
        case .nudge: return .opacity
        }
    }

    /// How far new content rises into place on a Swap, in points.
    static let swapLift: CGFloat = 4
    /// How far a Confirm dips before it settles, as a fraction of the size.
    static let confirmDip: CGFloat = 0.08
    /// How much a Nudge grows at the top of a beat.
    static let nudgeGrow: CGFloat = 0.06
    /// Beats before a Nudge rests. Three, then still.
    static let nudgeBeats = 3
    /// Half a beat — out or back — and the pause between beats.
    static let nudgeHalfBeat: Double = 0.32
    static let nudgeRest: Double = 0.28

    /// How far through the motion it is at `time` seconds, 0 at the start and
    /// 1 at rest. A spring can pass 1 on its way (Open and Confirm do); a
    /// Nudge goes out to 1 and back to 0 each beat. The same numbers the
    /// animations use, so the gallery's pictures and the tests see what the
    /// screen does.
    func progress(at time: Double, reduceMotion: Bool) -> Double {
        if self == .nudge { return Self.nudgeLean(at: time, reduceMotion: reduceMotion) }
        if reduceMotion { return Self.easeInOut(time / calmDuration) }
        var spring = SteppedSpring(0, response: CGFloat(response), damping: CGFloat(damping))
        spring.target = 1
        spring.step(CGFloat(max(time, 0)))
        return Double(spring.value)
    }

    /// How long the motion takes to come to rest.
    func duration(reduceMotion: Bool) -> Double {
        if self == .nudge {
            return reduceMotion ? calmDuration
                : Double(Self.nudgeBeats) * (2 * Self.nudgeHalfBeat + Self.nudgeRest)
        }
        if reduceMotion { return calmDuration }
        var spring = SteppedSpring(0, response: CGFloat(response), damping: CGFloat(damping))
        spring.target = 1
        var elapsed = 0.0
        while !spring.isSettled(within: 0.002), elapsed < 3 {
            spring.step(1.0 / 120)
            elapsed += 1.0 / 120
        }
        return elapsed
    }

    /// 0 at rest, 1 at the top of a beat. Calm: one soft fade, once.
    private static func nudgeLean(at time: Double, reduceMotion: Bool) -> Double {
        guard time > 0 else { return 0 }
        if reduceMotion {
            let calm = Motion.nudge.calmDuration
            guard time < calm else { return 0 }
            return sin(.pi * time / calm)
        }
        let beat = 2 * nudgeHalfBeat + nudgeRest
        guard time < Double(nudgeBeats) * beat else { return 0 }
        let within = time.truncatingRemainder(dividingBy: beat)
        if within < nudgeHalfBeat { return easeInOut(within / nudgeHalfBeat) }
        if within < 2 * nudgeHalfBeat { return 1 - easeInOut((within - nudgeHalfBeat) / nudgeHalfBeat) }
        return 0
    }

    private static func easeInOut(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    }
}

// MARK: - Named effects

/// The movements that are not one of the five, named so they are found here
/// rather than as a number in a view (card C2). Each is something the five
/// cannot say: a reading following its value, a loop that means "still going",
/// the pointer being answered. Anything that changes state uses a `Motion`.
///
/// The bloub's own choreography (blink, hop, the listening cloud) lives with
/// the bloub and stays its own, by C1's rule.
enum MotionEffect {
    /// The pointer answered: a hover, a drop target lighting, a click's flash,
    /// a thumb growing under a drag. Quick and plain, and kept under Reduce
    /// Motion, because following a gesture is feedback rather than decoration.
    static let pointer = Animation.easeOut(duration: 0.15)

    /// A reading moving to its next value: a figure rolling its digits, a bar
    /// or an arc following a measurement, an app overtaking another in a
    /// ranking. No bounce, because nothing was pushed. Reduce Motion drops it:
    /// these are small, frequent changes where the movement says nothing the
    /// new value does not (2026-10-04).
    static func reading(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.35)
    }

    /// A live audio meter between two frames. The envelope is already smoothed
    /// at 20fps, so this is only a lerp; anything longer would lag the music.
    static let meter = Animation.linear(duration: 0.05)

    /// A playhead moving one second of playback: linear, so it keeps time.
    static let playhead = Animation.linear(duration: 1)

    // Loops. Each is "still going" — something live, recording or loading —
    // and every caller switches it off under Reduce Motion (`Theme.perpetual`)
    // and makes the switch a change of identity, since a running
    // `repeatForever` keeps driving its property.

    /// A slow dip and back: the recording dot, a loading skeleton.
    static let pulse = Animation.easeInOut(duration: 0.7).repeatForever(autoreverses: true)

    /// A working agent's lamp breathing. One implicit animation, so Core
    /// Animation owns the motion and SwiftUI never re-evaluates the lamp while
    /// an agent runs.
    static let breathe = Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)

    /// The three waiting dots, each a beat behind the one before.
    static func waiting(dot index: Int) -> Animation {
        .easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(Double(index) * 0.18)
    }

    /// The music bars when there is no live audio to draw: a canned rise and
    /// fall, each bar a fifth of the cycle behind the one before, so the crest
    /// travels the width of the glyph instead of every bar rising together.
    static func musicBars(bar index: Int) -> Animation {
        .easeInOut(duration: 0.62).repeatForever(autoreverses: true).delay(Double(index) * 0.11)
    }

    /// The stats rings drawing on when the card opens, one after another, and
    /// then gliding between readings. A reading every three seconds, so the
    /// glide is shorter than that and the arc is resting when the next lands.
    static func ringSweep(order: Int) -> Animation {
        .spring(duration: 0.8, bounce: 0.12).delay(0.05 + 0.07 * Double(order))
    }
    static let ringGlide = Animation.smooth(duration: 0.7)

    // The guide's ring. It travels across the whole screen rather than inside
    // the island, so its arrival is its own effect; moving to the next button
    // is still a Swap and reaching it a Confirm.

    /// The first ring of a run drawing itself on around its button. Off under
    /// Reduce Motion, where the ring is simply there.
    static let ringDrawOn = Animation.easeInOut(duration: 0.6)
    /// The halo swelling once and fading back when the ring lands on a new
    /// button, a beat after it arrives. Off under Reduce Motion.
    static let ringPulse = Animation.easeOut(duration: 1.4).delay(0.2)
}

/// Confirm: a small settle the moment `settled` turns true — dips a touch and
/// springs back, or under Reduce Motion fades back up from a little dimmer.
/// Turning false again is a reset, not news, and plays nothing.
///
/// The value it moves RESTS at zero, the tab fade's pattern (build 628): it is
/// kicked without animation, then animated home a frame later. A panel whose
/// clock never runs shows the thing at rest, never stuck mid-dip.
private struct ConfirmSettle: ViewModifier {
    var settled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var kick: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : 1 - Motion.confirmDip * kick)
            .opacity(reduceMotion ? 1 - 0.45 * kick : 1)
            .onChange(of: settled) { _, now in
                guard now else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { kick = 1 }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    withAnimation(Motion.confirm.animation(reduceMotion: reduceMotion)) { kick = 0 }
                }
            }
    }
}

/// Nudge: while `active`, a few gentle beats, then still and visible. Becoming
/// active again starts a fresh set; becoming inactive stops at rest.
private struct NudgeBeats: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lean: CGFloat = 0
    @State private var beats: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : 1 + Motion.nudgeGrow * lean)
            .opacity(reduceMotion ? 1 - 0.4 * lean : 1)
            .onChange(of: active, initial: true) { _, now in
                beats?.cancel()
                beats = nil
                guard now else {
                    lean = 0
                    return
                }
                beats = Task { @MainActor in await play() }
            }
            .onDisappear {
                beats?.cancel()
                beats = nil
            }
    }

    private func play() async {
        let calm = reduceMotion
        let half = calm ? Motion.nudge.calmDuration / 2 : Motion.nudgeHalfBeat
        let count = calm ? 1 : Motion.nudgeBeats
        for _ in 0..<count {
            withAnimation(.easeInOut(duration: half)) { lean = 1 }
            try? await Task.sleep(for: .seconds(half))
            withAnimation(.easeInOut(duration: half)) { lean = 0 }
            try? await Task.sleep(for: .seconds(half + Motion.nudgeRest))
            if Task.isCancelled { break }
        }
        lean = 0
    }
}

extension View {
    /// A Confirm settle each time `settled` turns true.
    func confirmSettle(when settled: Bool) -> some View {
        modifier(ConfirmSettle(settled: settled))
    }

    /// A Nudge while `active`: a few beats, then still.
    func nudge(while active: Bool) -> some View {
        modifier(NudgeBeats(active: active))
    }
}
