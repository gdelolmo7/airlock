import SwiftUI
import AirlockCore

/// What the expanded island draws: the drop box while a file the shelf keeps
/// is near the top (`DropPocket`), the panel otherwise.
///
/// One closure for the kit's expanded content, so the switch lives here and
/// not in the kit: the black follows whichever is drawn, and going from one to
/// the other is the kit animating a content size, as it does for a tab change.
struct NotchExpandedContent: View {
    var onCollapse: () -> Void
    var onDragSettled: () -> Void
    var onOpenSettings: () -> Void
    let registry: WidgetRegistry
    @Environment(NotchUIState.self) private var uiState

    var body: some View {
        if let phase = uiState.dropPocket {
            DropPocketView(phase: phase)
                .transition(.opacity)
        } else {
            NotchExpandedView(onCollapse: onCollapse,
                              onDragSettled: onDragSettled,
                              onOpenSettings: onOpenSettings,
                              registry: registry)
                .transition(.opacity)
        }
    }
}

/// The drop box: the places a drop near the top can go, side by side. The
/// shelf, wide, and AirDrop; under them, for a kind of file the box knows,
/// the formats it can become and, past a thin line, what can be done to it
/// (`DropOffer`). Dashed while the file is near, the place under it lit
/// once it is on the box, and once it is dropped, what the drop did.
///
/// No drop handler of its own. `NotchDropCatcher` rests over the box while it
/// is up and takes the drop, and the controller routes it by where it landed,
/// with the same `DropPocketLayout` this draws from.
struct DropPocketView: View {
    let phase: DropPocket.Phase
    @Environment(NotchUIState.self) private var uiState
    @Environment(NotchAppearanceModel.self) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LicenseModel.self) private var license: LicenseModel?

    private var offer: DropOffer { uiState.pocketOffer }
    private var layout: DropPocketLayout { DropPocketLayout(offer: offer) }
    /// False on a plan that leaves out the chips tagged with one: they are
    /// drawn with the tag, and a drop on one is kept on the shelf.
    private var extras: Bool { uiState.pocketExtras }
    /// The place under the file. The shelf until the first move says
    /// otherwise: it is where a drop anywhere else on the box goes.
    private var lit: DropPocketTarget? {
        phase == .over ? (uiState.overPocketTarget ?? .shelf) : nil
    }
    private var litChip: DropChoice? {
        if case .choice(let choice) = lit { return choice }
        return nil
    }
    private var note: DropPocketNote? { phase == .landed ? uiState.pocketNote : nil }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let note {
                landed(note)
                    .frame(width: layout.size.width, height: layout.size.height - DropPocketLayout.top)
                    .offset(y: DropPocketLayout.top)
                    .transition(.opacity)
            } else {
                places
                    .transition(.opacity)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        // Published like the rail's frame, and for the same reason: the drop
        // is routed by where on the box it landed.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PocketFrameKey.self, value: proxy.frame(in: .global))
            }
        )
        .onPreferenceChange(PocketFrameKey.self) { frame in
            if frame.width > 0 { uiState.pocketFrame = frame }
        }
        .onDisappear { uiState.pocketFrame = nil }
        // The same ground as the panel, over-drawn past the kit's black for the
        // same reason — see `NotchExpandedView`.
        .background { appearance.surface.background.padding(-70) }
        .environment(\.colorScheme, appearance.surface.colorScheme)
        .animation(MotionEffect.pointer, value: lit)
        .animation(Motion.confirm.animation(reduceMotion: reduceMotion), value: note)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(note?.line ?? spoken)
    }

    /// Placed by `DropPocketLayout`'s rectangles, not by stacks: a drop is
    /// routed by those same rectangles, so a place drawn anywhere else would
    /// light up in one spot and take the drop in another.
    @ViewBuilder private var places: some View {
        tile(.shelf, symbol: "tray.and.arrow.down.fill", label: String(localized: "Keep on the shelf"), wide: true)
            .frame(width: layout.shelf.width, height: layout.shelf.height)
            .offset(x: layout.shelf.minX, y: layout.shelf.minY)
        tile(.airDrop, symbol: TrayRailDestination.airDrop.symbol,
             label: TrayRailDestination.airDrop.label, wide: false)
            .frame(width: layout.airDrop.width, height: layout.airDrop.height)
            .offset(x: layout.airDrop.minX, y: layout.airDrop.minY)
        if let caption = layout.caption {
            // What a drop on the chip under the file makes, said before the
            // drop rather than discovered after it.
            Text(litChip.map(captionLine) ?? String(localized: "Or drop on one of these"))
                .font(Theme.fixed(13, .medium))
                .foregroundStyle(litChip == nil ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
                .frame(width: caption.width, height: caption.height, alignment: .leading)
                .offset(x: caption.minX, y: caption.minY)
        }
        if let row = layout.formatRow, let inside = layout.formatChips {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.rowFill)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.rowStroke, lineWidth: 1))
                .frame(width: row.width, height: row.height)
                .offset(x: row.minX, y: row.minY)
            PictureChipColumns(spacing: DropPocketLayout.stripSpacing) {
                ForEach(offer.formats, id: \.self) { choice in
                    segment(choice)
                }
            }
            .frame(width: inside.width, height: inside.height)
            .offset(x: inside.minX, y: inside.minY)
        }
        if let line = layout.separator {
            Rectangle()
                .fill(Theme.rowStroke)
                .frame(width: line.width, height: line.height)
                .offset(x: line.minX, y: line.minY)
        }
        if let row = layout.actionRow {
            PictureChipColumns(spacing: DropPocketLayout.actionSpacing) {
                ForEach(offer.actions, id: \.self) { choice in
                    actionBox(choice)
                }
            }
            .frame(width: row.width, height: row.height)
            .offset(x: row.minX, y: row.minY)
        }
    }

    /// One format in the joined strip: no ground of its own, lit under the
    /// file.
    private func segment(_ choice: DropChoice) -> some View {
        let on = litChip == choice
        return Text(choice.label(count: offer.count))
            .font(Theme.fixed(14, .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? Theme.running.opacity(0.22) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(on ? Theme.running : .clear, lineWidth: 1.5))
            )
            .overlay(alignment: .top) {
                if locked(choice), let plan = choice.needs {
                    PlanChipTag(plan: plan).offset(y: -9)
                }
            }
    }

    /// One action: a box, its icon over its words.
    private func actionBox(_ choice: DropChoice) -> some View {
        let on = litChip == choice
        return VStack(spacing: 5) {
            Image(systemName: Self.symbol(choice))
                .font(Theme.fixed(18, .semibold))
                .foregroundStyle(on ? Theme.running : Theme.textSecondary)
            Text(choice.label(count: offer.count))
                .font(Theme.fixed(12, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(on ? Theme.running.opacity(0.16) : Theme.rowFill)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(on ? Theme.running : Theme.rowStroke, lineWidth: on ? 1.5 : 1))
        )
        .overlay(alignment: .top) {
            if locked(choice), let plan = choice.needs {
                PlanChipTag(plan: plan).offset(y: -7)
            }
        }
    }

    private static func symbol(_ choice: DropChoice) -> String {
        switch choice {
        case .smaller: return "arrow.down.right.and.arrow.up.left"
        case .cutOut: return "person.and.background.dotted"
        case .copyText: return "text.viewfinder"
        case .noLocation: return "location.slash"
        case .splitPages: return "doc.on.doc"
        case .noSound: return "speaker.slash"
        case .writeItOut: return "text.quote"
        case .notesFromIt: return "note.text"
        case .nameInOrder: return "list.number"
        default: return "sparkles"
        }
    }

    private func locked(_ choice: DropChoice) -> Bool {
        choice.needs != nil && !extras
    }

    private func captionLine(_ choice: DropChoice) -> String {
        locked(choice) ? (choice.lockedCaption ?? choice.caption(count: offer.count))
            : choice.caption(count: offer.count)
    }

    /// Fixed type, not the panel's scaled type: the box is a fixed size, and
    /// the larger text setting would push the words out of it.
    private func tile(_ target: DropPocketTarget, symbol: String, label: String, wide: Bool) -> some View {
        let on = lit == target
        let icon = Image(systemName: symbol)
            .font(Theme.fixed(wide ? 28 : 26, .semibold))
            .foregroundStyle(on ? Theme.running : Theme.textSecondary)
        let words = Text(label)
            .font(Theme.fixed(wide ? 17 : 15, .semibold))
            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
            .lineLimit(1)
        return ZStack {
            outline(lit: on, tint: Theme.running)
            if wide {
                HStack(spacing: 12) { icon; words }
            } else {
                VStack(spacing: 6) { icon; words }
            }
        }
    }

    private func landed(_ note: DropPocketNote) -> some View {
        let tint = PocketWork.tint(for: note)
        return ZStack {
            outline(lit: true, tint: tint)
            HStack(spacing: 12) {
                if note.work == .none {
                    Image(systemName: note.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(Theme.fixed(28, .semibold))
                        .foregroundStyle(tint)
                    Text(note.line)
                        .font(Theme.fixed(17, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: note.seePlan == nil ? nil : .infinity, alignment: .leading)
                } else {
                    PocketWork(note: note)
                }
                if let plan = note.seePlan {
                    Button {
                        license?.showPlans(from: "drop_box")
                    } label: {
                        Text("See \(plan.label)")
                            .font(Theme.fixed(14, .semibold))
                            .foregroundStyle(PlanTag.plusText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(PlanTag.plusText.opacity(0.16)))
                            .overlay(Capsule().strokeBorder(PlanTag.plusText.opacity(0.5), lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 16)
        }
        .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: note.work)
    }

    /// Dashed while the file is only near, solid and filled under it.
    private func outline(lit: Bool, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(lit ? tint.opacity(0.14) : .clear)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(lit ? tint : Theme.textSecondary,
                              style: StrokeStyle(lineWidth: 1.5, dash: lit ? [] : [6, 5]))
        }
    }

    /// One whole sentence for each mix of rows, so a translation can order
    /// it its own way; the chip lists are joined the way the language joins
    /// a list ("JPG, PNG, or PDF").
    private var spoken: String {
        let formats = offer.formats.map { $0.label(count: offer.count) }
        let actions = offer.actions.map { $0.label(count: offer.count) }
        let asFormats = formats.formatted(.list(type: .or))
        let asActions = actions.formatted(.list(type: .or))
        switch (formats.isEmpty, actions.isEmpty) {
        case (true, true):
            return String(localized: "Drop box: keep it on the shelf, or AirDrop it")
        case (false, true):
            return String(localized: "Drop box: keep it on the shelf, AirDrop it, or get a copy as \(asFormats)")
        case (true, false):
            return String(localized: "Drop box: keep it on the shelf, AirDrop it, or choose \(asActions)")
        case (false, false):
            return String(localized: "Drop box: keep it on the shelf, AirDrop it, get a copy as \(asFormats), or choose \(asActions)")
        }
    }
}

/// How full a chip's cloud is while its work goes, by time alone: nothing
/// in the work reports how far along it is. The pour fills the bottom, then
/// it creeps up and never quite reaches full, which only the finish does.
/// The notch's small cloud carries on from where the box left it.
enum DropWorkFill {
    /// How long the file takes to pour in, and how full that leaves it.
    static let pour: Double = 0.9
    static let poured: CGFloat = 0.12
    /// Where it creeps toward, and how fast: about two thirds of the way
    /// there every `pace` seconds.
    static let ceiling: CGFloat = 0.94
    static let pace: Double = 4

    static func level(after elapsed: Double) -> CGFloat {
        guard elapsed > pour else { return poured * CGFloat(max(elapsed, 0) / pour) }
        let rest = 1 - exp(-(elapsed - pour) / pace)
        return poured + (ceiling - poured) * CGFloat(rest)
    }
}

/// A chip's work in the box: the cloud, the line, and a thin bar under it.
///
/// The file pours into an empty cloud, which fills from the bottom while the
/// work goes, the bar keeping pace. Done, it fills up green, hops, and a tick
/// pops on its shoulder while a few rays shine out. When it can't, it turns
/// orange, shakes its head, and a question mark says the line is why. Never
/// red: nothing is broken, the file is still on the shelf.
///
/// It moves only while the box is up and busy, a few seconds at a time, so
/// the clock can tick every frame without costing anything the rest of the
/// day. With Reduce Motion nothing pours, hops or shakes; the fill still
/// rises, once a second, because it is the news.
private struct PocketWork: View {
    let note: DropPocketNote
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()
    @State private var pouring = false

    static let height: CGFloat = 30
    static let hop: CGFloat = 7
    static let barWidth: CGFloat = 180

    static func tint(for note: DropPocketNote) -> Color {
        note.work == .finished ? Theme.done : note.ok ? Theme.running : Theme.needs
    }

    private var going: Bool { note.work == .going }

    private var face: BloubExpression {
        switch note.work {
        case .none, .going: return .curious
        case .finished: return .happy
        case .failed: return .confused
        }
    }

    var body: some View {
        let tint = Self.tint(for: note)
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : nil, paused: !going)) { context in
            let level = going ? DropWorkFill.level(after: context.date.timeIntervalSince(started)) : 1
            HStack(spacing: 12) {
                cloud(level: level, tint: tint)
                VStack(alignment: .leading, spacing: 7) {
                    Text(note.line)
                        .font(Theme.fixed(17, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    if note.work != .failed {
                        ZStack(alignment: .leading) {
                            Capsule().fill(tint.opacity(0.2))
                            Capsule().fill(tint).frame(width: Self.barWidth * level)
                        }
                        .frame(width: Self.barWidth, height: 4)
                        .transition(.opacity)
                    }
                }
            }
            .animation(Motion.confirm.animation(reduceMotion: reduceMotion), value: note.work)
        }
        .onAppear {
            started = Date()
            if going && !reduceMotion { pouring = true }
        }
    }

    private func cloud(level: CGFloat, tint: Color) -> some View {
        BloubView(expression: face, motion: going ? .working : .still, tint: tint, fill: level)
            .frame(height: Self.height)
            .overlay(alignment: .topTrailing) { badge }
            .background { PocketRays(shine: note.work == .finished && !reduceMotion, tint: tint) }
            .keyframeAnimator(initialValue: CGSize.zero, trigger: note.work) { view, jolt in
                view.offset(jolt)
            } keyframes: { _ in
                KeyframeTrack(\.height) {
                    if note.work == .finished && !reduceMotion {
                        SpringKeyframe(-Self.hop, duration: 0.16, spring: .snappy)
                        SpringKeyframe(0, duration: 0.34, spring: .bouncy)
                    } else {
                        LinearKeyframe(0, duration: 0.01)
                    }
                }
                KeyframeTrack(\.width) {
                    if note.work == .failed && !reduceMotion {
                        LinearKeyframe(-3, duration: 0.07)
                        LinearKeyframe(3, duration: 0.09)
                        LinearKeyframe(-2, duration: 0.08)
                        LinearKeyframe(2, duration: 0.08)
                        LinearKeyframe(0, duration: 0.07)
                    } else {
                        LinearKeyframe(0, duration: 0.01)
                    }
                }
            }
            .overlay(alignment: .top) { PocketPour(pouring: pouring) }
    }

    /// A tick when it's done, a question mark when it can't be.
    @ViewBuilder private var badge: some View {
        let mark: (String, Color)? = switch note.work {
        case .finished: ("checkmark", Theme.done)
        case .failed: ("questionmark", Theme.needs)
        case .none, .going: nil
        }
        if let mark {
            Image(systemName: mark.0)
                .font(Theme.fixed(7, .black))
                .foregroundStyle(Theme.bloubEyes)
                .frame(width: 13, height: 13)
                .background(Circle().fill(mark.1))
                .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                .offset(x: 4, y: -4)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
        }
    }
}

/// The file tipping over above the cloud and pouring into it, once, as the
/// work starts. It rests invisible, so a frame that never plays shows
/// nothing rather than a file stuck mid-pour.
private struct PocketPour: View {
    var pouring: Bool

    private struct Frame {
        var drop: CGFloat = -12
        var tilt: Double = 0
        var stream: CGFloat = 0
        var shown: Double = 0
    }

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .keyframeAnimator(initialValue: Frame(), trigger: pouring) { _, frame in
                ZStack(alignment: .top) {
                    Capsule()
                        .fill(Theme.running)
                        .frame(width: 3, height: 14)
                        .scaleEffect(y: frame.stream, anchor: .top)
                        .offset(x: -3, y: -6)
                    Image(systemName: "doc.fill")
                        .font(Theme.fixed(12, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .rotationEffect(.degrees(frame.tilt), anchor: .bottomLeading)
                        .offset(x: 2, y: -20 + frame.drop)
                }
                .opacity(frame.shown)
                .fixedSize()
            } keyframes: { _ in
                // Plays only when `pouring` turns true, which it does once.
                KeyframeTrack(\.shown) {
                    LinearKeyframe(1, duration: 0.1)
                    LinearKeyframe(1, duration: 0.62)
                    LinearKeyframe(0, duration: 0.18)
                }
                KeyframeTrack(\.drop) {
                    SpringKeyframe(0, duration: 0.25, spring: .snappy)
                }
                KeyframeTrack(\.tilt) {
                    LinearKeyframe(0, duration: 0.25)
                    SpringKeyframe(-110, duration: 0.2, spring: .snappy)
                }
                KeyframeTrack(\.stream) {
                    LinearKeyframe(0, duration: 0.4)
                    LinearKeyframe(1, duration: 0.15)
                    LinearKeyframe(1, duration: 0.25)
                    LinearKeyframe(0, duration: 0.1)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A few short rays shining out from behind the cloud, once, when it's done.
private struct PocketRays: View {
    var shine: Bool
    var tint: Color

    static let count = 6

    var body: some View {
        Color.clear
            .keyframeAnimator(initialValue: CGFloat(0), trigger: shine) { view, t in
                view.overlay {
                    ZStack {
                        ForEach(0..<Self.count, id: \.self) { ray in
                            Capsule()
                                .fill(tint)
                                .frame(width: 2, height: 6)
                                .offset(y: -(20 + 9 * t))
                                .rotationEffect(.degrees(Double(ray) * 360 / Double(Self.count) + 30))
                        }
                    }
                    .opacity(t > 0 && t < 1 ? sin(Double(t) * .pi) : 0)
                }
            } keyframes: { _ in
                if shine {
                    LinearKeyframe(1, duration: 0.6)
                } else {
                    LinearKeyframe(0, duration: 0.01)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct PocketFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 { value = next }
    }
}
