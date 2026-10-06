import AirlockCore
import AppKit
import SwiftUI

/// The trackpad ticks (card D3): every moment `Moment.tick` names gets its
/// bump here, behind one switch, and nowhere else.
///
/// Listening to `Moments` rather than firing at each call site is what keeps a
/// tick from doubling: the announcer already counts the same moment twice in
/// a quarter second once, and the guards that decide whether a moment
/// happened at all — the hover tick's not-while-hidden, its arbiter edge —
/// stay at the call sites, unchanged.
///
/// Only Force Touch trackpads have an actuator. With a mouse the call does
/// nothing, which is the right answer.
@MainActor
enum Ticks {
    static let defaultsKey = "feel.trackpadTicks"

    /// "Trackpad feedback" in Settings › General. On by default: a tick is
    /// felt only by a finger already on the trackpad, so it cannot reach
    /// anyone who did not just touch something.
    static var isOn: Bool { Defaults.bool(defaultsKey, default: true) }

    /// `enabled` and `perform` are there for the tests, which must neither
    /// write a real preference nor reach for the actuator.
    static func listen(to moments: Moments = .shared,
                       enabled: @escaping @MainActor () -> Bool = { isOn },
                       perform: @escaping @MainActor (NSHapticFeedbackManager.FeedbackPattern) -> Void = Self.perform) {
        for moment in Moment.allCases {
            guard let tick = moment.tick else { continue }
            moments.listen(to: moment) {
                guard enabled() else { return }
                perform(pattern(for: tick))
            }
        }
    }

    static func pattern(for tick: TrackpadTick) -> NSHapticFeedbackManager.FeedbackPattern {
        switch tick {
        case .light: .alignment
        case .settle: .generic
        case .firm: .levelChange
        }
    }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }
}

/// The soft stop: a scroll view that announces `.scrolledToEnd` when the
/// person scrolls it into either end (card D3, M25).
///
/// Only while a finger is on it (`.interacting`). A fling that coasts into
/// the end has left the trackpad already, and content growing under a still
/// list — a row copied in, an answer streaming — is not something the person
/// did.
private struct ScrollEndTick: ViewModifier {
    let axis: Axis

    @State private var scrolling = false

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                scrolling = phase == .interacting
            }
            .onScrollGeometryChange(for: ScrollEnd?.self) { geometry in
                // The insets are part of the travel: the offset reads
                // -inset.top at the start and runs to content + inset.bottom.
                let insets = geometry.contentInsets
                let (offset, content, visible, lead, trail) = axis == .vertical
                    ? (geometry.contentOffset.y, geometry.contentSize.height,
                       geometry.containerSize.height, insets.top, insets.bottom)
                    : (geometry.contentOffset.x, geometry.contentSize.width,
                       geometry.containerSize.width, insets.leading, insets.trailing)
                return ScrollEnd.at(offset: Double(offset + lead),
                                    content: Double(content + lead + trail),
                                    visible: Double(visible))
            } action: { before, after in
                guard scrolling, ScrollEnd.reached(from: before, to: after) else { return }
                Moments.shared.announce(.scrolledToEnd, after == .start ? "start" : "end")
            }
    }
}

extension View {
    /// A soft trackpad tick when the person scrolls this into either end.
    func ticksAtScrollEnds(_ axis: Axis = .vertical) -> some View {
        modifier(ScrollEndTick(axis: axis))
    }
}
