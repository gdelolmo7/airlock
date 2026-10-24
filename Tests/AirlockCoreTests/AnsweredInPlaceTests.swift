import AirlockTestSupport
import XCTest
@testable import AirlockCore

/// A question answered from the notch reaches Claude as the user's answer.
///
/// Every answer used to go back as a deny whose reason carried it. Claude read
/// the answer, and printed "PreToolUse:AskUserQuestion hook error" in red every
/// time, so a working answer looked like a failure. Claude's hooks take the
/// answer itself now: an allow whose `updatedInput` is the question's input
/// with `answers` added. These pin that shape, that the input is passed back
/// untouched, and that every case the hook cannot fill in still gets the deny,
/// which at least delivers the answer.
final class AnsweredInPlaceTests: XCTestCase {
    private let scratch = TestScratch("an-aip")
    private let integration = ClaudeCodeIntegration()

    private let questions: [[String: Any]] = [
        ["question": "Which colour?", "header": "Colour", "multiSelect": false,
         "options": [["label": "Red", "description": "Warm"], ["label": "Blue"]]],
        ["question": "Which pets?", "header": "Pets", "multiSelect": true,
         "options": [["label": "Cats"], ["label": "Dogs"], ["label": "Fish"]]],
    ]

    private func payload(input: [String: Any]?) throws -> Data {
        var root: [String: Any] = ["session_id": "s", "hook_event_name": "PreToolUse",
                                   "tool_name": "AskUserQuestion"]
        if let input { root["tool_input"] = input }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func specific(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
    }

    // MARK: - The directive

    func testAnAnswerIsAnAllowCarryingTheAnswers() {
        let directive = HookDirective.answered(["Which colour?": "Blue"], reply: "Blue")
        XCTAssertEqual(directive.action, .allow)
        XCTAssertEqual(directive.answers, ["Which colour?": "Blue"])
        XCTAssertEqual(directive.reason, "The user answered from Airlock: Blue",
                       "the reason is the fallback, and must still say what was answered")
    }

    func testNoAnswersIsTheDenyAnAnswerAlwaysWas() {
        let directive = HookDirective.answered([:], reply: "Blue")
        XCTAssertEqual(directive.action, .deny)
        XCTAssertNil(directive.answers)
        XCTAssertEqual(directive.reason, "The user answered from Airlock: Blue")
    }

    /// The answers travel over the socket like the rest of the directive.
    func testTheAnswersSurviveTheWire() throws {
        let directive = HookDirective.answered(["Which colour?": "Blue", "Which pets?": "Cats, Dogs"],
                                               reply: "x")
        let decoded = try JSONDecoder().decode(HookDirective.self, from: JSONEncoder().encode(directive))
        XCTAssertEqual(decoded, directive)
    }

    // MARK: - The hook's output

    func testTheAnswerIsWrittenIntoTheQuestionsOwnInput() throws {
        // `extra` stands for whatever Claude adds to the input later: the input
        // is replaced whole, so anything dropped here would be lost to Claude.
        let input: [String: Any] = ["questions": questions, "extra": ["kept": true]]
        let answers = ["Which colour?": "Blue", "Which pets?": "Cats, Dogs"]
        let output = try specific(integration.directiveOutput(
            for: .answered(answers, reply: "x"), eventName: "PreToolUse", payload: payload(input: input)))

        XCTAssertEqual(output["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(output["permissionDecision"] as? String, "allow")
        XCTAssertNil(output["permissionDecisionReason"])
        let updated = try XCTUnwrap(output["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["answers"] as? [String: String], answers)
        var expected = input
        expected["answers"] = answers
        XCTAssertEqual(updated as NSDictionary, expected as NSDictionary)
    }

    func testAnInputItCannotReadGetsTheDeny() throws {
        let answered = HookDirective.answered(["Which colour?": "Blue"], reply: "Blue")
        let unreadable: [Data] = [
            Data("not json".utf8),
            Data(),
            try payload(input: nil),
            try payload(input: ["question": "not the tool's shape"]),
        ]
        for data in unreadable {
            let output = try specific(integration.directiveOutput(
                for: answered, eventName: "PreToolUse", payload: data))
            XCTAssertEqual(output["permissionDecision"] as? String, "deny",
                           "an allow without the answers would ask the question again in the terminal")
            XCTAssertEqual(output["permissionDecisionReason"] as? String, "The user answered from Airlock: Blue")
            XCTAssertNil(output["updatedInput"])
        }
    }

    func testPermissionRequestGetsTheDeny() throws {
        let output = try specific(integration.directiveOutput(
            for: .answered(["Which colour?": "Blue"], reply: "Blue"), eventName: "PermissionRequest",
            payload: payload(input: ["questions": questions])))
        let decision = try XCTUnwrap(output["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["message"] as? String, "The user answered from Airlock: Blue")
    }

    // MARK: - The walk's answers

    func testTheWalkAnswersByQuestionText() {
        let prompts = QuestionPrompt.parseAll(toolInput: ["questions": questions])
        var walk = QuestionWalk(prompts)
        XCTAssertEqual(walk.answersByQuestion, [:], "nothing until every question is answered")
        _ = walk.answer("Blue")
        XCTAssertEqual(walk.answersByQuestion, [:])
        _ = walk.answer("Cats, Dogs")
        XCTAssertEqual(walk.answersByQuestion, ["Which colour?": "Blue", "Which pets?": "Cats, Dogs"])
    }

    func testTypedAnswersGoAsTyped() {
        var walk = QuestionWalk(QuestionPrompt.parseAll(toolInput: ["questions": [questions[0]]]))
        _ = walk.answer("Purple, actually")
        XCTAssertEqual(walk.answersByQuestion, ["Which colour?": "Purple, actually"])
    }

    /// Keyed by text, two questions with the same text would become one answer.
    func testQuestionsItCannotTellApartGoAsTheReply() {
        let same = QuestionPrompt(question: "Which?", options: [QuestionOption(label: "A")])
        XCTAssertEqual(QuestionWalk.answersByQuestion([same, same], answers: ["A", "A"]), [:])
        XCTAssertEqual(QuestionWalk.answersByQuestion([same], answers: ["A", "B"]), [:])
        XCTAssertEqual(QuestionWalk.answersByQuestion([], answers: []), [:])
    }

    // MARK: - End to end

    func testTheBridgeSendsTheAnswersToTheHook() async throws {
        let path = scratch.socket()
        let policyURL = scratch.file("policy.yaml")
        let bridge = BridgeServer(registry: .shared, path: path,
                                  policy: PolicyEngine(store: PolicyStore(globalFileURL: policyURL)))
        try await bridge.start()

        let gate = Task { () -> PermissionRequest? in
            for await event in bridge.events {
                if case let .permissionRequested(request) = event.kind { return request }
            }
            return nil
        }
        let json = try payload(input: ["questions": questions])
        let hookPayload = HookPayload(source: "claude-code", eventName: "PreToolUse", wantsDirective: true,
                                      cwd: nil, terminal: nil, payload: json, receivedAt: Date())
        let client = Task.detached { () -> HookDirective? in
            try? UnixSocketClient.send(path: path,
                                       envelopes: [.hello(protocolVersion: 1), .hookPayload(hookPayload)],
                                       awaitDirective: true, timeout: 5)
        }

        guard let request = await gate.value else {
            await bridge.stop()
            return XCTFail("the question never reached the app")
        }
        var walk = QuestionWalk(request.questions)
        _ = walk.answer("Blue")
        guard case let .finished(reply) = walk.answer("Cats, Dogs") else {
            await bridge.stop()
            return XCTFail("two answers should finish a two-question walk")
        }
        await bridge.answer(sessionID: "s", requestID: request.id, choice: reply,
                            answers: walk.answersByQuestion)
        let directive = await client.value
        await bridge.stop()

        let delivered = try XCTUnwrap(directive)
        XCTAssertEqual(delivered.action, .allow)
        XCTAssertEqual(delivered.answers, ["Which colour?": "Blue", "Which pets?": "Cats, Dogs"])
        let output = try specific(integration.directiveOutput(
            for: delivered, eventName: "PreToolUse", payload: json))
        XCTAssertEqual(output["permissionDecision"] as? String, "allow")
    }
}
