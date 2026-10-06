import Foundation

/// Decoder for the Claude-style hook payload schema — the de-facto standard
/// the agent ecosystem converged on (Claude Code defined it; Codex documents
/// its hooks as "the same event schema", and the Claude forks are
/// byte-compatible). Fields: `session_id`, `hook_event_name`, `cwd`,
/// `tool_name`, `tool_input`, `message`.
///
/// `gatesPermissions` controls what PreToolUse becomes:
/// - true (Claude): a `permissionRequested` card — the hook blocks on our
///   directive, so Approve/Deny buttons are real. Claude's PermissionRequest
///   becomes one too, in the modes where PreToolUse does not — see
///   `promptOpensCard`.
/// - false (Codex): hooks are observational, so the same event becomes a
///   `questionAsked` ("approve in terminal") — attention without fake buttons.
enum ClaudeStyleHookDecoder {
    /// The tool that is a question rather than a permission request. Named
    /// because several places have to agree about it.
    static let questionTool = "AskUserQuestion"

    /// What a non-gating agent's ask is recorded as: this, then the command.
    /// `SessionCardText.terminalAsk` takes it apart again for the card.
    static let terminalAskPrefix = "Approve in terminal · "

    /// The row's line while Claude summarises the conversation to make room.
    static let compactingLine = "Summarising the conversation so far…"

    /// The tool that hands Claude's plan to the person to approve. Never a
    /// card — see the PermissionRequest case.
    static let planTool = "ExitPlanMode"

    /// Permission modes where the session has already decided, so a gate here
    /// asks a question nobody is waiting to answer — and worse, blocks the hook
    /// while doing it.
    ///
    /// `plan` belongs here for a different reason than the rest. The others are
    /// the user saying "stop asking me". Plan mode is Claude *not running the
    /// tool at all* — it is thinking, not acting — so for almost every call
    /// Claude Code never puts an approval in the chat either. The card had
    /// nowhere to be answered from: not the notch, since resolving it changed
    /// nothing, and not the session, since the session was never asking.
    /// Meanwhile the held hook stalled the very planning run it interrupted.
    ///
    /// "A gate here" means at PreToolUse, which fires for every call whether or
    /// not anything will be asked. These modes still ask sometimes — auto when
    /// it will not decide alone, plan when Claude reaches for something it may
    /// not do unasked, bypass at the few actions no mode approves on its own —
    /// and when they do, Claude says so with PermissionRequest. That is where
    /// the notch asks for them; see `promptOpensCard`.
    static let nonGatingModes: Set<String> = [
        "bypassPermissions", "dontAsk", "auto", "plan",
    ]

    static func decode(
        payload: Data,
        context: HookContext,
        agent: AgentKind,
        gatesPermissions: Bool
    ) throws -> [AgentEvent] {
        guard
            let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return [] }

        let sessionID = (root["session_id"] as? String)
            ?? "\(agent.rawValue)-\(context.receivedAt.timeIntervalSince1970)"
        let event = (root["hook_event_name"] as? String) ?? context.source
        let cwd = (root["cwd"] as? String) ?? context.cwd
        var seq = UInt64(context.receivedAt.timeIntervalSince1970 * 1000)
        func nextSeq() -> UInt64 { seq += 1; return seq }

        func make(_ kind: AgentEvent.Kind) -> AgentEvent {
            AgentEvent(sessionID: sessionID, agent: agent, sequence: nextSeq(),
                       timestamp: context.receivedAt, kind: kind)
        }

        // Transcript path rides along on lifecycle moments — the app resolves
        // the AI conversation title from it (summary lines) when no explicit
        // name has arrived via the status-line channel.
        var prefix: [AgentEvent] = []
        if ["SessionStart", "UserPromptSubmit", "Stop"].contains(event),
           let transcript = root["transcript_path"] as? String, !transcript.isEmpty {
            prefix.append(make(.metadata(transcriptPath: transcript)))
        }
        func made(_ kinds: [AgentEvent.Kind]) -> [AgentEvent] { prefix + kinds.map(make) }

        switch event {
        case "SessionStart":
            let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? SessionState.unknownProject
            var kinds: [AgentEvent.Kind] = [.sessionStarted(project: project, cwd: cwd, terminal: context.terminal)]
            if let title = root["session_title"] as? String, !title.isEmpty {
                kinds.append(.titleChanged(title: title))
            }
            return made(kinds)

        case "UserPromptSubmit":
            if let prompt = (root["prompt"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                return made([.promptSubmitted(prompt: prompt)])
            }
            return made([.activity(summary: "Working…")])

        case "PermissionRequest" where gatesPermissions:
            let tool = (root["tool_name"] as? String) ?? "Tool"
            // Approving a plan is also choosing how Claude goes on — which mode
            // it works in, or back to planning with a note — and a card's
            // Approve would pick one of those without saying which. The dialog
            // stays Claude's; the row says where it is. A line, not a "Needs
            // you": escaping that dialog fires no hook at all (not even Stop),
            // so a waiting state would have nothing to end it.
            if tool == Self.planTool {
                return [make(.activity(summary: "Plan ready for review in Claude"))]
            }
            guard Self.promptOpensCard(tool: tool, mode: root["permission_mode"] as? String) else {
                return []
            }
            // No `tool_use_id` on this event, so the id takes a fresh one.
            let request = permissionRequest(tool: tool, input: root["tool_input"] as? [String: Any],
                                            at: context.receivedAt)
            return [make(.permissionRequested(request))]

        case "PreToolUse", "PermissionRequest":
            let tool = (root["tool_name"] as? String) ?? "Tool"
            let input = root["tool_input"] as? [String: Any]
            let request = permissionRequest(tool: tool, input: input, at: context.receivedAt,
                                            callID: root["tool_use_id"] as? String)

            // The session has already decided — see `nonGatingModes`. Holding a
            // gate here stalls it for ask_timeout per tool call and asks a
            // question nobody is waiting on. Surface as passive activity;
            // never block.
            //
            // EXCEPT a question. "Bypass permissions" means "stop asking me
            // whether you may run things"; it has never meant "stop asking me
            // things". Claude Code agrees — in bypass mode it still puts its own
            // picker on screen and waits. Treating `AskUserQuestion` as
            // auto-runnable was what left the notch reporting "Auto-run · You
            // get a free, permanent superpower…" while the terminal sat there
            // holding the actual question.
            let mode = root["permission_mode"] as? String
            if let mode, tool != Self.questionTool, Self.nonGatingModes.contains(mode) {
                let activity = request.activity ?? request.summary
                return [make(.activity(summary: Self.passiveSummary(mode: mode, activity: activity)))]
            }

            if gatesPermissions {
                // Only in plan mode in practice, which passes above — but a plan
                // is approved in Claude's own dialog whatever the mode says (see
                // the PermissionRequest case), and an Approve here would not
                // approve it.
                if tool == Self.planTool {
                    return [make(.activity(summary: request.activity ?? request.summary))]
                }
                return [make(.permissionRequested(request))]
            }
            // The command when there is one, because that is what the terminal
            // is asking about; otherwise the call in words, since the card's
            // "Allow …?" would put a question inside this one.
            let subject = request.command ?? request.activity ?? request.summary
            return [make(.questionAsked(prompt: Self.terminalAskPrefix + subject))]

        case "PostToolUse":
            let tool = (root["tool_name"] as? String) ?? "tool"
            let input = root["tool_input"] as? [String: Any]
            let summary = ToolPhrase.phrase(tool: tool, input: input, .finished)
            // Non-gating: the terminal prompt we surfaced is over — clear it.
            return gatesPermissions
                ? made([.activity(summary: summary)])
                : made([.questionAnswered(answer: ""), .activity(summary: summary)])

        case "Notification":
            // Written by the agent, not by us, so it can name a tool the way the
            // agent knows it.
            // One with no words says nothing a person could read; the event's
            // own name used to stand in for them.
            guard let message = (root["message"] as? String).map(ToolPhrase.humanizingToolNames),
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [make(.activity(summary: message))]

        case "SubagentStop":
            // A helper the agent sent off has come back. The agent itself is
            // still at work — it reads the helper's answer and carries on — so
            // this is not its turn ending: decoded as one, it put the session
            // to rest mid-task (a Done chime for nothing) and showed the
            // helper's last words as the agent's reply.
            return []

        case "Stop":
            let reply = root["last_assistant_message"] as? String
            let ended = make(.turnEnded(assistantMessage: reply))
            return gatesPermissions
                ? [ended]
                : [make(.questionAnswered(answer: "")), ended]

        case "SessionEnd":
            return [make(.sessionEnded)]

        case "PreCompact":
            // Claude making room by summarising the conversation so far — a
            // pause worth a line, said the way a person would.
            return [make(.activity(summary: Self.compactingLine))]

        default:
            // An event this version does not know. Its name is Claude's
            // internal word for it ("SubagentStart"), so it never reaches the
            // row; the line keeps whatever it last said, which is still true.
            return []
        }
    }

    /// Whether Claude's own permission prompt becomes a card: only where
    /// PreToolUse let the call through.
    ///
    /// Every call meets PreToolUse first. In the modes that gate, the notch has
    /// had its say by the time Claude asks, so the prompt means the card was
    /// handed back, or that one of Claude's own rules asks whatever a hook
    /// said — and a second card for the same call would be asking twice. In
    /// `nonGatingModes` PreToolUse only watched, so this is the one place the
    /// question reaches the notch.
    ///
    /// The event carries no `tool_use_id`, so it cannot be matched to its
    /// PreToolUse call for call; the mode tells them apart, read exactly as
    /// PreToolUse reads it. A missing or unknown mode gated there, so it passes
    /// here — the safe side, because passing leaves Claude's dialog asking. And
    /// a question was a card at PreToolUse in every mode, so it is never one
    /// twice.
    static func promptOpensCard(tool: String, mode: String?) -> Bool {
        guard tool != questionTool, let mode else { return false }
        return nonGatingModes.contains(mode)
    }

    /// A tool call in a mode that does not gate.
    ///
    /// It is not a question — the session already decided — so it never reads
    /// as one; it used to print the card's own "Allow …?" behind "Auto-run".
    /// Nor does it name the mode: `auto` or `bypassPermissions` in brackets is
    /// a setting's internal name, and the row is about what the agent is doing.
    ///
    /// Plan mode keeps its word, for the reason it got one: nothing is running,
    /// Claude is working out what it would do, and saying so keeps the row
    /// honest.
    static func passiveSummary(mode: String, activity: String) -> String {
        mode == "plan" ? "Planning · \(activity)" : activity
    }

    /// Build a rich permission card from a `PreToolUse` tool input.
    ///
    /// The id must be unique per gate: every guard that keeps one gate's
    /// answer off another — the bridge's, the reducer's, the app's — compares
    /// ids. It was the tool and the millisecond, which parallel calls to one
    /// tool share whenever they reach the hook together, and then an answer for
    /// the first was delivered to the second. `callID` is the agent's own id for
    /// the call (`tool_use_id`) when it sends one; otherwise a fresh one.
    static func permissionRequest(tool: String, input: [String: Any]?, at now: Date,
                                  callID: String? = nil) -> PermissionRequest {
        let call = callID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        let id = "\(tool)-\(UInt64(now.timeIntervalSince1970 * 1000))-\(call)"
        // Claude's own description of a command, "Edit main.swift", "Allow
        // Trello: write card?" — see `ToolPhrase` for every tool's wording.
        let headline = ToolPhrase.phrase(tool: tool, input: input, .asking)
        let activity = ToolPhrase.phrase(tool: tool, input: input, .running)
        // Said here, where the tool's own input is still in hand: a rule can
        // deny this gate long after that input is gone, and "Auto-denied ·
        // Running: …" is a line about a call that never ran.
        let refusal = ToolPhrase.phrase(tool: tool, input: input, .refused)
        switch tool {
        case "Bash":
            let command = input?["command"] as? String
            return PermissionRequest(id: id, toolName: tool, summary: headline, activity: activity,
                                     refusal: refusal, command: command, target: command, createdAt: now)
        case "Edit", "Write", "MultiEdit":
            let path = input?["file_path"] as? String
            let diff = input?["new_string"] as? String ?? input?["content"] as? String
            return PermissionRequest(id: id, toolName: tool, summary: headline, activity: activity,
                                     refusal: refusal, diff: diff, target: path, createdAt: now)
        case questionTool:
            // All of them. The card steps through the ask and answers it once —
            // it used to show the first question and drop the rest, so the
            // agent heard back about one and nothing about the others.
            let questions = input.map(QuestionPrompt.parseAll) ?? []
            var request = PermissionRequest(id: id, toolName: tool,
                                            summary: questions.first?.question ?? "Claude has a question",
                                            activity: activity, refusal: refusal, createdAt: now)
            request.questions = questions
            return request
        default:
            return PermissionRequest(id: id, toolName: tool, summary: headline, activity: activity,
                                     refusal: refusal, createdAt: now)
        }
    }
}
