import XCTest

/// The kit's `.keepVisible` makes `hide()` wait for as long as the kit believes
/// the pointer is on the panel, and that belief can outlive the pointer. One
/// wait hung a hide for 727s and queued every transition behind it, over a
/// full-screen film. The host keeps the panel up under the pointer itself (see
/// the `hoverBehavior` comment in `NotchController`), so the kit is never asked
/// to. Read from the source because the app target has no test seam for it.
final class KitHideNeverWaitsTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AirlockCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheKitIsNotAskedToHoldThePanelUnderThePointer() throws {
        let controller = try source("Sources/AirlockApp/Notch/NotchController.swift")
        let line = controller.split(separator: "\n")
            .first { $0.contains("hoverBehavior:") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let behaviour = try XCTUnwrap(line, "NotchController no longer passes `hoverBehavior:` to the kit.")
        XCTAssertFalse(behaviour.contains(".keepVisible"), """
            NotchController asks the kit for `.keepVisible` again. Its `hide()` then \
            waits on a hover flag that can go stale, and every transition queues \
            behind a hide that never returns.
            """)
    }
}
