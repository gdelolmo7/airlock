import AirlockTestSupport
import XCTest
@testable import AirlockCore

/// Keeping Claude's status line carrying Airlock's usage bridge — see
/// `UsageConnection`.
///
/// The case that started it: a Mac where another tool owned the status line, so
/// the usage cache had never been written and the switch in Settings offered a
/// feature that could not work.
final class UsageConnectionTests: XCTestCase {
    private let scratch = TestScratch("an-usage")
    private var settings: URL!
    /// A status line of somebody else's, with the spaces and quotes that a
    /// careless rewrite would lose.
    private let theirs = #"/usr/local/bin/node "/Users/me/.claude/hooks/statusline.js" --fancy 'two words'"#

    override func setUpWithError() throws {
        settings = scratch.file("settings.json")
    }

    override func tearDownWithError() throws { scratch.remove() }

    private func connection() -> UsageConnection { UsageConnection(settingsURL: settings) }

    private func installHooks() throws {
        try ClaudeHookInstaller(configURL: settings).install(hookBinaryPath: "/Users/me/.airlock/bin/airlock-hook")
    }

    private func writeTheirStatusLine(padding: Int = 1) throws {
        let existing = try? JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        var root = existing.flatMap { $0 } ?? [:]
        root["statusLine"] = ["type": "command", "command": theirs, "padding": padding]
        try JSONSerialization.data(withJSONObject: root).write(to: settings)
    }

    private func statusLine() throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        return (root?["statusLine"] as? [String: Any]) ?? [:]
    }

    // MARK: - Putting it back

    /// The reported case: hooks are installed, the figures are switched on, and
    /// the status line belongs to something else.
    func testAReplacedStatusLineIsPutBackWithTheirCommandIntact() throws {
        try installHooks()
        try writeTheirStatusLine()
        XCTAssertEqual(connection().state(), .replaced)

        XCTAssertEqual(connection().sync(wantsUsage: true, bridgeBinaryPath: "/Users/me/.airlock/bin/airlock-hook"),
                       .connected)

        let entry = try statusLine()
        let command = try XCTUnwrap(entry["command"] as? String)
        XCTAssertTrue(command.hasPrefix("'/Users/me/.airlock/bin/airlock-hook' --statusline"), command)
        XCTAssertEqual(ClaudeStatusLineInstaller.chainArgument(in: command),
                       Data(theirs.utf8).base64EncodedString(),
                       "their command rides along untouched, so their line still draws")
        XCTAssertEqual(entry["padding"] as? Int, 1, "their padding is theirs")
        XCTAssertEqual(connection().state(), .connected)
    }

    /// It runs at every launch, so it has to settle: once the bridge is ours,
    /// nothing is written at all.
    func testNothingHappensWhenItIsAlreadyOurs() throws {
        try installHooks()
        try writeTheirStatusLine()
        connection().sync(wantsUsage: true, bridgeBinaryPath: "/x/airlock-hook")
        let settled = try Data(contentsOf: settings)

        XCTAssertEqual(connection().sync(wantsUsage: true, bridgeBinaryPath: "/x/airlock-hook"), .none)
        XCTAssertEqual(try Data(contentsOf: settings), settled, "not rewritten")
    }

    /// Never on a Mac that has not invited us into Claude's settings, and never
    /// by installing hooks to make it so.
    func testHooksAbsentIsNotOursToFix() throws {
        try writeTheirStatusLine()
        let untouched = try Data(contentsOf: settings)
        XCTAssertEqual(connection().state(), .hooksMissing)

        XCTAssertEqual(connection().sync(wantsUsage: true, bridgeBinaryPath: "/x/airlock-hook"), .none)
        XCTAssertEqual(connection().sync(wantsUsage: false, bridgeBinaryPath: "/x/airlock-hook"), .none)
        XCTAssertEqual(try Data(contentsOf: settings), untouched)
        XCTAssertEqual(try statusLine()["command"] as? String, theirs)
    }

    /// The switch off is an answer, so somebody else's status line is left
    /// exactly as it is.
    func testTheFiguresBeingOffLeavesSomebodyElsesLineAlone() throws {
        try installHooks()
        try writeTheirStatusLine()
        let untouched = try Data(contentsOf: settings)

        XCTAssertEqual(connection().sync(wantsUsage: false, bridgeBinaryPath: "/x/airlock-hook"), .none)
        XCTAssertEqual(try Data(contentsOf: settings), untouched)
    }

    // MARK: - Taking it out again

    /// Turning the figures off unchains rather than leaving a reader nobody
    /// reads — and the next launch does not put it back.
    func testTurningTheFiguresOffGivesTheirCommandBackAndLeavesItOff() throws {
        try installHooks()
        try writeTheirStatusLine(padding: 2)
        connection().sync(wantsUsage: true, bridgeBinaryPath: "/x/airlock-hook")

        XCTAssertEqual(connection().sync(wantsUsage: false, bridgeBinaryPath: "/x/airlock-hook"), .disconnected)
        XCTAssertEqual(try statusLine()["command"] as? String, theirs, "byte for byte, quotes and all")
        XCTAssertEqual(try statusLine()["padding"] as? Int, 2)
        XCTAssertEqual(connection().state(), .replaced)

        // Every later launch reads the same switch and leaves it alone.
        let settled = try Data(contentsOf: settings)
        XCTAssertEqual(connection().sync(wantsUsage: false, bridgeBinaryPath: "/x/airlock-hook"), .none)
        XCTAssertEqual(try Data(contentsOf: settings), settled)
    }

    /// Nobody else's line to keep: ours is added on its own and removed again,
    /// leaving Claude's settings as they were.
    func testWithNoStatusLineOfTheirOwnItIsAddedAndRemoved() throws {
        try installHooks()
        let before = try Data(contentsOf: settings)

        XCTAssertEqual(connection().sync(wantsUsage: true, bridgeBinaryPath: "/x/airlock-hook"), .connected)
        XCTAssertTrue((try statusLine()["command"] as? String)?.contains("--statusline") ?? false)

        XCTAssertEqual(connection().sync(wantsUsage: false, bridgeBinaryPath: "/x/airlock-hook"), .disconnected)
        XCTAssertEqual(try statusLine() as NSDictionary, [:], "the key goes rather than being left empty")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let was = try XCTUnwrap(try JSONSerialization.jsonObject(with: before) as? [String: Any])
        XCTAssertEqual(root["hooks"] as? NSDictionary, was["hooks"] as? NSDictionary, "hooks untouched throughout")
    }

    /// Settings kept in a dotfiles repository are a link. The write goes
    /// through it — see `ConfigFileWriter` — and the link stays a link.
    func testASymlinkedSettingsFileIsWrittenThrough() throws {
        let real = scratch.folder("dotfiles").appendingPathComponent("settings.json")
        let link = scratch.folder("home").appendingPathComponent("settings.json")
        settings = link
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../dotfiles/settings.json")
        try installHooks()
        try writeTheirStatusLine()

        XCTAssertEqual(connection().sync(wantsUsage: true, bridgeBinaryPath: "/x/airlock-hook"), .connected)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       "../dotfiles/settings.json", "still a link to their file")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any])
        let entry = try XCTUnwrap(root["statusLine"] as? [String: Any])
        XCTAssertTrue((entry["command"] as? String)?.contains("--statusline") ?? false,
                      "written to the real file, not to a copy over the link")
    }

    /// A button that cannot work says why rather than doing nothing.
    func testWithoutABinaryItSaysSoAndWritesNothing() throws {
        try installHooks()
        try writeTheirStatusLine()
        let untouched = try Data(contentsOf: settings)

        guard case let .failed(why) = connection().sync(wantsUsage: true, bridgeBinaryPath: nil) else {
            return XCTFail("a missing binary is a failure, not a silent success")
        }
        XCTAssertFalse(why.isEmpty)
        XCTAssertEqual(try Data(contentsOf: settings), untouched)
    }

    /// Hooks that only LOOK like ours are not an install to build on.
    ///
    /// The tightened matcher decides what "hooks are installed" means here, and
    /// the answer has to be no: a user whose own script happens to be named
    /// after our binary never invited us into their status line either.
    func testALookAlikeHookIsNotAnInstallToConnect() throws {
        let theirs: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "", "hooks": [[
            "type": "command",
            "command": "~/bin/airlock-hook-logger.sh --source claude-code --event PreToolUse",
        ]]]]]]
        try JSONSerialization.data(withJSONObject: theirs).write(to: settings)
        try writeTheirStatusLine()
        let untouched = try Data(contentsOf: settings)

        XCTAssertEqual(connection().state(), .hooksMissing)
        XCTAssertEqual(connection().sync(wantsUsage: true, bridgeBinaryPath: "/x/airlock-hook"), .none)
        XCTAssertEqual(try Data(contentsOf: settings), untouched)
    }

    /// Connecting twice does not wrap our own command inside itself: the
    /// installer reads the line it wrote as ours and keeps the chain it was
    /// carrying. Worth pinning here, because the matcher that decides it was
    /// tightened after this bridge was built.
    func testConnectingTwiceKeepsTheirCommandRatherThanWrappingOurs() throws {
        try installHooks()
        try writeTheirStatusLine()
        connection().sync(wantsUsage: true, bridgeBinaryPath: "/x/airlock-hook")

        // A second connect, from a different staged path — what a reinstall or
        // a moved binary looks like.
        try ClaudeStatusLineInstaller(configURL: settings).install(bridgeBinaryPath: "/y/airlock-hook")

        let command = try XCTUnwrap(try statusLine()["command"] as? String)
        XCTAssertTrue(command.hasPrefix("'/y/airlock-hook' --statusline"), command)
        XCTAssertEqual(ClaudeStatusLineInstaller.chainArgument(in: command),
                       Data(theirs.utf8).base64EncodedString(), "still their command, not ours")
        XCTAssertEqual(connection().sync(wantsUsage: false, bridgeBinaryPath: nil), .disconnected)
        XCTAssertEqual(try statusLine()["command"] as? String, theirs)
    }
}
