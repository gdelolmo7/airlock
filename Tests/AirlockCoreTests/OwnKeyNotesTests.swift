import XCTest
@testable import AirlockCore

/// Notes written with the person's own Anthropic key: the request, the
/// reading of every answer, when it is asked at all, the key itself, and
/// what the page says.
final class OwnKeyNotesTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func body(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - The request

    func testTheInstructionsAreACachedSystemBlockAndTheCallIsTheUserTurn() throws {
        let sent = try json(OwnKeyNotes.requestBody(instructions: "Write notes.", prompt: "S1 Hello"))
        XCTAssertEqual(sent["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(sent["max_tokens"] as? Int, OwnKeyNotes.maxTokens)
        let system = try XCTUnwrap(sent["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(system[0]["type"] as? String, "text")
        XCTAssertEqual(system[0]["text"] as? String, "Write notes.")
        XCTAssertEqual((system[0]["cache_control"] as? [String: String])?["type"], "ephemeral")
        let messages = try XCTUnwrap(sent["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "S1 Hello")
    }

    func testTheSameCallMakesTheSameBytes() {
        // Sorted keys: the cached prefix is byte for byte the same each time.
        XCTAssertEqual(OwnKeyNotes.requestBody(instructions: "A", prompt: "B"),
                       OwnKeyNotes.requestBody(instructions: "A", prompt: "B"))
    }

    func testTheKeyTravelsInItsHeaderOnly() {
        let request = OwnKeyNotes.request(key: "sk-ant-test", body: Data("{}".utf8), timeout: 30)
        XCTAssertEqual(request.url, URL(string: "https://api.anthropic.com/v1/messages"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertFalse(request.url!.absoluteString.contains("sk-ant"))
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    func testTheCheckIsTheSmallestRequest() throws {
        let sent = try json(OwnKeyNotes.checkBody())
        XCTAssertEqual(sent["max_tokens"] as? Int, 1)
        XCTAssertEqual(sent["model"] as? String, OwnKeyNotes.model)
        XCTAssertNil(sent["system"])
    }

    // MARK: - The answer

    func testATextAnswerIsTheNotes() {
        let reply = OwnKeyNotes.Reply.read(status: 200, body: body("""
            {"model":"claude-sonnet-5-5","stop_reason":"end_turn",
             "content":[{"type":"text","text":"{\\"summary\\":"},{"type":"text","text":"\\"Hi\\"}"}]}
            """))
        XCTAssertEqual(reply, .notes(text: #"{"summary":"Hi"}"#, model: "claude-sonnet-5-5", cutOff: false))
        XCTAssertEqual(reply.logName, "notes")
    }

    func testAnAnswerStoppedAtTheLimitIsMarkedCutOff() {
        let reply = OwnKeyNotes.Reply.read(status: 200, body: body("""
            {"stop_reason":"max_tokens","content":[{"type":"text","text":"{"}]}
            """))
        XCTAssertEqual(reply, .notes(text: "{", model: nil, cutOff: true))
        XCTAssertEqual(reply.logName, "notes, cut off")
    }

    func testAnEmptyOrUnreadableAnswerIsUnavailable() {
        XCTAssertEqual(OwnKeyNotes.Reply.read(status: 200, body: body(#"{"content":[]}"#)), .problem(.unavailable))
        XCTAssertEqual(OwnKeyNotes.Reply.read(status: 200, body: body("not json")), .problem(.unavailable))
        XCTAssertEqual(OwnKeyNotes.Reply.read(status: 200, body: body(
            #"{"content":[{"type":"thinking","thinking":"hmm"}]}"#)), .problem(.unavailable))
    }

    func testEveryRefusalHasItsOwnReason() {
        func problem(_ status: Int, _ type: String = "", _ message: String = "") -> OwnKeyNotes.Reply {
            .read(status: status, body: body(#"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#))
        }
        XCTAssertEqual(problem(401, "authentication_error", "invalid x-api-key"), .problem(.badKey))
        XCTAssertEqual(problem(400, "invalid_request_error",
                               "Your credit balance is too low to access the Anthropic API."), .problem(.noCredit))
        XCTAssertEqual(problem(400, "invalid_request_error", "prompt is too long: 250000 tokens > 200000 maximum"),
                       .problem(.tooLong))
        XCTAssertEqual(problem(400, "authentication_error"), .problem(.badKey))
        XCTAssertEqual(problem(400, "invalid_request_error", "something else"), .problem(.unavailable))
        XCTAssertEqual(problem(403, "permission_error"), .problem(.notAllowed))
        XCTAssertEqual(problem(404, "not_found_error", "model: claude-sonnet-5-5"), .problem(.notAllowed))
        XCTAssertEqual(problem(413, "request_too_large"), .problem(.tooLong))
        XCTAssertEqual(problem(429, "rate_limit_error"), .problem(.busy))
        XCTAssertEqual(problem(500, "api_error"), .problem(.unavailable))
        XCTAssertEqual(problem(529, "overloaded_error"), .problem(.unavailable))
        XCTAssertEqual(OwnKeyNotes.Reply.read(status: 502, body: body("<html>")), .problem(.unavailable))
        XCTAssertEqual(problem(401).logName, "badKey")
    }

    /// Every reason reads as a plain sentence, and none but "offline" leaves
    /// the reader wondering whether there are notes at all.
    func testEveryReasonHasPlainWords() {
        let all: [OwnKeyNotes.Problem] = [.badKey, .noCredit, .notAllowed, .tooLong, .busy, .unavailable,
                                          .offline, .nothingHeldUp]
        for problem in all {
            XCTAssertTrue(problem.line.hasSuffix("."), "\(problem)")
            XCTAssertFalse(problem.checkLine.isEmpty)
            XCTAssertFalse(problem.line.contains("API"), "\(problem): no jargon on the page")
            if problem != .offline { XCTAssertTrue(problem.line.contains("written the usual way"), "\(problem)") }
        }
        XCTAssertTrue(OwnKeyNotes.Problem.badKey.line.contains("Settings › Meeting notes"))
    }

    // MARK: - Deciding

    func testItIsAskedOnlyWithAKeyEnoughWordsAndAPromptThatFits() {
        let enough = MeetingNotes.minimumWords
        XCTAssertEqual(OwnKeyNotes.decide(hasKey: false, words: 500, promptSize: 100), .skip(.noKey))
        XCTAssertEqual(OwnKeyNotes.decide(hasKey: true, words: enough - 1, promptSize: 100), .skip(.tooShort))
        XCTAssertEqual(OwnKeyNotes.decide(hasKey: true, words: enough, promptSize: 100), .ask)
        XCTAssertEqual(OwnKeyNotes.decide(hasKey: true, words: 500, promptSize: OwnKeyNotes.promptLimit), .ask)
        XCTAssertEqual(OwnKeyNotes.decide(hasKey: true, words: 500, promptSize: OwnKeyNotes.promptLimit + 1),
                       .skip(.tooLong))
    }

    // MARK: - The model

    func testSonnetUnlessAnotherWasPicked() {
        XCTAssertEqual(OwnKeyNotes.Choice.saved(nil), .sonnet)
        XCTAssertEqual(OwnKeyNotes.Choice.saved("somethingNew"), .sonnet, "an unknown pick reads as Sonnet")
        XCTAssertEqual(OwnKeyNotes.Choice.saved("opus"), .opus)
        XCTAssertEqual(OwnKeyNotes.Choice.saved("haiku"), .haiku)
        XCTAssertEqual(OwnKeyNotes.model, "claude-sonnet-5-5")
    }

    func testEachPickAsksForItsModel() throws {
        let ids = ["sonnet": "claude-sonnet-5-5", "opus": "claude-opus-5-5", "haiku": "claude-haiku-5-5"]
        let names = ["sonnet": "Claude Sonnet", "opus": "Claude Opus", "haiku": "Claude Haiku"]
        XCTAssertEqual(OwnKeyNotes.Choice.allCases.count, 3)
        for choice in OwnKeyNotes.Choice.allCases {
            XCTAssertEqual(choice.id, ids[choice.rawValue])
            XCTAssertEqual(choice.name, names[choice.rawValue])
            XCTAssertFalse(choice.note.isEmpty)
            let notes = try json(OwnKeyNotes.requestBody(instructions: "I", prompt: "P", model: choice.id))
            XCTAssertEqual(notes["model"] as? String, choice.id)
            XCTAssertEqual(try json(OwnKeyNotes.checkBody(model: choice.id))["model"] as? String, choice.id)
            XCTAssertEqual(OwnKeyNotes.Choice.of(model: choice.id), choice)
        }
        XCTAssertEqual(OwnKeyNotes.Choice.of(model: "claude-opus-5-5-20261101"), .opus, "a dated name Anthropic answers with")
        XCTAssertNil(OwnKeyNotes.Choice.of(model: "gemini-x"))
        XCTAssertNil(OwnKeyNotes.Choice.of(model: nil))
    }

    func testTheFooterNamesTheModelThatWroteThem() {
        XCTAssertEqual(OwnKeyNotes.footer(model: "claude-opus-5-5"),
                       "Written by Claude Opus, with your own Anthropic key")
        XCTAssertEqual(OwnKeyNotes.footer(model: "claude-haiku-5-5"),
                       "Written by Claude Haiku, with your own Anthropic key")
        XCTAssertEqual(OwnKeyNotes.footer(model: "claude-sonnet-5-5"),
                       "Written by Claude Sonnet, with your own Anthropic key")
        XCTAssertEqual(OwnKeyNotes.footer(model: "claude-something-else"),
                       "Written by Claude, with your own Anthropic key")
    }

    // MARK: - The key

    private let key = "sk-ant-api03-" + String(repeating: "Ab3_", count: 20) + "wxyz"

    func testAPastedKeyIsCheckedForShapeOnly() {
        XCTAssertTrue(OwnKeyNotes.looksLikeKey(key))
        XCTAssertTrue(OwnKeyNotes.looksLikeKey("  \(key)\n"), "spaces and a line break around it are fine")
        XCTAssertFalse(OwnKeyNotes.looksLikeKey("sk-proj-" + String(repeating: "a", count: 60)), "an OpenAI key")
        XCTAssertFalse(OwnKeyNotes.looksLikeKey("sk-ant-short"))
        XCTAssertFalse(OwnKeyNotes.looksLikeKey("sk-ant-" + String(repeating: "a", count: 300)))
        XCTAssertFalse(OwnKeyNotes.looksLikeKey("sk-ant-api03-" + String(repeating: "a", count: 40) + " b"))
        XCTAssertFalse(OwnKeyNotes.looksLikeKey(""))
    }

    func testTheKeyIsShownByItsStartAndLastFourOnly() {
        XCTAssertEqual(OwnKeyNotes.masked(key), "sk-ant-…wxyz")
        XCTAssertEqual(OwnKeyNotes.masked("abcdefghijklmnop"), "abcd…mnop")
        XCTAssertEqual(OwnKeyNotes.masked("short"), "••••")
        XCTAssertFalse(OwnKeyNotes.masked(key).contains("Ab3_"))
    }

    // MARK: - Kept with the notes

    private let date = Date(timeIntervalSince1970: 1_791_468_600)

    func testTheWriterKeepsTheOwnKeyAndSaysNothingWhenItWasNotUsed() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let own = MeetingNotesWriter.ownKey(model: nil, at: date, plan: .free)
        XCTAssertEqual(own.place, .online)
        XCTAssertEqual(own.model, OwnKeyNotes.model)
        XCTAssertTrue(own.ownKey)
        XCTAssertEqual(try decoder.decode(MeetingNotesWriter.self, from: encoder.encode(own)), own)

        var failed = MeetingNotesWriter.mac(at: date, why: .plan)
        failed.ownKeyProblem = .noCredit
        XCTAssertEqual(try decoder.decode(MeetingNotesWriter.self, from: encoder.encode(failed)), failed)

        let plain = try json(encoder.encode(MeetingNotesWriter.mac(at: date)))
        XCTAssertNil(plain["ownKey"], "files that never used a key stay as they were")
        XCTAssertNil(plain["ownKeyProblem"])

        let future = #"{"place":"mac","writtenAt":"2026-10-14T10:00:00Z","ownKeyProblem":"somethingNew"}"#
        let read = try decoder.decode(MeetingNotesWriter.self, from: Data(future.utf8))
        XCTAssertNil(read.ownKeyProblem, "a reason this build doesn't know reads as none")
        XCTAssertFalse(read.ownKey)
    }

    // MARK: - The page

    private func record() -> MeetingRecord {
        MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: date,
                      endedAt: date.addingTimeInterval(90),
                      segments: [MeetingSegment(speaker: .them, start: 5, end: 12,
                                                text: "Then we launch on the twentieth.")])
    }

    private func page(_ writer: MeetingNotesWriter?) -> String {
        MeetingFiles.notesPage(for: record(), notes: MeetingNotes(summary: "A call to plan the launch."),
                               writer: writer, timeZone: TimeZone(identifier: "UTC")!)
    }

    func testNotesFromTheOwnKeySaySoAtTheFoot() {
        let text = page(.ownKey(model: nil, at: date))
        XCTAssertTrue(text.contains("_Written by Claude Sonnet, with your own Anthropic key. No audio was kept."))
        XCTAssertFalse(text.contains("Written online by Airlock"))
        XCTAssertFalse(text.contains("written the usual way"))
        XCTAssertTrue(page(.ownKey(model: "claude-opus-5-5", at: date))
            .contains("_Written by Claude Opus, with your own Anthropic key. No audio was kept."))
    }

    func testAKeyThatDidNotWorkIsSaidUnderTheDate() {
        var writer = MeetingNotesWriter.mac(at: date, why: .plan)
        writer.ownKeyProblem = .badKey
        let text = page(writer)
        XCTAssertTrue(text.contains("_\(OwnKeyNotes.Problem.badKey.line)_"))
        XCTAssertTrue(text.contains("_Written on your Mac. No audio was kept."))

        var online = MeetingNotesWriter.online(model: "gemini-x", at: date)
        online.ownKeyProblem = .noCredit
        XCTAssertTrue(page(online).contains(OwnKeyNotes.Problem.noCredit.line))

        XCTAssertFalse(page(.mac(at: date)).contains("Claude"), "no key, nothing said")
    }

    func testOfflineIsNotSaidTwice() {
        var waiting = MeetingNotesWriter.mac(at: date, waitsForOnline: true)
        waiting.ownKeyProblem = .offline
        XCTAssertFalse(page(waiting).contains(OwnKeyNotes.Problem.offline.line),
                       "the waiting line already says the Mac was offline")
        var notWaiting = MeetingNotesWriter.mac(at: date, why: .plan)
        notWaiting.ownKeyProblem = .offline
        XCTAssertTrue(page(notWaiting).contains(OwnKeyNotes.Problem.offline.line))
    }

    // MARK: - Shown in the app's language

    /// Every line the key leaves on a notes page is one the window knows,
    /// so a Spanish Mac draws it in Spanish. A line it doesn't know would
    /// stay English there.
    func testTheWindowKnowsEveryKeyLine() {
        for problem in OwnKeyNotes.Problem.allCases {
            XCTAssertEqual(MeetingNotesShown.shown(problem.line), problem.line, "\(problem)")
        }
        for model in OwnKeyNotes.Choice.allCases.map(\.id) + ["claude-something-else"] {
            let footer = OwnKeyNotes.footer(model: model) + ". " + MeetingNotesShown.footerTail
            XCTAssertEqual(MeetingNotesShown.shown(footer), footer, model)
        }
    }
}
