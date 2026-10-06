import XCTest
@testable import AirlockCore

/// Tool calls in words, not identifiers.
///
/// The first three tests are the lines from the owner's screenshot, decoded the
/// way the hook delivers them. Everything after pins the pieces: how an MCP name
/// comes apart, how each built-in reads, and the one rule none of them may
/// break — nothing on the notch shows `mcp__`, a UUID, or a mode's token.
final class ToolPhraseTests: XCTestCase {
    private let trello = "mcp__7adb9f71-433e-414a-a8a1-f17b52e5037f__trelloWriteCard"
    private let browser = "mcp__Claude_Browser__preview_list"

    private func decode(_ root: [String: Any], gates: Bool = true) throws -> [AgentEvent] {
        var root = root
        root["session_id"] = "s1"
        return try ClaudeStyleHookDecoder.decode(
            payload: JSONSerialization.data(withJSONObject: root),
            context: HookContext(source: "claude-code", cwd: nil, terminal: nil,
                                 receivedAt: Date(timeIntervalSince1970: 1_785_160_000)),
            agent: gates ? .claudeCode : .codex, gatesPermissions: gates)
    }

    private func activity(_ events: [AgentEvent]) -> String? {
        guard case let .activity(summary)? = events.last?.kind else { return nil }
        return summary
    }

    // MARK: - The screenshot

    /// Was "Ran mcp__7adb9f71-433e-414a-a8a1-f17b52e5037f__trelloWriteCard".
    func testAConnectorToolThatRanReadsAsWhatItDid() throws {
        let events = try decode(["hook_event_name": "PostToolUse", "tool_name": trello,
                                 "tool_input": ["name": "Fix login"]])
        XCTAssertEqual(activity(events), "Used Trello: write card")
    }

    /// Was "Auto-run (auto) · Allow mcp__Claude_Browser__preview_list?" — a
    /// question, in a mode where nothing was being asked, with the mode's
    /// internal name in brackets.
    func testANonGatingModeSaysWhatIsHappeningAndAsksNothing() throws {
        for mode in ["auto", "bypassPermissions", "dontAsk"] {
            let events = try decode(["hook_event_name": "PreToolUse", "permission_mode": mode,
                                     "tool_name": browser, "tool_input": [:] as [String: Any]])
            XCTAssertEqual(activity(events), "Using Claude Browser: preview list", mode)
        }
    }

    /// A card that IS waiting on the user may still ask — with the name a
    /// person reads. The raw name stays on the request, where policy needs it.
    func testAGateAsksWithThePlainNameAndKeepsTheRawOne() throws {
        let events = try decode(["hook_event_name": "PreToolUse", "tool_name": trello,
                                 "tool_input": [:] as [String: Any]])
        guard case let .permissionRequested(request)? = events.last?.kind else {
            return XCTFail("expected a gate, got \(events)")
        }
        XCTAssertEqual(request.summary, "Allow Trello: write card?")
        XCTAssertEqual(request.activity, "Using Trello: write card")
        XCTAssertEqual(request.toolName, trello, "rules match on the raw name")
    }

    /// Plan mode keeps the word that makes it honest.
    func testPlanModeStillSaysPlanning() throws {
        let events = try decode(["hook_event_name": "PreToolUse", "permission_mode": "plan",
                                 "tool_name": "Read", "tool_input": ["file_path": "/x/notes.md"]])
        XCTAssertEqual(activity(events), "Planning · Reading notes.md")
    }

    /// Codex cannot gate, so its line points at the terminal — and must not
    /// carry the card's "Allow …?" inside it.
    func testCodexPointsAtTheTerminalWithoutAQuestionInsideIt() throws {
        let events = try decode(["hook_event_name": "PreToolUse", "tool_name": browser,
                                 "tool_input": [:] as [String: Any]], gates: false)
        guard case let .questionAsked(prompt)? = events.last?.kind else {
            return XCTFail("expected a terminal pointer, got \(events)")
        }
        XCTAssertEqual(prompt, "Approve in terminal · Using Claude Browser: preview list")
    }

    // MARK: - MCP names

    func testUUIDServerWithTheServiceInTheToolName() {
        XCTAssertEqual(ToolPhrase.name(trello), "Trello: write card")
        XCTAssertEqual(ToolPhrase.name("mcp__7adb9f71-433e-414a-a8a1-f17b52e5037f__trelloSearch"),
                       "Trello: search")
    }

    /// Nothing says whose `create_file` it is, and guessing would be worse
    /// than saying what it does.
    func testUUIDServerWithAGenericTool() {
        XCTAssertEqual(ToolPhrase.name("mcp__a972bfaa-6c9e-436f-9adf-7414d7eb49e6__create_file"),
                       "create file")
        XCTAssertEqual(ToolPhrase.name("mcp__50c50f71-0324-4131-bc16-5cc787279028__execute_sql"),
                       "execute SQL")
    }

    func testNamedServerWithSnakeCaseTool() {
        XCTAssertEqual(ToolPhrase.name(browser), "Claude Browser: preview list")
        XCTAssertEqual(ToolPhrase.name("mcp__Claude_Code_iOS_Simulator__build"),
                       "Claude Code iOS Simulator: build")
        XCTAssertEqual(ToolPhrase.name("mcp__claude-in-chrome__navigate"), "Claude in chrome: navigate")
    }

    /// `plugin_<plugin>_<server>`: the server half is its name.
    func testPluginServer() {
        XCTAssertEqual(
            ToolPhrase.name("mcp__plugin_cloudflare_cloudflare-docs__search_cloudflare_documentation"),
            "Cloudflare docs: search cloudflare documentation")
    }

    func testClaudeAIConnectorAsTheCLINamesIt() {
        XCTAssertEqual(ToolPhrase.name("mcp__claude_ai_Gmail__search_threads"), "Gmail: search threads")
    }

    /// `mcp__trello__trelloReadBoard` is not "Trello: trello read board".
    func testAToolNamedAfterItsServerDoesNotSayItTwice() {
        XCTAssertEqual(ToolPhrase.name("mcp__trello__trelloReadBoard"), "Trello: read board")
    }

    func testCamelCaseAndAcronyms() {
        XCTAssertEqual(ToolPhrase.name("mcp__mcp-registry__search_mcp_registry"),
                       "MCP registry: search MCP registry")
        XCTAssertEqual(ToolPhrase.name("mcp__github__getPRStatus"), "Github: get PR status")
        XCTAssertEqual(ToolPhrase.name("mcp__docs__getURLInfo"), "Docs: get URL info")
    }

    /// Built-in names are already names, and rules are written with them.
    func testBuiltInNamesAreLeftAlone() {
        XCTAssertEqual(ToolPhrase.name("Read"), "Read")
        XCTAssertEqual(ToolPhrase.name("WebSearch"), "WebSearch")
        XCTAssertFalse(ToolPhrase.isMCP("Read"))
        XCTAssertTrue(ToolPhrase.isMCP(trello))
    }

    // MARK: - MCP lines

    func testAnMCPToolInEachMoment() {
        XCTAssertEqual(ToolPhrase.phrase(tool: trello, input: nil, .asking), "Allow Trello: write card?")
        XCTAssertEqual(ToolPhrase.phrase(tool: trello, input: nil, .running), "Using Trello: write card")
        XCTAssertEqual(ToolPhrase.phrase(tool: trello, input: nil, .finished), "Used Trello: write card")
    }

    /// With nobody to name, a verb reads better as a verb: "Created file", not
    /// "Used create file".
    func testAServerlessToolThatOpensWithAVerbIsConjugated() {
        let tool = "mcp__a972bfaa-6c9e-436f-9adf-7414d7eb49e6__create_file"
        XCTAssertEqual(ToolPhrase.phrase(tool: tool, input: nil, .asking), "Create file")
        XCTAssertEqual(ToolPhrase.phrase(tool: tool, input: nil, .running), "Creating file")
        XCTAssertEqual(ToolPhrase.phrase(tool: tool, input: nil, .finished), "Created file")
        XCTAssertEqual(
            ToolPhrase.phrase(tool: "mcp__a972bfaa-6c9e-436f-9adf-7414d7eb49e6__get_file_metadata",
                              input: nil, .finished),
            "Got file metadata")
    }

    func testAServerlessToolWithNoVerbIsUsed() {
        let tool = "mcp__1a59c906-04da-521d-bda7-7f71b9f9e01c__batch"
        XCTAssertEqual(ToolPhrase.phrase(tool: tool, input: nil, .finished), "Used batch")
        XCTAssertEqual(ToolPhrase.phrase(tool: tool, input: nil, .asking), "Allow batch?")
    }

    // MARK: - Built-in tools

    func testReadNamesTheFile() {
        let input: [String: Any] = ["file_path": "/Users/me/project/notes.md"]
        XCTAssertEqual(ToolPhrase.phrase(tool: "Read", input: input, .asking), "Read notes.md")
        XCTAssertEqual(ToolPhrase.phrase(tool: "Read", input: input, .running), "Reading notes.md")
        XCTAssertEqual(ToolPhrase.phrase(tool: "Read", input: input, .finished), "Read notes.md")
        XCTAssertEqual(ToolPhrase.phrase(tool: "Read", input: nil, .running), "Reading a file")
    }

    /// The card has always asked "Edit x" for all three; after the fact it
    /// says what happened.
    func testFileWrites() {
        let input: [String: Any] = ["file_path": "/x/middleware.ts"]
        XCTAssertEqual(ToolPhrase.phrase(tool: "Write", input: input, .asking), "Edit middleware.ts")
        XCTAssertEqual(ToolPhrase.phrase(tool: "Write", input: input, .finished), "Wrote middleware.ts")
        XCTAssertEqual(ToolPhrase.phrase(tool: "Edit", input: input, .running), "Editing middleware.ts")
        XCTAssertEqual(ToolPhrase.phrase(tool: "MultiEdit", input: input, .finished), "Edited middleware.ts")
        XCTAssertEqual(ToolPhrase.phrase(tool: "Edit", input: nil, .asking), "Edit file")
    }

    /// Claude's description of a command, always; the command only when there
    /// is no description, in the wording these lines already had.
    func testBashPrefersClaudesDescription() {
        let described: [String: Any] = ["command": "zsh scripts/package-app.sh", "description": "Package the app"]
        for moment in [ToolPhrase.Moment.asking, .running, .finished] {
            XCTAssertEqual(ToolPhrase.phrase(tool: "Bash", input: described, moment), "Package the app")
        }
        let bare: [String: Any] = ["command": "npm test"]
        XCTAssertEqual(ToolPhrase.phrase(tool: "Bash", input: bare, .asking), "Run shell command")
        XCTAssertEqual(ToolPhrase.phrase(tool: "Bash", input: bare, .running), "Running: npm test")
        XCTAssertEqual(ToolPhrase.phrase(tool: "Bash", input: bare, .finished), "Ran: npm test")
        XCTAssertEqual(ToolPhrase.phrase(tool: "Bash", input: nil, .finished), "Ran command")
    }

    func testSearching() {
        XCTAssertEqual(ToolPhrase.phrase(tool: "WebSearch", input: ["query": "swift actors"], .running),
                       "Searching the web for “swift actors”")
        XCTAssertEqual(ToolPhrase.phrase(tool: "WebSearch", input: nil, .finished), "Searched the web")
        XCTAssertEqual(ToolPhrase.phrase(tool: "Grep", input: ["pattern": "TODO"], .finished),
                       "Searched files for “TODO”")
        // A regular expression means nothing read aloud.
        XCTAssertEqual(ToolPhrase.phrase(tool: "Grep", input: ["pattern": #"\bfoo\("#], .running),
                       "Searching files")
        // Nor does a glob.
        XCTAssertEqual(ToolPhrase.phrase(tool: "Glob", input: ["pattern": "**/*.swift"], .running),
                       "Looking for files")
    }

    func testTheWebNamesTheSiteNotTheAddress() {
        XCTAssertEqual(ToolPhrase.phrase(tool: "WebFetch",
                                         input: ["url": "https://www.apple.com/mac/?x=1"], .running),
                       "Reading apple.com")
        XCTAssertEqual(ToolPhrase.phrase(tool: "WebFetch", input: nil, .finished), "Read a web page")
    }

    func testTheRestOfClaudeCodesTools() {
        XCTAssertEqual(ToolPhrase.phrase(tool: "Task", input: ["description": "Find auth handlers"], .running),
                       "Starting a helper: Find auth handlers")
        XCTAssertEqual(ToolPhrase.phrase(tool: "Agent", input: nil, .finished), "Helper finished")
        XCTAssertEqual(ToolPhrase.phrase(tool: "TodoWrite", input: nil, .finished), "Updated the to-do list")
        XCTAssertEqual(ToolPhrase.phrase(tool: "Skill", input: ["skill": "anthropic-skills:pdf"], .running),
                       "Using the pdf skill")
        XCTAssertEqual(ToolPhrase.phrase(tool: "ToolSearch", input: nil, .running), "Looking up tools")
        XCTAssertEqual(ToolPhrase.phrase(tool: "NotebookEdit", input: ["notebook_path": "/x/a.ipynb"], .asking),
                       "Edit a.ipynb")
        XCTAssertEqual(ToolPhrase.phrase(tool: "KillShell", input: nil, .finished),
                       "Stopped a background task")
    }

    /// A built-in with no wording of its own still reads as a sentence.
    func testAnUnfamiliarBuiltIn() {
        XCTAssertEqual(ToolPhrase.phrase(tool: "EnterWorktree", input: nil, .finished), "Entered worktree")
        XCTAssertEqual(ToolPhrase.phrase(tool: "ListMcpResourcesTool", input: nil, .running),
                       "Listing MCP resources")
        XCTAssertEqual(ToolPhrase.phrase(tool: "Monitor", input: nil, .finished), "Used Monitor")
    }

    // MARK: - The rule

    /// Every tool name this very machine exposes, in every moment: none of it
    /// may reach the notch as an identifier.
    func testNoLineCarriesAnIdentifier() {
        let tools = [
            trello, browser,
            "mcp__7adb9f71-433e-414a-a8a1-f17b52e5037f__trelloReadChecklist",
            "mcp__a972bfaa-6c9e-436f-9adf-7414d7eb49e6__download_file_content",
            "mcp__57de52aa-efa2-4aeb-894d-0033aabe16d4__generate_video_batch",
            "mcp__1a59c906-04da-521d-bda7-7f71b9f9e01c__guide",
            "mcp__plugin_cloudflare_cloudflare-docs__migrate_pages_to_workers_guide",
            "mcp__ccd_session__mark_chapter", "mcp__computer-use__app_click",
            "mcp__scheduled-tasks__create_scheduled_task", "mcp__weird",
            "Read", "Write", "Bash", "Glob", "Grep", "WebFetch", "WebSearch", "Task", "Agent",
            "TodoWrite", "NotebookEdit", "Skill", "ToolSearch", "SomethingNew",
        ]
        let uuid = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-"#
        for tool in tools {
            for moment in [ToolPhrase.Moment.asking, .running, .finished] {
                let line = ToolPhrase.phrase(tool: tool, input: nil, moment)
                XCTAssertFalse(line.contains("mcp__"), line)
                XCTAssertFalse(line.contains("__"), line)
                XCTAssertNil(line.range(of: uuid, options: .regularExpression), line)
                XCTAssertFalse(line.isEmpty, tool)
                if moment != .asking { XCTAssertFalse(line.hasSuffix("?"), line) }
            }
        }
    }

    // MARK: - Text we did not write

    func testANotificationNamingAToolIsTranslated() throws {
        XCTAssertEqual(
            ToolPhrase.humanizingToolNames(in: "Claude needs your permission to use \(trello)"),
            "Claude needs your permission to use Trello: write card")
        XCTAssertEqual(ToolPhrase.humanizingToolNames(in: "Waiting on \(browser)."),
                       "Waiting on Claude Browser: preview list.")
        XCTAssertEqual(ToolPhrase.humanizingToolNames(in: "Claude is waiting for your input"),
                       "Claude is waiting for your input")

        let events = try decode(["hook_event_name": "Notification",
                                 "message": "Claude needs your permission to use \(trello)"])
        XCTAssertEqual(activity(events), "Claude needs your permission to use Trello: write card")
    }

    // MARK: - A call that did not happen

    /// "Auto-denied · Running: rm -rf ./dist" told the user a blocked command
    /// was under way. A refusal has no tense, and asks nothing.
    func testARefusedCallIsNeverInTheRunningTense() {
        func refused(_ tool: String, _ input: [String: Any]?) -> String {
            ToolPhrase.phrase(tool: tool, input: input, .refused)
        }
        XCTAssertEqual(refused("Bash", ["command": "rm -rf ./dist"]), "rm -rf ./dist")
        XCTAssertEqual(refused("Bash", ["command": "rm -rf ./dist", "description": "Remove the dist folder"]),
                       "Remove the dist folder", "Claude's own description still wins")
        XCTAssertEqual(refused("Bash", nil), "a shell command")
        XCTAssertEqual(refused("Edit", ["file_path": "/p/main.swift"]), "Edit main.swift")
        XCTAssertEqual(refused(trello, nil), "Trello: write card", "no question, and nothing about using it")

        for tool in ["Bash", "Edit", "Read", "WebFetch", trello, browser, "SomeFutureTool"] {
            let line = refused(tool, ["command": "npm test", "file_path": "/p/a.swift", "url": "https://x.dev"])
            XCTAssertFalse(line.hasSuffix("?"), "\(tool): a refusal is not a question — \(line)")
            // "Read" is not in this list because English will not have it:
            // the instruction and the past tense are the same word, and
            // "Read notes.md" is what the card asks with.
            for tense in ["Running", "Ran ", "Using", "Used", "Reading", "Editing", "Looking"] {
                XCTAssertFalse(line.hasPrefix(tense), "\(tool): reads as something that happened — \(line)")
            }
        }
    }

    /// The decoder carries it, because the tool's input is gone by the time a
    /// rule denies the gate.
    func testTheRequestCarriesItsOwnRefusalWording() throws {
        let events = try decode(["hook_event_name": "PreToolUse", "permission_mode": "default",
                                 "tool_name": "Bash",
                                 "tool_input": ["command": "rm -rf ./dist"]])
        guard case let .permissionRequested(request)? = events.last?.kind else {
            return XCTFail("expected a gate")
        }
        XCTAssertEqual(request.activity, "Running: rm -rf ./dist")
        XCTAssertEqual(request.refusal, "rm -rf ./dist")
    }
}
