import Foundation
import XCTest
@testable import AirlockApp

/// A test run leaves the owner's logs alone (see `OwnerLogs`).
///
/// This is checked against the REAL files, using a marker that only this test
/// can write. The running app, or another checkout's test run, can append to
/// those files at any moment. That cannot make this flaky, because what is
/// asserted is that one line is absent, not that the file stood still.
@MainActor
final class OwnerLogsTests: XCTestCase {

    /// Shut for the whole of every test process. It starts shut, and the only
    /// way to open it takes an `AgenticNotchMain.Launch`, which a test cannot
    /// make. Try it and the test does not compile.
    func testATestProcessHasTheOwnersLogsShut() {
        XCTAssertFalse(OwnerLogs.areOpen)
    }

    /// Through the same functions the app logs with. `dictationLog` is what
    /// `AudioCapture` is given by default, and it is how `AssistantModel` put
    /// 21 lines a run into `dictation.log`.
    func testNothingATestLogsReachesTheOwnersFiles() throws {
        let marker = "test-run-marker-\(UUID().uuidString)"

        dictationLog(marker)
        DictationDiagnostics.log(marker)
        ControlDiagnostics.log(.sleepDisplay, marker)
        WaveDiagnostics.log(marker)
        AppVolumeDiagnostics.log(marker)
        // The hover trace writes only when it is switched on, so switch it on;
        // otherwise this line would pass whether or not the gate works.
        let previous = ProcessInfo.processInfo.environment["AIRLOCK_DEBUG"]
        setenv("AIRLOCK_DEBUG", "1", 1)
        defer {
            if let previous { setenv("AIRLOCK_DEBUG", previous, 1) } else { unsetenv("AIRLOCK_DEBUG") }
        }
        XCTAssertTrue(HoverTrace.isEnabled)
        HoverTrace.note(marker)

        // Where `HoverTrace` puts it, without its `create: true`: this test
        // must not make the folder either.
        let support = try XCTUnwrap(FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first)
        let files = [DictationDiagnostics.url, ControlDiagnostics.url, WaveDiagnostics.url,
                     AppVolumeDiagnostics.url, support.appendingPathComponent("Airlock/hover.log")]
        for file in files {
            // Bytes, not a String: a line another writer is halfway through
            // could fail to decode, and that must not read as "not found".
            let contents = (try? Data(contentsOf: file)) ?? Data()
            XCTAssertNil(contents.range(of: Data(marker.utf8)),
                         "a test wrote to the owner's \(file.lastPathComponent)")
        }
    }

    /// The other half: the app still opens them, and first. A gate opened a
    /// few lines later would lose whatever was logged before it, without
    /// any error.
    func testTheAppOpensThemBeforeAnythingElse() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AirlockAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/AirlockApp/App.swift")
        let source = try String(contentsOf: app, encoding: .utf8)
        let main = try XCTUnwrap(source.range(of: "static func main() {"),
                                 "the entry point moved; this test has to follow it")
        let firstStatement = source[main.upperBound...]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("//") }
        XCTAssertEqual(firstStatement, "OwnerLogs.open(Launch())",
                       "main() must open the owner's logs before anything else, or the app loses its first lines")
    }
}
