import AirlockCore
import AirlockTestSupport
import XCTest
@testable import AirlockApp

/// A stand-in for the notes server: answers in turn, counts the questions.
/// Nothing in these tests reaches the network.
private actor Server {
    private var replies: [CloudNotes.Reply]
    private(set) var asked = 0

    init(_ replies: [CloudNotes.Reply]) { self.replies = replies }

    func answer() -> CloudNotes.Reply {
        asked += 1
        return replies.isEmpty ? .unavailable : replies.removeFirst()
    }
}

/// Meeting notes online in the app: when a meeting is sent, what an answer
/// leaves behind for the next meeting, and the meetings written offline,
/// written again once online. Made-up calls only.
@MainActor
final class CloudNotesServiceTests: XCTestCase {
    private static let start = Date(timeIntervalSince1970: 1_791_468_600)

    private static let answer = #"""
        {"summary": "A call to plan the launch.",
         "decisions": [{"text": "Launch on the twentieth", "sources": ["S3"]}],
         "todos": [{"task": "Send the budget", "owner": "You", "due": "Thursday", "sources": ["S2"]}],
         "questions": [{"text": "Who pays for the venue?", "sources": ["S4"]}],
         "keyPoints": [{"text": "Catering is cheaper this year", "sources": ["S6"]}]}
        """#

    private var suite = ""
    private var defaults: UserDefaults!
    private var scratch: TestScratch!
    private var store: MeetingStore!

    override func setUp() {
        super.setUp()
        suite = "CloudNotesServiceTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        scratch = TestScratch("cns")
        store = MeetingStore(root: scratch.root)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        scratch = nil
        super.tearDown()
    }

    private static var subscriber: Entitlement {
        .licensed(License(id: "lic_1", email: "a@b.com", product: "airlock", period: .yearly,
                          issued: start, renewsAt: Date().addingTimeInterval(30 * 86_400),
                          checkBy: Date().addingTimeInterval(44 * 86_400)))
    }

    /// `setting` is "Write notes online" in Settings: untouched unless a test
    /// says otherwise, which is on. `switchedOn` nil leaves the hidden switch
    /// unset, as on every Mac that never touched it.
    private func service(_ server: Server, switchedOn: Bool? = true, paid: Bool = true,
                         setting: Bool? = nil) -> CloudNotesService {
        if let switchedOn {
            defaults.set(switchedOn, forKey: CloudNotesService.enabledKey)
        } else {
            defaults.removeObject(forKey: CloudNotesService.enabledKey)
        }
        if let setting {
            defaults.set(setting, forKey: CloudNotesService.settingKey)
        } else {
            defaults.removeObject(forKey: CloudNotesService.settingKey)
        }
        let service = CloudNotesService(defaults: defaults, store: store,
                                        transport: { _, _, _ in await server.answer() })
        service.plan = { paid ? Self.subscriber.snapshot : .free }
        service.access = { (URL(string: "https://notes.invalid/notes")!, "token") }
        service.hasServer = { true }
        return service
    }

    private static func record(startingAt start: Date = start, said: [String]? = nil,
                               writer: MeetingNotesWriter? = nil,
                               startedOn: PlanSnapshot? = nil) -> MeetingRecord {
        let lines = said ?? [
            "Can you send me the budget by Friday?",
            "Sure, I'll send it on Thursday.",
            "Good. Then we launch on the twentieth.",
            "Agreed. Who pays for the venue, though?",
            "No idea yet. The old hall might be free again.",
            "The catering quote came in lower than last year.",
        ]
        let segments = lines.enumerated().map { index, text in
            MeetingSegment(speaker: index.isMultiple(of: 2) ? .them : .me,
                           start: Double(index * 10), end: Double(index * 10 + 8), text: text)
        }
        return MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                             endedAt: start.addingTimeInterval(90), segments: segments, notesWriter: writer,
                             startedOn: startedOn)
    }

    // MARK: - One meeting

    func testSwitchedOffNothingIsAsked() async {
        let server = Server([])
        let attempt = await service(server, switchedOn: false).write(Self.record(), log: { _ in })
        guard case .mac(.hiddenSwitchOff) = attempt else { return XCTFail("\(attempt)") }
        let asked = await server.asked
        XCTAssertEqual(asked, 0)
    }

    /// On for everyone from 1.0.20: a Mac that never set the hidden switch
    /// sends a subscriber's notes, and nobody else's.
    func testAnUnsetSwitchIsOn() async {
        let server = Server([])
        let subscriber = service(server, switchedOn: nil)
        XCTAssertTrue(subscriber.isOn)
        _ = await subscriber.write(Self.record(), log: { _ in })
        let asked = await server.asked
        XCTAssertEqual(asked, 1)

        let free = await service(server, switchedOn: nil, paid: false).write(Self.record(), log: { _ in })
        guard case .mac(.notSubscribed) = free else { return XCTFail("\(free)") }
        let stillOnce = await server.asked
        XCTAssertEqual(stillOnce, 1, "Free: nothing leaves")
    }

    func testOnlyASubscriberWithTheSettingOnIsAsked() async {
        let server = Server([])
        let free = await service(server, paid: false).write(Self.record(), log: { _ in })
        guard case .mac(.notSubscribed) = free else { return XCTFail("\(free)") }

        let off = await service(server, setting: false).write(Self.record(), log: { _ in })
        guard case .mac(.settingOff) = off else { return XCTFail("\(off)") }
        let asked = await server.asked
        XCTAssertEqual(asked, 0)
    }

    // MARK: - The plan a call started on

    /// A subscription that ends during a call still gets that call's notes
    /// written online: the plan is the one it started on.
    func testACallKeepsThePlanItStartedOn() async {
        let server = Server([])
        let paidAtTheStart = Self.subscriber.snapshot
        _ = await service(server, paid: false).write(Self.record(startedOn: paidAtTheStart), log: { _ in })
        let asked = await server.asked
        XCTAssertEqual(asked, 1, "started on Plus, so written online although it is Free now")
    }

    /// Bought during the call: whoever just paid expects it to count.
    func testAPlanBoughtDuringACallCounts() async {
        let server = Server([])
        _ = await service(server).write(Self.record(startedOn: .free), log: { _ in })
        let asked = await server.asked
        XCTAssertEqual(asked, 1)
    }

    /// A call from before plans has nothing to keep, so it goes by the plan
    /// now, either way.
    func testACallFromBeforePlansGoesByThePlanNow() async {
        let server = Server([])
        let free = await service(server, paid: false).write(Self.record(), log: { _ in })
        guard case .mac(.notSubscribed) = free else { return XCTFail("\(free)") }
        _ = await service(server).write(Self.record(), log: { _ in })
        let asked = await server.asked
        XCTAssertEqual(asked, 1)
    }

    // MARK: - On unless switched off

    /// Nobody is asked: a subscriber who never touched the switch has the
    /// notes written online at the first meeting.
    func testNobodyIsAskedASubscribersNotesGoOnline() async {
        let server = Server([.notes(text: Self.answer, model: "gemini-test", usedFraction: nil)])
        let attempt = await service(server, setting: nil).write(Self.record(), log: { _ in })
        guard case .written(let notes, _) = attempt else { return XCTFail("\(attempt)") }
        XCTAssertEqual(notes.summary, "A call to plan the launch.")
        let asked = await server.asked
        XCTAssertEqual(asked, 1)
    }

    /// Untouched is on; then off, or on again.
    func testTheSettingIsOnUntilSwitchedOff() {
        let service = service(Server([]), setting: nil)
        XCTAssertNil(service.setting)
        XCTAssertTrue(CloudNotesService.switchIsOn(in: defaults), "an untouched switch shows on")
        defaults.set(false, forKey: CloudNotesService.settingKey)
        XCTAssertEqual(service.setting, false)
        XCTAssertFalse(CloudNotesService.switchIsOn(in: defaults))
        defaults.set(true, forKey: CloudNotesService.settingKey)
        XCTAssertEqual(service.setting, true)
        XCTAssertTrue(CloudNotesService.switchIsOn(in: defaults))
    }

    func testTheSettingsSwitchWritesTheSetting() {
        let service = service(Server([]), setting: nil)
        CloudNotesService.setSwitch(false, in: defaults)
        XCTAssertEqual(service.setting, false)
        XCTAssertEqual(defaults.object(forKey: CloudNotesService.settingKey) as? Bool, false)
        CloudNotesService.setSwitch(true, in: defaults)
        XCTAssertEqual(service.setting, true)
        XCTAssertEqual(defaults.object(forKey: CloudNotesService.settingKey) as? Bool, true)
    }

    /// Switched off in Settings, or "Keep on this Mac" from 1.0.20's
    /// question: kept. Nothing leaves; the log says why and not a word said.
    func testSwitchedOffNothingLeaves() async {
        let server = Server([])
        var logged: [String] = []
        let attempt = await service(server, setting: false).write(Self.record(), log: { logged.append($0) })
        guard case .mac(.settingOff) = attempt else { return XCTFail("\(attempt)") }
        let asked = await server.asked
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(logged, ["notes online: no, switched off in Settings"])
    }

    func testNotesWrittenOnlineAreChecked() async throws {
        let server = Server([.notes(text: Self.answer, model: "gemini-test", usedFraction: 0.1)])
        let attempt = await service(server).write(Self.record(), log: { _ in })
        guard case let .written(notes, model) = attempt else { return XCTFail("\(attempt)") }
        XCTAssertEqual(model, "gemini-test")
        XCTAssertEqual(notes.summary, "A call to plan the launch.")
        // The same checks as the Mac's notes: a due date that was said joins the task.
        XCTAssertEqual(notes.todos.map(\.text), ["Send the budget Thursday"])
        XCTAssertEqual(notes.decisions.map(\.text), ["Launch on the twentieth"])
    }

    /// A server error, an answer that can't be read, a refused token: the
    /// Mac writes this meeting's notes, and the next meeting asks again.
    func testAFailureIsNotRememberedForTheNextMeeting() async {
        let server = Server([.unavailable, .notes(text: "Sorry, I can't.", model: nil, usedFraction: nil),
                             .badToken, .tooLarge])
        let service = service(server)
        for _ in 0..<4 {
            let attempt = await service.write(Self.record(), log: { _ in })
            guard case .failed = attempt else { return XCTFail("\(attempt)") }
        }
        let asked = await server.asked
        XCTAssertEqual(asked, 4)
    }

    /// The month's online notes used: not asked again until the server's
    /// date, and asked again once it has passed.
    func testTheMonthsAllowanceIsRememberedUntilItsDate() async {
        let resets = Date().addingTimeInterval(10 * 86_400)
        let server = Server([.allowanceUsed(resetsAt: resets), .unavailable])
        let service = service(server)

        let first = await service.write(Self.record(), log: { _ in })
        guard case let .mac(.allowanceUsed(until)) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(until, resets)
        let second = await service.write(Self.record(), log: { _ in })
        guard case .mac(.allowanceUsed) = second else { return XCTFail("\(second)") }
        var asked = await server.asked
        XCTAssertEqual(asked, 1)

        defaults.set(Date().addingTimeInterval(-60), forKey: CloudNotesService.allowanceUntilKey)
        _ = await service.write(Self.record(), log: { _ in })
        asked = await server.asked
        XCTAssertEqual(asked, 2)
    }

    /// A licence that buys no online notes is refused once, then not asked
    /// again for a month on that licence.
    func testNotEligibleIsRememberedForThisLicence() async throws {
        let server = Server([.notEligible])
        let service = service(server)
        let first = await service.write(Self.record(), log: { _ in })
        guard case let .mac(.notEligible(until)) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(until.timeIntervalSinceNow, CloudNotesAllowance.notEligibleFor, accuracy: 60)
        let second = await service.write(Self.record(), log: { _ in })
        guard case .mac(.notEligible) = second else { return XCTFail("\(second)") }
        let asked = await server.asked
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(defaults.string(forKey: CloudNotesService.notEligibleTokenKey),
                       CloudNotesAllowance.tokenMark("token"), "a mark of the token, never the token")
    }

    /// A new token, renewed or bought, asks again at once.
    func testANewLicenceAsksAgainAtOnce() async {
        let server = Server([.notEligible, .unavailable])
        let service = service(server)
        _ = await service.write(Self.record(), log: { _ in })
        service.access = { (URL(string: "https://notes.invalid/notes")!, "renewed") }
        let attempt = await service.write(Self.record(), log: { _ in })
        guard case .failed = attempt else { return XCTFail("\(attempt)") }
        let asked = await server.asked
        XCTAssertEqual(asked, 2)
    }

    /// 1.0.20 kept a 403 for a day, with no mark: not believed, asked again.
    func testARefusalKeptWithoutAMarkIsNotBelieved() async {
        defaults.set(Date().addingTimeInterval(86_400), forKey: CloudNotesService.notEligibleUntilKey)
        let server = Server([])
        _ = await service(server).write(Self.record(), log: { _ in })
        let asked = await server.asked
        XCTAssertEqual(asked, 1)
    }

    func testARequestThatNeverLeftIsOffline() async {
        let attempt = await service(Server([.offline])).write(Self.record(), log: { _ in })
        guard case .mac(.offline) = attempt else { return XCTFail("\(attempt)") }
    }

    func testTheAllowanceIsSaidOnceAMonth() {
        let service = service(Server([]))
        let until = Date(timeIntervalSince1970: 1_793_491_200)
        let now = Self.start
        XCTAssertEqual(service.takeAllowanceNotice(until: until, now: now), until)
        XCTAssertNil(service.takeAllowanceNotice(until: until, now: now.addingTimeInterval(86_400)))
        XCTAssertEqual(service.takeAllowanceNotice(until: until, now: now.addingTimeInterval(40 * 86_400)), until)
    }

    // MARK: - Written again once online

    /// A meeting the Mac wrote while offline, as it is left on disk.
    private func savedOffline(startingAt start: Date = start, said: [String]? = nil) throws -> URL {
        try saved(startingAt: start, said: said, writer: .mac(at: start, waitsForOnline: true))
    }

    /// A meeting the Mac wrote, as it is left on disk.
    private func saved(startingAt start: Date = start, said: [String]? = nil,
                       writer: MeetingNotesWriter) throws -> URL {
        let record = Self.record(startingAt: start, said: said, writer: writer)
        let folder = try store.makeFolder(for: record)
        try store.saveTranscript(record, in: folder)
        try store.saveNotes(MeetingFiles.notesPage(for: record, notes: nil, unavailableReason: "Made up.",
                                                   writer: writer), in: folder)
        return folder
    }

    private func notes(in folder: URL) -> String { store.notesPage(in: folder) ?? "" }

    private func writer(in folder: URL) -> MeetingNotesWriter? { store.loadRecord(in: folder)?.notesWriter }

    func testWrittenAgainOnlineWithTheMacsPageKeptBeside() async throws {
        let folder = try savedOffline()
        XCTAssertTrue(notes(in: folder).contains(MeetingFiles.offlineLine))
        let server = Server([.notes(text: Self.answer, model: "gemini-test", usedFraction: nil)])
        let service = service(server)
        var redone: [URL] = []
        service.onRedone = { folder, _, _ in redone.append(folder) }

        await service.redoNow()

        let page = notes(in: folder)
        XCTAssertTrue(page.contains("A call to plan the launch."))
        XCTAssertTrue(page.contains("Written online by Airlock"))
        XCTAssertFalse(page.contains(MeetingFiles.offlineLine))
        let earlier = try String(contentsOf: folder.appendingPathComponent(MeetingFiles.earlierNotesFirstName),
                                 encoding: .utf8)
        XCTAssertTrue(earlier.contains("Made up."))
        XCTAssertFalse(earlier.contains(MeetingFiles.offlineLine), "the earlier page no longer promises")
        XCTAssertEqual(writer(in: folder)?.place, .online)
        XCTAssertEqual(writer(in: folder)?.model, "gemini-test")
        XCTAssertEqual(writer(in: folder)?.waitsForOnline, false)
        XCTAssertEqual(redone.map { $0.resolvingSymlinksInPath() }, [folder.resolvingSymlinksInPath()])
    }

    /// The server answered without notes: the Mac's notes stay, the page
    /// stops promising, and the meeting is never sent again.
    func testAMeetingIsSentAgainOnlyOnce() async throws {
        let folder = try savedOffline()
        let server = Server([.unavailable, .notes(text: Self.answer, model: nil, usedFraction: nil)])
        let service = service(server)

        await service.redoNow()
        await service.redoNow()

        let asked = await server.asked
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(writer(in: folder)?.waitsForOnline, false)
        XCTAssertEqual(writer(in: folder)?.onlineTries, 1)
        XCTAssertFalse(notes(in: folder).contains(MeetingFiles.offlineLine))
        XCTAssertTrue(notes(in: folder).contains("Made up."))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(MeetingFiles.earlierNotesFirstName).path))
    }

    /// Offline again before it left: still waiting, its try given back, and
    /// the rest wait too.
    func testARequestThatNeverLeftWaitsForTheNextTime() async throws {
        let older = try savedOffline()
        let newer = try savedOffline(startingAt: Self.start.addingTimeInterval(3_600))
        let server = Server([.offline])

        await service(server).redoNow()

        let asked = await server.asked
        XCTAssertEqual(asked, 1)
        for folder in [older, newer] {
            XCTAssertEqual(writer(in: folder)?.waitsForOnline, true)
            XCTAssertEqual(writer(in: folder)?.onlineTries, 0)
            XCTAssertTrue(notes(in: folder).contains(MeetingFiles.offlineLine))
        }
    }

    func testNewestFirstAFewAtATime() async throws {
        let folders = try (0..<4).map { try savedOffline(startingAt: Self.start.addingTimeInterval(Double($0) * 3_600)) }
        let answer = CloudNotes.Reply.notes(text: Self.answer, model: nil, usedFraction: nil)
        let server = Server(Array(repeating: answer, count: 4))

        await service(server).redoNow()

        let asked = await server.asked
        XCTAssertEqual(asked, CloudNotesRedo.perReturn)
        XCTAssertEqual(writer(in: folders[0])?.waitsForOnline, true, "the oldest waits for the next time")
        for folder in folders.dropFirst() { XCTAssertEqual(writer(in: folder)?.place, .online) }
    }

    func testSwitchedOffInSettingsTheyKeepWaiting() async throws {
        let folder = try savedOffline()
        let server = Server([])

        await service(server, setting: false).redoNow()

        let asked = await server.asked
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(writer(in: folder)?.waitsForOnline, true)
    }

    /// Too little said for notes at all: nothing to write online, ever.
    func testATooShortMeetingStopsWaiting() async throws {
        let folder = try savedOffline(said: ["Hello?", "Can you hear me?"])
        let server = Server([])

        await service(server).redoNow()

        let asked = await server.asked
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(writer(in: folder)?.waitsForOnline, false)
        XCTAssertFalse(notes(in: folder).contains(MeetingFiles.offlineLine))
    }

    // MARK: - A Mac that can't write notes

    /// A meeting the Mac couldn't write notes for, as left on disk when the
    /// call ended (`Self.ended`).
    private func savedWithoutNotes(_ missed: CloudNotesRedo.Missed) throws -> URL {
        try saved(writer: XCTUnwrap(CloudNotesRedo.withoutNotes(missed, now: Self.ended)))
    }

    private static let ended = start.addingTimeInterval(90)

    /// No Apple Intelligence, and online notes didn't work when the call
    /// ended: nothing is sent before the hour is up, then they are written,
    /// the call's first, with no empty page kept beside them.
    func testAFailedCallOnAMacThatCantWriteNotesEndsWithNotesWrittenLater() async throws {
        let folder = try savedWithoutNotes(.failed)
        XCTAssertTrue(notes(in: folder).contains(MeetingFiles.noNotesFailedLine))
        let server = Server([.notes(text: Self.answer, model: "gemini-test", usedFraction: nil)])
        let service = service(server)
        var redone: [Bool] = []
        service.onRedone = { _, _, first in redone.append(first) }

        service.now = { Self.ended.addingTimeInterval(30 * 60) }
        await service.redoNow()
        var asked = await server.asked
        XCTAssertEqual(asked, 0, "not before its hour")

        service.now = { Self.ended.addingTimeInterval(3_601) }
        await service.redoNow()

        asked = await server.asked
        XCTAssertEqual(asked, 1)
        let page = notes(in: folder)
        XCTAssertTrue(page.contains("A call to plan the launch."))
        XCTAssertFalse(page.contains(MeetingFiles.noNotesYet))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(MeetingFiles.earlierNotesFirstName).path),
                       "a page with no notes isn't kept")
        XCTAssertEqual(writer(in: folder)?.place, .online)
        XCTAssertEqual(writer(in: folder)?.waitsForOnline, false)
        XCTAssertNil(writer(in: folder)?.noNotesYet)
        XCTAssertEqual(redone, [true], "the call's first notes")
    }

    /// No Apple Intelligence, and this month's online notes were used when
    /// the call ended: the page says the day, a look is planned for it,
    /// nothing is sent before it, and the notes are written on it.
    func testAUsedMonthOnAMacThatCantWriteNotesEndsWithNotesWrittenOnTheDay() async throws {
        let until = Self.ended.addingTimeInterval(10 * 86_400)
        defaults.set(until, forKey: CloudNotesService.allowanceUntilKey)
        let folder = try savedWithoutNotes(.mac(.allowanceUsed(until: until)))
        let line = try XCTUnwrap(MeetingFiles.waitingLine(for: writer(in: folder)))
        XCTAssertTrue(line.hasPrefix(MeetingFiles.noNotesAllowanceLead))
        XCTAssertTrue(notes(in: folder).contains(line))
        let server = Server([.notes(text: Self.answer, model: "gemini-test", usedFraction: nil)])
        let service = service(server)
        var redone: [Bool] = []
        service.onRedone = { _, _, first in redone.append(first) }

        service.now = { until.addingTimeInterval(-60) }
        await service.redoNow()
        await service.planNextLook()
        XCTAssertEqual(service.nextLookAt, until)
        var asked = await server.asked
        XCTAssertEqual(asked, 0, "not before its day")

        service.now = { until.addingTimeInterval(60) }
        await service.redoNow()

        asked = await server.asked
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(notes(in: folder).contains("A call to plan the launch."))
        XCTAssertFalse(notes(in: folder).contains(MeetingFiles.noNotesYet))
        XCTAssertEqual(writer(in: folder)?.place, .online)
        XCTAssertEqual(redone, [true])
        await service.planNextLook()
        XCTAssertNil(service.nextLookAt, "nothing else waits for a day")
    }

    /// Sent on its hour and refused: this month's notes are used. It waits
    /// for the new day, its try given back, and the page says the day.
    func testARefusalMovesTheDayAndCostsNoTry() async throws {
        let folder = try savedWithoutNotes(.failed)
        let tried = Self.ended.addingTimeInterval(3_660)
        let resets = Self.ended.addingTimeInterval(20 * 86_400)
        let server = Server([.allowanceUsed(resetsAt: resets)])
        let service = service(server)
        service.now = { tried }

        await service.redoNow()

        let asked = await server.asked
        XCTAssertEqual(asked, 1)
        let waiting = try XCTUnwrap(writer(in: folder))
        XCTAssertTrue(waiting.waitsForOnline)
        XCTAssertEqual(waiting.onlineTries, 0, "a refusal costs no try")
        XCTAssertEqual(waiting.noNotesYet, .allowanceUsed)
        XCTAssertEqual(waiting.notBefore, resets)
        let page = notes(in: folder)
        XCTAssertTrue(page.contains(try XCTUnwrap(MeetingFiles.waitingLine(for: waiting))))
        XCTAssertFalse(page.contains(MeetingFiles.noNotesFailedLine))
    }

    /// Waiting for the network, and this month's notes turn out used: it
    /// learns the day without a request, and the page says it.
    func testAWaitingCallLearnsTheDayWithoutAsking() async throws {
        let folder = try savedWithoutNotes(.mac(.offline))
        XCTAssertTrue(notes(in: folder).contains(MeetingFiles.noNotesOfflineLine))
        let until = Self.ended.addingTimeInterval(5 * 86_400)
        defaults.set(until, forKey: CloudNotesService.allowanceUntilKey)
        let server = Server([])
        let service = service(server)
        service.now = { Self.ended.addingTimeInterval(60) }

        await service.redoNow()

        let asked = await server.asked
        XCTAssertEqual(asked, 0)
        let waiting = try XCTUnwrap(writer(in: folder))
        XCTAssertEqual(waiting.noNotesYet, .allowanceUsed)
        XCTAssertEqual(waiting.notBefore, until)
        XCTAssertEqual(waiting.onlineTries, 0)
        XCTAssertTrue(notes(in: folder).contains(try XCTUnwrap(MeetingFiles.waitingLine(for: waiting))))
        XCTAssertFalse(notes(in: folder).contains(MeetingFiles.noNotesOfflineLine))
    }

    /// Tried after an hour, six hours and a day; three tries without notes
    /// and it stops waiting. The page keeps the transcript and says why
    /// there are none, and stops promising.
    func testACallWithNoNotesStopsAfterThreeTries() async throws {
        let folder = try savedWithoutNotes(.failed)
        let server = Server([.unavailable, .unavailable, .unavailable])
        let service = service(server)
        var clock = Self.ended
        for (index, wait) in CloudNotesRedo.retryWaits.enumerated() {
            clock = clock.addingTimeInterval(wait + 1)
            let now = clock
            service.now = { now }
            await service.redoNow()
            let asked = await server.asked
            XCTAssertEqual(asked, index + 1)
            if index + 1 < CloudNotesRedo.retryWaits.count {
                XCTAssertEqual(writer(in: folder)?.notBefore,
                               now.addingTimeInterval(CloudNotesRedo.retryWaits[index + 1]))
                XCTAssertTrue(notes(in: folder).contains(MeetingFiles.noNotesFailedLine))
            }
        }
        let tryAgain = clock.addingTimeInterval(30 * 86_400)
        service.now = { tryAgain }
        await service.redoNow()

        let asked = await server.asked
        XCTAssertEqual(asked, 3, "never sent a fourth time")
        let stopped = try XCTUnwrap(writer(in: folder))
        XCTAssertFalse(stopped.waitsForOnline)
        XCTAssertNil(stopped.noNotesYet)
        XCTAssertNil(stopped.notBefore)
        let page = notes(in: folder)
        XCTAssertFalse(page.contains(MeetingFiles.noNotesYet))
        XCTAssertTrue(page.contains("No summary this time: Made up."))
    }

    /// The Mac's own notes, sent again and refused for the month: as before,
    /// never sent again and no day on the page.
    func testTheMacsNotesStillStopAtARefusal() async throws {
        let folder = try savedOffline()
        let server = Server([.allowanceUsed(resetsAt: Self.ended.addingTimeInterval(86_400))])
        let service = service(server)
        service.now = { Self.ended.addingTimeInterval(60) }

        await service.redoNow()

        let asked = await server.asked
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(writer(in: folder)?.waitsForOnline, false)
        XCTAssertNil(writer(in: folder)?.notBefore)
        XCTAssertFalse(notes(in: folder).contains(MeetingFiles.offlineLine))
        XCTAssertTrue(notes(in: folder).contains("Made up."))
    }
}
