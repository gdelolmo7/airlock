import AirlockTestSupport
import XCTest
import AirlockCore
@testable import AirlockApp

/// The app's half of the usage bridge: the switch in Settings, and what the
/// pane is allowed to say about it — see `UsageConnectionModel`.
@MainActor
final class UsageConnectionModelTests: XCTestCase {
    private let scratch = TestScratch("an-usagemodel")
    private var settings: URL!

    override func setUpWithError() throws {
        settings = scratch.file("settings.json")
        try ClaudeHookInstaller(configURL: settings).install(hookBinaryPath: "/x/airlock-hook")
        let root: [String: Any] = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        var withTheirs = root
        withTheirs["statusLine"] = ["type": "command", "command": "/their/line.sh"]
        try JSONSerialization.data(withJSONObject: withTheirs).write(to: settings)
    }

    override func tearDownWithError() throws { scratch.remove() }

    private func model(binary: String? = "/x/airlock-hook") -> UsageConnectionModel {
        UsageConnectionModel(connection: UsageConnection(settingsURL: settings),
                             bridgeBinaryPath: { binary })
    }

    /// What the pane draws follows the file, and the switch moves both ways.
    func testTheSwitchConnectsAndDisconnects() {
        let usage = model()
        XCTAssertEqual(usage.state, .replaced, "read at init, so the pane opens telling the truth")

        XCTAssertEqual(usage.sync(wantsUsage: true), .connected)
        XCTAssertEqual(usage.state, .connected)
        XCTAssertNil(usage.failure)

        XCTAssertEqual(usage.sync(wantsUsage: false), .disconnected)
        XCTAssertEqual(usage.state, .replaced, "ours is out, theirs is back")
    }

    /// The button in Settings has to say why when it cannot work — a button
    /// that silently does nothing is worse than no button.
    func testAMissingBinarySaysSoRatherThanFailingQuietly() throws {
        let usage = model(binary: nil)
        usage.connect()
        XCTAssertEqual(usage.state, .replaced, "nothing was written")
        XCTAssertNotNil(usage.failure)

        // And the message goes when a later attempt works.
        let working = model()
        working.connect()
        XCTAssertNil(working.failure)
        XCTAssertEqual(working.state, .connected)
    }
}
