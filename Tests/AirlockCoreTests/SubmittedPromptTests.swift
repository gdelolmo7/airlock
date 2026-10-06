import XCTest
@testable import AirlockCore

/// The "You:" line holds what the person typed.
///
/// The Claude desktop app reports a finished background task through
/// UserPromptSubmit as though it had been typed, and the card printed it —
/// `You: <task-notification> <task-id>bqjx76m5c</task-id> <tool-use-id>toolu_…`
/// — and named the conversation after it. These pin what counts as typing, and
/// what the reducer does with everything else.
final class SubmittedPromptTests: XCTestCase {
    /// The shape the desktop app sends, field for field.
    private let notification = """
    <task-notification>
    <task-id>bqjx76m5c</task-id>
    <tool-use-id>toolu_01XQ4ibg1CH1zoHBVxnMG4t5</tool-use-id>
    <output-file>/private/tmp/claude-501/tasks/bqjx76m5c.output</output-file>
    <status>completed</status>
    <summary>Background command "Run the test suite" completed (exit code 0)</summary>
    </task-notification>
    Read the output file to retrieve the result: /private/tmp/claude-501/tasks/bqjx76m5c.output
    """

    // MARK: - Classifying

    func testATaskNotificationIsNotTyping() {
        XCTAssertEqual(SubmittedPrompt.classify(notification), .taskNotification(.finished))
    }

    /// A command that ran to its end and exited 1 did not succeed, whatever the
    /// status says; a killed one was stopped.
    func testATaskNotificationSaysHowTheTaskEnded() {
        let failed = notification.replacingOccurrences(of: "exit code 0", with: "exit code 1")
        XCTAssertEqual(SubmittedPrompt.classify(failed), .taskNotification(.failed))
        let killed = notification.replacingOccurrences(of: "<status>completed</status>",
                                                       with: "<status>killed</status>")
        XCTAssertEqual(SubmittedPrompt.classify(killed), .taskNotification(.stopped))
        XCTAssertEqual(SubmittedPrompt.TaskOutcome.finished.activity, "Background task finished")
    }

    /// Exactly as the screenshot showed it: flattened, and cut at the row's
    /// limit before its closing tag.
    func testATruncatedNotificationIsStillOne() {
        let cut = "<task-notification> <task-id>bqjx76m5c</task-id> <tool-use-id>toolu_01XQ4ibg1CH1zoHBVxnMG4t5</tool-use-id> <output-file>/private/tmp/claud…"
        XCTAssertEqual(SubmittedPrompt.classify(cut), .taskNotification(.finished))
    }

    /// A slash command is a person's action, carried in tags. Show the action.
    func testACommandReadsTheWayItWasTyped() {
        let review = """
        <command-message>review is running…</command-message>
        <command-name>/review</command-name>
        <command-args>the auth module</command-args>
        """
        XCTAssertEqual(SubmittedPrompt.classify(review), .typed("/review the auth module"))
        XCTAssertEqual(SubmittedPrompt.classify("<command-name>review</command-name>\n<command-args></command-args>"),
                       .typed("/review"))
    }

    func testAShellEscapeReadsTheWayItWasTyped() {
        XCTAssertEqual(SubmittedPrompt.classify("<bash-input>ls -la</bash-input>"), .typed("! ls -la"))
    }

    func testAReminderWithNothingTypedIsInjected() {
        XCTAssertEqual(SubmittedPrompt.classify("<system-reminder>The date changed.</system-reminder>"),
                       .injected)
        XCTAssertEqual(SubmittedPrompt.classify("<local-command-stdout>Set model to Opus</local-command-stdout>"),
                       .injected)
    }

    /// Context the host put around a prompt comes off; the prompt stays.
    func testContextAroundAPromptComesOff() {
        XCTAssertEqual(
            SubmittedPrompt.classify("<ide_opened_file>The user opened main.swift.</ide_opened_file>\nfix the crash here"),
            .typed("fix the crash here"))
        XCTAssertEqual(
            SubmittedPrompt.classify("fix the login bug\n<system-reminder>Todo list is empty.</system-reminder>"),
            .typed("fix the login bug"))
    }

    /// Known tags, not any angle bracket.
    func testAnOrdinaryAngleBracketIsAPrompt() {
        XCTAssertEqual(SubmittedPrompt.classify("<div> doesn't render in Safari"),
                       .typed("<div> doesn't render in Safari"))
        XCTAssertEqual(SubmittedPrompt.classify("why does <system-reminder> show up in my logs?"),
                       .typed("why does <system-reminder> show up in my logs?"))
        XCTAssertEqual(SubmittedPrompt.classify("  fix the tests  "), .typed("fix the tests"))
    }

    // MARK: - The reducer

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func event(_ seq: UInt64, _ kind: AgentEvent.Kind) -> AgentEvent {
        AgentEvent(sessionID: "s1", agent: .claudeCode, sequence: seq, timestamp: t0, kind: kind)
    }

    /// THE regression: the notification changes neither the "You:" line nor
    /// the conversation's name, and the session still reads as working.
    func testAMachinePromptLeavesPromptAndTitleAlone() {
        var state = SessionState()
        state.apply(event(1, .promptSubmitted(prompt: "run the tests in the background")))
        state.apply(event(2, .turnEnded(assistantMessage: "Started them.")))
        state.apply(event(3, .promptSubmitted(prompt: notification)))

        let session = state.sessions["s1"]
        XCTAssertEqual(session?.lastPrompt, "run the tests in the background")
        XCTAssertEqual(session?.title, "run the tests in the background")
        XCTAssertEqual(session?.lastResponse, "Started them.", "the last real exchange stays on the card")
        XCTAssertEqual(session?.lastSummary, "Background task finished")
        XCTAssertEqual(session?.status, .running)
    }

    /// First thing in a conversation, it must not name it either.
    func testAMachinePromptNeverNamesTheConversation() {
        var state = SessionState()
        state.apply(event(1, .promptSubmitted(prompt: notification)))
        state.apply(event(2, .promptSubmitted(prompt: "<system-reminder>x</system-reminder>")))
        XCTAssertNil(state.sessions["s1"]?.title)
        XCTAssertNil(state.sessions["s1"]?.lastPrompt)

        state.apply(event(3, .promptSubmitted(prompt: "<command-name>/review</command-name>")))
        XCTAssertEqual(state.sessions["s1"]?.lastPrompt, "/review")
    }

    /// End to end, through the decoder the hook actually feeds.
    func testTheDesktopAppsNotificationThroughTheDecoder() throws {
        var state = SessionState()
        state.apply(event(1, .promptSubmitted(prompt: "fix the build")))
        let payload = try JSONSerialization.data(withJSONObject: [
            "session_id": "s1", "hook_event_name": "UserPromptSubmit", "prompt": notification,
        ])
        let events = try ClaudeStyleHookDecoder.decode(
            payload: payload,
            context: HookContext(source: "claude-code", cwd: nil, terminal: nil,
                                 receivedAt: Date(timeIntervalSince1970: 1_785_160_000)),
            agent: .claudeCode, gatesPermissions: true)
        events.forEach { state.apply($0) }
        XCTAssertEqual(state.sessions["s1"]?.lastPrompt, "fix the build")
        XCTAssertEqual(state.sessions["s1"]?.title, "fix the build")
    }

    /// A cache written before this existed still holds the notification — as
    /// the prompt and, if it came first, as the name. Restore clears both.
    func testRestoreClearsWhatAnOlderCacheStored() {
        let stored = SessionState.displayLine(notification)
        let session = AgentSession(id: "s1", agent: .claudeCode, projectName: "storefront",
                                   status: .idle, title: String(notification.prefix(60)),
                                   lastPrompt: stored, lastActivity: t0)
        let command = AgentSession(id: "s2", agent: .claudeCode, projectName: "api", status: .idle,
                                   title: "tidy the router", lastPrompt: SessionState.displayLine(
                                       "<command-message>review is running…</command-message>\n<command-name>/review</command-name>"),
                                   lastActivity: t0)
        let restored = SessionState(sessions: ["s1": session, "s2": command])
            .preparedForRestore(now: t0.addingTimeInterval(10))

        XCTAssertNil(restored.sessions["s1"]?.lastPrompt)
        XCTAssertNil(restored.sessions["s1"]?.title, "the project name reads better than a tag")
        XCTAssertEqual(restored.sessions["s2"]?.lastPrompt, "/review")
        XCTAssertEqual(restored.sessions["s2"]?.title, "tidy the router", "a typed title is left alone")
    }

    // MARK: - Pasted text

    /// Found on the owner's notch: "You: Previous message <pasted_content
    /// id="f93b"> Nothing is in progress…". The wrapper sits mid-prompt, so the
    /// start-and-end rule never saw it. The paste is what they sent and stays.
    func testAPastesWrapperIsTakenOffWhereverItSits() {
        let raw = "Previous message <pasted_content id=\"f93b\">\nNothing is in progress\n</pasted_content> go ahead"
        XCTAssertEqual(SubmittedPrompt.classify(raw), .typed("Previous message \nNothing is in progress\n go ahead"))
        XCTAssertEqual(SessionState.displayLine(
            { if case let .typed(t) = SubmittedPrompt.classify(raw) { return t } else { return "" } }()),
            "Previous message Nothing is in progress go ahead")
    }

    /// A paste with nothing typed around it is still what the person sent.
    func testAPasteAloneIsStillTyped() {
        XCTAssertEqual(SubmittedPrompt.classify("<pasted_content id=\"a1\">fix the build</pasted_content>"),
                       .typed("fix the build"))
    }

    /// A prompt that merely mentions the word is left alone.
    func testTheWordAloneIsNotAWrapper() {
        XCTAssertEqual(SubmittedPrompt.classify("why is pasted_content in the log?"),
                       .typed("why is pasted_content in the log?"))
    }

    /// A row saved before this rule is cleaned on restore.
    func testAStoredPasteIsCleanedOnRestore() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let stored = "Previous message <pasted_content id=\"f93b\"> Nothing is in progress"
        let session = AgentSession(id: "s1", agent: .claudeCode, projectName: "app", status: .idle,
                                   lastPrompt: stored, lastActivity: t0)
        let restored = SessionState(sessions: ["s1": session]).preparedForRestore(now: t0)
        XCTAssertEqual(restored.sessions["s1"]?.lastPrompt, "Previous message Nothing is in progress")
    }
}
