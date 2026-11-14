import SwiftUI
import AirlockCore

// The bloub — Airlock's character. Its geometry (the body outline, every
// expression's eyes) lives in AirlockCore's `BloubArt.swift`, which says where
// it came from and why it is numbers; the desktop widget draws it from there
// too. This file draws it in the app: colours from `Theme`, the blink, the
// fill, the drop of sweat.

/// The body outline, in source units, replayed onto a view rect.
struct BloubBody: Shape {
    /// The outline in source units, untransformed. Internal for the guide's
    /// cloud-to-card morph, which samples it.
    static func outline() -> Path { Path(BloubArt.outline()) }

    /// Tight bounds of the outline (`BloubArt.bounds`).
    static var bounds: CGRect { BloubArt.bounds }

    /// Source space onto `rect`, aspect preserved and centred.
    static func fit(in rect: CGRect) -> CGAffineTransform { BloubArt.fit(in: rect) }

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

/// The drop of sweat on `stressed`, in the same source space as the eyes.
///
/// A tear shape on the top right of the head, half above the outline, which
/// is what makes it read as sweat rather than a spot. It stays clear of both
/// eyes and inside the body's bounds, so it never widens or clips the frame
/// (`BloubTests` holds both).
///
/// `outline` returns the rim as a filled ring rather than asking for a stroke,
/// so the rim's weight is in source units and scales with the character: a
/// fixed one-point line would vanish at 22pt and go heavy at 200.
struct BloubSweat: Shape {
    var outline = false

    /// Rim width, in source units: the mockup's.
    static let rim: CGFloat = 3

    static let drop: Path = {
        var p = Path()
        let tip = CGPoint(x: 70, y: -72)
        p.move(to: tip)
        p.addCurve(to: CGPoint(x: 86, y: -39), control1: tip, control2: CGPoint(x: 86, y: -48))
        // The round bottom, right to left through its lowest point.
        p.addArc(center: CGPoint(x: 70, y: -39), radius: 16,
                 startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.addCurve(to: tip, control1: CGPoint(x: 54, y: -48), control2: tip)
        p.closeSubpath()
        return p
    }()

    func path(in rect: CGRect) -> Path {
        let shape = outline
            ? Self.drop.strokedPath(StrokeStyle(lineWidth: Self.rim, lineJoin: .round))
            : Self.drop
        return shape.applying(BloubBody.fit(in: rect))
    }
}

private extension CGAffineTransform {
    /// Translated in the space it maps INTO (unlike `translatedBy(x:y:)`).
    func translatedBy(_ offset: CGSize) -> CGAffineTransform {
        offset == .zero ? self : concatenating(CGAffineTransform(translationX: offset.width, y: offset.height))
    }
}

/// The part of a filling cloud's frame that is full: a band rising from the
/// bottom. Animatable, so a jump to full on a finish springs rather than snaps.
struct BloubFillLevel: Shape {
    var level: CGFloat

    var animatableData: CGFloat {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let height = rect.height * min(max(level, 0), 1)
        return Path(CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height))
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
    /// How full the body is, 0 to 1, for a cloud that fills while work goes.
    /// Below the level the body is its colour; above it, a faint ghost of it.
    /// `nil` is a whole body, as everywhere else.
    var fill: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The ghost's strength: enough that the empty part still reads as the
    /// cloud, and its dark eyes still show on it over black.
    static let ghost: Double = 0.42

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
            if let fill {
                BloubBody().fill((tint ?? Theme.bloubBody).opacity(Self.ghost))
                BloubBody().fill(tint ?? Theme.bloubBody)
                    .mask(BloubFillLevel(level: fill))
            } else {
                BloubBody().fill(tint ?? Theme.bloubBody)
            }
            BloubEyes(expression: expression, lid: lid).fill(Theme.bloubEyes)
            if expression.sweats {
                BloubSweat().fill(Theme.bloubSweat)
                BloubSweat(outline: true).fill(Theme.bloubEyes)
            }
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
