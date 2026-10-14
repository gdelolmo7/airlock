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

    /// `answered` is the person's answer to writing notes online: yes unless
    /// a test says otherwise, nil for not asked yet.
    private func service(_ server: Server, switchedOn: Bool = true, paid: Bool = true,
                         answered: Bool? = true) -> CloudNotesService {
        defaults.set(switchedOn, forKey: CloudNotesService.enabledKey)
        if let answered {
            defaults.set(answered, forKey: CloudNotesService.settingKey)
        } else {
            defaults.removeObject(forKey: CloudNotesService.settingKey)
        }
        let service = CloudNotesService(defaults: defaults, store: store,
                                        transport: { _, _, _ in await server.answer() })
        service.entitlement = { paid ? Self.subscriber : .free }
        service.access = { (URL(string: "https://notes.invalid/notes")!, "token") }
        service.hasServer = { true }
        return service
    }

    private static func record(startingAt start: Date = start, said: [String]? = nil,
                               writer: MeetingNotesWriter? = nil) -> MeetingRecord {
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
                             endedAt: start.addingTimeInterval(90), segments: segments, notesWriter: writer)
    }

    // MARK: - One meeting

    func testSwitchedOffNothingIsAsked() async {
        let server = Server([])
        let attempt = await service(server, switchedOn: false).write(Self.record(), log: { _ in })
        guard case .mac(.hiddenSwitchOff) = attempt else { return XCTFail("\(attempt)") }
        let asked = await server.asked
        XCTAssertEqual(asked, 0)
    }

    func testOnlyASubscriberWithTheSettingOnIsAsked() async {
        let server = Server([])
        let free = await service(server, paid: false).write(Self.record(), log: { _ in })
        guard case .mac(.notSubscribed) = free else { return XCTFail("\(free)") }

        let off = await service(server, answered: false).write(Self.record(), log: { _ in })
        guard case .mac(.settingOff) = off else { return XCTFail("\(off)") }
        let asked = await server.asked
        XCTAssertEqual(asked, 0)
    }

    // MARK: - Asked once, before anything leaves

    /// Absent is not asked yet, which sends nothing; then yes, or no.
    func testTheAnswerIsReadThreeWays() {
        let service = service(Server([]), answered: nil)
        XCTAssertNil(service.answer)
        XCTAssertFalse(CloudNotesService.switchIsOn(in: defaults), "the switch shows off until a yes")
        defaults.set(true, forKey: CloudNotesService.settingKey)
        XCTAssertEqual(service.answer, true)
        XCTAssertTrue(CloudNotesService.switchIsOn(in: defaults))
        defaults.set(false, forKey: CloudNotesService.settingKey)
        XCTAssertEqual(service.answer, false)
        XCTAssertFalse(CloudNotesService.switchIsOn(in: defaults))
    }

    /// Turning the Settings switch on is the yes, and off the no.
    func testTheSettingsSwitchWritesTheAnswer() {
        let service = service(Server([]), answered: nil)
        CloudNotesService.setSwitch(true, in: defaults)
        XCTAssertEqual(service.answer, true)
        XCTAssertEqual(defaults.object(forKey: CloudNotesService.settingKey) as? Bool, true)
        CloudNotesService.setSwitch(false, in: defaults)
        XCTAssertEqual(service.answer, false)
        XCTAssertEqual(defaults.object(forKey: CloudNotesService.settingKey) as? Bool, false)
    }

    /// Not asked yet: the Mac writes the notes and the question goes under
    /// them. Nothing has left; the log says why and not a word said.
    func testNotAskedYetNothingLeavesAndTheQuestionIsDue() async {
        let server = Server([])
        var logged: [String] = []
        let attempt = await service(server, answered: nil).write(Self.record(), log: { logged.append($0) })
        guard case .mac(.notAsked) = attempt else { return XCTFail("\(attempt)") }
        let asked = await server.asked
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(logged, ["notes online: no, not asked yet"])
    }

    /// Never asked for a trial, nor over this month's allowance or while
    /// not eligible: those notes couldn't have gone online anyway.
    func testNothingIsAskedWhenTheNotesCouldNotGoOnlineAnyway() async {
        let server = Server([])
        let trial = await service(server, paid: false, answered: nil).write(Self.record(), log: { _ in })
        guard case .mac(.notSubscribed) = trial else { return XCTFail("\(trial)") }

        defaults.set(Date().addingTimeInterval(86_400), forKey: CloudNotesService.allowanceUntilKey)
        let used = await service(server, answered: nil).write(Self.record(), log: { _ in })
        guard case .mac(.allowanceUsed) = used else { return XCTFail("\(used)") }
        defaults.removeObject(forKey: CloudNotesService.allowanceUntilKey)

        defaults.set(Date().addingTimeInterval(86_400), forKey: CloudNotesService.notEligibleUntilKey)
        let refused = await service(server, answered: nil).write(Self.record(), log: { _ in })
        guard case .mac(.notEligible) = refused else { return XCTFail("\(refused)") }

        let asked = await server.asked
        XCTAssertEqual(asked, 0)
    }

    /// "Write online": the yes is kept, and this meeting's notes are written
    /// again online now, the Mac's page kept beside them.
    func testWriteOnlineSaysYesAndWritesThisMeetingAgainOnline() async throws {
        let folder = try saved(writer: .mac(at: Self.start))
        let server = Server([.notes(text: Self.answer, model: "gemini-test", usedFraction: nil)])
        let service = service(server, answered: nil)
        var redone: [(URL, MeetingNotes)] = []
        service.onRedone = { redone.append(($0, $1)) }

        let first = await service.write(Self.record(), log: { _ in })
        guard case .mac(.notAsked) = first else { return XCTFail("\(first)") }

        service.writeOnline(folder)
        XCTAssertEqual(service.answer, true)
        await service.redoing?.value

        let asked = await server.asked
        XCTAssertEqual(asked, 1)
        let page = notes(in: folder)
        XCTAssertTrue(page.contains("A call to plan the launch."))
        XCTAssertTrue(page.contains("Written online by Airlock"))
        let earlier = try String(contentsOf: folder.appendingPathComponent(MeetingFiles.earlierNotesFirstName),
                                 encoding: .utf8)
        XCTAssertTrue(earlier.contains("Made up."))
        XCTAssertEqual(writer(in: folder)?.place, .online)
        XCTAssertEqual(writer(in: folder)?.waitsForOnline, false)
        XCTAssertEqual(redone.map { $0.0.resolvingSymlinksInPath() }, [folder.resolvingSymlinksInPath()])
        XCTAssertEqual(redone.first?.1.summary, "A call to plan the launch.")
    }

    /// Notes already written online, or already sent once, are not sent again.
    func testWriteOnlineSendsNothingTwice() async throws {
        var sent = MeetingNotesWriter.mac(at: Self.start)
        sent.onlineTries = 1
        let folder = try saved(writer: sent)
        let server = Server([])
        let service = service(server, answered: nil)

        service.writeOnline(folder)
        await service.redoing?.value

        XCTAssertEqual(service.answer, true, "the yes holds all the same")
        let asked = await server.asked
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(writer(in: folder)?.place, .mac)
    }

    /// "Keep on this Mac": the no is kept, nothing is sent, and the next
    /// meeting doesn't ask again.
    func testKeepOnThisMacSaysNoAndIsNeverAskedAgain() async {
        let server = Server([])
        let service = service(server, answered: nil)
        service.keepOnMac()
        XCTAssertEqual(service.answer, false)
        XCTAssertFalse(CloudNotesService.switchIsOn(in: defaults))

        let next = await service.write(Self.record(), log: { _ in })
        guard case .mac(let reason) = next else { return XCTFail("\(next)") }
        XCTAssertEqual(reason, .settingOff)
        XCTAssertFalse(CloudNotesRoute.mac(reason).asks)
        let asked = await server.asked
        XCTAssertEqual(asked, 0)
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

    func testNotEligibleIsRememberedForADay() async throws {
        let server = Server([.notEligible])
        let service = service(server)
        let first = await service.write(Self.record(), log: { _ in })
        guard case let .mac(.notEligible(until)) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(until.timeIntervalSinceNow, CloudNotesAllowance.notEligibleFor, accuracy: 60)
        let second = await service.write(Self.record(), log: { _ in })
        guard case .mac(.notEligible) = second else { return XCTFail("\(second)") }
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
        service.onRedone = { folder, _ in redone.append(folder) }

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

        await service(server, answered: false).redoNow()

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
}
