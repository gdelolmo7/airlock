import Foundation

// MARK: - What one sweep saw

/// A process as one sweep of the process table saw it.
///
/// Identity is the pid AND the start time. A pid alone is not an identity — the
/// kernel hands pids out again, and a build that runs hundreds of compilers a
/// minute recycles them within the two minutes the panel is about. A record
/// that matched on pid alone would difference one process's lifetime CPU
/// against another's and put the result on screen as a spike.
public struct ProcessRecord: Equatable, Sendable {
    public struct Identity: Hashable, Sendable {
        public let pid: Int32
        /// As the process listing reports it; only ever compared for equality.
        public let started: UInt64

        public init(pid: Int32, started: UInt64) {
            self.pid = pid
            self.started = started
        }
    }

    public enum Reading: Equatable, Sendable {
        case read(ProcessCPU)
        /// Not ours to read — another user's process — or a read that failed
        /// for some reason other than the process being gone.
        case unreadable
        /// Listed, then gone before it could be read: reaped in the moment
        /// between the listing and the read, or its pid already handed to a
        /// newer process.
        case vanished
    }

    public let identity: Identity
    /// The parent at the time of the listing.
    public let parent: Int32
    /// Only meaningful for `.read`; the process nobody can read has no row.
    public let group: ProcessGroup?
    public var reading: Reading
    /// Reaped by its parent after its own read and before its parent's
    /// end-of-sweep re-read (`ProcessCPU.reapedAtEnd`), so its whole life is
    /// already inside that re-read. See `CPUAttribution` for why that matters.
    public var foldedIntoParent: Bool

    public init(identity: Identity, parent: Int32, group: ProcessGroup?,
                reading: Reading, foldedIntoParent: Bool = false) {
        self.identity = identity
        self.parent = parent
        self.group = group
        self.reading = reading
        self.foldedIntoParent = foldedIntoParent
    }
}

/// A process's CPU counters, in seconds.
public struct ProcessCPU: Equatable, Sendable {
    /// User + system time the process itself has used since it started.
    public var own: Double
    /// Everything its children used, added by the kernel as each one was
    /// reaped — a child's own time plus whatever it had reaped in turn — as
    /// read in the sweep's first pass.
    public var reaped: Double
    /// The same counter, re-read at the end of the sweep once its children had
    /// been read. Equal to `reaped` when it was not re-read.
    public var reapedAtEnd: Double
    /// When the process started, on the sweep's clock (`ProcessSweep.takenAt`).
    public var startedAt: Double

    public init(own: Double, reaped: Double, reapedAtEnd: Double? = nil, startedAt: Double) {
        self.own = own
        self.reaped = reaped
        self.reapedAtEnd = reapedAtEnd ?? reaped
        self.startedAt = startedAt
    }
}

/// One pass over the process table.
public struct ProcessSweep: Equatable, Sendable {
    /// When the listing was taken, in seconds on a monotonic clock — the same
    /// clock `ProcessCPU.startedAt` is on.
    public let takenAt: Double
    public let records: [ProcessRecord]

    public init(takenAt: Double, records: [ProcessRecord]) {
        self.takenAt = takenAt
        self.records = records
    }
}

// MARK: - Taking a sweep

/// The parts of `CPUAttribution`'s read order that are decisions rather than
/// system calls, here so they can be tested without a process table. The app's
/// reader makes the calls, in the order these give.
extension ProcessSweep {
    /// Indices into a listing — process `i` is `pids[i]`, started by
    /// `parents[i]` — with every process after its parent, so that a child
    /// reaped between the two reads is missing from its parent's counter rather
    /// than counted in both. Breadth-first from the processes whose parent is
    /// not listed, in listing order. The members of a parent cycle, which a
    /// real table cannot contain, have no root to be reached from; they are
    /// still read, last.
    public static func readingOrder(pids: [Int32], parents: [Int32]) -> [Int] {
        let count = min(pids.count, parents.count)
        var indexByPID: [Int32: Int] = [:]
        indexByPID.reserveCapacity(count)
        for index in 0..<count where indexByPID[pids[index]] == nil { indexByPID[pids[index]] = index }

        var firstChild = [Int](repeating: -1, count: count)
        var nextSibling = [Int](repeating: -1, count: count)
        var roots: [Int] = []
        // Backwards, so each parent's children come out in listing order.
        for index in (0..<count).reversed() {
            if let parent = indexByPID[parents[index]], parent != index {
                nextSibling[index] = firstChild[parent]
                firstChild[parent] = index
            } else {
                roots.append(index)
            }
        }

        var order = Array(roots.reversed())
        order.reserveCapacity(count)
        var placed = [Bool](repeating: false, count: count)
        for index in order { placed[index] = true }
        var next = 0
        while next < order.count {
            var child = firstChild[order[next]]
            next += 1
            while child >= 0 {
                if !placed[child] {
                    placed[child] = true
                    order.append(child)
                }
                child = nextSibling[child]
            }
        }
        for index in 0..<count where !placed[index] { order.append(index) }
        return order
    }

    /// Marks the records whose whole life is already inside a parent's
    /// end-of-sweep re-read (`ProcessRecord.foldedIntoParent`).
    ///
    /// `alive` is the sweep's second listing, taken after the first pass and
    /// before any re-read; `reRead` holds the pids whose re-read succeeded. A
    /// process missing from the second listing had been reaped by then, so it
    /// is inside its parent's re-read — or, when the parent was gone by the
    /// second listing too, inside whatever re-read the parent is inside. A
    /// chain that reaches a process that was alive and not re-read stops there,
    /// unfolded: that only means its CPU is taken out of a counter again next
    /// window, which can lose CPU and never invent it.
    ///
    /// (A child whose parent died first was reaped by `launchd` instead, and
    /// its CPU is in no counter anyone reads. Folding it is still right: it
    /// keeps that CPU from being taken out of a counter it never reached.)
    public static func markFolded(_ records: inout [ProcessRecord], alive: Set<ProcessRecord.Identity>,
                                  reRead: Set<Int32>) {
        var position: [Int32: Int] = [:]
        position.reserveCapacity(records.count)
        for (index, record) in records.enumerated() where position[record.identity.pid] == nil {
            position[record.identity.pid] = index
        }
        let listed = records
        func isInsideAReRead(_ record: ProcessRecord) -> Bool {
            var pid = record.parent
            var visited = record.identity.pid
            for _ in 0..<CPUAttribution.maximumAncestorHops {
                if reRead.contains(pid) { return true }
                guard pid != visited, let index = position[pid],
                      !alive.contains(listed[index].identity) else { return false }
                visited = pid
                pid = listed[index].parent
            }
            return false
        }
        for index in records.indices {
            guard case .read = listed[index].reading, !alive.contains(listed[index].identity) else { continue }
            records[index].foldedIntoParent = isInsideAReRead(listed[index])
        }
    }
}

// MARK: - Between two sweeps

/// Where the CPU used between two sweeps went, by `ProcessGroup`.
///
/// **Counting processes that are alive at both ends is the easy half.** The
/// half that matters is the ones that are not: a parallel build is hundreds of
/// compiler processes that each live a second or two, and most of them start
/// and finish between two readings. A per-process delta never sees them, so a
/// list built from deltas alone puts a build's CPU into the leftover line and
/// says the Mac is busy with nothing.
///
/// The kernel keeps that CPU, though. When a parent reaps a child it adds the
/// child's time — and everything the child had reaped in turn — to the
/// parent's "children" counter (measured: the parent's counter moved by exactly
/// the zombie's own figure). So the CPU of a process that ended between two
/// readings shows up as growth in its reaper's counter, and is credited to the
/// reaper's group: **whatever started it**, which for a compiler is the build
/// system inside Xcode and for a burst of shell commands is the shell.
///
/// That counter also carries history the list has already counted: a child
/// that was alive at the first reading had its CPU up to then credited to its
/// own group, and reaping moves that same CPU again. So each process that died
/// in the window has what was already counted for it (`own + reapedAtEnd` at
/// the first sweep) taken back out of the growth of its nearest surviving
/// ancestor — nearest, because a reaped parent carries its reaped children up
/// with it.
///
/// **Every race only ever loses CPU, never invents it.** The sweep is not a
/// snapshot — reading ~1,200 processes takes milliseconds, and processes end
/// during it — so the order of reads is chosen for that:
/// - Parents are read before their children. A child reaped between the two
///   reads is then missing from the parent's first-pass counter, and it is a
///   `.vanished` record rather than one counted twice.
/// - Each parent is re-read at the end (`reapedAtEnd`), and that is the
///   baseline for the next window. A child reaped during the sweep is inside it
///   — its CPU since the previous reading is lost, never counted in the next
///   window as though it were new.
/// - A process that died with nothing known about it (`.unreadable`, another
///   user's) leaves its reaper's growth unexplained, so that reaper gets no
///   reaped credit at all for the window rather than a guess.
///
/// What cannot be recovered goes to the leftover line: the last few seconds of
/// a process whose parent had already gone (it is reaped by `launchd`, which
/// is not ours to read), and anything reaped by another user's process.
public enum CPUAttribution {
    /// The most parents walked looking for a survivor. Real trees are a dozen
    /// deep; this only bounds a table that lists a cycle.
    static let maximumAncestorHops = 64

    /// CPU seconds per group used between `old` and `new`, and the span that
    /// covers. Never negative, and a process only counts for CPU it used inside
    /// the window.
    public static func attribute(from old: ProcessSweep, to new: ProcessSweep) -> (seconds: [ProcessGroup: Double], window: Double) {
        let window = new.takenAt - old.takenAt
        guard window > 0 else { return ([:], 0) }

        let before = Dictionary(old.records.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let beforeByPID = Dictionary(old.records.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.records.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })

        /// Alive at the second sweep, as the SAME process. A pid that is back
        /// with a different start time is a different process; one that was
        /// listed but gone before it could be read has ended.
        func survives(_ identity: ProcessRecord.Identity) -> Bool {
            guard let record = after[identity] else { return false }
            return record.reading != .vanished
        }

        // Every process that ended in the window, charged to its nearest
        // surviving ancestor — by the FIRST sweep's parent links, which are the
        // ones in force when it was reaped (an orphan goes to launchd, and
        // launchd is never ours to read, so a stale link can only under-count).
        var alreadyCounted: [ProcessRecord.Identity: Double] = [:]
        var unexplained: Set<ProcessRecord.Identity> = []
        var ended: Set<ProcessRecord.Identity> = []
        for record in old.records where !survives(record.identity) && ended.insert(record.identity).inserted {
            guard let reaper = survivingAncestor(of: record, in: beforeByPID, survives: survives) else { continue }
            switch record.reading {
            case .read(let cpu):
                // Already inside the parent's end-of-sweep baseline.
                if record.foldedIntoParent { continue }
                alreadyCounted[reaper, default: 0] += cpu.own + cpu.reapedAtEnd
            case .unreadable:
                unexplained.insert(reaper)
            case .vanished:
                // Gone during the first sweep, so inside its parent's
                // end-of-sweep baseline already.
                continue
            }
        }

        // In listing order, and each process once: the order keeps the sums
        // the same from run to run, and a process listed twice is still one.
        var seconds: [ProcessGroup: Double] = [:]
        var credited: Set<ProcessRecord.Identity> = []
        for record in new.records where credited.insert(record.identity).inserted {
            guard case .read(let now) = record.reading, let group = record.group else { continue }
            if let previous = before[record.identity] {
                // Alive at both ends. No baseline — unread, or vanished and
                // somehow back — means no credit this window, never a guess.
                guard case .read(let then) = previous.reading else { continue }
                var used = max(0, now.own - then.own)
                if !unexplained.contains(record.identity) {
                    let reaped = now.reaped - then.reapedAtEnd - alreadyCounted[record.identity, default: 0]
                    used += max(0, reaped)
                }
                if used > 0 { seconds[group, default: 0] += used }
            } else if now.startedAt >= old.takenAt {
                // Born inside the window: everything it and its reaped children
                // ever used is this window's.
                let used = max(0, now.own) + max(0, now.reaped)
                if used > 0 { seconds[group, default: 0] += used }
            }
            // Otherwise it predates the first sweep without being in it — its
            // CPU so far has no known start, so none of it is counted.
        }
        return (seconds, window)
    }

    private static func survivingAncestor(
        of record: ProcessRecord,
        in beforeByPID: [Int32: ProcessRecord],
        survives: (ProcessRecord.Identity) -> Bool
    ) -> ProcessRecord.Identity? {
        var pid = record.parent
        var visited = record.identity.pid
        for _ in 0..<maximumAncestorHops {
            guard pid != visited, let ancestor = beforeByPID[pid] else { return nil }
            if survives(ancestor.identity) { return ancestor.identity }
            visited = pid
            pid = ancestor.parent
        }
        return nil
    }
}
