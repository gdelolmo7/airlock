import XCTest
@testable import AirlockCore

final class DictationHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let day: TimeInterval = 24 * 3600

    private func entry(_ text: String = "hello", daysAgo: Double = 0, finished: Bool = true,
                       recording: Bool = false) -> DictationEntry {
        DictationEntry(date: now.addingTimeInterval(-daysAgo * day), heard: text, text: text,
                       finished: finished, delivery: finished ? .typed : .none, hasRecording: recording)
    }

    func testKeepsTwoHundredAtMostNewestFirst() {
        let entries = (0..<205).map { entry("n\($0)", daysAgo: Double($0) / 100) }
        let pruning = DictationHistory.pruning(entries, now: now)
        XCTAssertEqual(pruning.entries.count, 5)
        XCTAssertEqual(pruning.entries, Set(entries.suffix(5).map(\.id)))
    }

    func testDropsTextOlderThanThirtyDays() {
        let fresh = entry(daysAgo: 29)
        let old = entry(daysAgo: 31)
        XCTAssertEqual(DictationHistory.pruning([fresh, old], now: now).entries, [old.id])
    }

    func testDropsRecordingsAfterAWeekButKeepsTheText() {
        let week = entry(daysAgo: 6, recording: true)
        let older = entry(daysAgo: 8, recording: true)
        let pruning = DictationHistory.pruning([week, older], now: now)
        XCTAssertEqual(pruning.entries, [])
        XCTAssertEqual(pruning.recordings, [older.id])
    }

    func testNeverPrunesAnUnfinishedEntry() {
        let cutOff = entry(daysAgo: 40, finished: false, recording: true)
        XCTAssertTrue(DictationHistory.pruning([cutOff], now: now).isEmpty)
        XCTAssertEqual(DictationHistory.toRecover([entry(), cutOff]).map(\.id), [cutOff.id])
    }

    func testRecoversOldestFirst() {
        let first = entry(daysAgo: 2, finished: false)
        let second = entry(daysAgo: 1, finished: false)
        XCTAssertEqual(DictationHistory.toRecover([second, first]).map(\.id), [first.id, second.id])
    }

    func testSearchIgnoresCaseAndAccentsAndNeedsEveryWord() {
        var withApp = entry("Call José tomorrow")
        withApp.app = "Mail"
        let other = entry("Lunch with Ana")
        XCTAssertEqual(DictationHistory.search([withApp, other], for: "jose").map(\.id), [withApp.id])
        XCTAssertEqual(DictationHistory.search([withApp, other], for: "mail call").map(\.id), [withApp.id])
        XCTAssertEqual(DictationHistory.search([withApp, other], for: "jose ana"), [])
        XCTAssertEqual(DictationHistory.search([withApp, other], for: "  ").count, 2)
    }

    func testSearchFindsWhatWasHeardAndEarlierVersions() {
        var tidied = entry("Send the report.")
        tidied.heard = "uh send the the report"
        tidied.earlier = ["send report"]
        XCTAssertEqual(DictationHistory.search([tidied], for: "uh").count, 1)
        XCTAssertEqual(DictationHistory.search([tidied], for: "send report").count, 1)
    }

    func testTryAgainReplacesAndKeepsTheOldText() {
        let first = entry("helo world")
        let again = DictationHistory.retried(first, heard: "hello world", text: "Hello world.")
        XCTAssertEqual(again.text, "Hello world.")
        XCTAssertEqual(again.heard, "hello world")
        XCTAssertEqual(again.earlier, ["helo world"])
        XCTAssertEqual(again.id, first.id)
    }

    func testTryAgainThatHearsNothingChangesNothing() {
        let first = entry("keep me")
        XCTAssertEqual(DictationHistory.retried(first, heard: "", text: "  "), first)
    }

    func testTryAgainWithTheSameTextKeepsNoDuplicate() {
        let first = entry("same")
        XCTAssertEqual(DictationHistory.retried(first, heard: "same", text: "same").earlier, [])
    }

    func testRestoringAnEarlierVersionKeepsTheCurrentOne() {
        var tried = entry("new")
        tried.earlier = ["old"]
        let back = DictationHistory.restored(tried, earlier: "old")
        XCTAssertEqual(back.text, "old")
        XCTAssertEqual(back.earlier, ["new"])
    }

    func testLastSkipsUnfinishedAndEmpty() {
        let older = entry("older", daysAgo: 1)
        let empty = entry("", daysAgo: 0.5)
        let running = entry("running", daysAgo: 0, finished: false)
        XCTAssertEqual(DictationHistory.last([older, empty, running])?.id, older.id)
    }

    func testOldRecordWithoutNewFieldsStillDecodes() throws {
        let json = #"{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","date":0,"text":"hi"}"#
        let decoded = try JSONDecoder().decode(DictationEntry.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.text, "hi")
        XCTAssertTrue(decoded.finished)
        XCTAssertEqual(decoded.earlier, [])
    }

    func testPasswordFieldIsFoundThroughFocusedChildrenOnly() {
        let password = FocusTarget.Snapshot(role: "AXSecureTextField", isFocused: true)
        let focusedParent = FocusTarget.Snapshot(role: "AXGroup", children: [password])
        var unfocused = password
        unfocused.isFocused = false
        let unfocusedParent = FocusTarget.Snapshot(role: "AXGroup", children: [unfocused])
        XCTAssertTrue(FocusTarget.containsPasswordField(focusedParent))
        XCTAssertFalse(FocusTarget.containsPasswordField(unfocusedParent))
        XCTAssertFalse(FocusTarget.containsPasswordField(.init(role: "AXTextArea")))
    }
}
