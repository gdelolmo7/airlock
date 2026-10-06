import Foundation

/// How to restore focus to a session's terminal. A pure value so the routing
/// logic is unit-testable without AppleScript or a running terminal.
public enum JumpStrategy: Equatable, Sendable {
    case iterm(tty: String?, sessionID: String?)
    case terminalApp(tty: String?)
    case tmux(pane: String)
    case activate(app: String)
    case none
}

/// Chooses a jump strategy from a session's terminal metadata.
///
/// tmux wins when a pane is known (a tmux session lives *inside* another
/// terminal, so pane targeting is the precise move); otherwise dispatch by the
/// reported terminal app. This is the seam new terminals plug into.
public enum TerminalJumpPlanner {
    public static func plan(for session: AgentSession) -> JumpStrategy {
        if let pane = tmuxPane(for: session) {
            return .tmux(pane: pane)
        }
        guard let terminal = session.terminal else { return .none }
        switch terminal.app {
        case "iTerm.app":
            return .iterm(tty: terminal.tty, sessionID: terminal.sessionID)
        case "Apple_Terminal":
            return .terminalApp(tty: terminal.tty)
        default:
            return .activate(app: terminal.app)
        }
    }

    private static func tmuxPane(for session: AgentSession) -> String? {
        if let pane = session.jumpTarget?.tmuxPane { return pane }
        if session.terminal?.app == "tmux", let pane = session.terminal?.sessionID { return pane }
        return nil
    }
}
