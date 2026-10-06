import XCTest
@testable import AirlockApp

/// A process with no app bundle has no notification center, and must go on
/// without one rather than die asking for it.
///
/// **The crash this pins.** `UNUserNotificationCenter.current()` raises an
/// Objective-C exception when there is no bundle, and nothing can catch it. The
/// app set its notification delegate on every launch, so from 2eaa587 on the
/// documented demo command, `AIRLOCK_DEMO=1 swift run AirlockApp`, died before
/// it drew anything.
///
/// A test runner is exactly such a process, which is what makes this testable
/// at all. One test proves that premise, so the others cannot pass quietly
/// somewhere the crash was never possible.
final class NotificationsWithoutBundleTests: XCTestCase {

    func testTheTestRunnerHasNoAppBundle() {
        XCTAssertFalse(AppBundle.isBundled, """
            the tests below assume the runner has no app bundle, like `swift run`; \
            if that changed, they no longer reach the crash they are about
            """)
    }

    /// A regression cannot fail this politely. The raise happens inside
    /// `dispatch_once`, which ends the process whoever is trying to catch it —
    /// wrapping this in `ALExceptionCatcher` was tried and changes nothing. What
    /// a regression looks like is the whole run dying on SIGABRT, with
    /// `bundleProxyForCurrentProcess is nil` recorded against this test's name.
    func testTheCenterIsAbsentRatherThanFatal() {
        XCTAssertNil(Notifications.center(), "a run with no app bundle has no notification center")
    }

    /// `Notifications.center()` protects only the code that goes through it.
    /// Both call sites that crashed asked for the center directly, so the next
    /// notification written the same way would bring the crash straight back.
    func testNothingElseAsksForTheCenterDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AirlockAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources")

        var callers: [String] = []  // "File.swift: line"
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            // The vendored kit posts nothing, and this rule is about what WE write.
            guard !url.path.contains("/DynamicNotchKit/") else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Code only. Prose explaining why — including this rule's own —
                // is not a call.
                guard trimmed.contains("UNUserNotificationCenter.current"),
                      !trimmed.hasPrefix("//") else { continue }
                callers.append("\(url.lastPathComponent): \(trimmed)")
            }
        }

        XCTAssertFalse(callers.isEmpty, """
            the scanner found not even `Notifications.center()` — it has stopped working
            """)
        let elsewhere = callers.filter { !$0.hasPrefix("Notifications.swift: ") }
        XCTAssertTrue(elsewhere.isEmpty, """
            ask `Notifications.center()` instead — calling `current()` directly \
            crashes any run without an app bundle, `swift run` included:
            \(elsewhere.joined(separator: "\n"))
            """)
        XCTAssertEqual(callers.count, 1, """
            only `Notifications.center()` should call `current()`:
            \(callers.joined(separator: "\n"))
            """)
    }
}
