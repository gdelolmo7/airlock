import AirlockTestSupport
import XCTest
@testable import AirlockCore

/// An ask with several questions is answered whole.
///
/// `AskUserQuestion` carries one to four questions and is answered once. The
/// notch surfaced the first and dropped the rest, so the agent heard back about
/// question one and nothing about the others. These pin the parse, the walk
/// through them, and the one reply they become — and that a single question
/// still gets exactly the reply it always got.
final class MultiQuestionTests: XCTestCase {
    private let scratch = TestScratch("an-mq")
    private let input: [String: Any] = [
        "questions": [
            ["question": "Which auth method should the API use?", "header": "Auth method",
             "multiSelect": false,
             "options": [["label": "OAuth", "description": "Delegated login; no passwords stored"],
                         ["label": "API keys"]]],
            ["question": "Which databases should it support?", "header": "Database",
             "multiSelect": true,
             "options": [["label": "Postgres"], ["label": "SQLite"]]],
        ],
    ]

    private var questions: [QuestionPrompt] { QuestionPrompt.parseAll(toolInput: input) }

    // MARK: - Parsing

    override func tearDownWithError() throws { scratch.remove() }

    func testEveryQuestionIsParsedInOrder() {
        XCTAssertEqual(questions.map(\.header), ["Auth method", "Database"])
        XCTAssertEqual(questions.map(\.multiSelect), [false, true])
        XCTAssertEqual(questions.first?.options.first?.detail, "Delegated login; no passwords stored")
        XCTAssertEqual(QuestionPrompt.parse(toolInput: input)?.header, "Auth method",
                       "the first is still the first")
        XCTAssertEqual(QuestionPrompt.parseAll(toolInput: ["questions": "nope"]), [])
    }

    /// Nothing to pick is still a question: it is kept, answered in words,
    /// rather than dropped — which left a command's Approve / Deny / Always
    /// under "Claude has a question" (card A27).
    func testAQuestionWithNothingToPickIsKeptToAnswerInWords() throws {
        let parsed = QuestionPrompt.parseAll(toolInput: ["questions": [
            ["question": "What should the new plan be called?", "options": [] as [Any], "multiSelect": true],
            ["question": "Anything else?", "header": "Notes"],
            ["question": "   ", "options": [["label": "A"]]],
        ]])
        XCTAssertEqual(parsed.map(\.question), ["What should the new plan be called?", "Anything else?"],
                       "a blank question is still nothing to ask")
        XCTAssertEqual(parsed.map(\.options.count), [0, 0])
        XCTAssertEqual(parsed.map(\.multiSelect), [false, false], "nothing to tick is not \"pick any\"")

        var walk = QuestionWalk([parsed[0]])
        XCTAssertEqual(walk.answer("Team plan"), .finished(reply: "Team plan"))

        let payload = try JSONSerialization.data(withJSONObject: [
            "session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "What should the new plan be called?", "options": [] as [Any]]]],
        ])
        let events = try ClaudeStyleHookDecoder.decode(
            payload: payload,
            context: HookContext(source: "claude-code", cwd: nil, terminal: nil, receivedAt: Date()),
            agent: .claudeCode, gatesPermissions: true)
        guard case let .permissionRequested(request)? = events.last?.kind else {
            return XCTFail("expected a request, got \(events)")
        }
        XCTAssertEqual(request.summary, "What should the new plan be called?")
        XCTAssertNotNil(request.question, "drawn as a question, not as a command to approve")
        XCTAssertEqual(request.waitingLine, "Waiting for your answer")
        XCTAssertFalse(request.offersAlways, "there is no rule to save for an answer")
    }

    func testTheGateCarriesThemAll() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "session_id": "s1", "hook_event_name": "PreToolUse",
            "tool_name": "AskUserQuestion", "tool_input": input,
        ])
        let events = try ClaudeStyleHookDecoder.decode(
            payload: payload,
            context: HookContext(source: "claude-code", cwd: nil, terminal: nil, receivedAt: Date()),
            agent: .claudeCode, gatesPermissions: true)
        guard case let .permissionRequested(request)? = events.last?.kind else {
            return XCTFail("expected a gate, got \(events)")
        }
        XCTAssertEqual(request.questions.count, 2)
        XCTAssertEqual(request.question?.header, "Auth method", "`question` is the first of them")
        XCTAssertEqual(request.summary, "Which auth method should the API use?")
    }

    /// Sessions are cached with their gates in them. One written before this
    /// existed has no later questions, and must still load.
    func testARequestCachedBeforeThisStillDecodes() throws {
        var request = PermissionRequest(id: "r1", toolName: "AskUserQuestion", summary: "q",
                                        createdAt: Date(timeIntervalSince1970: 1_000))
        request.questions = questions
        let roundTrip = try JSONDecoder().decode(PermissionRequest.self,
                                                 from: JSONEncoder().encode(request))
        XCTAssertEqual(roundTrip.questions, questions)

        let legacy = Data(#"""
        {"id":"r1","toolName":"AskUserQuestion","summary":"q","createdAt":0,
         "question":{"question":"Which?","options":[{"label":"A"}],"multiSelect":false}}
        """#.utf8)
        let old = try JSONDecoder().decode(PermissionRequest.self, from: legacy)
        XCTAssertEqual(old.questions.map(\.question), ["Which?"])
    }

    // MARK: - Walking

    /// One question: the bare answer, exactly what every ask used to send.
    func testASingleQuestionRepliesExactlyAsBefore() {
        var walk = QuestionWalk([questions[0]])
        XCTAssertNil(walk.position, "one question has nothing to count")
        XCTAssertEqual(walk.answer("OAuth"), .finished(reply: "OAuth"))
        XCTAssertEqual(QuestionWalk.reply(to: [questions[0]], answers: ["Use \"magic\" links"]),
                       "Use \"magic\" links", "a single typed answer is not quoted or escaped")
    }

    func testTwoQuestionsStepThenSendOnce() {
        var walk = QuestionWalk(questions)
        XCTAssertEqual(walk.position, "1 of 2")
        XCTAssertFalse(walk.canGoBack)

        XCTAssertEqual(walk.answer("OAuth"), .next, "nothing is sent until the last one")
        XCTAssertEqual(walk.position, "2 of 2")
        XCTAssertEqual(walk.current?.header, "Database")
        XCTAssertTrue(walk.isLast)

        XCTAssertEqual(walk.answer("Postgres, SQLite"),
                       .finished(reply: #""Auth method"="OAuth", "Database"="Postgres, SQLite""#))
    }

    /// Going back to fix one answer must not cost the other.
    func testGoingBackKeepsWhatWasAnswered() {
        var walk = QuestionWalk(questions)
        _ = walk.answer("API keys")
        walk.back()
        XCTAssertEqual(walk.step, 0)
        XCTAssertEqual(walk.currentAnswer, "API keys", "the earlier pick is shown, not forgotten")

        XCTAssertEqual(walk.answer("OAuth"), .next)
        XCTAssertNil(walk.currentAnswer)
        XCTAssertEqual(walk.answer("None of them"),
                       .finished(reply: #""Auth method"="OAuth", "Database"="None of them""#))

        walk.back()
        walk.back()
        walk.back()
        XCTAssertEqual(walk.step, 0, "there is nothing before the first")
    }

    /// The card's quiet line on a later question: what was already answered,
    /// so moving on visibly kept it.
    func testLaterQuestionsShowWhatWasAlreadyAnswered() {
        let three = questions + [QuestionPrompt(question: "Ship it?", options: [QuestionOption(label: "Yes")])]
        var walk = QuestionWalk(three)
        XCTAssertNil(walk.earlierAnswers, "nothing is answered on the first question")

        _ = walk.answer("OAuth")
        XCTAssertEqual(walk.earlierAnswers, "Auth method: OAuth")

        _ = walk.answer("Postgres, SQLite")
        XCTAssertEqual(walk.earlierAnswers, "Auth method: OAuth · Database: Postgres, SQLite")

        // Only what comes before the question on screen; a later answer kept
        // for when you return is not "earlier".
        walk.back()
        XCTAssertEqual(walk.earlierAnswers, "Auth method: OAuth")
        walk.back()
        XCTAssertNil(walk.earlierAnswers)
    }

    /// Labelled as the reply labels them, and one line whatever was typed.
    func testEarlierAnswersUseTheReplysLabels() {
        let a = QuestionPrompt(question: "Which region?", header: "Where", options: [QuestionOption(label: "EU")])
        let b = QuestionPrompt(question: "Which zone?", header: "Where", options: [QuestionOption(label: "1a")])
        let c = QuestionPrompt(question: "Ship it?", options: [QuestionOption(label: "Yes")])
        var walk = QuestionWalk([a, b, c])
        _ = walk.answer("EU, but\nnot Frankfurt")
        _ = walk.answer("1a")
        XCTAssertEqual(walk.earlierAnswers, "Which region?: EU, but not Frankfurt · Which zone?: 1a")
    }

    // MARK: - The row above the card

    func testTheRowSaysItIsWaitingAndHowMany() {
        var request = PermissionRequest(id: "r", toolName: "AskUserQuestion", summary: "q", createdAt: Date())
        request.questions = questions
        XCTAssertEqual(request.waitingLine, "Waiting for your answer · 2 questions")
        request.questions = [questions[0]]
        XCTAssertEqual(request.waitingLine, "Waiting for your answer")
        XCTAssertNil(PermissionRequest(id: "p", toolName: "Bash", summary: "Run", createdAt: Date()).waitingLine)
    }

    // MARK: - The reply

    /// No header, or a header two questions share: the question itself is the
    /// only label that tells them apart.
    func testLabelsFallBackToTheQuestion() {
        let a = QuestionPrompt(question: "Which region?", header: "Where", options: [QuestionOption(label: "EU")])
        let b = QuestionPrompt(question: "Which zone?", header: "Where", options: [QuestionOption(label: "1a")])
        let c = QuestionPrompt(question: "Ship it?", options: [QuestionOption(label: "Yes")])
        XCTAssertEqual(QuestionWalk.reply(to: [a, b, c], answers: ["EU", "1a", "Yes"]),
                       #""Which region?"="EU", "Which zone?"="1a", "Ship it?"="Yes""#)
    }

    /// A typed answer can hold anything; it must not end its own quote or
    /// break the line.
    func testTypedAnswersCannotBreakTheReply() {
        let reply = QuestionWalk.reply(to: questions, answers: ["Use \"magic\"\nlinks", #"C:\data"#])
        XCTAssertEqual(reply, #""Auth method"="Use \"magic\" links", "Database"="C:\\data""#)
    }

    // MARK: - Through the bridge

    /// What the agent actually reads, over a real socket: one deny, one reason,
    /// every answer in it — and a single question's reason unchanged.
    func testTheAgentReadsEveryAnswerInOneReason() async throws {
        let multi = try await deliveredReason(questionsJSON: """
            [{"question":"Which auth method?","header":"Auth method","options":[{"label":"OAuth"},{"label":"API keys"}]},\
            {"question":"Which database?","header":"Database","options":[{"label":"Postgres"},{"label":"SQLite"}]}]
            """) { request in
            var walk = QuestionWalk(request.questions)
            _ = walk.answer("OAuth")
            guard case let .finished(reply) = walk.answer("SQLite") else { return "" }
            return reply
        }
        XCTAssertEqual(multi, #"The user answered from Airlock: "Auth method"="OAuth", "Database"="SQLite""#)

        let single = try await deliveredReason(questionsJSON: """
            [{"question":"Which target?","header":"Deploy target","options":[{"label":"Production"},{"label":"Staging"}]}]
            """) { request in
            var walk = QuestionWalk(request.questions)
            guard case let .finished(reply) = walk.answer("Production") else { return "" }
            return reply
        }
        XCTAssertEqual(single, "The user answered from Airlock: Production")
    }

    private func deliveredReason(questionsJSON: String,
                                 answering: @escaping @Sendable (PermissionRequest) -> String)
        async throws -> String? {
        let path = scratch.socket()
        // Empty temp policy → deterministic `.ask`, whatever is on the host.
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
        let json = Data("""
            {"session_id":"mq-1","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion",\
            "tool_input":{"questions":\(questionsJSON)}}
            """.utf8)
        let payload = HookPayload(source: "claude-code", eventName: "PreToolUse", wantsDirective: true,
                                  cwd: nil, terminal: nil, payload: json, receivedAt: Date())
        let client = Task.detached { () -> HookDirective? in
            try? UnixSocketClient.send(path: path,
                                       envelopes: [.hello(protocolVersion: 1), .hookPayload(payload)],
                                       awaitDirective: true, timeout: 5)
        }

        guard let request = await gate.value else {
            await bridge.stop()
            XCTFail("the question never reached the app")
            return nil
        }
        await bridge.answer(sessionID: "mq-1", requestID: request.id, choice: answering(request))
        let directive = await client.value
        await bridge.stop()
        XCTAssertEqual(directive?.action, .deny, "an answer is delivered as a deny with a reason")
        return directive?.reason
    }
}
