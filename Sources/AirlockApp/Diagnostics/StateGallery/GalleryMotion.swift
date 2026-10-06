import SwiftUI

/// The five named motions (N), card C1: each one as a filmstrip, the full
/// version above its Reduce Motion version, sampled at the same moments so the
/// two read side by side.
///
/// The frames come from `Motion.progress(at:reduceMotion:)`, the same numbers
/// the animations and the tests use, so a picture here cannot drift from what
/// the screen does. Sizes are true sizes: a Confirm dip of 8% on a small check
/// is small, and that is the point of it.
///
/// In the browse window each row also plays, looping; an exported picture
/// leaves the loop out, so it stays a still.
@MainActor
enum GalleryMotion {
    static let area = "Motion"

    static var states: [GalleryState] {
        [
            GalleryState("N1", area, "Open") {
                MotionStrip(motion: .open, times: springTimes,
                            about: "The island growing out of the notch. Calm: no bounce. The notch "
                                + "still grows, because that shape belongs to the panel itself.")
            },
            GalleryState("N2", area, "Close") {
                MotionStrip(motion: .close, times: springTimes,
                            about: "Tucking back in: a little quicker than Open, and it never overshoots.")
            },
            GalleryState("N3", area, "Swap") {
                MotionStrip(motion: .swap, times: springTimes,
                            about: "Content changing inside a still frame: tabs, guide steps, list "
                                + "updates. The new content rises a few points as it fades in. Calm: a plain cross-fade.")
            },
            GalleryState("N4", area, "Confirm") {
                MotionStrip(motion: .confirm, times: springTimes,
                            about: "A small settle when something is done or reached: it dips and "
                                + "springs back. Calm: it brightens back up instead.")
            },
            GalleryState("N5", area, "Nudge") {
                MotionStrip(motion: .nudge, times: nudgeTimes,
                            about: "A gentle \"look at me\" on the closed island when something needs "
                                + "you. Three beats, then it rests, still visible. Calm: one soft fade.")
            },
        ]
    }

    /// Seconds. Dense early, where the springs do their work, and the last one
    /// after every version has come to rest.
    static let springTimes: [Double] = [0, 0.04, 0.08, 0.12, 0.18, 0.26, 0.36, 0.7]
    /// The tops of the three beats, the rests between them, and after.
    static let nudgeTimes: [Double] = [0, 0.16, 0.32, 0.92, 1.24, 2.16, 2.5, 2.9]
}

extension EnvironmentValues {
    /// True in the browse window, where the motion rows also play live. Off
    /// for the exported pictures, which must be stills.
    @Entry var galleryPlays: Bool = false
}

/// One motion: what it is for, a Full and a Calm filmstrip on one time axis,
/// and in the browse window both playing.
private struct MotionStrip: View {
    var motion: Motion
    var times: [Double]
    var about: String

    @Environment(\.galleryPlays) private var plays

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(about)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            row("Full", calm: false)
            row("Calm", calm: true)
            HStack(spacing: MotionCell.gap) {
                Color.clear.frame(width: MotionStrip.labelWidth, height: 1)
                ForEach(times, id: \.self) { time in
                    Text(verbatim: Self.label(time))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: MotionCell.size.width)
                }
            }
            if plays {
                HStack(spacing: 16) {
                    LiveMotion(motion: motion, calm: false)
                    LiveMotion(motion: motion, calm: true)
                }
                .padding(.top, 6)
            }
        }
    }

    static let labelWidth: CGFloat = 40

    /// Verbatim, so a German or Spanish Mac does not print 1240 ms as
    /// "1.240 ms".
    static func label(_ time: Double) -> String {
        time < 1 ? "\(Int((time * 1000).rounded())) ms" : String(format: "%.2f s", time)
    }

    private func row(_ label: String, calm: Bool) -> some View {
        HStack(spacing: MotionCell.gap) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: Self.labelWidth, alignment: .leading)
            ForEach(times, id: \.self) { time in
                MotionCell(motion: motion, value: motion.progress(at: time, reduceMotion: calm), calm: calm)
            }
        }
    }
}

/// The motion playing on a loop, with a pause at rest between plays.
private struct LiveMotion: View {
    var motion: Motion
    var calm: Bool

    var body: some View {
        let period = motion.duration(reduceMotion: false) + 0.9
        VStack(spacing: 4) {
            TimelineView(.animation) { context in
                let time = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
                MotionCell(motion: motion, value: motion.progress(at: time, reduceMotion: calm), calm: calm)
                    .scaleEffect(2, anchor: .top)
                    .frame(width: MotionCell.size.width * 2, height: MotionCell.size.height * 2, alignment: .top)
            }
            Text(calm ? "Calm, live" : "Full, live")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// One frame: the motion's subject at `value` — progress for the four that
/// travel, lean for Nudge — on a stand-in desktop.
private struct MotionCell: View {
    var motion: Motion
    var value: Double
    var calm: Bool

    static let size = CGSize(width: 62, height: 56)
    static let gap: CGFloat = 5

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.24, green: 0.26, blue: 0.31)
            subject
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(.rect(cornerRadius: 6))
    }

    private var p: CGFloat { CGFloat(value) }

    @ViewBuilder private var subject: some View {
        switch motion {
        case .open: island(grown: p)
        case .close: island(grown: 1 - p)
        case .swap: swap
        case .confirm: confirm
        case .nudge: nudge
        }
    }

    /// The island between its compact size (0) and open (1). Past 1 is a
    /// spring's overshoot, drawn as it is. The content fades in over the
    /// second half, as the panel's own content does.
    private func island(grown: CGFloat) -> some View {
        let compact = CGSize(width: 30, height: 9)
        let open = CGSize(width: 54, height: 42)
        let width = compact.width + (open.width - compact.width) * grown
        let height = compact.height + (open.height - compact.height) * grown
        return VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(.white.opacity(0.55)).frame(width: 26, height: 3)
            Capsule().fill(.white.opacity(0.3)).frame(width: 34, height: 3)
            Capsule().fill(.white.opacity(0.3)).frame(width: 20, height: 3)
        }
        .opacity(Double(min(max((grown - 0.5) * 2, 0), 1)))
        .frame(width: max(width, 0), height: max(height, 0))
        .background(Color.black, in: .rect(bottomLeadingRadius: 8, bottomTrailingRadius: 8))
    }

    /// A still frame: the old lines fade out, the new block fades in, rising
    /// `Motion.swapLift` unless calm.
    private var swap: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(.white.opacity(0.55)).frame(width: 30, height: 3)
                Capsule().fill(.white.opacity(0.3)).frame(width: 22, height: 3)
            }
            .opacity(Double(max(1 - p, 0)))
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.running)
                .frame(width: 26, height: 12)
                .offset(y: calm ? 0 : (1 - p) * Motion.swapLift)
                .opacity(Double(min(max(p, 0), 1)))
        }
        .frame(width: 54, height: 42)
        .background(Color.black, in: .rect(bottomLeadingRadius: 8, bottomTrailingRadius: 8))
    }

    /// `ConfirmSettle`: the kick starts at 1 and the motion carries it home.
    private var confirm: some View {
        let kick = 1 - p
        return Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 26))
            .foregroundStyle(Theme.done)
            .scaleEffect(calm ? 1 : 1 - Motion.confirmDip * kick)
            .opacity(calm ? Double(1 - 0.45 * kick) : 1)
            .frame(maxHeight: .infinity)
    }

    /// `NudgeBeats`: grows a touch with the lean, or dims under Reduce Motion.
    private var nudge: some View {
        BloubView(expression: .attentive, motion: .still, tint: Theme.needs)
            .frame(width: 26, height: 22)
            .scaleEffect(calm ? 1 : 1 + Motion.nudgeGrow * p)
            .opacity(calm ? Double(1 - 0.4 * p) : 1)
            .frame(maxHeight: .infinity)
    }
}
