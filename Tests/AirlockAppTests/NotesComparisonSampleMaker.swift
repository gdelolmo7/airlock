import Foundation
import XCTest
@testable import AirlockApp
@testable import AirlockCore

/// Opt-in, not hermetic, and the online half costs money: writes the notes
/// "What each plan writes" shows (`NotesComparisonSample`) and saves them
/// as `NotesComparisonPages`.
///
///     AIRLOCK_MAKE_NOTES_SAMPLE=1 swift test --filter NotesComparisonSampleMaker
///
/// Free: Apple's on-device model on THIS Mac, from the first 30 minutes, as
/// Free writes them. Plus and Pro: the models the licence server uses for
/// each plan, asked the way it asks them (the same instructions, prompt,
/// request and privacy settings: zero data retention, no data collection),
/// with an OpenRouter key kept in the login keychain under
/// `airlock-notes-comparison-openrouter`. The key is read into memory and
/// never printed. Each run costs a few cents, printed at the end. A plan
/// whose model can't be asked (no key, no credit) or answers with no text
/// keeps the page it has, and the run is reported skipped after the others
/// are saved.
///
/// Run it again when a plan's model changes, and read the pages before
/// committing them: they are what people are shown as each plan's notes.
@MainActor
final class NotesComparisonSampleMaker: XCTestCase {
    private static let enabled = ProcessInfo.processInfo.environment["AIRLOCK_MAKE_NOTES_SAMPLE"] == "1"

    /// The licence server's models (worker/wrangler.toml), with their price
    /// per million tokens: no route dearer than that is taken.
    private static let models: [(plan: AirlockPlan, id: String, prompt: Double, completion: Double)] = [
        (.plus, "google/gemini-3.8-flash", 0.75, 3.75),
        (.pro, "openai/gpt-6.1-sol", 2.75, 11),
    ]

    func testMakeThePages() async throws {
        try XCTSkipUnless(Self.enabled, "Writes the example notes; set AIRLOCK_MAKE_NOTES_SAMPLE=1 to run it.")
        var pages: [AirlockPlan: String] = [:]

        let free = NotesComparisonSample.freeRecord
        let outcome = await MeetingSummarizer.notes(for: free) { print("FREE \($0)") }
        guard case .notes(let freeNotes) = outcome else {
            return XCTFail("Apple's model wrote no notes on this Mac: \(outcome)")
        }
        pages[.free] = MeetingFiles.notesPage(
            for: free, notes: freeNotes,
            writer: .mac(at: Self.writtenAt(free), why: .plan, plan: .free),
            locale: Locale(identifier: "en_US"), timeZone: NotesComparisonSample.timeZone)

        let key = try? Self.key()
        let record = NotesComparisonSample.record
        let prompt = CallNotesPrompts.cloud(for: record, language: CallLanguage.check(record).decision?.name)
        var spent = 0.0
        var notAsked: [String] = []
        for model in Self.models {
            guard let key, let answer = try await Self.ask(model, prompt: prompt, key: key) else {
                print("\(model.plan.label.uppercased()) not asked: kept the page it had")
                pages[model.plan] = NotesComparisonSample.written(model.plan)
                notAsked.append(model.plan.label)
                continue
            }
            spent += answer.cost ?? 0
            print("\(model.plan.label.uppercased()) \(answer.model) via \(answer.format), "
                  + String(format: "$%.4f", answer.cost ?? 0))
            let draft = try XCTUnwrap(CloudNotes.parse(answer.text), "\(model.id): the answer didn't read as notes")
            let (notes, tally) = CloudNotes.notes(from: draft, record: record)
            print("\(model.plan.label.uppercased()) kept \(tally.kept), dropped \(tally.dropped)")
            XCTAssertFalse(notes.isEmpty, model.id)
            pages[model.plan] = MeetingFiles.notesPage(
                for: record, notes: notes,
                writer: .online(model: answer.model, at: Self.writtenAt(record),
                                 plan: PlanSnapshot(plan: model.plan, isPaid: true)),
                locale: Locale(identifier: "en_US"), timeZone: NotesComparisonSample.timeZone)
        }
        print(String(format: "SPENT $%.4f", spent))

        for plan in AirlockPlan.allCases {
            print("\n===== \(plan.label) =====\n" + (pages[plan] ?? ""))
        }
        try Self.save(pages)
        if !notAsked.isEmpty {
            throw XCTSkip("Not asked: \(notAsked.joined(separator: ", ")). "
                          + (key == nil ? "No OpenRouter key in the keychain." : "Its model refused; see above."))
        }
    }

    private static func writtenAt(_ record: MeetingRecord) -> Date {
        (record.endedAt ?? record.startedAt).addingTimeInterval(60)
    }

    // MARK: - Asking

    private struct Answer {
        let text: String
        let model: String
        let cost: Double?
        let format: String
    }

    /// The licence server's request (worker/src/openrouter.js), sent
    /// straight to OpenRouter: the strict notes shape first, then any JSON,
    /// then none, each only after the one before was refused.
    private static func ask(_ model: (plan: AirlockPlan, id: String, prompt: Double, completion: Double),
                            prompt: String, key: String) async throws -> Answer? {
        let formats: [(String, Any?)] = [
            ("json_schema", ["type": "json_schema",
                             "json_schema": ["name": "notes", "strict": true, "schema": schema]] as [String: Any]),
            ("json_object", ["type": "json_object"]),
            ("plain", nil),
        ]
        for (label, format) in formats {
            var body: [String: Any] = [
                "model": model.id,
                "temperature": 0,
                "max_tokens": 12_000,
                "messages": [
                    ["role": "system", "content": CallNotesPrompts.cloudInstructions],
                    ["role": "user", "content": prompt],
                ],
                // Nobody may keep a meeting transcript, even a made-up one:
                // the same two locks as the server.
                "provider": [
                    "zdr": true,
                    "data_collection": "deny",
                    "max_price": ["prompt": model.prompt, "completion": model.completion],
                ] as [String: Any],
                "usage": ["include": true],
            ]
            if let format { body["response_format"] = format }
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                                     timeoutInterval: 300)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Airlock", forHTTPHeaderField: "X-Title")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let session = URLSession(configuration: .ephemeral)
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let why = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
                print("\(model.id) refused \(label) with \(status) \(why.prefix(160))")
                if [401, 402, 403, 429].contains(status) { break }
                continue
            }
            let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let choice = (reply["choices"] as? [[String: Any]])?.first
            let usage = reply["usage"] as? [String: Any]
            let cost = usage?["cost"] as? Double
            guard let text = (choice?["message"] as? [String: Any])?["content"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Paid for and empty, as the server would get it: say why it
                // stopped, never what it said.
                let reasoning = (usage?["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"]
                print("\(model.id) answered with no text via \(label): "
                      + "finish \(choice?["finish_reason"] ?? "?"), "
                      + "native finish \(choice?["native_finish_reason"] ?? "?"), "
                      + "answer tokens \(usage?["completion_tokens"] ?? "?"), reasoning tokens \(reasoning ?? "?"), "
                      + String(format: "$%.4f", cost ?? 0))
                return nil
            }
            return Answer(text: text, model: reply["model"] as? String ?? model.id, cost: cost, format: label)
        }
        return nil
    }

    /// The shape the app parses (NOTES_SCHEMA on the server).
    private static var schema: [String: Any] {
        func sourced(_ fields: [String: Any]) -> [String: Any] {
            var properties = fields
            properties["sources"] = ["type": "array", "items": ["type": "string"]]
            return ["type": "object", "additionalProperties": false,
                    "required": Array(fields.keys).sorted() + ["sources"], "properties": properties]
        }
        let text: [String: Any] = ["text": ["type": "string"]]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["summary", "title", "decisions", "todos", "questions", "keyPoints"],
            "properties": [
                "summary": ["type": "string"],
                "title": ["type": "string"],
                "decisions": ["type": "array", "items": sourced(text)],
                "todos": ["type": "array", "items": sourced(["task": ["type": "string"],
                                                             "owner": ["type": "string"],
                                                             "due": ["type": "string"]])],
                "questions": ["type": "array", "items": sourced(text)],
                "keyPoints": ["type": "array", "items": sourced(text)],
            ] as [String: Any],
        ]
    }

    /// The key, from the login keychain, into memory only.
    private static func key() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "airlock-notes-comparison-openrouter",
                             "-a", NSUserName(), "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !key.isEmpty else {
            throw CocoaError(.userCancelled)
        }
        return key
    }

    // MARK: - Saving

    private static func save(_ pages: [AirlockPlan: String]) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Sources/AirlockCore/Meetings/NotesComparisonPages.swift")
        var source = """
        // The notes each plan wrote of `NotesComparisonSample`'s call, as written.
        // Made by NotesComparisonSampleMaker; run it again rather than editing these.

        enum NotesComparisonPages {

        """
        for plan in AirlockPlan.allCases {
            let page = try XCTUnwrap(pages[plan])
            XCTAssertFalse(page.contains("\"\"\"#"), "the page can't sit in a raw string")
            let indented = page.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? "" : "        " + $0 }.joined(separator: "\n")
            source += "    static let \(plan.rawValue) = #\"\"\"\n\(indented)\n        \"\"\"#\n"
            if plan != AirlockPlan.allCases.last { source += "\n" }
        }
        source += "}\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        print("SAVED \(file.path)")
    }
}
