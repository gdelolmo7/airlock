import Foundation

/// A point-in-time view of running processes (`ps -axo pid,ppid,tty,command`).
///
/// Used twice: the hook walks its parent chain to find the agent process that
/// invoked it, and the app polls to check that tracked agents are still alive.
/// Parsing is pure and fixture-tested; only `capture()` touches the system.
public struct ProcessSnapshot: Sendable {
    public struct Entry: Sendable, Equatable {
        public let pid: Int32
        public let ppid: Int32
        /// Full device path ("/dev/ttys002"), nil for TTY-less processes.
        public let tty: String?
        public let command: String

        public init(pid: Int32, ppid: Int32, tty: String?, command: String) {
            self.pid = pid
            self.ppid = ppid
            self.tty = tty
            self.command = command
        }
    }

    private let byPID: [Int32: Entry]

    public init(entries: [Entry]) {
        var map: [Int32: Entry] = [:]
        for entry in entries { map[entry.pid] = entry }
        byPID = map
    }

    public func entry(_ pid: Int32) -> Entry? { byPID[pid] }

    /// Walk the parent chain of `pid` (excluding `pid` itself) until an entry
    /// satisfies `predicate`. Bounded, and cycle-safe by construction.
    public func ancestor(of pid: Int32, maxHops: Int = 8, where predicate: (Entry) -> Bool) -> Entry? {
        var current = entry(pid)?.ppid
        for _ in 0..<maxHops {
            guard let pid = current, pid > 1, let candidate = entry(pid) else { return nil }
            if predicate(candidate) { return candidate }
            current = candidate.ppid
        }
        return nil
    }

    // MARK: - Parsing

    /// Parse `ps -axo pid=,ppid=,tty=,command=` output.
    public static func parse(_ text: String) -> ProcessSnapshot {
        var entries: [Entry] = []
        for line in text.components(separatedBy: .newlines) {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]) else { continue }
            let tty = fields[2] == "??" ? nil : "/dev/\(fields[2])"
            // The remainder keeps padding spaces from ps's column alignment.
            entries.append(Entry(pid: pid, ppid: ppid, tty: tty,
                                 command: String(fields[3].drop(while: { $0 == " " }))))
        }
        return ProcessSnapshot(entries: entries)
    }

    /// Run `ps` and parse. Returns nil on any failure — callers must treat a
    /// missing snapshot as "no information", never as "everything died".
    /// - Parameters:
    ///   - timeout: how long to wait for `ps` before giving up on it. The wait
    ///     used to be unbounded, and this runs on a 5-second repeat for the life
    ///     of the app: one wedged process table or stalled mount and
    ///     `waitUntilExit()` never returns, taking liveness, usage refresh and
    ///     title resolution with it — silently, for the rest of the session.
    ///     Returning nil is already the "no information" answer every caller
    ///     handles, so a slow `ps` now costs one cycle instead of all of them.
    ///   - executable/arguments: injectable so a test can point this at a
    ///     command that deliberately hangs. Nothing in the app passes them.
    public static func capture(timeout: TimeInterval = 5,
                               executable: String = "/bin/ps",
                               arguments: [String] = ["-axo", "pid=,ppid=,tty=,command="]) -> ProcessSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        // Terminating closes the pipe, which is what actually unblocks the read
        // below — so this bounds both waits, not just `waitUntilExit`. Honest
        // limit: it is SIGTERM, so a child in uninterruptible sleep still will
        // not die. That is a kernel state no user-space deadline can escape, and
        // it is rarer than the cases this does cover.
        let deadline = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)

        // `readToEnd()` throws where `readDataToEndOfFile()` raised an
        // Objective-C exception, which Swift cannot catch — so a read error
        // killed whichever process asked (the app, or the hook in the middle
        // of a tool call) instead of being the "no information" this returns
        // for every other failure. It is nil, never an empty table: an empty
        // snapshot reads as every process having died.
        let data: Data?
        do {
            data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        } catch {
            data = nil
        }
        process.waitUntilExit()
        deadline.cancel()

        guard process.terminationStatus == 0, let data else { return nil }
        // `String(decoding:)`, not the failable `String(data:encoding:)`: a
        // single non-UTF-8 byte anywhere in anybody's argv used to discard the
        // ENTIRE snapshot — every session's liveness, tty and agent PID — for a
        // command this app does not even care about. Lossy decoding costs at
        // worst a garbled character in a process name we only ever match against.
        return parse(String(decoding: data, as: UTF8.self))
    }
}
