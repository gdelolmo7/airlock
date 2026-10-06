import SwiftUI
import AirlockCore

// The bloub — Airlock's character, ported off generated SVGs: twelve at first,
// plus `scared` added later from its own static/animated pair.
//
// The numbers below were extracted from the source SVGs once — the first twelve
// by hand, `scared` by script — and THIS FILE is the source of truth from here
// on. There is no generator to re-run. Deliberate: re-running one would overwrite the reasoning in these
// comments, and the silhouette is not expected to change often enough to be
// worth that trade.
//
// Vector code rather than checked-in vector assets, for the same reason
// `scripts/make-icon.swift` is one: the shape is code, the palette is `Theme`'s,
// and a change to either is a diff instead of a binary swap. It is also what
// keeps the decision reversible — the character is not exclusive to this product
// (see the mascot note in the planning memory), so the body may yet be redrawn.
// Everything below is arranged so that costs ONE table.
//
// **The whole expression system is capsules, two per expression.** The source
// set draws each eye as a rounded rectangle whose corner radius equals its
// smaller half-extent — verified across all of them — which is a capsule.
// `scared`'s export states the capsule as a path instead, at a fixed 40×60 with
// the scale in its matrix; same construction, so it reads through unchanged. So no path
// data is needed for the eyes at all: an expression is two sizes and two affine
// poses, and that is why `BloubEye` is a value type and adding an expression is
// one line rather than an asset.
//
// **The body is one shape.** The static files each carry a slightly different
// body (generator jitter, ~0.3 units); the animated ones all share a single
// normalised path, so that is the one used here — `scared`'s animated body was
// diffed against it and is identical to all 386 numbers, which is what says the
// later pair came off the same character rather than a redraw. Rest poses for
// the eyes come from the static files, since the animated ones only have
// keyframes and drift around the pose rather than stating it.
//
// **The eyes are filled, not masked.** In SVG they are knocked out of the body
// so the layer beneath shows through. Reproducing that with a real mask buys
// nothing and costs a compositing group per instance; two fills give identical
// output and let `Theme` pick both ends independently — which is what makes the
// dark-appearance inversion a token rather than a second asset.

/// One eye: a capsule in the source artwork's coordinate space, plus the affine
/// pose that places it. Sizes and poses are in SVG user units (the body spans
/// roughly ±97); `BloubBody.fit(in:)` maps that space onto a view rect.
struct BloubEye: Equatable {
    var size: CGSize
    var pose: CGAffineTransform
}

enum BloubExpression: String, CaseIterable, Sendable {
    case neutral, attentive, surprised, excited, happy, laughing
    case angry, confused, curious, proud, unimpressed, sleepy
    /// Added later than the other twelve, from its own pair of source files.
    ///
    /// Its export encodes the eyes differently — a fixed 40×60 capsule with the
    /// scale carried in the matrix, where the original set sized the rect and
    /// left the transform near unit. Both reduce to the same size-plus-pose the
    /// renderer wants, so the numbers below are the source's verbatim rather
    /// than renormalised: a decomposition would be arithmetic nobody could check
    /// against the file it came from.
    case scared

    private static func e(_ w: CGFloat, _ h: CGFloat, _ a: CGFloat, _ b: CGFloat,
                         _ c: CGFloat, _ d: CGFloat, _ tx: CGFloat, _ ty: CGFloat) -> BloubEye {
        BloubEye(size: CGSize(width: w, height: h),
                 pose: CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty))
    }

    /// Left eye first, as the artwork orders them.
    var eyes: (left: BloubEye, right: BloubEye) {
        let e = Self.e
        switch self {
        case .neutral: return (e(18.6, 41.2, 0.88, -0.31, 0.42, 0.85, 14.25, -28.65),
                               e(18.6, 41.2, 0.65, -0.05, 0.42, 0.85, 50.41, -39.65))
        case .attentive: return (e(21, 44, 0.98, -0.1, 0.1, 0.99, -13.75, -0.33),
                                 e(21, 44, 0.91, -0.08, 0.1, 0.99, 33.42, -4.79))
        case .surprised: return (e(45, 47, 0.95, 0.03, -0.03, 0.95, -30.5, 1.78),
                                 e(45, 47, 0.94, 0.02, -0.03, 0.95, 31.52, 3.36))
        case .excited: return (e(40, 56, 0.97, -0.06, 0.13, 0.95, -18.87, 27.01),
                               e(40, 56, 0.87, 0.06, -0.19, 0.95, 44.38, 29.49))
        case .happy: return (e(27, 17, 0.96, 0.16, -0.19, 0.98, -17.11, -11.86),
                             e(27, 17, 0.88, -0.22, 0.27, 0.96, 29.96, -12.68))
        case .laughing: return (e(34, 13, 0.92, 0.28, -0.33, 0.94, -17.91, -17.72),
                                e(34, 13, 0.86, -0.26, 0.32, 0.94, 32.66, -15.87))
        case .angry: return (e(34, 15, 0.85, 0.46, -0.47, 0.88, -17.48, -9.47),
                             e(34, 15, 0.8, -0.47, 0.48, 0.87, 28.61, -9.52))
        case .confused: return (e(20, 44, 0.86, -0.23, 0.15, 0.97, -35.65, -6.07),
                                e(28, 17, 0.93, 0.36, -0.36, 0.93, 10.35, -0.81))
        case .curious: return (e(24, 46, 0.93, -0.34, 0.36, 0.91, -12.07, 19.79),
                               e(20, 38, 0.8, -0.42, 0.34, 0.9, 39.32, 7.2))
        case .proud: return (e(30, 15, 0.95, 0.2, -0.27, 0.93, -15.34, -25.5),
                             e(30, 15, 0.86, -0.21, 0.32, 0.93, 32.93, -24.57))
        case .unimpressed: return (e(30, 12, 0.75, 0, -0.01, 0.41, -58.45, 1.04),
                                   e(30, 12, 0.99, 0, -0.01, 0.41, -11.92, 1.39))
        // Extracted by script rather than by hand — see the note on the case.
        case .scared: return (e(40, 60, 0.91, 0.16, 0, 0.93, -40.9, 33.11),
                              e(40, 60, 0.96, -0.1, 0, 0.93, 25.18, 31.07))
        case .sleepy: return (e(20, 42, 0.99, -0.02, 0.06, 0.45, -13.65, 13.71),
                              e(20, 42, 0.91, -0.05, 0.06, 0.45, 39.63, 9.84))
        }
    }
}

extension BloubExpression {
    /// Mirrors `Theme.accent(for:)`: the same seven statuses, resolved onto four
    /// faces rather than seven.
    ///
    /// **The face deliberately does not encode the gate.** `needsAttention` and
    /// `waitingQuestion` get the same attentive face as plain work, because the
    /// urgency already has two louder channels — `Theme.accent(for:)` turns the
    /// lamp warm, and the panel opens by itself. Restating an urgent signal in a
    /// softer, cuter channel is how the loud one starts getting ignored, and a
    /// character mugging at somebody mid-approval undercuts a decision that is
    /// supposed to feel weighty.
    ///
    /// `.angry` is reachable through `allCases` but is mapped to by nothing, on
    /// purpose: a tool that looks annoyed at the person paying for it is a
    /// mis-signal in every context this app has. Errors get `.confused`.
    init(for status: SessionStatus) {
        switch status {
        case .idle:                            self = .sleepy
        case .starting, .running:              self = .attentive
        case .needsAttention, .waitingQuestion: self = .attentive
        case .done:                            self = .happy
        case .error:                           self = .confused
        }
    }
}

/// The body outline, in source units, replayed onto a view rect.
struct BloubBody: Shape {
    /// Start point, then 64 cubic segments flattened as c1x c1y c2x c2y px py.
    /// A numeric table rather than a vector asset so a change to the silhouette
    /// shows up in review as numbers that moved.
    private static let start = CGPoint(x: 91.76, y: 0.33)
    private static let curves: [CGFloat] = [
        93.06, 3.31, 94.09, 6.47, 94.78, 9.65,
        95.47, 12.82, 95.86, 16.12, 95.92, 19.37,
        95.98, 22.62, 95.71, 25.93, 95.13, 29.13,
        94.56, 32.33, 93.65, 35.53, 92.46, 38.55,
        91.27, 41.57, 89.75, 44.53, 87.99, 47.26,
        86.23, 49.99, 84.17, 52.6, 81.91, 54.93,
        79.65, 57.27, 77.12, 59.42, 74.45, 61.27,
        71.77, 63.12, 68.87, 64.74, 65.89, 66.03,
        62.91, 67.32, 59.74, 68.34, 56.56, 69.02,
        53.38, 69.7, 49.48, 68.96, 46.83, 70.13,
        44.18, 71.31, 42.86, 74.23, 40.67, 76.06,
        38.47, 77.9, 36.12, 79.62, 33.66, 81.14,
        31.2, 82.65, 28.59, 84.02, 25.92, 85.17,
        23.25, 86.32, 20.46, 87.3, 17.64, 88.05,
        14.81, 88.81, 11.9, 89.36, 8.99, 89.69,
        6.08, 90.03, 3.11, 90.15, 0.19, 90.05,
        -2.74, 89.95, -5.69, 89.63, -8.56, 89.11,
        -11.43, 88.59, -14.29, 87.84, -17.04, 86.91,
        -19.78, 85.98, -22.49, 84.84, -25.05, 83.53,
        -27.62, 82.22, -30.07, 80.66, -32.42, 79.06,
        -34.78, 77.46, -36.4, 74.8, -39.16, 73.94,
        -41.91, 73.07, -45.7, 74.19, -48.95, 73.87,
        -52.2, 73.55, -55.49, 72.92, -58.64, 72.01,
        -61.79, 71.1, -64.93, 69.87, -67.88, 68.39,
        -70.82, 66.91, -73.69, 65.12, -76.32, 63.12,
        -78.95, 61.11, -81.45, 58.82, -83.67, 56.36,
        -85.89, 53.9, -87.92, 51.18, -89.65, 48.35,
        -91.38, 45.51, -92.87, 42.47, -94.05, 39.36,
        -95.23, 36.26, -96.13, 32.99, -96.71, 29.72,
        -97.29, 26.46, -97.57, 23.08, -97.54, 19.77,
        -97.51, 16.46, -97.17, 13.09, -96.53, 9.85,
        -95.89, 6.61, -94.93, 3.38, -93.72, 0.33,
        -92.5, -2.73, -90.97, -5.71, -89.23, -8.48,
        -87.48, -11.24, -85.45, -13.88, -83.25, -16.27,
        -81.05, -18.65, -77.97, -20.6, -76.03, -22.79,
        -74.09, -24.98, -72.47, -26.93, -71.62, -29.41,
        -70.77, -31.89, -71.4, -34.96, -70.93, -37.68,
        -70.46, -40.41, -69.74, -43.15, -68.8, -45.77,
        -67.86, -48.39, -66.67, -50.97, -65.28, -53.4,
        -63.89, -55.82, -62.25, -58.16, -60.45, -60.31,
        -58.66, -62.46, -56.63, -64.49, -54.48, -66.29,
        -52.33, -68.09, -49.98, -69.72, -47.55, -71.12,
        -45.12, -72.51, -42.52, -73.71, -39.89, -74.65,
        -37.26, -75.6, -34.5, -76.32, -31.75, -76.78,
        -29.01, -77.25, -26.18, -77.47, -23.41, -77.46,
        -20.64, -77.44, -17.83, -77.17, -15.13, -76.68,
        -12.43, -76.18, -9.74, -75.44, -7.18, -74.5,
        -4.63, -73.56, -2.14, -72.38, 0.19, -71.04,
        2.51, -69.71, 4.63, -67.64, 6.77, -66.47,
        8.9, -65.3, 10.71, -64.02, 12.98, -64.01,
        15.26, -64, 17.89, -65.83, 20.43, -66.41,
        22.98, -66.98, 25.63, -67.34, 28.26, -67.45,
        30.89, -67.56, 33.59, -67.43, 36.21, -67.06,
        38.83, -66.69, 41.47, -66.07, 43.99, -65.23,
        46.51, -64.39, 49.01, -63.3, 51.34, -62,
        53.68, -60.71, 55.93, -59.18, 58, -57.48,
        60.06, -55.78, 62, -53.86, 63.72, -51.81,
        65.44, -49.76, 66.99, -47.52, 68.31, -45.19,
        69.62, -42.86, 70.74, -40.37, 71.61, -37.85,
        72.48, -35.32, 73.12, -32.68, 73.51, -30.04,
        73.9, -27.41, 72.77, -24.44, 73.96, -22.05,
        75.14, -19.65, 78.45, -17.98, 80.62, -15.67,
        82.79, -13.37, 85.12, -10.89, 86.98, -8.22,
        88.84, -5.55, 90.46, -2.65, 91.76, 0.33
    ]

    /// The outline in source units, untransformed. Internal for the guide's
    /// cloud-to-card morph, which samples it.
    static func outline() -> Path {
        var p = Path()
        p.move(to: start)
        for i in stride(from: 0, to: curves.count, by: 6) {
            p.addCurve(to: CGPoint(x: curves[i + 4], y: curves[i + 5]),
                       control1: CGPoint(x: curves[i], y: curves[i + 1]),
                       control2: CGPoint(x: curves[i + 2], y: curves[i + 3]))
        }
        p.closeSubpath()
        return p
    }

    /// Tight bounds of the outline, taken from the curve itself.
    ///
    /// This was a hand-written literal for one commit and it was wrong: it held
    /// the CONTROL-POINT extents (193×193) where the curve is 193×167, so every
    /// instance drew short and off-centre while looking approximately right.
    /// Control points sit outside the curve they bend, so only the curve knows
    /// its own bounds. Computed once, on first use.
    static let bounds: CGRect = outline().boundingRect

    /// Source space onto `rect`, aspect preserved and centred.
    static func fit(in rect: CGRect) -> CGAffineTransform {
        let s = min(rect.width / bounds.width, rect.height / bounds.height)
        return CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                 tx: rect.midX - bounds.midX * s,
                                 ty: rect.midY - bounds.midY * s)
    }

    func path(in rect: CGRect) -> Path {
        Self.outline().applying(Self.fit(in: rect))
    }
}

/// The eye pair for one expression, with an optional lid scale for the blink.
struct BloubEyes: Shape {
    var expression: BloubExpression
    /// 1 is open, 0 is shut. Scales about each eye's own centre, before its pose,
    /// so a tilted eye closes along its own axis rather than the screen's.
    var lid: CGFloat = 1
    /// Where the eyes look, in source units, added after the pose: the guide's
    /// thinking cloud glances round the screen with it. Zero is the artwork.
    var gaze: CGSize = .zero

    var animatableData: CGFloat {
        get { lid }
        set { lid = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let fit = BloubBody.fit(in: rect)
        let lidScale = CGAffineTransform(scaleX: 1, y: max(lid, 0.0001))
        var p = Path()
        for eye in [expression.eyes.left, expression.eyes.right] {
            let box = CGRect(x: -eye.size.width / 2, y: -eye.size.height / 2,
                             width: eye.size.width, height: eye.size.height)
            // Circular, not continuous: the source corners are true arcs.
            let capsule = Path(roundedRect: box,
                               cornerRadius: min(box.width, box.height) / 2,
                               style: .circular)
            p.addPath(capsule, transform: lidScale.concatenating(eye.pose)
                                                  .translatedBy(gaze)
                                                  .concatenating(fit))
        }
        // Not clipped to the silhouette, and that is a measured decision rather
        // than an omission. The source knocks the eyes out through a mask, which
        // would also trim an eye that overhung the outline — so the question is
        // whether any of them do. None does: every eye of every expression
        // sits wholly inside the body (~22k sampled points, see
        // `testEveryExpressionKeepsItsEyesInsideTheSilhouette`). A path
        // intersection per draw to clip nothing is not worth it. A hand-added
        // expression that overhangs would need one, and that test is what says so.
        return p
    }
}

private extension CGAffineTransform {
    /// Translated in the space it maps INTO (unlike `translatedBy(x:y:)`).
    func translatedBy(_ offset: CGSize) -> CGAffineTransform {
        offset == .zero ? self : concatenating(CGAffineTransform(translationX: offset.width, y: offset.height))
    }
}

/// The character. Body plus eyes, both coloured from `Theme`.
///
/// `animated` is off by default and that is a power decision, not an oversight:
/// this app is resident in the menu bar all day, so a view that never stops
/// interpolating is a cost paid forever for a blink nobody is looking at. Call
/// sites that are genuinely being looked at — onboarding, an empty panel — opt in.
struct BloubView: View {
    var expression: BloubExpression
    /// How often it blinks. Was a `Bool`, which could only say whether motion
    /// happened — and once the resting island started moving too, the channel
    /// needed to carry a RATE or it would have stopped meaning anything.
    var motion: BloubMotion = .still
    /// Overrides the body colour. The compact island passes the amber/blue the
    /// chamber lamp used to carry, so swapping the glyph for a face does not cost
    /// the urgency signal — the tint says how much it matters, the expression says
    /// what is happening, and the blink says whether it is moving. Three channels
    /// where the lamp had two. `nil` keeps the appearance-adaptive body.
    var tint: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Measured off the source keyframes rather than invented: the lid closes to
    /// 23% of open, the close and the open take ~80ms each, and the cycle repeats
    /// every 2.967s.
    private static let shutLid: CGFloat = 0.23
    static let closingDuration: Double = 0.080
    static let openingDuration: Double = 0.086
    static let betweenDuration: Double = 2.967


    @State private var lid: CGFloat = 1

    private var blinkInterval: Double? { reduceMotion ? nil : motion.interval }

    var body: some View {
        ZStack {
            BloubBody().fill(tint ?? Theme.bloubBody)
            BloubEyes(expression: expression, lid: lid).fill(Theme.bloubEyes)
        }
        .aspectRatio(BloubBody.bounds.width / BloubBody.bounds.height, contentMode: .fit)
        .accessibilityHidden(true)
        // Keyed on the interval, so a change of RATE restarts the loop rather
        // than leaving it running at the old cadence.
        .task(id: blinkInterval) {
            guard let interval = blinkInterval else { lid = 1; return }
            await blinkForever(every: interval)
        }
    }

    /// An explicit sleep loop, and NOT `phaseAnimator`, which is what this was.
    ///
    /// The declarative version carried the 2.967s wait in a `held` phase holding
    /// the same lid value as `open` — the idea being that a long transition which
    /// interpolates nothing is free. SwiftUI treats an animation between two
    /// identical values as ALREADY FINISHED, so it advanced instantly: the wait
    /// never happened and the cycle collapsed to close-open-close-open at ~80ms
    /// each. It blinked like a fault light.
    ///
    /// No test caught that, and none here could have — a rendered still frame is
    /// correct at every point of the cycle, and the bug was entirely in when the
    /// frames arrive. It took someone watching the menu bar.
    ///
    /// Sleeping is honest about what this mostly is, which is waiting, and it is
    /// the cheaper of the two: suspended for ~97% of the cycle where an
    /// interpolating animation ticks every frame. `.task` cancels on disappear,
    /// and the lid is restored so a cancelled blink cannot leave the eyes shut.
    @MainActor private func blinkForever(every interval: Double) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { break }
            withAnimation(.easeIn(duration: Self.closingDuration)) { lid = Self.shutLid }
            try? await Task.sleep(for: .seconds(Self.closingDuration))
            guard !Task.isCancelled else { break }
            withAnimation(.easeOut(duration: Self.openingDuration)) { lid = 1 }
            try? await Task.sleep(for: .seconds(Self.openingDuration))
        }
        lid = 1
    }
}
