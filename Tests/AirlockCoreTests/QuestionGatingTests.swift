import XCTest
@testable import AirlockCore

/// A question is not a permission request, and the difference matters most in
/// exactly the mode where it was being ignored.
final class QuestionGatingTests: XCTestCase {
    private let context = HookContext(source: "claude-code", cwd: "/tmp/project",
                                      terminal: nil,
                                      receivedAt: Date(timeIntervalSince1970: 1_785_160_000))

    private func decode(tool: String, input: [String: Any], mode: String?) throws -> [AgentEvent] {
        var root: [String: Any] = [
            "session_id": "s1",
            "hook_event_name": "PreToolUse",
            "cwd": "/tmp/project",
            "tool_name": tool,
            "tool_input": input,
        ]
        if let mode { root["permission_mode"] = mode }
        return try ClaudeStyleHookDecoder.decode(
            payload: JSONSerialization.data(withJSONObject: root),
            context: context, agent: .claudeCode, gatesPermissions: true)
    }

    private let question: [String: Any] = [
        "questions": [[
            "question": "Which superpower?",
            "header": "Pick",
            "multiSelect": false,
            "options": [["label": "Perfect recall", "description": "Every API"],
                        ["label": "See the bug", "description": "Before you run it"]],
        ]],
    ]

    private func isGate(_ events: [AgentEvent]) -> PermissionRequest? {
        for event in events {
            if case .permissionRequested(let request) = event.kind { return request }
        }
        return nil
    }

    // MARK: - The bug

    /// "Bypass permissions" means "stop asking whether you may run things". It
    /// has never meant "stop asking me things" — Claude Code itself still shows
    /// its picker and waits. The notch reported "Auto-run · …" and stayed shut.
    func testQuestionStillGatesUnderBypassPermissions() throws {
        for mode in ["bypassPermissions", "dontAsk", "auto"] {
            let request = isGate(try decode(tool: "AskUserQuestion", input: question, mode: mode))
            XCTAssertNotNil(request, "\(mode) must not swallow a question")
            XCTAssertEqual(request?.question?.options.map(\.label),
                           ["Perfect recall", "See the bug"])
        }
    }

    /// The exemption is for questions only — a shell command under bypass still
    /// must not interrupt, or an unattended run would stall on every tool call.
    ///
    /// The line says what is happening and nothing else: it used to read
    /// "Auto-run (bypassPermissions) · …", a setting's internal name.
    func testCommandsAreStillAutoRunUnderBypass() throws {
        let events = try decode(tool: "Bash", input: ["command": "npm test"],
                                mode: "bypassPermissions")
        XCTAssertNil(isGate(events))
        if case .activity(let summary) = events.first?.kind {
            XCTAssertEqual(summary, "Running: npm test")
            XCTAssertFalse(summary.contains("bypassPermissions"))
        } else {
            XCTFail("expected passive activity, got \(String(describing: events.first?.kind))")
        }
    }

    /// Plan mode is Claude working out what it WOULD do — it never runs the
    /// tool, so Claude Code never puts the approval in the chat either. A card
    /// here had nowhere to be answered from, and the held hook stalled the very
    /// planning run it interrupted.
    func testPlanModeDoesNotGate() throws {
        let events = try decode(tool: "Bash", input: ["command": "rg TODO"], mode: "plan")
        XCTAssertNil(isGate(events))
        if case .activity(let summary) = events.first?.kind {
            // "Auto-run" would be a lie — nothing is running.
            XCTAssertTrue(summary.hasPrefix("Planning ·"), summary)
        } else {
            XCTFail("expected passive activity, got \(String(describing: events.first?.kind))")
        }
    }

    /// A question still gates in plan mode: Claude asking which approach to take
    /// is the whole point of planning, and it genuinely waits for the answer.
    func testQuestionStillGatesInPlanMode() throws {
        XCTAssertNotNil(isGate(try decode(tool: "AskUserQuestion", input: question, mode: "plan")))
    }

    func testNormalModesAreUnaffected() throws {
        XCTAssertNotNil(isGate(try decode(tool: "Bash", input: ["command": "npm test"], mode: nil)))
        XCTAssertNotNil(isGate(try decode(tool: "Bash", input: ["command": "npm test"],
                                          mode: "default")))
        XCTAssertNotNil(isGate(try decode(tool: "AskUserQuestion", input: question, mode: nil)))
    }

    /// The card needs its options to be answerable; a question that arrives
    /// without them would render as a gate with nothing to pick.
    func testQuestionOptionsSurviveDecoding() throws {
        let request = isGate(try decode(tool: "AskUserQuestion", input: question, mode: nil))
        XCTAssertEqual(request?.question?.question, "Which superpower?")
        XCTAssertEqual(request?.question?.header, "Pick")
        XCTAssertEqual(request?.question?.options.first?.detail, "Every API")
        XCTAssertEqual(request?.question?.multiSelect, false)
    }
}

/// The other way a question could vanish: a policy rule silently answering it.
final class QuestionPolicyTests: XCTestCase {
    private func questionRequest() -> PermissionRequest {
        PermissionRequest(id: "q1", toolName: "AskUserQuestion",
                          summary: "Which superpower?",
                          question: QuestionPrompt(question: "Which superpower?",
                                                   options: [QuestionOption(label: "A")]),
                          createdAt: Date(timeIntervalSince1970: 1_785_160_000))
    }

    /// A question has no command and no target, so a tool-only allow rule is the
    /// only thing that could match it. Worth pinning: `AskUserQuestion` in an
    /// allow list would auto-answer questions by picking nothing, which is a
    /// far worse failure than an extra interruption.
    func testQuestionIsNotMatchedByPatternRules() throws {
        let policy = Policy(allow: [try PolicyRule(parsing: "AskUserQuestion(*)")])
        XCTAssertEqual(PolicyEngine.evaluate(questionRequest(), policy: policy), .ask(risk: nil))
    }

    func testUnrelatedRulesLeaveQuestionsAlone() throws {
        let policy = Policy(allow: [try PolicyRule(parsing: "Bash(*)"),
                                    try PolicyRule(parsing: "Read")])
        XCTAssertEqual(PolicyEngine.evaluate(questionRequest(), policy: policy), .ask(risk: nil))
    }
}
