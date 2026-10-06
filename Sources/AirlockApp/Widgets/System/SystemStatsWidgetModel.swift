import AirlockCore
import Foundation
import Observation

struct SystemStats: Equatable {
    var cpuPercent: Double        // 0–100, whole machine
    var memoryPercent: Double     // 0–100 of physical RAM
    var memoryUsedGB: Double
    var memoryTotalGB: Double
    /// 0–100, the busiest GPU at the moment of the reading — a moment, not an
    /// average; see `SystemReader.readGPU`. `nil` when the Mac does not say,
    /// which leaves the meter out: 0% would claim an idle GPU.
    var gpuPercent: Double?
}

/// The list under the meters.
enum CPUByApp: Equatable {
    /// Nothing to draw: the widget has just been switched on with the panel
    /// shut, or the Mac would not list its processes.
    case hidden
    /// The panel is open and the first sweep is in. A list is the difference
    /// between two, and one reading is never presented as one.
    case measuring
    case breakdown(CPUBreakdown)
}

/// CPU, GPU and memory, plus — while the panel is open — which apps the CPU is
/// going to. Like the battery widget: no TCC, no entitlement, no subprocess,
/// panel-only. Developer-relevant: coding agents, builds and simulators peg the
/// machine, and this shows how hard and who at a glance.
///
/// The readings are taken by `SystemReader`, off the main actor; this model
/// decides when to ask, and keeps what is drawn.
///
/// **The rate follows the panel; the sampler never stops.** This is the one
/// widget whose only reader is a panel section — nothing here reaches the
/// compact island, the gutter or the menu bar (`SystemStatsWidget.panelSection`
/// is its entire surface). So while the panel is shut the poll drops to
/// `SystemSampling.dormant` and the presentation callback is not fired at all,
/// which is where the saving actually is: `NotchController.apply()` recomputes
/// the whole island, and nothing it computes can depend on a CPU figure.
///
/// It does **not** go dormant to the point of stopping, and that is the fix for
/// the empty trace. The trace draws two minutes; the panel, under the expansion
/// contract, lives for seconds. History therefore has to exist *before* the
/// panel opens, so the sampler keeps a slow beat while shut — one exactly one
/// trace column wide, so reopening changes the rate without changing what a
/// column means. The GPU's trace rides on the same readings and is kept the
/// same way.
///
/// **No sample is taken on open.** The freshest reading is at most one dormant
/// tick — six seconds — old, and it is an honest six-second average. Forcing an
/// extra reading at the instant the panel appears would produce a delta measured
/// over whatever fraction of a second had passed since the last tick, and put
/// that noise on screen as the current figure. Instead the poll's phase is
/// preserved across the rate change (see `reschedule`), so the next reading
/// lands on time rather than on the panel. The per-app list pays for that: it
/// needs two sweeps, the first is taken by the first reading after opening, and
/// until the second the list says "Measuring…" — three to six seconds.
@MainActor
@Observable
final class SystemStatsWidgetModel {
    private(set) var stats: SystemStats?

    /// Two minutes of CPU on a fixed 0–100 scale. Memory has none: it moves by
    /// the gigabyte over hours and a trace of it would be a straight line, while
    /// CPU is the number an agent run actually moves.
    ///
    /// The observable copy of `recorder.trace`, written only when a column is
    /// actually cut: `@Observable` invalidates on every write, and four readings
    /// in five change nothing that is drawn.
    private(set) var cpuTrace = SystemTrace()

    /// Two minutes of the GPU, kept exactly as the CPU's is. Its columns are
    /// moments standing in for six seconds rather than averages over them —
    /// `SystemTraceRecorder` says what that costs.
    private(set) var gpuTrace = SystemTrace()

    /// `.measuring` from the moment the panel opens until two sweeps are in.
    /// Left as it is when the panel closes, so the list does not vanish from a
    /// panel that is still animating shut; the next opening replaces it before
    /// anything is drawn.
    private(set) var cpuByApp: CPUByApp = .hidden

    @ObservationIgnored private let toggle = WidgetToggle(key: "widget.system.enabled", defaultValue: false)
    /// Stored, not computed over UserDefaults: `@Observable` cannot track a
    /// computed property reading `@ObservationIgnored` storage, so toggling this
    /// in settings wrote the value without invalidating anything that reads it.
    var isEnabled: Bool = WidgetToggle.stored("widget.system.enabled", default: false) {
        didSet {
            guard isEnabled != oldValue else { return }
            toggle.value = isEnabled
            if !isEnabled {
                forgetSamples()
            } else if panelVisible {
                cpuByApp = .measuring
            }
            onChange?()
            if isEnabled { sample() }
            reschedule()
        }
    }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// When the poll last fired, successfully or not. Only the timer uses it.
    @ObservationIgnored private var lastSampledAt: Date?
    @ObservationIgnored private var recorder = SystemTraceRecorder()
    @ObservationIgnored private var gpuRecorder = SystemTraceRecorder()
    @ObservationIgnored private var ranker = CPUBreakdownRanker()
    @ObservationIgnored private var panelVisible = false
    /// Replaced when the widget is switched off, so what it holds — a
    /// megabyte of process table, a name for every process — goes with it.
    @ObservationIgnored private var reader = SystemReader()
    /// Bumped whenever what is known is thrown away. A reading asked for under
    /// an older generation is dropped when it lands, rather than drawn into a
    /// history that has just been cleared.
    @ObservationIgnored private var generation = 0
    /// A reading takes milliseconds, and the next is seconds away; if one is
    /// ever still out when the timer fires, the tick is skipped rather than
    /// queued, and the next reading covers both intervals and says so.
    @ObservationIgnored private var readingInFlight = false

    func start() {
        sample()
        reschedule()
    }

    /// Told by `NotchController` whenever the panel's presentation changes.
    /// Expanded is the only state that draws this widget — compact is the
    /// island, which has never carried a CPU figure.
    ///
    /// Never calls `onChange`: this is called from inside
    /// `NotchController.apply()`, whose presentation is already being built.
    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        if visible {
            // Whatever the list said when the panel last closed is minutes old.
            if isEnabled { cpuByApp = .measuring }
        } else {
            // Reopened, the list is ordered by size again rather than by
            // whatever was on screen last time.
            ranker.forget()
        }
        reschedule()
    }

    /// One timer, restarted whenever the answer to "how often" changes.
    ///
    /// It resumes the existing cadence rather than restarting it: the first
    /// sleep is only the remainder of the interval already under way. Two
    /// reasons, and both were bugs. Restarting meant a reading whose delta
    /// spanned the whole previous rate — thirty seconds of averaging presented
    /// as the current figure. And it meant that opening and closing the panel
    /// faster than the interval postponed the sample indefinitely, so the trace
    /// starved and then broke.
    private func reschedule() {
        pollTask?.cancel()
        guard let interval = SystemSampling.interval(panelVisible: panelVisible, widgetEnabled: isEnabled) else {
            pollTask = nil
            return
        }
        let elapsed = max(0, lastSampledAt.map { Date().timeIntervalSince($0) } ?? 0)
        let first = max(0, interval - elapsed)
        pollTask = Task { [weak self] in
            var wait = first
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.sample()
                wait = interval
            }
        }
    }

    private func forgetSamples() {
        generation += 1
        reader = SystemReader()
        readingInFlight = false
        stats = nil
        cpuTrace = SystemTrace()
        gpuTrace = SystemTrace()
        recorder.forget()
        gpuRecorder.forget()
        ranker.forget()
        cpuByApp = .hidden
        lastSampledAt = nil
    }

    private func sample() {
        guard isEnabled, !readingInFlight else { return }
        lastSampledAt = Date()
        readingInFlight = true
        let request = SystemReader.Request(
            generation: generation,
            sweep: SystemSampling.sweepsProcesses(panelVisible: panelVisible, widgetEnabled: isEnabled))
        // Utility: a reading is for looking at, and it must never compete with
        // the thing it is measuring — least of all with audio.
        Task(priority: .utility) { [weak self, reader] in
            let reading = await reader.read(request)
            self?.apply(reading)
        }
    }

    private func apply(_ reading: SystemReader.Reading) {
        guard reading.generation == generation else { return }
        readingInFlight = false
        guard isEnabled else { return }
        let before = (stats, cpuByApp)

        if let gpu = reading.gpu {
            gpuRecorder.record(gpu.percent, spacing: gpu.spacing)
            if gpuRecorder.trace != gpuTrace { gpuTrace = gpuRecorder.trace }
        }
        // CPU needs two readings to produce a delta — the priming one has none,
        // and neither does a kernel that declined to answer.
        guard let cpu = reading.cpu, let memory = reading.memory else { return }
        recorder.record(cpu.percent, spacing: cpu.spacing)
        // Assigned only when a column was actually cut: `@Observable`
        // invalidates on every write, and most readings only move the recorder's
        // accumulator, which nothing draws.
        if recorder.trace != cpuTrace { cpuTrace = recorder.trace }
        let next = SystemStats(
            cpuPercent: cpu.percent,
            memoryPercent: memory.percent,
            memoryUsedGB: memory.usedGB,
            memoryTotalGB: memory.totalGB,
            gpuPercent: reading.gpu?.percent
        )
        if next != stats { stats = next }

        if panelVisible {
            let list: CPUByApp? = switch reading.apps {
            // Asked for before the panel opened; the list waits for its own.
            case .notSwept: nil
            case .measuring: .measuring
            case .unavailable: .hidden
            // Ranked against the CPU figure from the same reading, which is the
            // same stretch of time, so the lines add up to the meter above them.
            case .shares(let shares): .breakdown(ranker.rank(shares: shares, headline: cpu.percent))
            }
            if let list, list != cpuByApp { cpuByApp = list }
        }

        // Only while someone is reading. `onChange` is `NotchController.apply()`,
        // which recomputes the entire island presentation; nothing it computes
        // reads a CPU figure, because this widget's whole surface is a panel
        // section. Firing it on every dormant tick would be the widget's largest
        // cost by far, and it would buy nothing.
        if panelVisible, stats != before.0 || cpuByApp != before.1 { onChange?() }
    }
}
