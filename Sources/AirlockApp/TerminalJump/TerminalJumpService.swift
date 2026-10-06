import AppKit
import AirlockCore

/// Executes a `JumpStrategy` — activating the terminal and, where possible,
/// selecting the exact tab/pane the session lives in.
///
/// iTerm2 / Terminal.app use AppleScript (first use prompts for Automation
/// permission — expected, and user-initiated). tmux uses its CLI. External
/// processes run off the main thread so a slow terminal never stalls the UI.
///
/// **Every AppleScript path reports how it went** (`TerminalTrouble`). They
/// were fired and forgotten: a refused Automation permission closed the panel
/// as if the jump had worked, and the quick prompt threw away the words it had
/// failed to send. The other paths (tmux, activating an app) cannot tell, and
/// say nothing.
@MainActor
struct TerminalJumpService {
    func jump(to session: AgentSession) async -> TerminalTrouble? {
        switch TerminalJumpPlanner.plan(for: session) {
        case let .iterm(tty, _):
            return await runAppleScript(itermScript(tty: tty), app: Self.iTermName)
        case let .terminalApp(tty):
            return await runAppleScript(terminalScript(tty: tty), app: Self.terminalName)
        case let .tmux(pane):
            let p = sanitize(pane)
            runShell("tmux select-window -t '\(p)' 2>/dev/null; tmux select-pane -t '\(p)' 2>/dev/null")
        case let .activate(app):
            // Prefer the process's real owner: a GUI-hosted session (Claude.app,
            // Codex.app, VS Code) reports a meaningless TERM_PROGRAM, and its
            // agent PID belongs to the app we actually want to front.
            if !activateOwningApp(of: session) { activate(app) }
        case .none:
            // No terminal info at all — the owning app is the only target.
            _ = activateOwningApp(of: session)
        }
        return nil
    }

    /// The terminals as a person names them, for `TerminalTrouble`'s sentence.
    private static let iTermName = "iTerm"
    private static let terminalName = "Terminal"

    /// Front the application that owns the agent process. Returns false when
    /// the PID isn't a GUI app (a terminal-bound CLI), so callers can fall back.
    @discardableResult
    private func activateOwningApp(of session: AgentSession) -> Bool {
        guard let pid = session.jumpTarget?.agentPID,
              let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate()
    }

    /// Open a NEW terminal window running `claude`, optionally seeded with a
    /// prompt (the AI-first quick-prompt). A new window on purpose: never inject
    /// into a session the user already owns. The prompt is base64-wrapped so any
    /// text — quotes, `$`, backticks — reaches `claude` verbatim with no shell
    /// or AppleScript escaping hazards.
    func openTerminalRunningClaude(prompt: String? = nil) async -> TerminalTrouble? {
        let claude: String
        if let prompt, !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            let b64 = Data(prompt.utf8).base64EncodedString()
            claude = "claude \"$(echo '\(b64)' | base64 --decode)\""
        } else {
            claude = "claude"
        }
        // Land in our own workspace rather than wherever Terminal happens to
        // open — an agent let loose in $HOME is a much wider blast radius than
        // one in a folder that exists for this. `mkdir -p` because the user may
        // have deleted it since launch.
        let layout = WorkspaceLayout.resolve()
        try? layout.ensureExists()
        let directory = Self.shellQuoted(layout.workspace.path)
        return await openTerminal(running: "mkdir -p \(directory) && cd \(directory) && \(claude)")
    }

    /// Open a NEW terminal window running a shell command, in whichever terminal
    /// the user has.
    ///
    /// A new window, always. Injecting into a session someone already owns would
    /// interleave with whatever is running in it — and the command is visible in
    /// their own shell, which is the point: nothing here installs anything
    /// behind the user's back, it hands them the command already typed.
    @discardableResult
    func openTerminal(running command: String) async -> TerminalTrouble? {
        // Only `"` and `\` need escaping for the AppleScript string.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let hasITerm = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
        if hasITerm {
            return await runAppleScript("""
            tell application "iTerm2"
              activate
              set w to (create window with default profile)
              tell current session of w to write text "\(escaped)"
            end tell
            """, app: Self.iTermName)
        } else {
            return await runAppleScript("""
            tell application "Terminal"
              activate
              do script "\(escaped)"
            end tell
            """, app: Self.terminalName)
        }
    }

    /// Single-quote for `sh`, escaping any embedded quote the POSIX way. Home
    /// directories can contain spaces; this is the only safe form.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Scripts

    private func itermScript(tty: String?) -> String {
        guard let tty = sanitizeOrNil(tty) else {
            return #"tell application "iTerm2" to activate"#
        }
        return """
        tell application "iTerm2"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  if (tty of s) is "\(tty)" then
                    select w
                    tell t to select
                    tell s to select
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end tell
        """
    }

    private func terminalScript(tty: String?) -> String {
        guard let tty = sanitizeOrNil(tty) else {
            return #"tell application "Terminal" to activate"#
        }
        return """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (tty of t) is "\(tty)" then
                  set selected tab of w to t
                  set frontmost of w to true
                end if
              end try
            end repeat
          end repeat
        end tell
        """
    }

    // MARK: - Execution

    private func activate(_ termProgram: String) {
        let name = friendlyName(for: termProgram)
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            app.activate()
        } else {
            runProcess("/usr/bin/open", ["-a", name])
        }
    }

    /// In-process (NOT osascript subprocess) so the Apple event is sent by our
    /// entitled app and TCC grants "control iTerm/Terminal" to us — the same
    /// fix that unbroke Spotify. A subprocess is auto-denied under hardened
    /// runtime, which is why jump-back silently did nothing.
    ///
    /// The code goes to the log, never the script: it carries the command.
    private func runAppleScript(_ source: String, app: String) async -> TerminalTrouble? {
        switch await AppleScriptClient.perform(source) {
        case .ok:
            return nil
        case .failed(let code):
            Log.app.error("terminal script failed — code \(code, privacy: .private)")
            return TerminalTrouble(appleScriptCode: code, app: app)
        }
    }

    /// tmux/plain shell — no Apple events, so a subprocess is correct here.
    private func runShell(_ command: String) {
        runProcess("/bin/sh", ["-c", command])
    }

    private func runProcess(_ launchPath: String, _ arguments: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                Log.app.error("jump helper failed to launch — \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    // MARK: - Helpers

    private func friendlyName(for termProgram: String) -> String {
        switch termProgram {
        case "vscode": return "Code"
        case "ghostty": return "Ghostty"
        case "WezTerm": return "WezTerm"
        case "Hyper": return "Hyper"
        default: return termProgram.replacingOccurrences(of: ".app", with: "")
        }
    }

    /// Strip characters that could break out of the single-quoted shell / script
    /// context. tty and tmux-pane values are well-formed, but never trust input.
    private func sanitize(_ value: String) -> String {
        value.filter { !"'\"\n\r\\`$".contains($0) }
    }

    private func sanitizeOrNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let cleaned = sanitize(value)
        return cleaned.isEmpty ? nil : cleaned
    }
}
