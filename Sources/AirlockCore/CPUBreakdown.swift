import Foundation

/// The System panel's "which apps" list: at most three apps and one leftover
/// line, in the same unit as the CPU meter above it.
///
/// **One unit, the whole Mac.** A share is CPU time over the reading's span
/// divided by every core's worth of that span, so it is directly comparable to
/// the headline and the lines add up to it. Per-core percentages — Activity
/// Monitor's "250%" — would put a figure bigger than the meter under the meter.
///
/// **Load does not vanish.** Whatever part of the headline the apps shown do not
/// account for is one leftover line: other users' processes (the kernel, the
/// window server), apps too small to list, apps past the three-row cap, and CPU
/// the sweep could not place. So the lines always add up to the headline —
/// never more, never negative — and a busy Mac never reads as three small rows
/// and a mystery.
///
/// **The apps, then the leftover.** The leftover goes under the apps at every
/// length, however big it is. It is the one line that is not an app — no icon,
/// the quieter colour, nothing in it anyone can quit — and the list is read to
/// find the app to quit. Placed among the apps by size, as it first was, it
/// broke the column of icons and read as one more app, and with room for two
/// lines it put "Everything else 46%" over the "Xcode 41%" that was the answer.
/// At the bottom its figure is still there, which is all "load does not vanish"
/// asks of it.
///
/// Made by `CPUBreakdownRanker`, which is the only thing that knows what the
/// list looked like last time.
public struct CPUBreakdown: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            case group(ProcessGroup)
            case leftover
        }

        public let kind: Kind
        /// Percent of the whole Mac.
        public let share: Double

        public init(kind: Kind, share: Double) {
            self.kind = kind
            self.share = share
        }

        public var id: String {
            switch kind {
            case .group(let group): return group.key
            case .leftover: return "leftover"
            }
        }

        public var group: ProcessGroup? {
            if case .group(let group) = kind { return group }
            return nil
        }

        public var isLeftover: Bool { kind == .leftover }
    }

    /// The list at one length.
    struct Fit: Equatable, Sendable {
        var lines: [Line]
        var leftoverHoldsApps: Bool
    }

    /// The CPU meter's figure for the same span.
    public let headline: Double
    /// `fits[n - 1]` is the list in at most `n` lines: the ranked apps from the
    /// top, then the leftover. Every length takes its rows from the one ranking,
    /// so a panel that is short of room shows the same apps in the same order
    /// as one with room to spare, and is as steady.
    let fits: [Fit]

    init(headline: Double, fits: [Fit]) {
        self.headline = headline
        self.fits = fits
    }

    /// In display order: the apps by rank, then the leftover.
    public var lines: [Line] { fits.last?.lines ?? [] }

    /// Whether an app big enough for a row of its own is inside the leftover —
    /// past the three-row cap, or out of room in the panel. It decides the
    /// leftover's name; see `leftoverName`.
    public var leftoverHoldsApps: Bool { fits.last?.leftoverHoldsApps ?? false }

    /// Nothing at or above the threshold: an idle Mac, which shows no list and
    /// no filler text.
    public var isEmpty: Bool { lines.isEmpty }

    /// A line is drawn at 1% of the whole Mac and above. Below that it is noise
    /// on a 0–100 meter, and a list of 0% rows is a list that says nothing.
    public static let threshold: Double = 1

    /// Two lines only change places when one leads by a whole point. Readings
    /// every three seconds jitter by fractions of a point, and a list that
    /// reorders on every one of them cannot be read.
    public static let hysteresis: Double = 1

    /// "At most three app rows plus the leftover line."
    public static let maximumApps = 3

    /// The most lines the list can ever be: the apps and the leftover.
    public static var maximumLines: Int { maximumApps + 1 }

    // MARK: - Naming the leftover

    /// What the leftover is called while it holds only what the list could
    /// never have named: other users' processes, which are macOS's own, and
    /// the owner's processes too small for a row.
    public static let backgroundName = "macOS & background"

    /// What it is called once an app that would have had a row is inside it.
    /// "macOS & background" around a 3% Spotify would be false, and the
    /// vaguer name is always true.
    public static let everythingElseName = "Everything else"

    public var leftoverName: String {
        leftoverHoldsApps ? Self.everythingElseName : Self.backgroundName
    }

    public func name(of line: Line) -> String {
        line.group?.name ?? leftoverName
    }

    // MARK: - From seconds to shares

    /// CPU seconds per group over `window`, as percent of every core's worth of
    /// that window. Non-finite and non-positive figures are dropped.
    public static func shares(seconds: [ProcessGroup: Double], window: TimeInterval,
                              processors: Int) -> [ProcessGroup: Double] {
        guard window > 0, processors > 0 else { return [:] }
        let capacity = window * Double(processors)
        return seconds.compactMapValues { used in
            guard used.isFinite, used > 0 else { return nil }
            return used / capacity * 100
        }
    }

    // MARK: - Fitting the panel

    /// The same list in at most `maxLines` lines, for a panel short of room.
    /// Fewer rows, never truncated ones: the lowest-ranked apps are folded into
    /// the leftover, which is never itself dropped, because that would be load
    /// vanishing.
    public func fitted(maxLines: Int) -> CPUBreakdown {
        guard maxLines < fits.count else { return self }
        return CPUBreakdown(headline: headline, fits: Array(fits.prefix(max(0, maxLines))))
    }

    /// `apps` in rank order, folded from the bottom until they and the leftover
    /// fit in `maxLines`, and the leftover under them. Folding from the bottom
    /// of the ranked order rather than by the smallest figure keeps the choice
    /// as steady as the ranking: two apps within a point of each other do not
    /// take turns at the last row.
    static func fold(_ apps: [Line], headline: Double, maxLines: Int) -> Fit {
        var apps = apps
        var folded = false
        func leftover() -> Double { max(0, headline - apps.reduce(0) { $0 + $1.share }) }
        while !apps.isEmpty, apps.count + (leftover() >= threshold ? 1 : 0) > maxLines {
            apps.removeLast()
            folded = true
        }
        // One line of "Everything else" under a meter showing the same figure
        // says nothing: no list at all is the honest version.
        if folded, apps.isEmpty { return Fit(lines: [], leftoverHoldsApps: true) }
        let rest = leftover()
        if rest >= threshold { apps.append(Line(kind: .leftover, share: rest)) }
        return Fit(lines: apps, leftoverHoldsApps: folded)
    }

    // MARK: - Drawn as whole numbers

    /// The whole-number percent each line shows, in line order.
    ///
    /// Rounding each line on its own can make them add up to more than the
    /// meter above them — 20.5 and 20.5 show as 21 and 21 under a meter reading
    /// 41. So every line starts from its figure rounded down, and the ones with
    /// the largest remainders are rounded up while the total stays within the
    /// meter's own figure (`displayedPercent(of:)`). Each line is still its share
    /// rounded down or to nearest, and a line over the threshold never shows 0.
    public var displayedPercents: [Int] {
        let target = Self.displayedPercent(of: headline)
        var values = lines.map { Int(max(0, $0.share).rounded(.down)) }
        var budget = target - values.reduce(0, +)
        let byRemainder = lines.indices.sorted { a, b in
            let ra = lines[a].share - Double(values[a]), rb = lines[b].share - Double(values[b])
            return ra != rb ? ra > rb : a < b
        }
        for index in byRemainder {
            guard budget > 0, lines[index].share - Double(values[index]) >= 0.5 else { break }
            values[index] += 1
            budget -= 1
        }
        return values
    }

    /// How the CPU meter writes a percentage. Shared so the list can be held to
    /// the meter's own figure rather than to a differently rounded one.
    public static func displayedPercent(of value: Double) -> Int {
        Int(clampedPercent(value).rounded())
    }

    static func clampedPercent(_ value: Double) -> Double {
        guard value.isFinite else { return value.isNaN ? 0 : (value > 0 ? 100 : 0) }
        return min(100, max(0, value))
    }
}

/// Turns each reading's shares into a `CPUBreakdown`, remembering what it drew
/// last time so lines only move when the numbers genuinely say so.
///
/// Value-typed and clockless like `SystemTraceRecorder`. The model holds one
/// and forgets it when the panel closes, so a reopened panel is ordered by size
/// rather than by whatever was on screen minutes ago.
public struct CPUBreakdownRanker: Equatable, Sendable {
    /// Every app over the threshold, including the ones past the row cap — so a
    /// fourth app has to beat the third by a whole point to take its row,
    /// rather than the two taking turns at it.
    ///
    /// The only order remembered. Each length of the list is the top of this
    /// one and the leftover under it, so nothing is left to order per length —
    /// which was also the one pass that ever moved the leftover.
    private var candidateOrder: [String] = []
    /// Whether the leftover has held an app at each length since the panel
    /// opened. Once it has, it keeps the vaguer name until the panel closes:
    /// a fourth app hovering at the threshold would otherwise rename the line
    /// every few seconds.
    private var heldApps: [Bool] = []

    public init() {}

    /// `shares` is percent of the whole Mac per group, `headline` the CPU
    /// meter's figure for the same span.
    ///
    /// If the shares add up to more than the headline — the two are separate
    /// measurements, taken a few milliseconds apart — they are scaled down to
    /// it, so the lines can never add up to more than the meter above them.
    public mutating func rank(shares: [ProcessGroup: Double], headline: Double) -> CPUBreakdown {
        let headline = CPUBreakdown.clampedPercent(headline)
        let finite = shares.compactMapValues { $0.isFinite && $0 > 0 ? $0 : nil }
        let total = finite.values.reduce(0, +)
        let scale = total > headline && total > 0 ? headline / total : 1

        let candidates = finite.compactMap { group, share -> CPUBreakdown.Line? in
            let scaled = share * scale
            return scaled >= CPUBreakdown.threshold
                ? CPUBreakdown.Line(kind: .group(group), share: scaled) : nil
        }
        let ranked = Self.stableOrder(candidates, previous: candidateOrder)
        candidateOrder = ranked.map(\.id)

        let shown = Array(ranked.prefix(CPUBreakdown.maximumApps))
        let overflow = ranked.count > shown.count
        let fits = (1...CPUBreakdown.maximumLines).map { length -> CPUBreakdown.Fit in
            let slot = length - 1
            var fit = CPUBreakdown.fold(shown, headline: headline, maxLines: length)
            fit.leftoverHoldsApps = fit.leftoverHoldsApps || overflow
                || (slot < heldApps.count && heldApps[slot])
            return fit
        }
        heldApps = fits.map(\.leftoverHoldsApps)
        return CPUBreakdown(headline: headline, fits: fits)
    }

    public mutating func forget() { self = CPUBreakdownRanker() }

    /// Largest first, except that a line only goes ahead of one it followed
    /// last time when it leads it by `CPUBreakdown.hysteresis`. Ties — and
    /// lines with no previous place — go by size, then by name.
    ///
    /// Built greedily: at each step the candidates are the lines no remaining
    /// line leads by a whole point, and of those the one placed earliest last
    /// time goes next. So no line is ever drawn above one that leads it by a
    /// point or more, and within a point the previous order stands.
    ///
    /// Apps only. The leftover is never ranked: `fold` puts it under them.
    static func stableOrder(_ lines: [CPUBreakdown.Line], previous: [String]) -> [CPUBreakdown.Line] {
        let place = Dictionary(previous.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var remaining = lines
        var ordered: [CPUBreakdown.Line] = []
        ordered.reserveCapacity(lines.count)
        while let top = remaining.map(\.share).max() {
            var best: Int?
            for index in remaining.indices where remaining[index].share > top - CPUBreakdown.hysteresis {
                guard let current = best else { best = index; continue }
                if precedes(remaining[index], remaining[current], place: place) { best = index }
            }
            ordered.append(remaining.remove(at: best!))
        }
        return ordered
    }

    private static func precedes(_ a: CPUBreakdown.Line, _ b: CPUBreakdown.Line,
                                 place: [String: Int]) -> Bool {
        let pa = place[a.id] ?? .max, pb = place[b.id] ?? .max
        if pa != pb { return pa < pb }
        if a.share != b.share { return a.share > b.share }
        let na = sortName(a), nb = sortName(b)
        if na != nb { return na < nb }
        return a.id < b.id
    }

    private static func sortName(_ line: CPUBreakdown.Line) -> String {
        line.group?.name.lowercased() ?? ""
    }
}
