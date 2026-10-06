import AirlockCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Panel section: CPU, GPU and memory as three rings, and under them, while the
/// panel is open, the apps the CPU is going to.
struct SystemStatsSectionView: View {
    @Environment(SystemStatsWidgetModel.self) private var system

    var body: some View {
        // Drawn before the first figure too: the CPU needs two readings, three
        // to six seconds apart, and a card that appeared only then pushed
        // everything under it down while somebody was reading it.
        SystemStatsContent(stats: system.stats, apps: system.cpuByApp)
    }
}

/// The section as a function of what it shows, so it can be drawn from sample
/// data as well as from the model.
///
/// **Redrawn 2026-10-01 as rings, after the owner asked for it to "make
/// sense".** It was three labelled bars, two of them carrying two minutes of
/// history as a strip of columns. Side by side those were three different
/// shapes for one kind of number, an idle Mac drew a row of stubs that read as
/// a broken graph, and a normal 65% memory figure was painted amber. A ring
/// with the figure in its middle says one thing — how full — the same way
/// three times, and the colour is kept for when something is actually wrong.
struct SystemStatsContent: View {
    /// nil until the first figures are in: the rings are drawn empty, at
    /// their real size, and fill when they arrive.
    let stats: SystemStats?
    let apps: CPUByApp

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(symbol: "laptopcomputer", title: "This Mac")
            HStack(alignment: .top, spacing: 0) {
                LoadRing(label: "CPU", order: 0,
                         // The list under the rings is held to this exact figure.
                         percent: stats.map { Double(CPUBreakdown.displayedPercent(of: $0.cpuPercent)) },
                         tint: LoadRing.tint(stats?.cpuPercent ?? 0, busyAt: 75, fullAt: 90),
                         detail: "Processor")
                // The Mac did not say. No ring, rather than one reading 0%.
                // Before the first reading nobody knows yet, so it is drawn
                // waiting with the others: most Macs do report one.
                if stats == nil || stats?.gpuPercent != nil {
                    let gpu = stats?.gpuPercent
                    LoadRing(label: "GPU", order: 1, percent: gpu,
                             tint: LoadRing.tint(gpu ?? 0, busyAt: 75, fullAt: 90),
                             detail: "Graphics")
                }
                LoadRing(label: "Memory", order: 2, percent: stats?.memoryPercent,
                         // macOS keeps memory full on purpose — it caches — so
                         // memory is only worth a colour much later than the CPU.
                         tint: LoadRing.tint(stats?.memoryPercent ?? 0, busyAt: 88, fullAt: 95),
                         detail: stats.map {
                             String(format: "%.1f of %.0f GB in use", $0.memoryUsedGB, $0.memoryTotalGB)
                         } ?? "Memory")
            }
            .padding(.top, 10)
            CPUByAppView(apps: apps)
        }
        .modifier(HomeCardBackground())
    }
}

/// How full one thing is: an arc on a faint track, the figure inside it, the
/// name under it.
///
/// **It moves (owner, 2026-10-04: "they simply move directly from one spot to
/// another").** Opening the tab sweeps each ring up from empty, a beat apart
/// left to right, and a new reading glides the arc there while the figure rolls
/// its digits. Under Reduce Motion it is drawn at the value, as before.
private struct LoadRing: View {
    let label: String
    /// Left to right, for the stagger when the tab opens.
    let order: Int
    /// nil before the first reading: an empty track and a dash, never "0%".
    let percent: Double?
    let tint: Color
    /// The tooltip and what VoiceOver adds after the figure.
    let detail: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the arc draws: starts empty and follows `percent` under animation.
    @State private var drawn: Double = 0

    /// Scaled with the text, so "100%" still fits inside at the largest size.
    private var diameter: CGFloat { ceil(46 * Theme.textScale) }
    private static let lineWidth: CGFloat = 4.5

    /// Brand blue while things are fine; amber, then red, only past the point
    /// where somebody would want to know.
    static func tint(_ percent: Double, busyAt: Double, fullAt: Double) -> Color {
        switch percent {
        case ..<busyAt: return Theme.running
        case ..<fullAt: return Theme.needs
        default: return Theme.danger
        }
    }

    var body: some View {
        let clamped = min(max(percent ?? 0, 0), 100)
        let figure = percent == nil ? "–" : "\(Int(clamped.rounded()))%"
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: Self.lineWidth)
                if percent != nil {
                    Circle()
                        // A sliver at zero, so an idle ring still shows where it starts.
                        .trim(from: 0, to: max(0.015, drawn / 100))
                        .stroke(tint, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(figure)
                    .font(Theme.chrome(11.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: clamped))
                    .animation(reduceMotion ? nil : MotionEffect.ringGlide, value: Int(clamped.rounded()))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, Self.lineWidth + 2)
            }
            .frame(width: diameter, height: diameter)
            Text(label)
                .font(Theme.chrome(10.5, .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : MotionEffect.ringGlide, value: tint)
        .onAppear {
            guard !reduceMotion else { drawn = clamped; return }
            withAnimation(MotionEffect.ringSweep(order: order)) { drawn = clamped }
        }
        .onChange(of: clamped) { _, next in
            withAnimation(reduceMotion ? nil : MotionEffect.ringGlide) { drawn = next }
        }
        .help(percent == nil ? "\(label): measuring" : "\(label): \(figure) · \(detail)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(percent == nil ? "Measuring" : "\(Int(clamped.rounded())) percent, \(detail)")
    }
}

// MARK: - Which apps

/// The apps the CPU is going to, under the rings: at most three rows and,
/// under them, the leftover line, each a share of the whole Mac — the CPU
/// ring's own unit, so the lines add up to the figure above them and never
/// past it. The leftover is last however big it is, so the icons stay one
/// unbroken column and the apps, which are what the list is read for, come
/// first (`CPUBreakdown`).
///
/// Every row is whole or absent. When the panel is short of room the list
/// shows fewer rows, folding the rest into the leftover, rather than rows cut
/// in half at the bottom of the scroll region (`yieldingContentRoom`).
private struct CPUByAppView: View {
    let apps: CPUByApp
    @Environment(\.yieldingContentRoom) private var room
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The list's heading on an idle Mac.
    static let nothingBusy = "Nothing busy"
    /// Between the rings and the list.
    private static let gap: CGFloat = 8
    private static let rowSpacing: CGFloat = 3
    private var captionHeight: CGFloat { ceil(13 * Theme.textScale) }
    private var rowHeight: CGFloat { ceil(16 * Theme.textScale) }
    private var iconSize: CGFloat { ceil(14 * Theme.textScale) }

    private struct Row: Identifiable {
        let line: CPUBreakdown.Line
        let name: String
        let percent: Int
        var id: String { line.id }
    }

    var body: some View {
        switch apps {
        case .hidden:
            EmptyView()
        case .measuring:
            // One quiet line: a list is the difference between two sweeps, and
            // until the second is in there is nothing honest to rank.
            if room >= Self.gap + captionHeight {
                caption(trailing: "Measuring…")
                    .padding(.top, Self.gap)
                    .reportsYieldingHeight()
            }
        case .breakdown(let breakdown) where breakdown.isEmpty:
            // An idle Mac has no line at 1% or more. The heading stays and
            // says so: a list that vanished took its height with it, so the
            // card jumped every time the Mac went quiet and back.
            if room >= Self.gap + captionHeight {
                caption(trailing: Self.nothingBusy)
                    .padding(.top, Self.gap)
                    .reportsYieldingHeight()
            }
        case .breakdown(let breakdown):
            let fitted = breakdown.fitted(maxLines: lines(fittingIn: room))
            // Empty here only when the room is too short for one whole row.
            if !fitted.isEmpty {
                let rows = rows(of: fitted)
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    caption(trailing: nil)
                    ForEach(rows) { row in
                        rowView(row)
                            .transition(.opacity)
                    }
                }
                // An app overtaking another slides past it rather than the
                // two names swapping in place, and a figure rolls its digits.
                .animation(MotionEffect.reading(reduceMotion: reduceMotion),
                           value: rows.map { "\($0.id)·\($0.percent)" })
                .padding(.top, Self.gap)
                .reportsYieldingHeight()
            }
        }
    }

    /// The most lines the room holds under the caption.
    private func lines(fittingIn room: CGFloat) -> Int {
        var count = CPUBreakdown.maximumLines
        while count > 0, Self.gap + captionHeight + CGFloat(count) * (Self.rowSpacing + rowHeight) > room {
            count -= 1
        }
        return count
    }

    private func rows(of breakdown: CPUBreakdown) -> [Row] {
        zip(breakdown.lines, breakdown.displayedPercents).map { line, percent in
            Row(line: line, name: breakdown.name(of: line), percent: percent)
        }
    }

    private func caption(trailing: String?) -> some View {
        HStack {
            Text("Busiest apps")
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing)
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(height: captionHeight)
    }

    private func rowView(_ row: Row) -> some View {
        // The leftover is quieter than the apps: no icon, since it is no app,
        // and the tertiary colour the section's labels use.
        let tint = row.line.isLeftover ? Theme.textTertiary : Theme.textSecondary
        return HStack(spacing: 6) {
            Group {
                if let group = row.line.group {
                    Image(nsImage: ProcessGroupIcon.image(for: group))
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    // The empty slot keeps the leftover's name in line with
                    // the apps' names.
                    Color.clear
                }
            }
            .frame(width: iconSize, height: iconSize)
            Text(row.name)
                .font(Theme.chrome(11))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text("\(row.percent)%")
                .font(Theme.chrome(10, .medium))
                .foregroundStyle(tint)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(row.percent)))
        }
        .frame(height: rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(row.percent)% of CPU")
    }
}

/// Icons for the list's rows, looked up once per group rather than on every
/// redraw: LaunchServices caches too, but asking it is still a round trip,
/// and the list redraws every three seconds.
@MainActor
private enum ProcessGroupIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for group: ProcessGroup) -> NSImage {
        if let image = cache[group.key] { return image }
        let image = lookUp(group)
        // Bounded: groups come and go with the processes behind them.
        if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
        cache[group.key] = image
        return image
    }

    private static func lookUp(_ group: ProcessGroup) -> NSImage {
        let workspace = NSWorkspace.shared
        switch group.kind {
        case .app:
            guard let path = group.bundlePath else { return workspace.icon(for: .application) }
            return workspace.icon(forFile: path)
        case .simulator:
            if let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.iphonesimulator") {
                return workspace.icon(forFile: url.path)
            }
        case .system:
            if group == .spotlight {
                return workspace.icon(forFile: "/System/Library/CoreServices/Spotlight.app")
            }
        case .program:
            break
        }
        // A command-line program has no icon of its own; the generic one says
        // "a program" without pretending to be the terminal it runs in.
        return workspace.icon(for: .unixExecutable)
    }
}
