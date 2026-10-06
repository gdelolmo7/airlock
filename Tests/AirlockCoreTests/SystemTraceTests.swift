import XCTest
@testable import AirlockCore

/// The trace exists because an autoscaled one is a lie: normalised to its own
/// peak, an idle machine and a pegged one draw exactly the same picture. So the
/// tests that matter are about the scale being fixed, about every column meaning
/// the same span of time, and about what is drawn when there is not enough
/// history to draw anything honest.
final class SystemTraceTests: XCTestCase {

    private let attentive = SystemSampling.attentive
    private let dormant = SystemSampling.dormant

    /// Feed `count` readings at `spacing`, as the sampler would.
    private func recorder(_ values: [Double], spacing: TimeInterval) -> SystemTraceRecorder {
        var recorder = SystemTraceRecorder()
        for value in values { recorder.record(value, spacing: spacing) }
        return recorder
    }

    // MARK: - The scale is fixed, and that is the whole point

    func testAnIdleMachineAndAPeggedOneDoNotDrawTheSameShape() {
        let idle = recorder(Array(repeating: 3, count: 10), spacing: dormant)
        let pegged = recorder(Array(repeating: 90, count: 10), spacing: dormant)
        XCTAssertEqual(idle.trace.heights, Array(repeating: 0.03, count: 10))
        XCTAssertEqual(pegged.trace.heights, Array(repeating: 0.90, count: 10))
        XCTAssertNotEqual(idle.trace.heights, pegged.trace.heights)
    }

    /// Full height is 100%, never "the largest thing seen so far".
    func testTheCeilingIsAHundredAndNotTheTraceOwnPeak() {
        let traced = recorder([10, 20, 10], spacing: dormant)
        XCTAssertEqual(traced.trace.heights.max(), 0.20)
    }

    func testOutOfRangeAndNonFiniteSamplesAreClamped() {
        let traced = recorder([-5, 140, .nan, .infinity], spacing: dormant)
        XCTAssertEqual(traced.trace.samples, [0, 100, 0, 100])
        XCTAssertTrue(traced.trace.heights.allSatisfy { (0...1).contains($0) })
    }

    // MARK: - Every column covers the same span

    /// The bug this cluster fixes, in one assertion: the panel is open for a
    /// while, then shut for a while, and the columns from the two periods are
    /// indistinguishable in width. A three-second reading is half a column and
    /// never a column of its own.
    func testColumnsAreTheSameWidthAtBothSamplingRates() {
        var traced = SystemTraceRecorder()
        // Panel open: two attentive readings make one column.
        traced.record(40, spacing: attentive)
        XCTAssertTrue(traced.trace.isEmpty)
        traced.record(60, spacing: attentive)
        XCTAssertEqual(traced.trace.samples, [50])
        // Panel shut: one dormant reading is exactly one column.
        traced.record(80, spacing: dormant)
        XCTAssertEqual(traced.trace.samples, [50, 80])
        XCTAssertEqual(SystemTrace.column, dormant)
        XCTAssertEqual(dormant, attentive * 2)
    }

    /// The value of a column is the duration-weighted mean, not the last reading
    /// in it — otherwise a spike that happened for one second of six would draw
    /// as six seconds of spike.
    func testAColumnIsWeightedByHowLongEachReadingCovered() {
        var traced = SystemTraceRecorder()
        traced.record(0, spacing: 4)
        traced.record(100, spacing: 2)
        XCTAssertEqual(traced.trace.samples.first.map { ($0 * 100).rounded() / 100 }, 33.33)
    }

    /// The panel opening or closing shifts the poll's phase, so a reading now and
    /// then covers an odd span. It still belongs to the picture — it is weighed
    /// by what it covered and folded into the column it lands in.
    func testAPhaseShiftedReadingIsFoldedInRatherThanDiscarded() {
        var traced = SystemTraceRecorder()
        traced.record(50, spacing: 5)
        traced.record(50, spacing: attentive)
        XCTAssertEqual(traced.trace.samples, [50])
    }

    func testReadingsInTheSameInstantAreNeitherAColumnNorABreak() {
        var traced = SystemTraceRecorder()
        traced.record(50, spacing: dormant)
        traced.record(99, spacing: 0)
        XCTAssertEqual(traced.trace.samples, [50])
        traced.record(70, spacing: dormant)
        XCTAssertEqual(traced.trace.samples, [50, 70])
    }

    // MARK: - Breaks

    /// The first reading has no predecessor, so it is a delta over an unknown
    /// window. Drawing it as a column the same width as the rest would be
    /// inventing a measurement.
    func testAReadingWithNoPredecessorIsNotAColumn() {
        var traced = SystemTraceRecorder()
        traced.record(42, spacing: nil)
        XCTAssertTrue(traced.trace.isEmpty)
        traced.record(42, spacing: dormant)
        XCTAssertEqual(traced.trace.samples, [42])
    }

    /// A gap wider than two columns is a sleep, a switched-off widget or a
    /// starved process. What is behind it is not the last two minutes any more.
    func testAGapPastTheToleranceDiscardsTheHistory() {
        var traced = recorder([10, 20, 30], spacing: dormant)
        XCTAssertEqual(traced.trace.samples.count, 3)
        traced.record(70, spacing: SystemTraceRecorder.maximumSpacing + 1)
        XCTAssertTrue(traced.trace.isEmpty)
        traced.record(12, spacing: dormant)
        XCTAssertEqual(traced.trace.samples, [12])
    }

    /// A tick that is merely late — the main actor busy, a sleep overshooting —
    /// is still the same two minutes.
    func testASlightlyLateTickStillCounts() {
        var traced = recorder([10], spacing: dormant)
        traced.record(20, spacing: dormant + 1)
        XCTAssertEqual(traced.trace.samples.count, 2)
        XCTAssertLessThan(dormant + 1, SystemTraceRecorder.maximumSpacing)
    }

    /// **A dormant tick is no longer a break.** This is the regression the whole
    /// cluster is about: at thirty seconds every reopen exceeded the tolerance,
    /// so the trace was wiped every single time the panel was opened.
    func testTheDormantRateIsInsideTheTolerance() {
        XCTAssertLessThanOrEqual(SystemSampling.dormant, SystemTraceRecorder.maximumSpacing)
        var traced = recorder([10, 20, 30], spacing: attentive)
        let before = traced.trace.samples
        traced.record(40, spacing: dormant)
        XCTAssertEqual(Array(traced.trace.samples.prefix(before.count)), before)
        XCTAssertFalse(traced.trace.isEmpty)
    }

    /// A clock that moved backwards (NTP, a wake) cannot be used to justify a
    /// column either.
    func testANegativeSpacingIsTreatedAsABreak() {
        var traced = recorder([10, 20, 30], spacing: dormant)
        traced.record(20, spacing: -1)
        XCTAssertTrue(traced.trace.isEmpty)
    }

    func testForgettingDropsThePartialColumnAsWellAsTheDrawnOnes() {
        var traced = recorder([10, 20, 30], spacing: dormant)
        traced.record(90, spacing: attentive)  // half a column, not yet drawn
        traced.forget()
        XCTAssertTrue(traced.trace.isEmpty)
        // If the half column had survived, one more attentive reading would cut
        // a column immediately instead of priming a fresh one.
        traced.record(90, spacing: attentive)
        XCTAssertTrue(traced.trace.isEmpty)
    }

    // MARK: - Too short to read

    /// An empty track is not a smaller picture. Drawn on the fixed 0–100 scale
    /// it is a picture of a machine doing nothing, and that is what the panel
    /// showed on every reopen.
    func testATraceWithNothingInItIsNotOfferedForDrawing() {
        XCTAssertNil(SystemTrace().readable)
        XCTAssertFalse(SystemTrace().isReadable)
    }

    func testATraceBecomesDrawableOnlyOnceItHasAShape() {
        var traced = SystemTraceRecorder()
        for _ in 0..<(SystemTrace.minimumColumns - 1) {
            traced.record(50, spacing: dormant)
            XCTAssertNil(traced.trace.readable)
        }
        traced.record(50, spacing: dormant)
        XCTAssertEqual(traced.trace.readable?.samples.count, SystemTrace.minimumColumns)
    }

    // MARK: - Bounded

    func testTheTraceNeverGrowsPastItsWindow() {
        var traced = SystemTraceRecorder()
        for index in 0..<(SystemTrace.capacity * 3) {
            traced.record(Double(index % 100), spacing: dormant)
        }
        XCTAssertEqual(traced.trace.samples.count, SystemTrace.capacity)
        XCTAssertEqual(traced.trace.latest, Double((SystemTrace.capacity * 3 - 1) % 100))
    }

    func testTheWindowIsTheCapacityTimesTheColumn() {
        XCTAssertEqual(SystemTrace.window, Double(SystemTrace.capacity) * SystemTrace.column)
        XCTAssertEqual(SystemTrace.window, 120)
    }

    func testAnOversizedInitialiserIsTrimmedToTheNewestSamples() {
        let values = (0..<(SystemTrace.capacity + 4)).map(Double.init)
        let trace = SystemTrace(samples: values)
        XCTAssertEqual(trace.samples.count, SystemTrace.capacity)
        XCTAssertEqual(trace.latest, values.last)
    }

    // MARK: - Spoken

    func testTheShapeGetsASentenceBecauseAShapeReadsAsNothing() {
        let traced = recorder([12, 84, 31], spacing: dormant)
        XCTAssertEqual(traced.trace.spoken(label: "CPU"),
                       "CPU over the last 2 minutes, now 31%, peak 84%")
    }

    func testAnEmptyTraceSaysSoRatherThanReadingAsZeroPercent() {
        XCTAssertEqual(SystemTrace().spoken(label: "CPU"),
                       "CPU over the last 2 minutes, no history yet")
    }

    // MARK: - Cadence

    /// The widget being off is the only case with no reader AND no baseline
    /// worth keeping — switching it back on re-primes from scratch anyway.
    func testAnOffWidgetIsNotSampledAtAll() {
        XCTAssertNil(SystemSampling.interval(panelVisible: false, widgetEnabled: false))
        XCTAssertNil(SystemSampling.interval(panelVisible: true, widgetEnabled: false))
    }

    /// Closed slows the poll; it does not stop it. Two minutes of history cannot
    /// be collected inside a panel that lives for seconds, so it has to already
    /// be there when the panel opens.
    func testAClosedPanelSlowsTheSamplerRatherThanStoppingIt() {
        let closed = SystemSampling.interval(panelVisible: false, widgetEnabled: true)
        XCTAssertEqual(closed, SystemSampling.dormant)
        XCTAssertGreaterThan(SystemSampling.dormant, SystemSampling.attentive)
    }

    func testAnOpenPanelSamplesFasterThanAColumn() {
        XCTAssertEqual(SystemSampling.interval(panelVisible: true, widgetEnabled: true),
                       SystemSampling.attentive)
        XCTAssertLessThan(SystemSampling.attentive, SystemTrace.column)
    }

    /// The per-app list has no timer of its own. It rides on the readings the
    /// meters already take, and only on the attentive ones: a sweep costs more
    /// than a reading nobody is looking at can justify.
    func testTheProcessSweepRidesOnlyOnTheOpenPanelsReadings() {
        for visible in [false, true] {
            for enabled in [false, true] {
                let sweeps = SystemSampling.sweepsProcesses(panelVisible: visible, widgetEnabled: enabled)
                XCTAssertEqual(sweeps, visible && enabled, "visible \(visible), enabled \(enabled)")
                if sweeps {
                    XCTAssertEqual(SystemSampling.interval(panelVisible: visible, widgetEnabled: enabled),
                                   SystemSampling.attentive)
                }
            }
        }
    }

    /// A list is a difference between two sweeps. The first is taken by the
    /// first reading after the panel opens, which the kept phase lands within
    /// one attentive interval, and the second one interval after that — so
    /// "Measuring…" lasts three to six seconds, well inside the time a panel
    /// is read.
    func testTheListIsReadyWithinTwoAttentiveIntervalsOfOpening() {
        XCTAssertLessThanOrEqual(2 * SystemSampling.attentive, 6)
    }

    /// Both rates divide the column exactly, which is what lets a column mean
    /// six seconds no matter which rate produced it.
    func testBothRatesDivideTheColumnExactly() {
        XCTAssertEqual(SystemTrace.column.truncatingRemainder(dividingBy: SystemSampling.attentive), 0)
        XCTAssertEqual(SystemTrace.column.truncatingRemainder(dividingBy: SystemSampling.dormant), 0)
    }

    /// A full trace is reachable from a cold start inside its own window: the
    /// sampler never stops, so after two minutes of uptime the panel always
    /// opens onto a populated trace.
    func testAFullTraceIsReachableWithinTheWindowFromDormantSamplingAlone() {
        var traced = SystemTraceRecorder()
        var elapsed: TimeInterval = 0
        var spacing: TimeInterval? = nil
        while traced.trace.samples.count < SystemTrace.capacity {
            traced.record(50, spacing: spacing)
            spacing = SystemSampling.dormant
            elapsed += SystemSampling.dormant
            XCTAssertLessThanOrEqual(elapsed, SystemTrace.window + SystemSampling.dormant)
        }
        XCTAssertEqual(traced.trace.samples.count, SystemTrace.capacity)
    }
}
