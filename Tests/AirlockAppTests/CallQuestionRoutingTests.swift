import XCTest
import AirlockCore
@testable import AirlockApp

/// What the notch does with a question about past calls.
///
/// The model is reported absent throughout, so nothing here waits on Apple
/// Intelligence or depends on whether this Mac has it: what is tested is
/// which path a question takes, and what is said when there is nothing to
/// answer from, which never asks the model.
@MainActor
final class CallQuestionRoutingTests: XCTestCase {
    /// Calls kept in a dictionary, as the folders would give them.
    private struct Folders: CallFolders {
        var calls: [String: MeetingRecord] = [:]
        func stamps() -> [String: Date] { calls.mapValues { _ in Date(timeIntervalSince1970: 1_000) } }
        func record(in folder: String) -> MeetingRecord? { calls[folder] }
    }

    private func call(_ lines: [String], with people: [String]) -> MeetingRecord {
        let start = Date().addingTimeInterval(-2 * 86_400)
        let segments = lines.enumerated().map { index, line in
            MeetingSegment(speaker: .them, start: Double(index) * 10, end: Double(index) * 10 + 9, text: line)
        }
        return MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                             endedAt: start.addingTimeInterval(1800), segments: segments,
                             event: MeetingEvent(title: "Weekly sync", start: start, attendees: people))
    }

    private func model(notesOn: Bool, calls: [String: MeetingRecord] = [:]) -> AssistantModel {
        let assistant = AssistantModel()
        assistant.previewAvailability = .deviceNotEligible
        assistant.callNotesEnabled = { notesOn }
        let folders = Folders(calls: calls)
        assistant.callFolders = { folders }
        return assistant
    }

    /// The search runs off the main actor; this waits for it to land.
    private func settled(_ assistant: AssistantModel) async {
        for _ in 0..<300 where assistant.isStreaming {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(assistant.isStreaming, "the question never settled")
    }

    private var budgetCall: [String: MeetingRecord] {
        ["2026-10-06 10.00 – Weekly sync": call(["The budget is forty thousand for the launch."],
                                                with: ["Marta Gil"])]
    }

    // MARK: - Call notes off

    /// Off, a question about a call is like any other question: nothing is
    /// searched and the usual answer path runs.
    func testWithCallNotesOffNothingChanges() async {
        let assistant = model(notesOn: false, calls: budgetCall)
        assistant.ask("What did we agree on the call yesterday?")
        await settled(assistant)
        XCTAssertFalse(assistant.answersFromCalls)
        XCTAssertEqual(assistant.failure, ModelAvailability.deviceNotEligible.message(feature: "answering"))
        XCTAssertTrue(assistant.callSources.isEmpty)
    }

    // MARK: - Nothing to answer from

    func testWithNoCallsItSaysSoWithoutTheModel() async {
        let assistant = model(notesOn: true)
        assistant.ask("What did we agree on the call yesterday?")
        XCTAssertTrue(assistant.answersFromCalls)
        await settled(assistant)
        XCTAssertEqual(assistant.answer, "There are no saved calls to look in yet.")
        XCTAssertNil(assistant.failure)
        XCTAssertTrue(assistant.callSources.isEmpty)
    }

    func testNothingFoundIsSaidPlainly() async {
        let assistant = model(notesOn: true, calls: budgetCall)
        assistant.ask("What did we decide about the hiring plan on the call?")
        await settled(assistant)
        XCTAssertTrue(assistant.answersFromCalls)
        XCTAssertEqual(assistant.answer, "I couldn't find that in your calls.")
        XCTAssertNil(assistant.failure)
    }

    func testNothingFoundIsSaidInSpanishToASpanishQuestion() async {
        let assistant = model(notesOn: true, calls: budgetCall)
        assistant.ask("¿Qué quedamos sobre las contrataciones en la llamada?")
        await settled(assistant)
        XCTAssertEqual(assistant.answer, "No he encontrado nada de eso en tus llamadas.")
    }

    // MARK: - A name decides

    /// "What did Marta say" is about a call only if Marta was on one.
    func testSomeoneWhoWasOnACallMakesItACallQuestion() async {
        let assistant = model(notesOn: true, calls: budgetCall)
        assistant.ask("What did Marta say about the budget?")
        await settled(assistant)
        XCTAssertTrue(assistant.answersFromCalls)
        // Found, and the model is absent here, so that is what it says.
        XCTAssertEqual(assistant.failure, ModelAvailability.deviceNotEligible.message(feature: "answering"))
    }

    func testSomeoneWhoWasOnNoCallLeavesTheQuestionAlone() async {
        let assistant = model(notesOn: true, calls: budgetCall)
        assistant.ask("What did Messi say about the final?")
        await settled(assistant)
        XCTAssertFalse(assistant.answersFromCalls)
    }

    // MARK: - Sources

    func testASourceOpensItsCallAndClosesThePanel() async {
        let assistant = model(notesOn: true)
        assistant.ask("What did we agree on the call yesterday?")
        await settled(assistant)
        XCTAssertTrue(assistant.isPresenting)
        let source = CallSource(folder: "2026-10-06 10.00 – Weekly sync", title: "Weekly sync",
                                startedAt: Date(), time: 240)
        var opened: CallSource?
        assistant.onShowCall = { opened = $0 }
        assistant.openSource(source)
        XCTAssertEqual(opened, source)
        XCTAssertFalse(assistant.isPresenting)
    }

    /// A new question clears the last one's sources, so they never sit
    /// under an answer they did not come from.
    func testANewQuestionClearsTheSources() {
        let assistant = model(notesOn: false)
        let source = CallSource(folder: "f", title: "t", startedAt: Date(), time: 0)
        assistant.presentPreview(question: "q", answer: "a", availability: .deviceNotEligible,
                                 fromCalls: true, sources: [source])
        assistant.ask("What is the capital of France?")
        XCTAssertFalse(assistant.answersFromCalls)
        XCTAssertTrue(assistant.callSources.isEmpty)
    }
}
