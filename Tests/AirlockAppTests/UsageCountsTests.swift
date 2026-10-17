import Foundation
import XCTest
import AirlockCore
import AirlockTestSupport
@testable import AirlockApp

/// The rules for when usage counts are kept, sent and thrown away
/// (`UsageCounts`), with a stand-in for the network so nothing leaves.
@MainActor
final class UsageCountsTests: XCTestCase {
    private let endpoint = URL(string: "https://license.example.com/usage")!
    private var store: TestDefaults!
    private var scratch: TestScratch!
    private var network: FakeTransport!
    private var clock: Clock!

    override func setUp() async throws {
        store = TestDefaults("com.airlock.test.usagecounts")
        scratch = TestScratch("usage")
        network = FakeTransport()
        // Noon, so an hour later is the same day wherever the test runs.
        clock = Clock(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0,
                                            of: Date(timeIntervalSince1970: 1_790_000_000))!)
    }

    override func tearDown() async throws {
        store.remove()
        scratch.remove()
    }

    private var queueFile: URL { scratch.file("usage-waiting.json") }

    private func counts(endpoint: URL?) -> UsageCounts {
        let clock = clock!
        let counts = UsageCounts(endpoint: endpoint, defaults: store.defaults, transport: network,
                                 queueFile: queueFile, now: { clock.date }, roundEvery: nil)
        counts.context = {
            UsageContext(app: "1.0.24", build: "1010", os: "26.5.0", model: "Mac16,1",
                         language: "es", plan: .plus)
        }
        return counts
    }

    private func names(_ body: Data) throws -> [String] {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        return events.compactMap { $0["name"] as? String }
    }

    // MARK: - Nothing without somewhere to send

    func testWithoutAnEndpointNothingIsKeptWhateverTheAnswer() async {
        store.defaults.set(true, forKey: UsageCounts.enabledKey)
        let usage = counts(endpoint: nil)
        XCTAssertFalse(usage.isAvailable)
        XCTAssertFalse(usage.isEnabled)
        usage.launch()
        usage.record(.used(.dictation))
        await usage.send()
        XCTAssertEqual(usage.waitingCount, 0)
        let posts = await network.bodies
        XCTAssertTrue(posts.isEmpty)
        XCTAssertFalse(usage.hasQuestionWaiting)
    }

    /// A yes from a build that cannot send is not kept: the copy that can
    /// send would otherwise read an answer nobody gave it.
    func testABuildWithoutAnEndpointKeepsNoAnswer() {
        let usage = counts(endpoint: nil)
        usage.choose(true, from: .settings)
        XCTAssertNil(store.defaults.object(forKey: UsageCounts.enabledKey))
        XCTAssertNil(store.defaults.object(forKey: UsageCounts.askedKey))
    }

    /// No test, `swift run` or development package carries the licence
    /// server's address, so the shared counter in this process keeps nothing
    /// and offers nothing, and Settings search leads to no switch.
    func testThisProcessHasNoEndpoint() {
        XCTAssertNil(UsageCounts.bundleEndpoint)
        XCTAssertFalse(UsageCounts.shared.isAvailable)
        XCTAssertFalse(SettingsAnchor.usageCounts.isAvailable(guideOn: false))
        XCTAssertFalse(SettingsAnchor.search("usage", guideOn: false).contains(.usageCounts))
    }

    // MARK: - Only after a yes

    func testOffByDefaultSoNothingIsKept() async {
        let usage = counts(endpoint: endpoint)
        XCTAssertTrue(usage.isAvailable)
        XCTAssertFalse(usage.isEnabled)
        usage.launch()
        usage.record(.used(.clipboardPasted))
        await usage.round()
        await usage.send()
        XCTAssertEqual(usage.waitingCount, 0)
        let posts = await network.bodies
        XCTAssertTrue(posts.isEmpty)
        XCTAssertNil(store.defaults.object(forKey: UsageCounts.installKey))
    }

    func testAYesCountsFromThatMomentStartingWithTheYes() async throws {
        let usage = counts(endpoint: endpoint)
        usage.launch()
        usage.record(.used(.dictation))
        XCTAssertEqual(usage.waitingCount, 0, "nothing from before the yes")

        usage.choose(true, from: .question)
        XCTAssertTrue(usage.isEnabled)
        XCTAssertEqual(store.defaults.object(forKey: UsageCounts.enabledKey) as? Bool, true)
        usage.record(.used(.shelfDropped))
        XCTAssertEqual(usage.waitingCount, 2)

        await usage.send()
        let posts = await network.bodies
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(try names(posts[0]), ["counts_started", "feature_used"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: posts[0]) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual((events[0]["props"] as? [String: Any])?["from"] as? String, "question")
        let install = try XCTUnwrap(json["install"] as? String)
        XCTAssertNotNil(UUID(uuidString: install))
        XCTAssertEqual(store.defaults.string(forKey: UsageCounts.installKey), install)
        XCTAssertEqual(usage.waitingCount, 0, "a delivered batch is forgotten")
    }

    func testAYesFromBeforeIsReadAtLaunch() async throws {
        store.defaults.set(true, forKey: UsageCounts.enabledKey)
        let usage = counts(endpoint: endpoint)
        XCTAssertTrue(usage.isEnabled)
        usage.launch()
        await usage.send()
        let posts = await network.bodies
        XCTAssertEqual(try names(posts[0]), ["app_opened"])
    }

    /// The state gallery and the snapshot runs build views that would count,
    /// and never launch.
    func testNothingIsKeptBeforeLaunch() {
        store.defaults.set(true, forKey: UsageCounts.enabledKey)
        let usage = counts(endpoint: endpoint)
        usage.record(.used(.dictation))
        XCTAssertEqual(usage.waitingCount, 0)
    }

    // MARK: - Turning it off

    func testNoThrowsAwayEverythingWaitingAndTheID() async throws {
        store.defaults.set(true, forKey: UsageCounts.enabledKey)
        let usage = counts(endpoint: endpoint)
        usage.launch()
        await network.answer(503)
        await usage.send()
        usage.record(.used(.dictation))
        usage.willQuit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueFile.path))
        XCTAssertNotNil(store.defaults.string(forKey: UsageCounts.installKey))
        store.defaults.set(clock.date, forKey: UsageCounts.dayKey)

        usage.choose(false, from: .settings)
        XCTAssertFalse(usage.isEnabled)
        XCTAssertEqual(store.defaults.object(forKey: UsageCounts.enabledKey) as? Bool, false)
        XCTAssertEqual(usage.waitingCount, 0)
        XCTAssertNil(store.defaults.string(forKey: UsageCounts.installKey))
        XCTAssertNil(store.defaults.object(forKey: UsageCounts.dayKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueFile.path))

        usage.record(.used(.dictation))
        await usage.send()
        XCTAssertEqual(usage.waitingCount, 0)
        let posts = await network.bodies
        XCTAssertEqual(posts.count, 1, "only the one from before the no")
    }

    func testANewYesGetsANewID() async throws {
        let usage = counts(endpoint: endpoint)
        usage.launch()
        usage.choose(true, from: .settings)
        await usage.send()
        let first = try XCTUnwrap(store.defaults.string(forKey: UsageCounts.installKey))
        usage.choose(false, from: .settings)
        usage.choose(true, from: .settings)
        await usage.send()
        let second = try XCTUnwrap(store.defaults.string(forKey: UsageCounts.installKey))
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Sending

    func testWhatTheServerSaysDecidesWhatIsKept() async {
        let cases: [(Int?, Bool)] = [(204, false), (200, false), (400, false), (413, false),
                                     (429, true), (500, true), (503, true), (nil, true)]
        for (status, kept) in cases {
            store.defaults.set(true, forKey: UsageCounts.enabledKey)
            let usage = counts(endpoint: endpoint)
            usage.launch()
            await network.answer(status)
            await usage.send()
            XCTAssertEqual(usage.waitingCount, kept ? 1 : 0, "status \(String(describing: status))")
            usage.choose(false, from: .settings)
        }
    }

    func testWhatIsWaitingAtQuitIsSentAfterTheNextLaunch() async throws {
        store.defaults.set(true, forKey: UsageCounts.enabledKey)
        let first = counts(endpoint: endpoint)
        first.launch()
        first.record(.used(.terminalJump))
        first.willQuit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueFile.path))

        let second = counts(endpoint: endpoint)
        second.launch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueFile.path), "read once, then gone")
        await second.send()
        let posts = await network.bodies
        XCTAssertEqual(try names(posts[0]), ["app_opened", "feature_used", "app_opened"])
    }

    func testAFileLeftFromBeforeANoIsThrownAway() async {
        store.defaults.set(true, forKey: UsageCounts.enabledKey)
        let first = counts(endpoint: endpoint)
        first.launch()
        first.willQuit()
        store.defaults.set(false, forKey: UsageCounts.enabledKey)

        let second = counts(endpoint: endpoint)
        second.launch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueFile.path))
        XCTAssertEqual(second.waitingCount, 0)
    }

    func testFiftyWaitingSendsWithoutWaitingForTheRound() async throws {
        store.defaults.set(true, forKey: UsageCounts.enabledKey)
        let usage = counts(endpoint: endpoint)
        usage.launch()
        for _ in 1..<UsagePolicy.sendAtCount { usage.record(.used(.clipboardOpened)) }
        for _ in 0..<200 {
            if !(await network.bodies.isEmpty) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let posts = await network.bodies
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(try names(posts[0]).count, UsagePolicy.sendAtCount)
    }

    func testTheDailyEventGoesOncePerDay() async throws {
        store.defaults.set(true, forKey: UsageCounts.enabledKey)
        let usage = counts(endpoint: endpoint)
        usage.daySnapshot = {
            .dayActive(plan: .plus, widgetsOn: 6, agentsConnected: 1, dictationOn: true,
                       callNotesOn: false, crashReportsOn: true)
        }
        usage.launch()
        await usage.round()
        await usage.round()
        clock.date += 3600
        await usage.round()
        var posts = await network.bodies
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(try names(posts[0]), ["app_opened", "day_active"])

        clock.date += 24 * 3600
        await usage.round()
        posts = await network.bodies
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(try names(posts[1]), ["day_active"])
    }

    func testARepeatedLimitIsKeptOnceADay() async throws {
        store.defaults.set(true, forKey: UsageCounts.enabledKey)
        let usage = counts(endpoint: endpoint)
        usage.launch()
        for _ in 0..<5 { usage.recordOnceADay(.freeLimitHit("clipboard_shows"), key: "clipboard_shows") }
        usage.recordOnceADay(.freeLimitHit("notes_listen_for"), key: "notes_listen_for")
        clock.date += 3600
        usage.recordOnceADay(.freeLimitHit("clipboard_shows"), key: "clipboard_shows")
        await usage.send()
        var posts = await network.bodies
        XCTAssertEqual(try names(posts[0]), ["app_opened", "free_limit_hit", "free_limit_hit"])

        clock.date += 24 * 3600
        usage.recordOnceADay(.freeLimitHit("clipboard_shows"), key: "clipboard_shows")
        await usage.send()
        posts = await network.bodies
        XCTAssertEqual(try names(posts[1]), ["free_limit_hit"])
    }

    // MARK: - The question

    func testTheQuestionIsPutOnce() {
        let usage = counts(endpoint: endpoint)
        XCTAssertTrue(usage.hasQuestionWaiting)
        usage.questionAsked()
        XCTAssertFalse(usage.hasQuestionWaiting)
        XCTAssertFalse(counts(endpoint: endpoint).hasQuestionWaiting, "remembered")
    }

    func testAnswerCountsAsAsked() {
        let usage = counts(endpoint: endpoint)
        usage.choose(false, from: .question)
        XCTAssertFalse(usage.hasQuestionWaiting)
        XCTAssertEqual(store.defaults.object(forKey: UsageCounts.askedKey) as? Bool, true)
    }

    func testAYesIsNeverAskedAgain() {
        store.defaults.set(true, forKey: UsageCounts.enabledKey)
        XCTAssertFalse(counts(endpoint: endpoint).hasQuestionWaiting)
    }
}

private final class Clock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private actor FakeTransport: UsageTransport {
    private var status: Int? = 204
    private(set) var bodies: [Data] = []

    func answer(_ status: Int?) { self.status = status }

    func post(_ body: Data, to url: URL) async -> Int? {
        bodies.append(body)
        return status
    }
}
