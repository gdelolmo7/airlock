import AirlockTestSupport
import XCTest
@testable import AirlockCore

/// Finding the stretch of a call a question is about, in memory only.
final class CallSearchTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Thursday 8 October 2026, 12:00 in Madrid.
    private var now: Date { at(8, hour: 12) }

    private func at(_ day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    /// Calls kept in a dictionary, as the folders would give them.
    private struct Folders: CallFolders {
        var calls: [String: (stamp: Date, record: MeetingRecord)] = [:]
        func stamps() -> [String: Date] { calls.mapValues(\.stamp) }
        func record(in folder: String) -> MeetingRecord? { calls[folder]?.record }
    }

    private func call(_ lines: [(MeetingSpeaker, String)], on day: Int = 7, hour: Int = 10,
                      title: String? = nil, with people: [String] = [], gap: TimeInterval = 10) -> MeetingRecord {
        let start = at(day, hour: hour)
        let segments = lines.enumerated().map { index, line in
            MeetingSegment(speaker: line.0, start: Double(index) * gap,
                           end: Double(index) * gap + gap - 1, text: line.1)
        }
        let event = title.map { MeetingEvent(title: $0, start: start, attendees: people) }
        return MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                             endedAt: start.addingTimeInterval(1800), segments: segments, event: event)
    }

    private func index(_ calls: [String: MeetingRecord]) -> CallSearchIndex {
        var index = CallSearchIndex()
        let stamp = Date(timeIntervalSince1970: 1_000)
        index.refresh(from: Folders(calls: calls.mapValues { (stamp, $0) }))
        return index
    }

    private func search(_ index: CallSearchIndex, _ question: String) -> [CallChunk] {
        index.search(CallQuery(question, now: now, calendar: calendar))
    }

    // MARK: - Chunks

    func testChunksCloseBeforeTheLimit() {
        let line = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces) // 149
        let record = call(Array(repeating: (.them, line), count: 5), gap: 20)
        let chunks = CallSearchIndex.chunks(of: record, folder: "f")
        XCTAssertEqual(chunks.count, 3, "two lines of 149 fit in 400, a third does not")
        XCTAssertEqual(chunks.map(\.time), [0, 40, 80], "each starts where its first line was said")
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= CallSearchIndex.chunkLimit + 10 })
    }

    func testALineLongerThanTheLimitIsAChunkOfItsOwn() {
        let long = String(repeating: "presupuesto ", count: 50)
        let chunks = CallSearchIndex.chunks(of: call([(.me, "hola"), (.them, long), (.me, "vale")]), folder: "f")
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[1].time, 10)
    }

    func testAChunkNamesItsSpeakersAndCarriesTheCall() {
        let record = call([(.me, "Shall we move the launch?"), (.them, "Yes, to the 15th."),
                           (.them, "I'll tell marketing.")], title: "Weekly sync", with: ["Ana Ruiz"])
        let chunk = CallSearchIndex.chunks(of: record, folder: "2026-10-07 10.00 – Weekly sync")[0]
        XCTAssertEqual(chunk.speakers, ["You", "Ana Ruiz"], "a one-to-one call names the other side")
        XCTAssertEqual(chunk.text, "You: Shall we move the launch?\nAna Ruiz: Yes, to the 15th. I'll tell marketing.")
        XCTAssertEqual(chunk.folder, "2026-10-07 10.00 – Weekly sync")
        XCTAssertEqual(chunk.title, "Weekly sync")
        XCTAssertEqual(chunk.startedAt, at(7, hour: 10))
    }

    func testNothingSaidIsNoChunks() {
        XCTAssertTrue(CallSearchIndex.chunks(of: call([]), folder: "f").isEmpty)
    }

    // MARK: - Ranking

    func testTheChunkThatSaysItMostRanksFirst() {
        let filler = String(repeating: "and then we talked about other things ", count: 6)
        let index = index([
            "a": call([(.them, "The budget is fine."), (.me, filler), (.them, filler)]),
            "b": call([(.them, "The budget, the budget: the budget is over by ten percent.")], on: 6),
            "c": call([(.them, "Nothing to do with money here.")], on: 5),
        ])
        let hits = search(index, "What was said about the budget on the call?")
        XCTAssertEqual(hits.map(\.folder), ["b", "a"])
    }

    func testARareWordOutweighsACommonOne() {
        let index = index([
            "a": call([(.them, "The roadmap slipped again.")]),
            "b": call([(.them, "Pricing for the roadmap.")], on: 6),
            "c": call([(.them, "The roadmap is fine.")], on: 5),
            "d": call([(.them, "We looked at the roadmap.")], on: 4),
        ])
        XCTAssertEqual(search(index, "what did we say about pricing and the roadmap").first?.folder, "b")
    }

    func testTheTitleAndThePeopleCount() {
        let index = index([
            "a": call([(.them, "Let's ship on Friday.")], title: "Launch review", with: ["Marta García", "Pablo"]),
            "b": call([(.them, "Friday is a holiday.")], on: 6),
        ])
        XCTAssertEqual(search(index, "what did Marta say about Friday").first?.folder, "a")
        XCTAssertEqual(search(index, "what happened in the launch review").map(\.folder), ["a"])
    }

    func testSpanishAccentsMatchEitherWay() {
        let index = index([
            "a": call([(.them, "La facturacion de octubre sale el lunes.")]),
            "b": call([(.them, "La reunión con el banco fue bien.")], on: 6),
        ])
        XCTAssertEqual(search(index, "¿Qué dijeron de la facturación?").map(\.folder), ["a"])
        XCTAssertEqual(search(index, "¿qué pasó con el BANCO?").map(\.folder), ["b"])
    }

    func testNothingMatchingIsNothing() {
        let index = index(["a": call([(.them, "The budget is fine.")])])
        XCTAssertTrue(search(index, "what did they say about the holidays on the call").isEmpty)
    }

    func testAnEmptyLibraryFindsNothing() {
        let index = CallSearchIndex()
        XCTAssertTrue(index.isEmpty)
        XCTAssertTrue(search(index, "what did we agree about the budget").isEmpty)
        XCTAssertTrue(search(index, "¿qué quedamos ayer?").isEmpty)
    }

    func testTheLimitHolds() {
        var calls: [String: MeetingRecord] = [:]
        for day in 1...9 { calls["d\(day)"] = call([(.them, "budget talk")], on: day) }
        XCTAssertEqual(index(calls).search(CallQuery(terms: ["budget"], range: nil), limit: 6).count, 6)
    }

    func testTiesGoToTheNewerCall() {
        let index = index([
            "old": call([(.them, "The budget is fine.")], on: 2),
            "new": call([(.them, "The budget is fine.")], on: 6),
        ])
        XCTAssertEqual(search(index, "the budget on the call").map(\.folder), ["new", "old"])
    }

    // MARK: - Dates

    func testTheDateRangeLeavesOtherDaysOut() {
        let index = index([
            "tue": call([(.them, "The budget is fine.")], on: 6),
            "wed": call([(.them, "The budget is over.")], on: 7),
        ])
        XCTAssertEqual(search(index, "what did they say about the budget yesterday").map(\.folder), ["wed"])
        XCTAssertEqual(search(index, "¿qué dijeron del presupuesto el martes?").map(\.folder), [],
                       "Spanish words find nothing in an English call")
        XCTAssertEqual(search(index, "what did they say about the budget on Tuesday").map(\.folder), ["tue"])
        XCTAssertEqual(search(index, "what did they say about the budget on Monday").map(\.folder), [])
    }

    // MARK: - Only the agreeing

    func testAQuestionWithNoWordsReadsTheLatestCallInTheRange() {
        let index = index([
            "earlier": call([(.them, "We agreed on everything.")], on: 7, hour: 9),
            "later": call([(.them, "Hello there."), (.me, "So we agreed: ship on the 15th."),
                           (.them, "Bye.")], on: 7, hour: 16),
            "monday": call([(.them, "Deal, we decided it.")], on: 5),
        ])
        let hits = search(index, "¿qué quedamos ayer?")
        XCTAssertEqual(Set(hits.map(\.folder)), ["later"])
        XCTAssertTrue(hits[0].text.contains("ship on the 15th"))
    }

    func testWithNoAgreementWordsTheCallIsShownStartToEnd() {
        let line = String(repeating: "talk ", count: 70)
        let record = call((0..<10).map { _ in (MeetingSpeaker.them, line) }, on: 7)
        let index = index(["a": record])
        let hits = index.search(CallQuery(terms: [], range: nil), limit: 4)
        XCTAssertEqual(hits.map(\.time), [0, 30, 60, 90], "first to last, evenly, in order")
    }

    // MARK: - Refreshing

    func testOnlyChangedCallsAreReadAgain() {
        var folders = Folders()
        let stamp = Date(timeIntervalSince1970: 1_000)
        folders.calls["a"] = (stamp, call([(.them, "budget")]))
        folders.calls["b"] = (stamp, call([(.them, "roadmap")], on: 6))
        var index = CallSearchIndex()
        XCTAssertEqual(index.refresh(from: folders), .init(calls: 2, read: 2, dropped: 0))
        XCTAssertEqual(index.refresh(from: folders), .init(calls: 2, read: 0, dropped: 0),
                       "nothing changed, nothing read")

        folders.calls["a"] = (stamp.addingTimeInterval(5), call([(.them, "budget and pricing")]))
        XCTAssertEqual(index.refresh(from: folders), .init(calls: 2, read: 1, dropped: 0))
        XCTAssertEqual(index.search(CallQuery(terms: ["pricing"], range: nil)).map(\.folder), ["a"])
    }

    func testADeletedCallIsGoneFromTheNextAnswer() {
        var folders = Folders()
        let stamp = Date(timeIntervalSince1970: 1_000)
        folders.calls["a"] = (stamp, call([(.them, "budget")], title: "Sync", with: ["Marta"]))
        var index = CallSearchIndex()
        index.refresh(from: folders)
        XCTAssertEqual(index.people, ["Marta"])

        folders.calls["a"] = nil
        XCTAssertEqual(index.refresh(from: folders), .init(calls: 0, read: 0, dropped: 1))
        XCTAssertTrue(index.search(CallQuery(terms: ["budget"], range: nil)).isEmpty)
        XCTAssertEqual(index.people, [])
        XCTAssertTrue(index.isEmpty)
    }

    func testAnUnreadableRecordDropsOut() {
        struct Broken: CallFolders {
            func stamps() -> [String: Date] { ["a": Date()] }
            func record(in folder: String) -> MeetingRecord? { nil }
        }
        var index = CallSearchIndex()
        XCTAssertEqual(index.refresh(from: Broken()), .init(calls: 0, read: 1, dropped: 0))
    }

    // MARK: - The folders on disk

    /// The store is read for stamps and records and nothing is written: the
    /// search must never leave a copy of what was said.
    func testTheStoreIsReadAndNeverWritten() throws {
        let scratch = TestScratch("cs")
        let store = MeetingStore(root: scratch.root)
        let record = call([(.them, "The budget is fine.")])
        let folder = try store.makeFolder(for: record, timeZone: calendar.timeZone)
        try store.saveTranscript(record, in: folder, timeZone: calendar.timeZone)
        let before = try FileManager.default.subpathsOfDirectory(atPath: scratch.root.path).sorted()

        let search = CallSearch(folders: store)
        let expectation = expectation(description: "searched")
        Task {
            let found = await search.search(CallQuery(terms: ["budget"], range: nil))
            XCTAssertEqual(found.chunks.map(\.folder), [folder.lastPathComponent])
            XCTAssertEqual(found.refresh, .init(calls: 1, read: 1, dropped: 0))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        let after = try FileManager.default.subpathsOfDirectory(atPath: scratch.root.path).sorted()
        XCTAssertEqual(before, after)
        XCTAssertNil(store.stamps()[".hidden"])
    }
}
