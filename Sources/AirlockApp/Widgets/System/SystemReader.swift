import AirlockCore
import Darwin
import Foundation
import IOKit

/// Takes the System section's readings off the main actor: CPU, memory and GPU
/// on every tick, and — while the panel is open — a sweep of the process table
/// for the list of apps under the meters.
///
/// **Why an actor, when this used to be two Mach traps on the main actor.** The
/// meters alone are still that cheap. The sweep is not: it lists every process
/// on the Mac, reads the CPU counters of every one that is the owner's, lists
/// again and re-reads the ones that are parents — several milliseconds of CPU
/// (the figure is on `SystemSampling.sweepsProcesses`), which is too long to
/// hold the thread every animation and every click runs on. The main actor only
/// asks and applies.
///
/// **One reading, one call, one stretch of time.** The list has to add up to
/// the CPU meter above it, so the two must describe the same seconds. Both
/// baselines are taken in the same call, a millisecond apart, and a list is
/// only ever the difference between two sweeps whose readings also produced the
/// CPU figure. A baseline from any other reading — one where the tick counters
/// failed, one from before the panel was shut — is dropped rather than paired.
///
/// Public interfaces only, no helper and no subprocess: `sysctl`, `libproc`,
/// Mach host statistics and the I/O Registry, all readable by an ordinary
/// process for the processes its own user runs. Nothing here asks for a
/// permission or prompts.
actor SystemReader {
    struct Request: Sendable {
        /// Bumped by the model whenever it throws away what it knows, and every
        /// baseline here goes with it. A reading asked for under an older
        /// generation is ignored when it arrives.
        let generation: Int
        /// Whether to sweep the process table — `SystemSampling.sweepsProcesses`.
        let sweep: Bool
    }

    struct Reading: Sendable {
        struct Figure: Sendable, Equatable {
            /// 0–100.
            let percent: Double
            /// Seconds since the previous figure of the same kind, `nil` when
            /// there was none — what `SystemTraceRecorder.record` is told.
            let spacing: TimeInterval?
        }

        struct Memory: Sendable, Equatable {
            let percent: Double
            let usedGB: Double
            let totalGB: Double
        }

        enum Apps: Sendable {
            /// Not asked for: the panel is shut.
            case notSwept
            /// Swept, with nothing yet to difference against.
            case measuring
            /// The Mac would not list its processes.
            case unavailable
            /// Percent of the whole Mac per group, over the same stretch as the
            /// CPU figure in the same reading.
            case shares([ProcessGroup: Double])
        }

        /// What a sweep cost, for the live check and for whoever re-measures.
        struct Cost: Sendable {
            /// CPU time spent sweeping and attributing, on the thread that did it.
            let cpuMilliseconds: Double
            let wallMilliseconds: Double
            let listed: Int
            let read: Int
            let pathsLookedUp: Int
            /// The stretch the shares cover; `nil` with nothing to difference.
            let window: TimeInterval?
        }

        let generation: Int
        let cpu: Figure?
        let memory: Memory?
        let gpu: Figure?
        let apps: Apps
        let cost: Cost?
    }

    private var generation: Int?
    private var previousTicks: Ticks?
    /// When `previousTicks` was read. The CPU figure is a delta against those
    /// ticks, so this — not "when the last tick fired" — is the instant the
    /// reading's window opens, and the span the trace must be told about. They
    /// differ whenever `host_statistics` fails: the tick still happened, the
    /// baseline did not move, and the next reading covers two intervals.
    private var previousTicksAt: Date?
    private var previousGPUAt: Date?
    private var previousSweep: ProcessSweep?

    /// Reused between sweeps, and dropped when the panel shuts: the table is
    /// ~1,500 entries of 648 bytes, which is a megabyte to allocate every three
    /// seconds for nothing, and to keep for a list nobody is looking at.
    private var listing: [kinfo_proc] = []
    private var pathBuffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    /// What each process was resolved to, by identity, so its path is looked up
    /// once in its life rather than once a sweep. Measured in a release build:
    /// the first sweep, which looks up all of the owner's ~1,260 processes, took
    /// ~100 ms of CPU; later ones, which look up the few started since, took a
    /// median of 7.6 ms. Pruned to the current listing on every sweep.
    private var resolved: [ProcessRecord.Identity: Resolved] = [:]
    /// Bundle path → the name macOS shows for it.
    private var appNames: [String: String] = [:]

    private struct Resolved {
        /// The kernel's name for the process when it was resolved. A process
        /// that has exec'd since is a different program under the same pid and
        /// start time — a shell caught between fork and exec is still "zsh" —
        /// so a changed name means resolving it again.
        let name: String
        let group: ProcessGroup
    }

    func read(_ request: Request) -> Reading {
        if request.generation != generation {
            generation = request.generation
            previousTicks = nil
            previousTicksAt = nil
            previousGPUAt = nil
            previousSweep = nil
        }
        let now = Date()
        let memory = Self.readMemory()
        let gpu = gpuFigure(at: now)
        // The tick counters last, immediately before the sweep lists the
        // processes: the CPU figure and the list under it then cover the same
        // stretch to within the time one listing takes.
        let ticks = Self.readTicks()
        let cpu = cpuFigure(ticks, at: now)

        func reading(_ apps: Reading.Apps, _ cost: Reading.Cost? = nil) -> Reading {
            Reading(generation: request.generation, cpu: cpu, memory: memory, gpu: gpu, apps: apps, cost: cost)
        }
        guard request.sweep else {
            forgetSweeps()
            return reading(.notSwept)
        }
        // The CPU figure's baseline did not move, so a sweep taken now would
        // open a window that no CPU figure shares.
        guard ticks != nil else {
            previousSweep = nil
            return reading(.measuring)
        }
        let (apps, cost) = sweepApps()
        return reading(apps, cost)
    }

    private func forgetSweeps() {
        previousSweep = nil
        listing = []
    }

    // MARK: - CPU, memory, GPU

    struct Ticks: Sendable {
        let user: UInt32, system: UInt32, idle: UInt32, nice: UInt32
    }

    private func cpuFigure(_ ticks: Ticks?, at now: Date) -> Reading.Figure? {
        // No answer leaves the baseline where it was, so the next reading
        // covers both intervals and says so.
        guard let ticks else { return nil }
        let previous = previousTicks
        let previousAt = previousTicksAt
        previousTicks = ticks
        previousTicksAt = now
        guard let previous else { return nil }

        let user = Double(ticks.user &- previous.user)
        let system = Double(ticks.system &- previous.system)
        let nice = Double(ticks.nice &- previous.nice)
        let idle = Double(ticks.idle &- previous.idle)
        let total = user + system + nice + idle
        guard total > 0 else { return nil }
        return Reading.Figure(percent: min(100, (user + system + nice) / total * 100),
                              spacing: previousAt.map { now.timeIntervalSince($0) })
    }

    static func readTicks() -> Ticks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Ticks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    static func readMemory() -> Reading.Memory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = Double(getpagesize()) // concurrency-safe vs the global vm_page_size
        // Active + wired + compressed ≈ "in use" (matches Activity Monitor's feel).
        let used = (Double(stats.active_count) + Double(stats.wire_count)
                    + Double(stats.compressor_page_count)) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        let gb = 1024.0 * 1024.0 * 1024.0
        return Reading.Memory(percent: min(100, used / total * 100), usedGB: used / gb, totalGB: total / gb)
    }

    private func gpuFigure(at now: Date) -> Reading.Figure? {
        guard let percent = Self.readGPU() else { return nil }
        defer { previousGPUAt = now }
        return Reading.Figure(percent: percent, spacing: previousGPUAt.map { now.timeIntervalSince($0) })
    }

    /// The busiest GPU's utilisation, as its driver publishes it in the I/O
    /// Registry: `PerformanceStatistics` → `Device Utilization %` on every
    /// `IOAccelerator`. An undocumented figure, which is why its absence is
    /// an answer rather than an error — a VM, or a driver that does not publish
    /// it, gets `nil`, and the meter is simply not drawn. No other key is
    /// guessed at.
    ///
    /// **A moment, not an average.** The CPU figure is a difference of tick
    /// counters, so it is the average over exactly the seconds since the last
    /// reading. This is whatever the driver reports at the instant it is read,
    /// and how long a stretch the driver's own figure covers is not documented.
    /// So "now" on the GPU meter is a moment, the trace is a series of moments
    /// weighted as though each stood for the gap before it, and a burst that
    /// starts and ends between two readings can be missed. It is read on the
    /// CPU's cadence, which is as often as anything here is read.
    ///
    /// Several GPUs give one figure — the busiest, never the sum; see `GPULoad`.
    static func readGPU() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var figures: [Double] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            guard let statistics = IORegistryEntryCreateCFProperty(
                    entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let figure = statistics["Device Utilization %"] as? NSNumber else { continue }
            figures.append(figure.doubleValue)
        }
        return GPULoad.busiest(of: figures)
    }

    // MARK: - Which apps

    private struct Tally {
        var listed = 0
        var read = 0
        var pathsLookedUp = 0
    }

    private func sweepApps() -> (Reading.Apps, Reading.Cost?) {
        let startCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let startWall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var tally = Tally()
        guard let sweep = sweepProcesses(tally: &tally) else {
            forgetSweeps()
            return (.unavailable, nil)
        }
        let previous = previousSweep
        previousSweep = sweep

        var apps = Reading.Apps.measuring
        var window: TimeInterval?
        if let previous {
            let attributed = CPUAttribution.attribute(from: previous, to: sweep)
            if attributed.window > 0 {
                window = attributed.window
                apps = .shares(CPUBreakdown.shares(seconds: attributed.seconds, window: attributed.window,
                                                   processors: ProcessInfo.processInfo.activeProcessorCount))
            }
        }
        let cost = Reading.Cost(
            cpuMilliseconds: Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- startCPU) / 1e6,
            wallMilliseconds: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- startWall) / 1e6,
            listed: tally.listed, read: tally.read, pathsLookedUp: tally.pathsLookedUp, window: window)
        return (apps, cost)
    }

    /// A process as the listing gave it — the few fields the sweep needs,
    /// copied out once.
    private struct Listed {
        let identity: ProcessRecord.Identity
        let parent: Int32
        let isOwners: Bool
        let isZombie: Bool
        let name: String
    }

    /// One `ProcessSweep`, read in the order `CPUAttribution` depends on.
    ///
    /// 1. **List**, and note the time before and after. The time before is the
    ///    sweep's own (`takenAt`): a process that started while the kernel was
    ///    listing and was missed then counts as born inside the next window,
    ///    which it was. The time after is the latest a listed process can have
    ///    started, so a read that finds a later start has found a new process
    ///    under a reused pid.
    /// 2. **Read** every one of the owner's processes, parents before children
    ///    (`ProcessSweep.readingOrder`). Everyone else's is not asked — the
    ///    kernel would refuse — and is the leftover line's.
    /// 3. **List again**, then re-read the reaped counter of every process that
    ///    is some listed process's parent. A process gone by the second listing
    ///    was reaped before any re-read, so it is inside one
    ///    (`ProcessSweep.markFolded`). A parent gone by its own re-read is
    ///    written down as unreadable: what it reaped in its last moments is
    ///    unknown, so whatever reaps IT gets no reaped credit next window rather
    ///    than a guess that could count something twice.
    ///
    /// Only parents are re-read. A process with no listed children can only
    /// reap one born after the listing, whose CPU belongs to the next window —
    /// and a re-read would put it into this one's baseline, where it is lost.
    private func sweepProcesses(tally: inout Tally) -> ProcessSweep? {
        let listedFrom = mach_absolute_time()
        guard let processes = listProcesses() else { return nil }
        let listedBy = mach_absolute_time()
        tally.listed = processes.count

        var records: [ProcessRecord] = []
        records.reserveCapacity(processes.count)
        var groupByPID: [Int32: ProcessGroup] = [:]
        var kept: [ProcessRecord.Identity: Resolved] = [:]
        kept.reserveCapacity(resolved.count)
        for index in ProcessSweep.readingOrder(pids: processes.map(\.identity.pid), parents: processes.map(\.parent)) {
            let process = processes[index]
            guard process.isOwners else {
                records.append(ProcessRecord(identity: process.identity, parent: process.parent,
                                             group: nil, reading: .unreadable))
                continue
            }
            let reading = Self.readCPU(of: process.identity.pid, listedBy: listedBy)
            var group: ProcessGroup?
            if case .read = reading {
                tally.read += 1
                group = self.group(of: process, parentGroup: groupByPID[process.parent], keeping: &kept,
                                   tally: &tally)
                groupByPID[process.identity.pid] = group
            }
            records.append(ProcessRecord(identity: process.identity, parent: process.parent,
                                         group: group, reading: reading))
        }
        // Everything not in this listing has ended, and its pid may already be
        // somebody else's.
        resolved = kept

        guard let alive = listIdentities() else { return nil }
        let parents = Set(processes.map(\.parent))
        var reRead = Set<Int32>()
        // In reading order, parents first, so each parent is re-read as soon
        // after the second listing as it can be: a child that dies in between
        // was alive at the listing, is not folded, and is taken out of the
        // parent's counter again next window — CPU lost, never invented.
        for index in records.indices {
            guard case .read(var cpu) = records[index].reading,
                  parents.contains(records[index].identity.pid),
                  alive.contains(records[index].identity) else { continue }
            if let reaped = Self.readReaped(of: records[index].identity.pid, startedAt: cpu.startedAt) {
                cpu.reapedAtEnd = reaped
                records[index].reading = .read(cpu)
                reRead.insert(records[index].identity.pid)
            } else {
                records[index].reading = .unreadable
            }
        }
        ProcessSweep.markFolded(&records, alive: alive, reRead: reRead)
        return ProcessSweep(takenAt: Self.seconds(listedFrom), records: records)
    }

    /// The whole process table, or `nil` if the kernel would not give it.
    private func listProcesses() -> [Listed]? {
        let owner = getuid()
        guard let count = fillListing() else { return nil }
        return listing.prefix(count).map { entry in
            Listed(identity: Self.identity(of: entry),
                   parent: entry.kp_eproc.e_ppid,
                   isOwners: entry.kp_eproc.e_ucred.cr_uid == owner,
                   isZombie: entry.kp_proc.p_stat == SZOMB,
                   name: withUnsafeBytes(of: entry.kp_proc.p_comm) { raw in
                       String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                   })
        }
    }

    /// Who is still there, for the end of a sweep. A zombie is still listed —
    /// exited, not yet reaped — so missing from here means reaped.
    private func listIdentities() -> Set<ProcessRecord.Identity>? {
        guard let count = fillListing() else { return nil }
        return Set(listing.prefix(count).map(Self.identity(of:)))
    }

    /// The pid and the start time the listing reports. The start time is only
    /// ever compared for equality, between listings.
    private static func identity(of entry: kinfo_proc) -> ProcessRecord.Identity {
        let started = entry.kp_proc.p_un.__p_starttime
        return ProcessRecord.Identity(
            pid: entry.kp_proc.p_pid,
            started: UInt64(max(0, started.tv_sec)) &* 1_000_000 &+ UInt64(max(0, started.tv_usec)))
    }

    private func fillListing() -> Int? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<3 {
            if !listing.isEmpty {
                var size = listing.count * stride
                let result = listing.withUnsafeMutableBytes { buffer in
                    sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
                }
                if result == 0 { return size / stride }
                guard errno == ENOMEM else { return nil }
            }
            // Never sized, or outgrown: ask, and leave room for whatever starts
            // before the next call.
            var needed = 0
            guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0 else { return nil }
            let entries = needed / stride
            listing = [kinfo_proc](repeating: kinfo_proc(), count: entries + entries / 4 + 32)
        }
        return nil
    }

    private func group(of process: Listed, parentGroup: ProcessGroup?,
                       keeping kept: inout [ProcessRecord.Identity: Resolved], tally: inout Tally) -> ProcessGroup {
        if let known = resolved[process.identity], known.name == process.name {
            kept[process.identity] = known
            return known.group
        }
        // A zombie has no path to read (measured: `proc_pidpath` refuses one),
        // and now and then a live process's path cannot be read either. Both go
        // where their CPU would have gone had they been reaped a moment sooner —
        // to whatever started them — and neither is remembered, so a path that
        // was only briefly unreadable is asked for again next time.
        guard !process.isZombie, let path = executablePath(of: process.identity.pid) else {
            return parentGroup ?? ProcessGroup.owner(path: nil, name: process.name)
        }
        tally.pathsLookedUp += 1
        let group = shown(ProcessGroup.owner(path: path, name: process.name))
        kept[process.identity] = Resolved(name: process.name, group: group)
        return group
    }

    private func executablePath(of pid: Int32) -> String? {
        let length = pathBuffer.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: pathBuffer.prefix(Int(length)), as: UTF8.self)
    }

    /// An app's group under the name macOS shows for it, found the way
    /// `AppName` finds one for a bundle identifier: display name, then bundle
    /// name, then the file name `ProcessGroup` already carries. Two bundles that
    /// show the same name become one row.
    private func shown(_ group: ProcessGroup) -> ProcessGroup {
        guard group.kind == .app, let path = group.bundlePath else { return group }
        if let name = appNames[path] { return group.renamed(name) }
        let bundle = Bundle(url: URL(fileURLWithPath: path, isDirectory: true))
        let name = ["CFBundleDisplayName", "CFBundleName"].lazy
            .compactMap { bundle?.object(forInfoDictionaryKey: $0) as? String }
            .first { !$0.isEmpty } ?? group.name
        appNames[path] = name
        return group.renamed(name)
    }

    // MARK: - One process's counters

    private static func usage(of pid: Int32) -> (info: rusage_info_v2?, error: Int32) {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return result == 0 ? (info, 0) : (nil, errno)
    }

    private static func readCPU(of pid: Int32, listedBy: UInt64) -> ProcessRecord.Reading {
        let (info, error) = usage(of: pid)
        guard let info else { return error == ESRCH ? .vanished : .unreadable }
        // Started after the listing finished: this pid belongs to someone new.
        guard info.ri_proc_start_abstime <= listedBy else { return .vanished }
        return .read(ProcessCPU(own: seconds(info.ri_user_time &+ info.ri_system_time),
                                reaped: seconds(info.ri_child_user_time &+ info.ri_child_system_time),
                                startedAt: seconds(info.ri_proc_start_abstime)))
    }

    /// The reaped counter again, if this is still the same process.
    private static func readReaped(of pid: Int32, startedAt: Double) -> Double? {
        guard let info = usage(of: pid).info, seconds(info.ri_proc_start_abstime) == startedAt else { return nil }
        return seconds(info.ri_child_user_time &+ info.ri_child_system_time)
    }

    /// Mach absolute time to seconds. `rusage_info`'s CPU times are in the same
    /// units as its start time — measured on Apple silicon, where the timebase
    /// is 125/3 and reading them as nanoseconds is 42 times too small. (The
    /// timebase is 1/1 on Intel, so the same conversion is right on both.)
    static func seconds(_ ticks: UInt64) -> Double { Double(ticks) * secondsPerTick }

    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return 1e-9 }
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()
}
