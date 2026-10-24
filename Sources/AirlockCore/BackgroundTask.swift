import Foundation

/// Work an agent sent off to run on its own — a command left running, a
/// helper agent — that it has not yet heard back from.
///
/// It matters for one reason: an agent that stops talking while one of these
/// is out has not finished. It will speak again when the work reports back,
/// so its turn ending is a pause, and the notch read it as Done — the chime,
/// the green mark — while the real end was still minutes away.
///
/// Claude Code says both halves. The finished call (`PostToolUse`) says a task
/// went to the background and under which id; the task's end arrives as a
/// prompt nobody typed (`SubmittedPrompt.taskNotification`) naming the same
/// call. Measured 2026-10-08 in the Claude desktop app, for a task ending
/// while the agent waited and for one ending while it was still at work.
public struct BackgroundTask: Codable, Sendable, Hashable {
    /// The tool call that started it (`tool_use_id`). The notification names
    /// it as `<tool-use-id>`, so it is the id the two sides share.
    public var callID: String
    /// The agent's own id for it — the shell's or the helper's. What a stop
    /// call names, and the notification's `<task-id>`.
    public var taskID: String?
    public var startedAt: Date

    public init(callID: String, taskID: String? = nil, startedAt: Date) {
        self.callID = callID
        self.taskID = taskID
        self.startedAt = startedAt
    }

    /// Whether a notification or a stop call names this task.
    public func isNamed(taskID other: String?, callID otherCall: String?) -> Bool {
        if let otherCall, otherCall == callID { return true }
        if let other, other == taskID { return true }
        return false
    }

    /// The background task a finished tool call started, if it started one.
    ///
    /// A command shows it in its result (`backgroundTaskId`) — which also
    /// covers one moved to the background while it ran — and a helper agent
    /// by being launched rather than run (`isAsync`, `async_launched`). The
    /// call's own `run_in_background` is the fallback when the result is
    /// shaped some other way. A call with no id at all is left out: nothing
    /// could ever name it again, and it would hold the session open forever.
    public static func launched(tool: String, input: [String: Any]?, response: Any?,
                                callID: String?, at time: Date) -> BackgroundTask? {
        guard backgroundTools.contains(tool) else { return nil }
        let result = response as? [String: Any]
        let taskID = (result?["backgroundTaskId"] as? String)
            ?? (result?["agentId"] as? String)
            ?? (result?["task_id"] as? String)
        let launched = result?["backgroundTaskId"] != nil
            || (result?["isAsync"] as? Bool) == true
            || (result?["status"] as? String) == "async_launched"
            || (input?["run_in_background"] as? Bool) == true
        guard launched, let id = callID ?? taskID, !id.isEmpty else { return nil }
        return BackgroundTask(callID: id, taskID: taskID, startedAt: time)
    }

    /// The task a stop call ended, by the agent's id for it.
    public static func stopped(tool: String, input: [String: Any]?) -> String? {
        guard stopTools.contains(tool), let input else { return nil }
        return ["task_id", "shell_id", "bash_id", "agent_id"]
            .lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty }
    }

    /// Tools that can leave something running: a command, and a helper agent
    /// under either of its names.
    static let backgroundTools: Set<String> = ["Bash", "Agent", "Task"]
    /// Tools that end one, under the names Claude Code has used for them.
    static let stopTools: Set<String> = ["TaskStop", "KillShell", "KillBash"]

    /// The session row's line while the agent waits on them.
    public static func waitingLine(_ count: Int) -> String {
        count == 1 ? String(localized: "Waiting on a background task") : String(localized: "Waiting on \(count) background tasks")
    }
}
