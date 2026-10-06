import AirlockCore
import Darwin
import Foundation
import XCTest
@testable import AirlockApp

/// Opt-in, and not hermetic: reads THIS Mac.
///
///     AIRLOCK_LIVE_CPU_CHECK=1 taskpolicy -c background swift test --filter SystemReaderLiveCheck
///
/// Takes the System section's readings for real and prints what the panel
/// would show: the GPU figure, the CPU headline, the rows and the leftover.
/// Between the two readings it runs a burst of short-lived processes — the
/// shape of a parallel build, where each compiler starts and ends between two
/// readings — and prints where their CPU landed, against what the kernel says
/// they used.
///
/// Asserts only what has to hold on any Mac under any load: every figure is
/// finite and not negative, and the list never adds up past the meter above it.
/// What a particular app happens to be doing is not a test, and neither is the
/// burst's landing place — that is printed for a person to read, because it is
/// the evidence for what the leftover line may be called.
final class SystemReaderLiveCheck: XCTestCase {
    private static let enabled = ProcessInfo.processInfo.environment["AIRLOCK_LIVE_CPU_CHECK"] == "1"
    private static let skipReason = "Reads this Mac and runs a burst of processes; set AIRLOCK_LIVE_CPU_CHECK=1 to run it."

    func testWhereAShortLivedBurstsCPUGoes() async throws {
        try XCTSkipUnless(Self.enabled, Self.skipReason)
        let reader = SystemReader()
        let request = SystemReader.Request(generation: 1, sweep: true)
        let clock = ContinuousClock()

        let first = await reader.read(request)
        let firstAt = clock.now
        guard case .measuring = first.apps else {
            return XCTFail("The first sweep has nothing to difference against, so it must say measuring; got \(first.apps)")
        }
        XCTAssertNil(first.cpu, "The first reading has no tick baseline, so it has no CPU figure")

        let burst = try Burst(waves: 4, width: 4)
        defer { burst.stop() }
        try await burst.waitUntilDone()
        let burstTook = clock.now - firstAt
        // "Two readings 1–2 s apart": 1.5 s, or as soon as the burst is over.
        if burstTook < .milliseconds(1500) {
            try await Task.sleep(until: firstAt + .milliseconds(1500), clock: clock)
        }

        let second = await reader.read(request)
        // Everything the shell and the processes it reaped used, from the
        // kernel — read now, while the shell sits in `read` using nothing.
        let truth = try XCTUnwrap(burst.lifetimeCPU(), "The burst's shell must still be there to read")
        let shellGroup = burst.group()

        let cpu = try XCTUnwrap(second.cpu, "Two tick readings make a CPU figure")
        guard case .shares(let shares) = second.apps else {
            return XCTFail("The second sweep differences against the first; got \(second.apps)")
        }
        let cost = try XCTUnwrap(second.cost)
        let window = try XCTUnwrap(cost.window)
        let processors = ProcessInfo.processInfo.activeProcessorCount
        func seconds(_ share: Double) -> Double { share / 100 * window * Double(processors) }

        var ranker = CPUBreakdownRanker()
        let breakdown = ranker.rank(shares: shares, headline: cpu.percent)
        let shown = zip(breakdown.lines, breakdown.displayedPercents)

        var report = ["", "── System section, live ─────────────────────────────"]
        report.append("GPU        " + (second.gpu.map { String(format: "%.1f%% (a moment; busiest GPU)", $0.percent) }
                                        ?? "not reported — no meter"))
        report.append(String(format: "CPU        %d%% (%.2f), over %.3f s; the list's window %.3f s, %d processors",
                             CPUBreakdown.displayedPercent(of: cpu.percent), cpu.percent,
                             cpu.spacing ?? .nan, window, processors))
        report.append(String(format: "MEM        %.1f%%", second.memory?.percent ?? .nan))
        report.append("Rows:")
        for (line, percent) in shown {
            report.append(String(format: "  %@ %@ %3d%%   (%.2f)", line.isLeftover ? "·" : "▪",
                                 breakdown.name(of: line).padding(toLength: 22, withPad: " ", startingAt: 0),
                                 percent, line.share))
        }
        if breakdown.isEmpty { report.append("  (none at 1% or more — an idle Mac shows no list)") }
        let attributed = shares.values.reduce(0, +)
        report.append(String(format: "Attributed to named groups %.2f of %.2f; unattributed %.2f",
                             attributed, cpu.percent, max(0, cpu.percent - attributed)))
        report.append("Every group at 0.3% or more:")
        for (group, share) in shares.sorted(by: { $0.value > $1.value }) where share >= 0.3 {
            report.append(String(format: "    %@ %6.2f%%  %6.3f s",
                                 group.description.padding(toLength: 34, withPad: " ", startingAt: 0),
                                 share, seconds(share)))
        }
        let credited = shares[shellGroup].map(seconds) ?? 0
        let awk = shares[ProcessGroup(kind: .program, name: "awk")].map(seconds) ?? 0
        report.append(String(format: "Burst: %d processes of awk in %d waves, took %.2f s of wall time",
                             burst.waves * burst.width, burst.waves,
                             Double(burstTook.components.attoseconds) / 1e18 + Double(burstTook.components.seconds)))
        report.append(String(format: "  kernel says it used      %.3f s  (shell pid %d, own %.3f + reaped %.3f)",
                             truth.own + truth.reaped, burst.pid, truth.own, truth.reaped))
        report.append(String(format: "  credited to %@ %.3f s  (%.0f%% of what it used; the group may hold other processes)",
                             shellGroup.description.padding(toLength: 12, withPad: " ", startingAt: 0),
                             credited, credited / max(truth.own + truth.reaped, 1e-9) * 100))
        report.append(String(format: "  credited to program:awk  %.3f s  (the burst's processes, had any outlived the window)", awk))
        report.append(String(format: "Sweep: %.2f ms CPU, %.2f ms wall; %d listed, %d read, %d paths looked up",
                             cost.cpuMilliseconds, cost.wallMilliseconds, cost.listed, cost.read, cost.pathsLookedUp))
        print(report.joined(separator: "\n"))

        // What must hold anywhere.
        XCTAssert((0...100).contains(cpu.percent))
        if let gpu = second.gpu { XCTAssert((0...100).contains(gpu.percent), "GPU \(gpu.percent)") }
        for (group, share) in shares {
            XCTAssert(share.isFinite && share >= 0, "\(group) has share \(share)")
        }
        XCTAssertLessThanOrEqual(breakdown.lines.reduce(0) { $0 + $1.share }, cpu.percent + 1e-9)
        XCTAssertLessThanOrEqual(breakdown.displayedPercents.reduce(0, +), CPUBreakdown.displayedPercent(of: cpu.percent))
        XCTAssert(breakdown.displayedPercents.allSatisfy { $0 >= 0 })
        XCTAssert(breakdown.lines.allSatisfy { $0.share >= CPUBreakdown.threshold })
        XCTAssertLessThanOrEqual(breakdown.lines.count, CPUBreakdown.maximumLines)
        XCTAssertLessThanOrEqual(breakdown.lines.filter { !$0.isLeftover }.count, CPUBreakdown.maximumApps)
        XCTAssertLessThanOrEqual(breakdown.lines.filter(\.isLeftover).count, 1)
        // CPU is never invented: nothing is credited more than every core's
        // worth of the window, whatever it was grouped under.
        XCTAssertLessThanOrEqual(attributed, 100 * 1.02, "Shares add up to \(attributed)% of the whole Mac")
    }

    /// What one sweep costs, cold and then warm, and what one GPU read costs.
    /// The warm figure is the one the panel pays every three seconds.
    func testWhatASweepCosts() async throws {
        try XCTSkipUnless(Self.enabled, Self.skipReason)
        let reader = SystemReader()
        let request = SystemReader.Request(generation: 1, sweep: true)
        var costs: [SystemReader.Reading.Cost] = []
        for index in 0..<7 {
            if index > 0 { try await Task.sleep(for: .seconds(1)) }
            if let cost = await reader.read(request).cost { costs.append(cost) }
        }
        let cold = try XCTUnwrap(costs.first)
        let warm = costs.dropFirst().map(\.cpuMilliseconds).sorted()
        let warmWall = costs.dropFirst().map(\.wallMilliseconds).sorted()
        XCTAssertFalse(warm.isEmpty)

        let reads = 200
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var reported = 0
        for _ in 0..<reads where SystemReader.readGPU() != nil { reported += 1 }
        let perRead = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / Double(reads) / 1e6

        var report = ["", "── What a sweep costs ───────────────────────────────"]
        report.append(String(format: "Cold (every path looked up): %.2f ms CPU, %.2f ms wall; %d listed, %d read, %d paths",
                             cold.cpuMilliseconds, cold.wallMilliseconds, cold.listed, cold.read, cold.pathsLookedUp))
        for cost in costs.dropFirst() {
            report.append(String(format: "Warm: %.2f ms CPU, %.2f ms wall; %d listed, %d read, %d paths",
                                 cost.cpuMilliseconds, cost.wallMilliseconds, cost.listed, cost.read, cost.pathsLookedUp))
        }
        report.append(String(format: "Warm median %.2f ms CPU (range %.2f–%.2f), %.2f ms wall",
                             warm[warm.count / 2], warm.first ?? .nan, warm.last ?? .nan, warmWall[warmWall.count / 2]))
        report.append(String(format: "GPU read: %.3f ms each over %d reads; reported on %d", perRead, reads, reported))
        print(report.joined(separator: "\n"))
    }
}

/// Sixteen short-lived CPU burners, four at a time, all started and reaped by
/// one shell that then waits on its input — so it is still there to be read
/// when the second sweep lists it, and the burst's CPU has a live reaper to be
/// credited to rather than going up to the test runner with the shell.
///
/// Each process uses ~0.13 s of CPU (measured on the Mac this was written on),
/// so the whole burst is about two seconds of CPU on four cores at a time, at
/// whatever priority the test runs under — background, run as documented.
private final class Burst {
    let waves: Int
    let width: Int
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(waves: Int, width: Int) throws {
        self.waves = waves
        self.width = width
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
            for wave in $(seq 1 \(waves)); do
              for job in $(seq 1 \(width)); do
                /usr/bin/awk 'BEGIN { for (i = 0; i < 3000000; i++) s += i }' &
              done
              wait
            done
            echo done
            read line
            """]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
    }

    var pid: Int32 { process.processIdentifier }

    func waitUntilDone() async throws {
        let handle = output.fileHandleForReading
        let said = await Task.detached {
            var data = Data()
            while !data.contains(UInt8(ascii: "\n")) {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            return String(decoding: data, as: UTF8.self)
        }.value
        XCTAssertEqual(said.trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    /// The shell's own CPU and everything it reaped, in seconds.
    func lifetimeCPU() -> (own: Double, reaped: Double)? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        return (SystemReader.seconds(info.ri_user_time + info.ri_system_time),
                SystemReader.seconds(info.ri_child_user_time + info.ri_child_system_time))
    }

    /// The group the reader files the shell under, found the same way: from
    /// the path of what it is running now and the kernel's name for it.
    func group() -> ProcessGroup {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        let path = length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let name: String = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size
            ? withUnsafeBytes(of: info.pbsi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            : "sh"
        return ProcessGroup.owner(path: path, name: name)
    }

    func stop() {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}
