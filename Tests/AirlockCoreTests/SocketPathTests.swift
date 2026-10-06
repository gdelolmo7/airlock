import XCTest
@testable import AirlockCore

/// A demo must never listen where the hooks connect.
///
/// The server unlinks whatever is at its path before binding, so two processes
/// listening on one path means the newer one silently takes every hook — and a
/// demo started beside an installed Airlock did exactly that. See
/// `SocketPath.listening(demo:)`.
final class SocketPathTests: XCTestCase {

    /// The half that must not move: the hook connects to `default()`, so an app
    /// listening anywhere else would receive nothing.
    func testTheAppListensWhereEveryHookConnects() {
        XCTAssertEqual(SocketPath.listening(demo: false), SocketPath.default())
    }

    /// Nor may `default()` itself. The hook staged on disk can be older than the
    /// app that is running, and this path is the only thing they share.
    func testTheRealSocketHasNotMoved() throws {
        let support = try XCTUnwrap(FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        XCTAssertEqual(SocketPath.default(),
                       support.appendingPathComponent("Airlock/bridge.sock").path)
    }

    func testADemoNeverListensWhereTheHooksConnect() {
        XCTAssertNotEqual(SocketPath.listening(demo: true), SocketPath.default())
    }

    /// Same directory, so it gets the same 0700 protection as the real one.
    func testTheDemoSocketSitsBesideTheRealOne() {
        let demo = URL(fileURLWithPath: SocketPath.listening(demo: true))
        let real = URL(fileURLWithPath: SocketPath.default())
        XCTAssertEqual(demo.deletingLastPathComponent(), real.deletingLastPathComponent())
    }
}
