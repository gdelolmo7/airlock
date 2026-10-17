import Foundation
import XCTest
@testable import AirlockCore

/// What a usage count may carry (`UsageEvent`), and when counts are kept
/// and sent (`UsagePolicy`, `UsageQueue`, `UsageWire`).
final class UsageEventTests: XCTestCase {
    // MARK: - Never content

    /// The door every code word from the app goes through. Whatever a person
    /// writes has a space, a slash, a colon, a quote or a length that no
    /// identifier has.
    func testAnythingAPersonWritesBecomesOther() {
        for text in ["Delete all my files", "/Users/ana/Projects/secret-plan", "rm -rf ~",
                     "https://example.com", "ana@example.com", "\"quoted\"", "naïve",
                     "a\nb", "", String(repeating: "a", count: UsageEvent.wordLimit + 1),
                     "git push origin main", "Ana's MacBook"] {
            XCTAssertEqual(UsageEvent.word(text), "other", text)
        }
    }

    func testCodeWordsVersionsAndMacModelsAreKept() {
        for word in ["clipboard", "systemStats", "claude-code", "1.0.24", "Mac16,1",
                     "MacBookPro18,3", "free_limit", String(repeating: "a", count: UsageEvent.wordLimit)] {
            XCTAssertEqual(UsageEvent.word(word), word)
        }
    }

    /// The factories that take a word from the app put it through the door.
    func testAppWordsGoThroughTheDoor() {
        XCTAssertEqual(UsageEvent.widgetSwitched("My secret project", on: true).properties["widget"],
                       .word("other"))
        XCTAssertEqual(UsageEvent.settingsOpened("/etc/passwd").properties["page"], .word("other"))
        XCTAssertEqual(UsageEvent.plansOpened(from: "free card").properties["from"], .word("other"))
        XCTAssertEqual(UsageEvent.freeLimitHit("clipboardHistory").properties["limit"],
                       .word("clipboardHistory"))
        XCTAssertEqual(UsageEvent.problemSeen("accessibility").properties["problem"], .word("accessibility"))
    }

    /// Every word any factory can produce is one the door would keep, so
    /// nothing slips past it by being built some other way.
    func testEveryFactoryWordPassesTheDoor() {
        var events: [UsageEvent] = [
            .appOpened,
            .dayActive(plan: .pro, widgetsOn: 7, agentsConnected: 2, dictationOn: true,
                       callNotesOn: false, crashReportsOn: true),
            .setupEnded(.skipped, at: .agents, seconds: 40),
            .agentsDeclined,
            .callEnded(minutes: 31, notes: .online, inPerson: false),
            .planChanged(from: .free, to: .plus),
        ]
        events += OnboardingPlan.Step.allCases.map { .setupStep($0, position: 1, secondsBefore: 3) }
        events += UsageEvent.Feature.allCases.map { .used($0) }
        events += UsageEvent.Origin.allCases.map { .countsStarted(from: $0) }
        for agent in AgentKind.allCases {
            events += [.agentConnection(agent, connected: true, inSetup: false), .agentSession(agent),
                       .questionAnswered(agent), .approval(agent, .always, risky: true)]
        }
        for event in events {
            XCTAssertEqual(UsageEvent.word(event.name), event.name)
            for (key, value) in event.properties {
                XCTAssertEqual(UsageEvent.word(key), key)
                if case .word(let word) = value { XCTAssertEqual(UsageEvent.word(word), word, event.name) }
            }
        }
    }

    func testTimesAreNeverNegative() {
        XCTAssertEqual(UsageEvent.setupStep(.agents, position: 2, secondsBefore: -5)
            .properties["seconds_before"], .int(0))
        XCTAssertNil(UsageEvent.setupStep(.welcome, position: 1, secondsBefore: nil)
            .properties["seconds_before"])
        XCTAssertEqual(UsageEvent.callEnded(minutes: -1, notes: .none, inPerson: true)
            .properties["minutes"], .int(0))
    }

    // MARK: - Values

    func testValuesRoundTripAsPlainJSON() throws {
        let values: [String: UsageValue] = ["a": .bool(true), "b": .bool(false), "c": .int(0),
                                            "d": .int(42), "e": .word("claude-code")]
        let data = try JSONEncoder().encode(values)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"a\":true"))
        XCTAssertTrue(json.contains("\"d\":42"))
        XCTAssertEqual(try JSONDecoder().decode([String: UsageValue].self, from: data), values)
    }

    /// A word read back from the queue file comes through the same door.
    func testAWordReadBackGoesThroughTheDoor() throws {
        let data = Data(#"{"page":"what I typed"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([String: UsageValue].self, from: data)["page"],
                       .word("other"))
    }
}

final class UsagePolicyTests: XCTestCase {
    private let base = URL(string: "https://useairlock.app/api")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Only after a yes

    func testAbsentIsNo() {
        XCTAssertFalse(UsagePolicy.isOn(stored: nil))
        XCTAssertTrue(UsagePolicy.isOn(stored: true))
        XCTAssertFalse(UsagePolicy.isOn(stored: false))
    }

    func testOnlyAYesKeepsAnything() {
        let endpoint = UsagePolicy.endpoint(apiBase: base)
        XCTAssertTrue(UsagePolicy.keeps(endpoint: endpoint, isOn: true))
        XCTAssertFalse(UsagePolicy.keeps(endpoint: endpoint, isOn: false))
    }

    /// Asked once, only where it could send, and never somebody who already
    /// said yes.
    func testTheQuestionIsPutOnce() {
        XCTAssertTrue(UsagePolicy.asks(available: true, isOn: false, alreadyAsked: false))
        XCTAssertFalse(UsagePolicy.asks(available: true, isOn: false, alreadyAsked: true))
        XCTAssertFalse(UsagePolicy.asks(available: true, isOn: true, alreadyAsked: false))
        XCTAssertFalse(UsagePolicy.asks(available: false, isOn: false, alreadyAsked: false))
    }

    // MARK: - Somewhere to send

    func testTheAddressIsTheLicenceServersUsage() {
        XCTAssertEqual(UsagePolicy.endpoint(apiBase: base)?.absoluteString, "https://useairlock.app/api/usage")
    }

    func testWithoutAnHTTPSAddressNothingIsKept() {
        XCTAssertNil(UsagePolicy.endpoint(apiBase: nil))
        XCTAssertNil(UsagePolicy.endpoint(apiBase: URL(string: "http://useairlock.app/api")))
        XCTAssertNil(UsagePolicy.endpoint(apiBase: URL(string: "file:///tmp/usage")))
        XCTAssertFalse(UsagePolicy.keeps(endpoint: nil, isOn: true))
    }

    // MARK: - When

    func testASendIsDueEveryTenMinutesOrAtFifty() {
        XCTAssertFalse(UsagePolicy.sendIsDue(waiting: 0, lastTry: nil, now: now))
        XCTAssertTrue(UsagePolicy.sendIsDue(waiting: 1, lastTry: nil, now: now))
        XCTAssertFalse(UsagePolicy.sendIsDue(waiting: 3, lastTry: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(UsagePolicy.sendIsDue(waiting: 3, lastTry: now.addingTimeInterval(-600), now: now))
        XCTAssertTrue(UsagePolicy.sendIsDue(waiting: 50, lastTry: now.addingTimeInterval(-5), now: now))
    }

    func testWhatHappensToABatchAfterTheReply() {
        XCTAssertEqual(UsagePolicy.outcome(status: 204), .sent)
        XCTAssertEqual(UsagePolicy.outcome(status: 200), .sent)
        XCTAssertEqual(UsagePolicy.outcome(status: nil), .kept)
        XCTAssertEqual(UsagePolicy.outcome(status: 429), .kept)
        XCTAssertEqual(UsagePolicy.outcome(status: 500), .kept)
        XCTAssertEqual(UsagePolicy.outcome(status: 503), .kept)
        XCTAssertEqual(UsagePolicy.outcome(status: 400), .dropped)
        XCTAssertEqual(UsagePolicy.outcome(status: 404), .dropped)
        XCTAssertEqual(UsagePolicy.outcome(status: 413), .dropped)
    }

    func testTheDailyEventIsOncePerCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 8))!
        let night = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 23))!
        let next = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 0, minute: 5))!
        XCTAssertTrue(UsagePolicy.dayActiveIsDue(lastSent: nil, now: morning, calendar: calendar))
        XCTAssertFalse(UsagePolicy.dayActiveIsDue(lastSent: morning, now: night, calendar: calendar))
        XCTAssertTrue(UsagePolicy.dayActiveIsDue(lastSent: night, now: next, calendar: calendar))
    }

    // MARK: - The queue

    private func record(_ secondsAgo: TimeInterval) -> UsageRecord {
        UsageRecord(.used(.dictation), at: now.addingTimeInterval(-secondsAgo))
    }

    func testTheQueueKeepsTheNewestWhenFull() {
        var queue = UsageQueue()
        let records = (0..<(UsagePolicy.queueLimit + 20)).map { record(TimeInterval(1000 - $0)) }
        records.forEach { queue.append($0) }
        XCTAssertEqual(queue.count, UsagePolicy.queueLimit)
        XCTAssertEqual(queue.records.first, records[20])
        XCTAssertEqual(queue.records.last, records.last)
        // Read back from disk too long, it is cut the same way.
        XCTAssertEqual(UsageQueue(records: records).records, queue.records)
    }

    func testABatchIsAtMostTheLimitOldestFirst() {
        var queue = UsageQueue()
        (0..<(UsagePolicy.batchLimit + 5)).forEach { queue.append(record(TimeInterval(500 - $0))) }
        let batch = queue.nextBatch(now: now)
        XCTAssertEqual(batch.count, UsagePolicy.batchLimit)
        XCTAssertEqual(batch.first, queue.records.first)
    }

    func testTooOldIsNeverSentAndGoesAtTheNextSend() {
        var queue = UsageQueue()
        let old = record(UsagePolicy.oldestKept + 60)
        let fresh = record(60)
        queue.append(old)
        queue.append(fresh)
        let batch = queue.nextBatch(now: now)
        XCTAssertEqual(batch, [fresh])
        queue.remove(Set(batch.map(\.id)), now: now)
        XCTAssertTrue(queue.isEmpty)
    }

    func testAKeptBatchStaysForTheNextTry() {
        var queue = UsageQueue()
        queue.append(record(10))
        queue.remove([], now: now)
        XCTAssertEqual(queue.count, 1)
    }

    // MARK: - The wire

    func testTheBodyIsWhatTheServerChecks() throws {
        let id = UUID(uuidString: "6A1B2C3D-0000-4000-8000-00000000ABCD")!
        let records = [UsageRecord(.approval(.claudeCode, .allow, risky: false),
                                   at: Date(timeIntervalSince1970: 1_800_000_000), id: id)]
        let context = UsageContext(app: "1.0.24", build: "1010", os: "26.1", model: "Mac16,1",
                                   language: "es_ES", plan: .plus)
        let data = try UsageWire.body(install: "install-id", context: context, records: records)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["install"] as? String, "install-id")
        let sentContext = try XCTUnwrap(object["context"] as? [String: String])
        XCTAssertEqual(sentContext, ["app": "1.0.24", "build": "1010", "os": "26.1", "model": "Mac16,1",
                                     "lang": "es", "plan": "plus"])
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["id"] as? String, "6a1b2c3d-0000-4000-8000-00000000abcd")
        XCTAssertEqual(events[0]["name"] as? String, "approval")
        XCTAssertEqual(events[0]["at"] as? String, "2027-01-15T08:00:00Z")
        let props = try XCTUnwrap(events[0]["props"] as? [String: Any])
        XCTAssertEqual(props["agent"] as? String, "claude-code")
        XCTAssertEqual(props["answer"] as? String, "allow")
        XCTAssertEqual(props["risky"] as? Bool, false)
    }

    func testTheContextKeepsOnlyWords() {
        let context = UsageContext(app: "1.0.24", build: "1010", os: "26.1", model: "Ana's Mac",
                                   language: "en_ES", plan: .free)
        XCTAssertEqual(context.model, "other")
        XCTAssertEqual(context.language, "en")
        XCTAssertEqual(context.plan, "free")
    }

    func testRecordsRoundTripThroughTheQueueFile() throws {
        var queue = UsageQueue()
        queue.append(UsageRecord(.callEnded(minutes: 12, notes: .later, inPerson: true), at: now))
        queue.append(UsageRecord(.appOpened, at: now.addingTimeInterval(5)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(UsageQueue.self, from: encoder.encode(queue)), queue)
    }
}
