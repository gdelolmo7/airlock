import XCTest
@testable import AirlockCore

/// Claude's PermissionRequest hook: Claude about to ask in its own window.
///
/// When it becomes a card — only where PreToolUse let the call through, so no
/// call is asked about twice — what Airlock answers it with, its own schema
/// rather than PreToolUse's, and the trip over a real socket.
final class PermissionRequestTests: XCTestCase {
    private let integration = ClaudeCodeIntegration()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func decode(_ event: String = "PermissionRequest", mode: String?, tool: String = "Bash",
                        input: String = #"{"command":"npm publish"}"#) throws -> [AgentEvent] {
        let modeField = mode.map { #""permission_mode":"\#($0)","# } ?? ""
        let json = #"{"session_id":"s1","hook_event_name":"\#(event)",\#(modeField)"tool_name":"\#(tool)","tool_input":\#(input)}"#
        return try integration.decodeEvents(from: Data(json.utf8), context: HookContext(
            source: "claude-code", cwd: nil, terminal: nil, receivedAt: now))
    }

    private func cards(_ events: [AgentEvent]) -> [PermissionRequest] {
        events.compactMap { if case let .permissionRequested(request) = $0.kind { return request }; return nil }
    }

    // MARK: - When it is a card

    /// The reported bug. In these modes PreToolUse only watches, so when Claude
    /// asked in its own window the notch stayed shut.
    func testAsksInTheModesPreToolUseLetsThrough() throws {
        for mode in ["auto", "plan", "dontAsk", "bypassPermissions"] {
            let events = try decode(mode: mode)
            XCTAssertEqual(events.count, 1, mode)
            guard let card = cards(events).first else {
                return XCTFail("\(mode): Claude is asking, so the notch asks — got \(events)")
            }
            XCTAssertEqual(card.toolName, "Bash")
            XCTAssertEqual(card.command, "npm publish")
        }
    }

    /// The notch asked at PreToolUse already. Claude asking now means that card
    /// was handed back, or one of Claude's own rules asks anyway — and its
    /// dialog is on screen to answer. A missing or unknown mode gated there, so
    /// it passes here.
    func testPassesThroughWhereTheNotchAlreadyAsked() throws {
        for mode in ["default", "acceptEdits", nil, "someModeNotYetInvented"] {
            XCTAssertTrue(try decode(mode: mode).isEmpty, "\(mode ?? "no mode") was asked at PreToolUse")
        }
    }

    /// Whatever the mode, exactly one of the two events puts a call on a card.
    func testOneCardPerCallInEveryMode() throws {
        let question = #"{"questions":[{"question":"Which one?","header":"Pick","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}"#
        for mode in ["default", "acceptEdits", "auto", "plan", "dontAsk", "bypassPermissions", nil, "someModeNotYetInvented"] {
            for (tool, input) in [("Bash", #"{"command":"npm publish"}"#), ("AskUserQuestion", question)] {
                let both = try decode("PreToolUse", mode: mode, tool: tool, input: input)
                    + decode(mode: mode, tool: tool, input: input)
                XCTAssertEqual(cards(both).count, 1, "\(tool) in \(mode ?? "no mode")")
            }
        }
    }

    /// A question is a card at PreToolUse in every mode and answered from there.
    /// Claude's own picker coming up means that card was handed back.
    func testQuestionIsNeverAskedTwice() throws {
        let question = #"{"questions":[{"question":"Which one?","header":"Pick","options":[{"label":"A"}],"multiSelect":false}]}"#
        for mode in ["auto", "bypassPermissions", "default"] {
            XCTAssertTrue(try decode(mode: mode, tool: "AskUserQuestion", input: question).isEmpty, mode)
        }
    }

    /// Approving a plan also picks how Claude goes on, which only Claude's
    /// dialog offers. The row says where to look; nothing waits on the notch —
    /// from either event, in any mode.
    func testPlanReviewStaysInClaude() throws {
        let plan = #"{"plan":"Refactor auth\n1. Extract the session store","planFilePath":"/tmp/plan.md"}"#
        for mode in ["plan", "default"] {
            let events = try decode(mode: mode, tool: "ExitPlanMode", input: plan)
            XCTAssertEqual(events.map(\.kind), [.activity(summary: "Plan ready for review in Claude")], mode)
        }
        for mode in ["plan", "default", "acceptEdits", "auto", nil] {
            let both = try decode("PreToolUse", mode: mode, tool: "ExitPlanMode", input: plan)
                + decode(mode: mode, tool: "ExitPlanMode", input: plan)
            XCTAssertTrue(cards(both).isEmpty, "\(mode ?? "no mode"): never a card")
        }
    }

    /// The event has no `tool_use_id`, and two identical prompts in the same
    /// millisecond must still be two gates.
    func testIdsStayUniqueWithoutACallID() throws {
        let a = try XCTUnwrap(cards(try decode(mode: "auto")).first)
        let b = try XCTUnwrap(cards(try decode(mode: "auto")).first)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(a.id.hasPrefix("Bash-1700000000000-"), a.id)
    }

    /// Airlock does not gate Codex and registers no such event for it; its
    /// reading of one is what it always was.
    func testCodexReadingIsUnchanged() throws {
        let json = #"{"session_id":"c1","hook_event_name":"PermissionRequest","permission_mode":"auto","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        let events = try CodexIntegration().decodeEvents(from: Data(json.utf8), context: HookContext(
            source: "codex", cwd: nil, terminal: nil, receivedAt: now))
        XCTAssertTrue(cards(events).isEmpty)
    }

    // MARK: - What Claude is told

    private func output(_ directive: HookDirective) -> String? {
        integration.directiveOutput(for: directive, eventName: "PermissionRequest")
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// The example in Claude Code's hooks docs, less the `updatedInput` Airlock
    /// never sends.
    private let documentedAllow = #"""
        {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
        """#

    func testAllowIsTheDocumentedDecision() throws {
        let bytes = try XCTUnwrap(output(.from(.allowOnce)))
        XCTAssertEqual(bytes, #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)

        // The same object as the docs' — sorted keys are the only difference.
        let ours = try JSONSerialization.jsonObject(with: Data(bytes.utf8)) as? NSDictionary
        let docs = try JSONSerialization.jsonObject(with: Data(documentedAllow.utf8)) as? NSDictionary
        XCTAssertNotNil(docs)
        XCTAssertEqual(ours, docs)
    }

    /// "Always" writes its rule on Airlock's side; Claude hears a plain allow.
    /// So does a rule's approval: this event's allow has no reason to carry.
    func testEveryAllowIsTheSameAllow() {
        let plain = output(.from(.allowOnce))
        XCTAssertEqual(output(.from(.alwaysAllow)), plain)
        XCTAssertEqual(output(.approved(byRule: "Bash(npm *)")), plain)
    }

    func testDenyFromTheCardSaysAirlock() {
        XCTAssertEqual(output(.from(.deny)),
                       #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied from Airlock"},"hookEventName":"PermissionRequest"}}"#)
    }

    func testDenyByRuleNamesTheRule() {
        XCTAssertEqual(output(.denied(byRule: "Bash(rm -rf*)")),
                       #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied by Airlock policy rule Bash(rm -rf*). The user's policy file is .airlock/policy.yaml."},"hookEventName":"PermissionRequest"}}"#)
    }

    /// Dismissed, timed out, the app gone: no decision, which this event's
    /// docs call leaving the flow unchanged — Claude's own dialog asks.
    func testHandedBackWritesNothing() {
        XCTAssertNil(output(.from(.deferred)))
        XCTAssertNil(output(HookDirective(action: .ask)), "there is no ask here — Claude is already asking")
    }

    // MARK: - Over the socket

    private static let allowBytes =
        #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#

    /// What the hook prints for a reply — `main.swift` does exactly this.
    private func printed(_ reply: HookDirective?) -> String? {
        reply.flatMap { integration.directiveOutput(for: $0, eventName: "PermissionRequest") }
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private func prompt(session: String = "p", command: String = "npm publish",
                        mode: String = "plan") -> HookPayload {
        GateSocket.payload(session: session, tool: "Bash", input: #"{"command":"\#(command)"}"#,
                           event: "PermissionRequest", mode: mode)
    }

    /// The bug as reported, end to end: a plan-mode session asks in Claude's
    /// window, a card opens and the session needs you, Approve reaches the
    /// waiting hook, and what it prints is the documented decision.
    func testPlanModePromptOpensACardThatApproveAnswers() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let hook = GateSocket.hook(prompt(), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let requests = await recorder.requests()
        let card = try XCTUnwrap(requests.first)
        let session = GateSocket.replay(await recorder.all).sessions["p"]
        XCTAssertEqual(session?.status, .needsAttention, "Needs you")
        XCTAssertEqual(session?.pendingPermission?.id, card.id)

        await rig.bridge.resolve(sessionID: "p", requestID: card.id, decision: .allowOnce)
        let reply = await hook.value
        XCTAssertEqual(printed(reply), Self.allowBytes)

        await rig.bridge.stop()
        drain.cancel()
    }

    /// Dismissed: no decision, so Claude's own dialog takes the question.
    func testDismissedPromptPrintsNothing() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let hook = GateSocket.hook(prompt(mode: "auto"), path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let requests = await recorder.requests()
        let card = try XCTUnwrap(requests.first)

        await rig.bridge.resolve(sessionID: "p", requestID: card.id, decision: .deferred)
        let reply = await hook.value
        XCTAssertEqual(reply?.action, .deferToAgent)
        XCTAssertNil(printed(reply))

        await rig.bridge.stop()
        drain.cancel()
    }

    /// Where the notch already asked, the hook is let go at once: no card,
    /// nothing printed, and Claude's dialog asks.
    func testPromptTheNotchAlreadyAskedIsLetGoAtOnce() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let started = Date()
        let reply = await GateSocket.hook(prompt(mode: "default"), path: rig.path).value
        XCTAssertNil(reply, "acknowledged, not answered")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "and not held")
        let requests = await recorder.requests()
        XCTAssertTrue(requests.isEmpty)

        await rig.bridge.stop()
        drain.cancel()
    }

    /// The same policy as every other gate, in its fixed order: a deny rule
    /// answers first and names itself, an allow rule answers, and the risk
    /// floor still puts a covered command in front of a person.
    func testPolicyAnswersBeforeAnyoneIsAsked() async throws {
        let rig = try GateSocket.rig(policyYAML: """
            allow:
              - Bash(npm test*)
              - Bash(git *)
            deny:
              - Bash(npm publish*)
            """)
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)

        let denied = await GateSocket.hook(prompt(session: "d", mode: "auto"), path: rig.path).value
        XCTAssertEqual(printed(denied), #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied by Airlock policy rule Bash(npm publish*). The user's policy file is .airlock/policy.yaml."},"hookEventName":"PermissionRequest"}}"#)

        let allowed = await GateSocket.hook(prompt(session: "a", command: "npm test", mode: "auto"),
                                            path: rig.path).value
        XCTAssertEqual(printed(allowed), Self.allowBytes)

        let risky = GateSocket.hook(prompt(session: "r", command: "git reset --hard HEAD~1", mode: "auto"),
                                    path: rig.path)
        await GateSocket.waitFor { await recorder.requests().count == 1 }
        let requests = await recorder.requests()
        XCTAssertEqual(requests.map(\.command), ["git reset --hard HEAD~1"], "only the risky one reached a card")

        await rig.bridge.stop()
        let handedBack = await risky.value
        XCTAssertNil(printed(handedBack))
        drain.cancel()
    }

    /// Two prompts at once — same tool, same millisecond, no call id — are
    /// two gates in the session's queue, one card at a time, and "Always" on
    /// the first settles the second as its rule would have on arrival.
    func testParallelPromptsQueueAndAlwaysSettlesTheRest() async throws {
        let rig = try GateSocket.rig()
        try await rig.bridge.start()
        let (recorder, drain) = GateSocket.record(rig.bridge)
        let cwd = rig.project.path
        let at = Date()

        func held(_ command: String) async -> Task<HookDirective?, Never> {
            let count = await recorder.requests().count
            let hook = GateSocket.hook(GateSocket.payload(
                session: "p", tool: "Bash", input: #"{"command":"\#(command)"}"#, at: at, cwd: cwd,
                event: "PermissionRequest", mode: "plan"), path: rig.path)
            await GateSocket.waitFor { await recorder.requests().count == count + 1 }
            return hook
        }
        let test = await held("npm test")
        let lint = await held("npm run lint")
        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests.first?.id, requests.last?.id)

        let waiting = GateSocket.replay(await recorder.all).sessions["p"]
        XCTAssertEqual(waiting?.status, .needsAttention)
        XCTAssertEqual(waiting?.pendingPermission?.id, requests.first?.id)
        XCTAssertEqual(waiting?.queuedPermissions?.map(\.id), requests.last.map { [$0.id] })

        // What the app does on "Always": write the rule, then tell the bridge.
        try PolicyStore(globalFileURL: rig.globalPolicy).appendAllowRule("Bash(npm *)", projectRoot: cwd)
        await rig.bridge.resolve(sessionID: "p", requestID: try XCTUnwrap(requests.first).id,
                                 decision: .alwaysAllow)

        let testReply = await test.value
        let lintReply = await lint.value
        XCTAssertEqual(printed(testReply), Self.allowBytes)
        XCTAssertEqual(printed(lintReply), Self.allowBytes, "settled by the rule, not handed back")

        await rig.bridge.stop()
        drain.cancel()
    }

    // MARK: - The hook binary itself

    /// The built `airlock-hook`, not a stand-in for it: exactly what Claude
    /// reads on its stdout, and its exit status. Skipped when the binary was
    /// not built beside the tests.
    ///
    /// The hook finds the app's socket under its home directory, so it runs
    /// with one of its own (`CFFIXED_USER_HOME`). That is checked before any
    /// request is sent, with a source no app acts on: a hook that went to the
    /// running Airlock instead would put a test's card in somebody's notch.
    func testHookBinaryPrintsTheDecisionAndNothingWhenDismissed() async throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("airlock-hook")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("airlock-hook is not built beside the tests")
        }
        // Short: a socket path has to fit in 104 bytes.
        let home = URL(fileURLWithPath: "/tmp/anh-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let socket = home.appendingPathComponent("Library/Application Support/Airlock/bridge.sock").path

        let probe = UnixSocketServer(path: socket)
        try probe.start()
        let heard = Task { () -> Bool in
            for await event in probe.events {
                if case let .envelope(.hookPayload(payload), _) = event, payload.source == "airlock-probe" {
                    return true
                }
            }
            return false
        }
        let probed = try await Self.runHook(binary, home: home, source: "airlock-probe",
                                            event: "Probe", stdin: "{}").value
        let giveUp = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { probe.stop() }
        }
        let redirected = await heard.value
        giveUp.cancel()
        probe.stop()
        XCTAssertEqual(probed.status, 0)
        guard redirected else {
            return XCTFail("the hook did not use the test's home, so it would reach a running Airlock")
        }

        let bridge = BridgeServer(registry: .shared, path: socket, policy: PolicyEngine(
            store: PolicyStore(globalFileURL: home.appendingPathComponent("policy.yaml"))))
        try await bridge.start()
        addTeardownBlock { await bridge.stop() }
        let (recorder, drain) = GateSocket.record(bridge)
        let request = #"{"session_id":"bin","hook_event_name":"PermissionRequest","cwd":"\#(home.path)","permission_mode":"plan","tool_name":"Bash","tool_input":{"command":"npm publish"}}"#

        for (decision, expected) in [(PermissionDecision.allowOnce, Self.allowBytes), (.deferred, "")] {
            let answered = await recorder.requests().count
            let run = Self.runHook(binary, home: home, source: "claude-code",
                                   event: "PermissionRequest", stdin: request)
            await GateSocket.waitFor { await recorder.requests().count == answered + 1 }
            let requests = await recorder.requests()
            let card = try XCTUnwrap(requests.dropFirst(answered).first, "\(decision): no card")
            await bridge.resolve(sessionID: "bin", requestID: card.id, decision: decision)
            let result = try await run.value
            XCTAssertEqual(result.status, 0, "\(decision)")
            XCTAssertEqual(result.stdout, expected, "\(decision)")
        }
        drain.cancel()
    }

    /// Runs the hook the way Claude does: arguments, JSON on stdin, and
    /// whatever it prints collected once it exits.
    private static func runHook(_ binary: URL, home: URL, source: String, event: String,
                                stdin: String) -> Task<(status: Int32, stdout: String), Error> {
        Task.detached {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--source", source, "--event", event]
            process.currentDirectoryURL = home
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = home.path
            environment["PWD"] = home.path
            process.environment = environment
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: printed, as: UTF8.self))
        }
    }
}
