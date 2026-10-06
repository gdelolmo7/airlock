import Foundation

/// How often the system meters are sampled, and whether anyone needs them
/// sampled at all.
///
/// Pure so the answer is one table rather than a condition spread over a poll
/// loop, a toggle's `didSet` and a presentation callback.
public enum SystemSampling: Sendable {
    /// The panel is open with the widget on — the numbers are being read, and a
    /// CPU figure that only moves twice in the time the panel is up reads as a
    /// dead meter.
    public static let attentive: TimeInterval = 3

    /// Nobody is looking. Slowed, not stopped, and **not slowed to the point
    /// where the history breaks**, which is the whole of this cluster's fix.
    ///
    /// The trace draws the last two minutes. Two minutes of history cannot be
    /// gathered inside a panel that, under the expansion contract, lives for
    /// seconds — so it has to already exist when the panel opens, and that means
    /// the sampler keeps running while it is shut. At 30s it did not: every
    /// spacing exceeded the trace's tolerance, so every reopen wiped the trace
    /// and the meter drew an empty box that gained one column at a time.
    ///
    /// Six seconds is a deliberate multiple of `attentive`: it is exactly one
    /// trace column, and `attentive` is exactly half of one, so **every column
    /// covers the same six seconds whether the panel is open or shut**. A column
    /// width that means one thing at the left of the trace and another at the
    /// right is the failure the fixed scale exists to avoid.
    ///
    /// The cost this gives back is small and bounded: two Mach traps, one read
    /// of the GPU's statistics from the I/O Registry (~0.05 ms, measured over
    /// 200 reads) and one timer wakeup every six seconds, against the
    /// one-per-second poll this widget shipped with. The presentation callback
    /// is not fired at all while the panel is shut — see `SystemStatsWidgetModel`.
    public static let dormant: TimeInterval = 6

    /// `nil` means do not sample at all — there is no reader and no baseline
    /// worth keeping warm, because switching the widget back on re-primes from
    /// scratch anyway.
    public static func interval(panelVisible: Bool, widgetEnabled: Bool) -> TimeInterval? {
        guard widgetEnabled else { return nil }
        return panelVisible ? attentive : dormant
    }

    /// Whether a reading also sweeps the process table for the per-app CPU
    /// list. It rides on the same readings as everything else — there is no
    /// second timer — but **only while the panel is open**.
    ///
    /// A sweep is not cheap enough to run for nobody. Measured on the Mac this
    /// was built on (M5 Pro, ~1,470 processes of which ~1,260 the owner's, four
    /// iOS Simulators booted), release build at background priority: a median
    /// of 7.6 ms of CPU per sweep (6–11 ms) once each process's path is known,
    /// and ~100 ms for the first sweep after launch, which looks up every one.
    /// The rest of a reading is two Mach traps and the ~0.05 ms GPU read. The
    /// price of sweeping only while the panel is open is visible and short: a
    /// list is a difference between two sweeps, so the panel says "Measuring…"
    /// until the second reading after it opens — three to six seconds, because
    /// the first lands within one attentive interval of opening.
    public static func sweepsProcesses(panelVisible: Bool, widgetEnabled: Bool) -> Bool {
        widgetEnabled && panelVisible
    }
}

/// A short, **fixed-scale** history of a 0–100 percentage.
///
/// The fixed scale is the entire point. A trace normalised to its own peak
/// draws an idle machine and a pegged one identically — 3% and 90% both become
/// a full-height column, and the shape stops carrying information precisely
/// when it would be worth reading. Here 100 is 100 and nothing else ever is, so
/// height means load.
///
/// Bounded on both axes by construction: `capacity` columns, each covering
/// `column` seconds, nothing retained beyond `window`. There is no timer in here
/// and no clock — columns are cut by `SystemTraceRecorder`, which is told how
/// long it has been since the last sample by the only thing that can know.
public struct SystemTrace: Equatable, Sendable {
    /// Columns.
    public static let capacity: Int = 20

    /// The span one column covers. Equal to `SystemSampling.dormant` and twice
    /// `SystemSampling.attentive`, so the sampler's two rates both divide it and
    /// no column is ever wider than its neighbour.
    public static var column: TimeInterval { SystemSampling.dormant }

    /// The span the full trace describes: two minutes.
    public static var window: TimeInterval { Double(capacity) * column }

    /// Below this many columns there is no shape to read, and a nearly-empty
    /// track is not a smaller picture — it reads as "idle for two minutes". The
    /// caller draws its instantaneous meter instead; see `readable`.
    public static let minimumColumns: Int = 3

    /// Oldest first, each clamped to 0...100, never more than `capacity`.
    public private(set) var samples: [Double]

    public init(samples: [Double] = []) {
        self.samples = Self.bounded(samples.map(Self.clamped))
    }

    public var isEmpty: Bool { samples.isEmpty }
    public var latest: Double? { samples.last }
    public var peak: Double? { samples.max() }

    /// Whether there is enough here to draw as history.
    public var isReadable: Bool { samples.count >= Self.minimumColumns }

    /// The trace to draw, or `nil` when there is not enough of it yet — the
    /// caller falls back to the instantaneous bar. **Never present an empty
    /// track as data**: the first frames after launch, after a wake and after
    /// the widget is switched on all have no history, and a box drawn with no
    /// columns in it is a claim that the machine has been idle.
    public var readable: SystemTrace? { isReadable ? self : nil }

    /// Heights in 0...1 against the fixed 0–100 scale, oldest first. Never
    /// normalised to the trace's own peak — see the type comment.
    public var heights: [Double] { samples.map { $0 / 100 } }

    /// One sentence, because a trace is a shape and a shape alone reads as
    /// nothing at all to a screen reader.
    public func spoken(label: String) -> String {
        guard let latest, let peak else {
            return "\(label) over the last \(Self.spokenWindow), no history yet"
        }
        return "\(label) over the last \(Self.spokenWindow), now \(Int(latest.rounded()))%,"
            + " peak \(Int(peak.rounded()))%"
    }

    /// "2 minutes", not "120 seconds" — the sentence is read aloud.
    static var spokenWindow: String {
        let seconds = Int(window.rounded())
        guard seconds >= 60, seconds % 60 == 0 else { return "\(seconds) seconds" }
        let minutes = seconds / 60
        return minutes == 1 ? "minute" : "\(minutes) minutes"
    }

    /// Cutting columns is the recorder's job; this is the only way in.
    mutating func append(_ percent: Double) {
        samples = Self.bounded(samples + [Self.clamped(percent)])
    }

    /// NaN is "no number" and becomes an empty column; an infinity still has a
    /// direction and clamps like any other out-of-range value.
    static func clamped(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(100, max(0, value))
    }

    private static func bounded(_ values: [Double]) -> [Double] {
        values.count <= capacity ? values : Array(values.suffix(capacity))
    }
}

/// Turns a stream of irregularly-spaced readings into evenly-sized columns.
///
/// The sampler runs at two rates — `SystemSampling.attentive` while the panel is
/// open, `SystemSampling.dormant` while it is shut — and a panel opening or
/// closing shifts the phase besides. Feeding those readings straight into the
/// trace would draw columns of two or three different durations side by side at
/// the same width, which says they mean the same thing. So they are accumulated
/// instead: each reading is weighted by the seconds it stands for, and a
/// column is cut once a whole `SystemTrace.column` of them has arrived. A 3s
/// reading is therefore half a column and never a column of its own.
///
/// What a reading stands for depends on the meter, and the column claims no
/// more than that. The CPU's is an average over exactly those seconds (a
/// difference of tick counters), so its column is the true average of the
/// span. The GPU's is whatever the driver reports at the moment it is read —
/// how long a stretch that figure itself covers is not documented — so its
/// column is one or two such moments standing in for six seconds, and a burst
/// between readings can be missed.
///
/// Pure, clockless, value-typed: the caller says how long it has been since the
/// previous reading, because the caller is the only thing that can know.
public struct SystemTraceRecorder: Equatable, Sendable {
    /// The most one reading may cover and still be part of this picture. Beyond
    /// it the sampler was not merely late — the machine slept, the widget was
    /// off, the process was starved — and a reading averaged over that span is
    /// not a column, it is a different span entirely. With `dormant` at six
    /// seconds this is a rare event rather than, as at thirty, the guaranteed
    /// outcome of every reopen.
    public static var maximumSpacing: TimeInterval { SystemTrace.column * 2 }

    public private(set) var trace = SystemTrace()

    private var pendingWeighted: Double = 0
    private var pendingSeconds: TimeInterval = 0

    public init() {}

    /// Record a reading covering the `spacing` seconds since the previous one;
    /// `nil` spacing means there was no previous one.
    ///
    /// A break — no predecessor, a clock that moved backwards, a gap past
    /// `maximumSpacing` — discards the history rather than continuing across it.
    /// What is behind the gap is not the last two minutes any more, and drawing
    /// it as though it were is the lie the fixed scale exists to prevent.
    public mutating func record(_ percent: Double, spacing: TimeInterval?) {
        guard let spacing, spacing >= 0, spacing <= Self.maximumSpacing else {
            self = SystemTraceRecorder()
            return
        }
        // Two readings in the same instant: nothing elapsed, so there is nothing
        // to weigh — but nothing was skipped either, so this is not a break.
        guard spacing > 0 else { return }
        pendingWeighted += SystemTrace.clamped(percent) * spacing
        pendingSeconds += spacing
        guard pendingSeconds >= SystemTrace.column else { return }
        trace.append(pendingWeighted / pendingSeconds)
        pendingWeighted = 0
        pendingSeconds = 0
    }

    /// Everything known is dropped — the widget was switched off, and switching
    /// it back on re-primes from scratch.
    public mutating func forget() { self = SystemTraceRecorder() }
}
