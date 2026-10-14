import Darwin
import Foundation
import XCTest
@testable import AirlockApp

/// A write into a closed pipe fails instead of ending the app, the write is
/// noted, and the commands the app starts still die of a broken pipe like any
/// other command (see `BrokenPipeGuard`).
///
/// Each test puts back the process's own SIGPIPE handling when it is done, so
/// the rest of the run sees what it would have seen without these tests.
final class BrokenPipeGuardTests: XCTestCase {
    private var saved = sigaction()
    private var log: URL!

    override func setUpWithError() throws {
        sigaction(SIGPIPE, nil, &saved)
        log = FileManager.default.temporaryDirectory
            .appendingPathComponent("brokenpipe-\(UUID().uuidString).log")
    }

    override func tearDownWithError() throws {
        BrokenPipeGuard.install(log: nil)
        sigaction(SIGPIPE, &saved, nil)
        try? FileManager.default.removeItem(at: log)
    }

    func testAWriteIntoAClosedPipeFailsAndIsNoted() throws {
        BrokenPipeGuard.install(log: log)

        // Caught, not ignored: an ignore would pass on to every child.
        var now = sigaction()
        sigaction(SIGPIPE, nil, &now)
        let handler = unsafeBitCast(now.__sigaction_u.__sa_handler, to: Int.self)
        XCTAssertNotEqual(handler, unsafeBitCast(SIG_IGN, to: Int.self))
        XCTAssertNotEqual(handler, unsafeBitCast(SIG_DFL, to: Int.self))

        XCTAssertEqual(writeIntoAClosedPipe(), EPIPE)

        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("broken pipe at "), text)
        XCTAssertTrue(text.contains("the write failed and Airlock carried on"), text)
        // The writer's own frames follow the handler's, and the writer is
        // this test. Swift's mangling shortens repeated words in a name, so
        // the module is what can be looked for, not the function.
        XCTAssertTrue(text.contains("AirlockAppTests"), text)
    }

    func testAWriterInALoopStopsBeingNotedAtTheCap() throws {
        BrokenPipeGuard.install(log: log)
        for _ in 0..<(BrokenPipeGuard.tracesPerRun + 5) {
            XCTAssertEqual(writeIntoAClosedPipe(), EPIPE)
        }
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "broken pipe at ").count - 1,
                       BrokenPipeGuard.tracesPerRun)
    }

    /// Without a log the app still survives; it just has nothing to say.
    func testNoLogStillSurvives() {
        BrokenPipeGuard.install(log: nil)
        XCTAssertEqual(writeIntoAClosedPipe(), EPIPE)
    }

    /// A handler is put back to the default in a started command, where an
    /// ignore would carry over. The shell sends itself the signal; with the
    /// default it dies of it, as `ps` or `git` would if their reader went.
    func testACommandTheAppStartsStillDiesOfABrokenPipe() throws {
        BrokenPipeGuard.install(log: log)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "kill -PIPE $$; exit 0"]
        try shell.run()
        shell.waitUntilExit()
        XCTAssertEqual(shell.terminationReason, .uncaughtSignal)
        XCTAssertEqual(shell.terminationStatus, SIGPIPE)
    }

    /// The app installs it second, straight after opening its logs: a broken
    /// pipe before that would end the app as it always did.
    func testTheAppInstallsItAtTheStart() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AirlockAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/AirlockApp/App.swift")
        let source = try String(contentsOf: app, encoding: .utf8)
        let main = try XCTUnwrap(source.range(of: "static func main() {"))
        let statements = source[main.upperBound...]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        XCTAssertEqual(Array(statements.prefix(2)),
                       ["OwnerLogs.open(Launch())", "BrokenPipeGuard.install(Launch())"])
    }

    /// One byte into a pipe whose reading end is already shut. Returns the
    /// write's errno, 0 if it somehow succeeded.
    private func writeIntoAClosedPipe() -> Int32 {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return -1 }
        Darwin.close(ends[0])
        defer { Darwin.close(ends[1]) }
        var byte: UInt8 = 0x41
        errno = 0
        let wrote = Darwin.write(ends[1], &byte, 1)
        return wrote < 0 ? errno : 0
    }
}
