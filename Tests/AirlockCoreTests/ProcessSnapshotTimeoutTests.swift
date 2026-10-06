import XCTest
@testable import AirlockCore

/// `capture()` runs on a 5-second repeat for the life of the app. An unbounded
/// wait there is not a slow function — it is liveness, usage and title
/// resolution all stopping at once, with no error anywhere.
final class ProcessSnapshotTimeoutTests: XCTestCase {

    func testAHangingSubprocessGivesUpRatherThanBlockingForever() {
        let started = Date()
        let snapshot = ProcessSnapshot.capture(timeout: 0.2,
                                               executable: "/bin/sleep",
                                               arguments: ["30"])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(snapshot, "a command that produced nothing is no information, not an empty table")
        XCTAssertLessThan(elapsed, 5, "the deadline must bound the wait, not merely decorate it")
    }

    /// The deadline must not cost anything in the normal case — a `ps` that
    /// answers promptly should not be waiting on a timer.
    func testANormalCaptureStillReturnsRealData() throws {
        let snapshot = try XCTUnwrap(ProcessSnapshot.capture(timeout: 5))
        XCTAssertNotNil(snapshot.entry(getpid()), "this test process is itself in the table")
        XCTAssertNotNil(snapshot.entry(1), "launchd is always pid 1")
    }

    /// One non-UTF-8 byte in anybody's argv used to discard the entire snapshot,
    /// for a process this app does not care about. Lossy decoding costs at worst
    /// a garbled character in a name we only ever match against.
    func testInvalidUTF8DoesNotDiscardTheWholeSnapshot() throws {
        // 0xFF is not valid UTF-8 in any position.
        let snapshot = try XCTUnwrap(ProcessSnapshot.capture(
            timeout: 5,
            executable: "/bin/sh",
            arguments: ["-c", #"printf '  1     0 ??       /sbin/launchd\n  2     1 ??       /bin/\xff-weird\n'"#]))
        XCTAssertNotNil(snapshot.entry(1),
                        "the valid row must survive a neighbour with a bad byte")
        XCTAssertEqual(snapshot.entry(1)?.command, "/sbin/launchd")
        XCTAssertNotNil(snapshot.entry(2), "the row WITH the bad byte should decode lossily, not vanish")
    }
}
