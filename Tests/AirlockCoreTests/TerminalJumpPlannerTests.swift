import XCTest
@testable import AirlockCore

final class TerminalJumpPlannerTests: XCTestCase {
    private func session(terminal: TerminalInfo?, jumpTarget: JumpTarget? = nil) -> AgentSession {
        AgentSession(id: "s", agent: .claudeCode, projectName: "p",
                     terminal: terminal, lastActivity: Date(), jumpTarget: jumpTarget)
    }

    func testITermByTTY() {
        let plan = TerminalJumpPlanner.plan(for: session(
            terminal: TerminalInfo(app: "iTerm.app", tty: "/dev/ttys002", sessionID: "abc")))
        XCTAssertEqual(plan, .iterm(tty: "/dev/ttys002", sessionID: "abc"))
    }

    func testTerminalApp() {
        let plan = TerminalJumpPlanner.plan(for: session(
            terminal: TerminalInfo(app: "Apple_Terminal", tty: "/dev/ttys003")))
        XCTAssertEqual(plan, .terminalApp(tty: "/dev/ttys003"))
    }

    func testTmuxWinsWhenPaneKnown() {
        // Even inside iTerm, a known tmux pane is the precise target.
        let plan = TerminalJumpPlanner.plan(for: session(
            terminal: TerminalInfo(app: "iTerm.app", tty: "/dev/ttys002"),
            jumpTarget: JumpTarget(tmuxPane: "%4")))
        XCTAssertEqual(plan, .tmux(pane: "%4"))
    }

    func testTmuxFromTerminalInfo() {
        let plan = TerminalJumpPlanner.plan(for: session(
            terminal: TerminalInfo(app: "tmux", sessionID: "%7")))
        XCTAssertEqual(plan, .tmux(pane: "%7"))
    }

    func testUnknownTerminalActivates() {
        let plan = TerminalJumpPlanner.plan(for: session(
            terminal: TerminalInfo(app: "ghostty")))
        XCTAssertEqual(plan, .activate(app: "ghostty"))
    }

    func testNoTerminalIsNone() {
        XCTAssertEqual(TerminalJumpPlanner.plan(for: session(terminal: nil)), .none)
    }
}
