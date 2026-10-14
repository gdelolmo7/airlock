import Darwin
import Foundation
import Synchronization

/// Keeps a write into a closed pipe or socket from ending the app.
///
/// A process that writes to a pipe or socket nobody is reading any more gets
/// SIGPIPE, and by default SIGPIPE ends it on the spot: no crash report, no
/// exception, no line in any log. All that is left is runningboard's
/// "domain:signal(2) code:SIGPIPE(13)". A build that ran all day stopped that
/// way on 2026-10-08, and nothing on disk said which write it was.
///
/// The bridge sockets are already covered one by one (`SO_NOSIGPIPE` in
/// `UnixSocketServer` and `UnixSocketClient`). Everything else is not: a pipe
/// to a child process, a framework writing on its own thread. A per-socket fix
/// only covers the sockets somebody remembered.
///
/// **Caught, not ignored.** `SIG_IGN` would do the same for this process, but
/// it is inherited across `exec`. Every `ps`, `git` and `pmset` the app starts
/// would then outlive the reader of its output instead of dying like any other
/// command, and `yes | head -1` would never end. A handler is reset to the
/// default in the child, so children keep normal behaviour. In this process the
/// write that raised the signal fails with `EPIPE`, which every caller already
/// handles as a failed write.
///
/// The handler writes down where it came from, in `brokenpipe.log`, so the
/// next one names its writer. Signal handlers may only call what is safe at
/// any instant, so it uses `write`, `backtrace` and `backtrace_symbols_fd` on
/// a file opened in advance. No Swift string, no `Date`, no allocation. The
/// trace is raw (`date -r <seconds>` reads the time, `atos` the addresses).
enum BrokenPipeGuard {
    /// At most this many traces a run. A writer stuck in a loop would
    /// otherwise fill the disk one trace at a time.
    static let tracesPerRun = 10

    /// Started over at launch past this size, like the other logs here.
    private static let sizeLimit = 64 * 1024

    /// Not private so that `OwnerLogsTests` can check this exact file.
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Airlock/brokenpipe.log")
    }

    /// The app's own launch: the owner's log file. Only `main()` can make a
    /// `Launch`, so a test run never writes there (see `OwnerLogs`).
    static func install(_: AgenticNotchMain.Launch) {
        install(log: url)
    }

    /// Catches SIGPIPE for the rest of the process's life. Nil keeps no log;
    /// the app still survives the signal. Calling it again replaces the log.
    static func install(log: URL?) {
        // Opened here, never in the handler, and touching the globals here is
        // what initialises them: a Swift global's first use runs a lock, which
        // a signal handler must never be the one to take.
        let fd = log.map(open) ?? -1
        let previous = brokenPipeLogFD.exchange(fd, ordering: .sequentiallyConsistent)
        if previous >= 0 { Darwin.close(previous) }
        brokenPipeCount.store(0, ordering: .sequentiallyConsistent)

        // The first `backtrace` loads what it needs. Done now, so it is not
        // done for the first time inside the handler.
        withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 4) { frames in
            _ = backtrace(frames.baseAddress, 4)
        }

        catchSignal()
    }

    /// Takes SIGPIPE back after the crash reporter has started.
    ///
    /// A crash reporter catches every signal that can end a process, SIGPIPE
    /// among them, and it only steps aside for a signal somebody set to be
    /// ignored, not for one somebody catches. Left like that, a write into a
    /// closed pipe would be written up as a crash, sent as one at the next
    /// launch, and switch the crash reporter off for the rest of the run
    /// (it hands back to this handler, which then carries on as usual).
    /// So `CrashReporter` calls this straight after each start: the handler
    /// goes back without touching the log or the count. When the reporter is
    /// stopped it puts back what it found when it started, which is this
    /// handler again.
    static func reclaim() {
        catchSignal()
    }

    private static func catchSignal() {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = brokenPipeCaught
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_RESTART
        sigaction(SIGPIPE, &action, nil)
    }

    /// Owner-only, appended to, started over once it passes `sizeLimit`.
    private static func open(_ url: URL) -> Int32 {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? Int, size > sizeLimit {
            try? manager.removeItem(at: url)
        }
        return Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    }
}

/// The log's descriptor, or -1. Set before the handler is installed.
private let brokenPipeLogFD = Atomic<Int32>(-1)
/// Signals caught since the last `install`.
private let brokenPipeCount = Atomic<Int>(0)

/// The handler. Runs on the thread whose write failed, so the trace is the
/// writer's own. Only calls that are safe inside a signal handler.
private func brokenPipeCaught(_: Int32) {
    let saved = errno
    defer { errno = saved }

    let caught = brokenPipeCount.add(1, ordering: .relaxed).newValue
    let fd = brokenPipeLogFD.load(ordering: .relaxed)
    guard fd >= 0, caught <= BrokenPipeGuard.tracesPerRun else { return }

    writeStatic(fd, "broken pipe at ")
    writeNumber(fd, Int(time(nil)))
    writeStatic(fd, ", the write failed and Airlock carried on\n")
    withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 48) { frames in
        let depth = backtrace(frames.baseAddress, 48)
        backtrace_symbols_fd(frames.baseAddress, depth, fd)
    }
    writeStatic(fd, "\n")
}

private func writeStatic(_ fd: Int32, _ text: StaticString) {
    _ = Darwin.write(fd, text.utf8Start, text.utf8CodeUnitCount)
}

/// Decimal digits on the stack: `String(n)` allocates.
private func writeNumber(_ fd: Int32, _ number: Int) {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { digits in
        var value = max(number, 0)
        var start = digits.count
        repeat {
            start -= 1
            digits[start] = UInt8(ascii: "0") + UInt8(value % 10)
            value /= 10
        } while value > 0 && start > 0
        _ = Darwin.write(fd, digits.baseAddress! + start, digits.count - start)
    }
}
