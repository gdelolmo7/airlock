import XCTest
@testable import AirlockCore

final class ProcessSnapshotTests: XCTestCase {
    // Realistic `ps -axo pid=,ppid=,tty=,command=` shape, including the
    // sh -c wrapper Claude uses to run hook commands.
    private let fixture = """
        1     0 ??       /sbin/launchpad
      500     1 ttys002  -zsh
      600   500 ttys002  node /Users/me/.local/bin/claude --resume
      700   600 ttys002  /bin/sh -c /path/airlock-hook --source claude-code --event Stop
      710   700 ttys002  /path/airlock-hook --source claude-code --event Stop
      800     1 ??       claude
      900   500 ttys002  vim claude.md
    """

    private var snapshot: ProcessSnapshot { ProcessSnapshot.parse(fixture) }
    private let claude = ClaudeCodeIntegration()

    func testParseEntries() {
        XCTAssertEqual(snapshot.entry(600)?.ppid, 500)
        XCTAssertEqual(snapshot.entry(600)?.tty, "/dev/ttys002")
        XCTAssertNil(snapshot.entry(800)?.tty, "?? means no controlling terminal")
        XCTAssertEqual(snapshot.entry(700)?.command,
                       "/bin/sh -c /path/airlock-hook --source claude-code --event Stop")
        XCTAssertNil(snapshot.entry(999))
    }

    func testAncestorWalkFindsAgentThroughShWrapper() {
        // Hook (710) → sh -c wrapper (700, must NOT match despite "claude-code"
        // in its args) → the actual claude process (600).
        let agent = snapshot.ancestor(of: 710) { claude.matchesProcess(command: $0.command) }
        XCTAssertEqual(agent?.pid, 600)
    }

    func testAncestorExcludesSelf() {
        // 800 is itself a claude process; the walk must look at parents only.
        let agent = snapshot.ancestor(of: 800) { claude.matchesProcess(command: $0.command) }
        XCTAssertNil(agent)
    }

    func testMatchesProcess() {
        XCTAssertTrue(claude.matchesProcess(command: "claude"))
        XCTAssertTrue(claude.matchesProcess(command: "claude --resume abc"))
        XCTAssertTrue(claude.matchesProcess(command: "node /x/.bin/claude serve"))
        XCTAssertFalse(claude.matchesProcess(command: "/bin/sh -c /x/hook --source claude-code"))
        XCTAssertFalse(claude.matchesProcess(command: "vim claude.md"))
        XCTAssertFalse(claude.matchesProcess(command: "grep claude notes.txt"))
    }
}

final class LivenessTrackerTests: XCTestCase {
    func testTwoStrikesDeclareDeath() {
        var tracker = LivenessTracker()
        XCTAssertEqual(tracker.update(observations: ["s1": false]), [], "one miss is not death")
        XCTAssertEqual(tracker.update(observations: ["s1": false]), ["s1"])
    }

    func testAliveResetsStrikes() {
        var tracker = LivenessTracker()
        _ = tracker.update(observations: ["s1": false])
        _ = tracker.update(observations: ["s1": true])   // came back (ps hiccup)
        XCTAssertEqual(tracker.update(observations: ["s1": false]), [], "strikes were reset")
    }

    func testUntrackedSessionsAreForgotten() {
        var tracker = LivenessTracker()
        _ = tracker.update(observations: ["s1": false])
        _ = tracker.update(observations: [:])            // session pruned meanwhile
        XCTAssertEqual(tracker.update(observations: ["s1": false]), [])
    }

    func testIndependentSessions() {
        var tracker = LivenessTracker()
        _ = tracker.update(observations: ["a": false, "b": true])
        XCTAssertEqual(tracker.update(observations: ["a": false, "b": false]), ["a"])
    }
}
