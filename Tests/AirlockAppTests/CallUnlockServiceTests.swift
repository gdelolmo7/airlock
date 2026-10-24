@testable import AirlockCore
import AirlockTestSupport
import CryptoKit
import XCTest
@testable import AirlockApp

/// A stand-in for `/unlock`: opens the sealed key as the server would, or
/// answers what it is told to. Nothing here reaches the network.
private actor UnlockServer {
    private let key: Curve25519.KeyAgreement.PrivateKey
    private var answers: [CallUnlockWire.Reply?]
    private(set) var asked = 0

    /// A nil answer is the real one: the key, opened.
    init(_ key: Curve25519.KeyAgreement.PrivateKey, answers: [CallUnlockWire.Reply?] = []) {
        self.key = key
        self.answers = answers
    }

    func answer(_ body: Data) -> CallUnlockWire.Reply {
        asked += 1
        if !answers.isEmpty, let told = answers.removeFirst() { return told }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let enc = (object["enc"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let sealed = (object["key"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let keptUntil = object["keptUntil"] as? Int,
              var recipient = try? HPKE.Recipient(privateKey: key, ciphersuite: CallLock.suite,
                                                  info: CallLock.info, encapsulatedKey: enc),
              let opened = try? recipient.open(sealed, authenticating: CallLock.aad(
                  machine: object["machine"] as? String,
                  keptUntil: Date(timeIntervalSince1970: TimeInterval(keptUntil)))) else { return .wontOpen }
        return .key(opened)
    }
}

/// Locked calls looked after in the app: opened on a paid plan, removed at
/// the end of their week, left alone while the notes hold them. Made-up
/// calls only.
@MainActor
final class CallUnlockServiceTests: XCTestCase {
    private let startedAt = Date(timeIntervalSince1970: 1_791_468_600)
    private let server = Curve25519.KeyAgreement.PrivateKey()
    private let plus = PlanSnapshot(plan: .plus, isPaid: true)

    private var suite = ""
    private var defaults: UserDefaults!
    private var scratch: TestScratch!
    private var store: MeetingStore!

    override func setUp() {
        super.setUp()
        suite = "CallUnlockServiceTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        scratch = TestScratch("cus")
        store = MeetingStore(root: scratch.root)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        scratch = nil
        super.tearDown()
    }

    /// A finished Free call on disk, locked at 30 minutes, heard for 12 more.
    private func lockedCall() throws -> URL {
        let sealer = try CallLock.Sealer(publicKey: server.publicKey, machine: "MAC-1",
                                         keptUntil: CallLock.keptUntil(startedAt: startedAt), from: 30 * 60)
        var record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: startedAt)
        record.add(MeetingSegment(speaker: .them, start: 60, end: 64, text: "Before the limit."))
        record.locked = sealer.part
        record.add(MeetingSegment(speaker: .them, start: 1_810, end: 1_814, text: "The budget is forty thousand."),
                   sealing: sealer)
        record.endedAt = startedAt.addingTimeInterval(42 * 60)
        let folder = try store.makeFolder(for: record)
        try store.saveTranscript(record, in: folder)
        return folder
    }

    private func service(_ unlockServer: UnlockServer, plan: PlanSnapshot,
                         now: Date? = nil) -> CallUnlockService {
        let service = CallUnlockService(defaults: defaults, store: store,
                                        transport: { body, _ in await unlockServer.answer(body) })
        service.plan = { plan }
        service.access = { (URL(string: "https://unlock.invalid/unlock")!, "token") }
        let now = now ?? startedAt.addingTimeInterval(3_600)
        service.now = { now }
        return service
    }

    private func transcript(_ folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(MeetingFiles.transcriptName), encoding: .utf8)
    }

    func testOnPlusTheCallOpensAndTheTranscriptIsWhole() async throws {
        let folder = try lockedCall()
        XCTAssertFalse(try transcript(folder).contains("budget"))
        let unlockServer = UnlockServer(server)
        var changed = 0
        let service = service(unlockServer, plan: plus)
        service.onChanged = { changed += 1 }
        await service.look()

        let record = try XCTUnwrap(store.loadRecord(in: folder))
        XCTAssertNil(record.locked)
        XCTAssertEqual(record.openedMinutes, 12)
        XCTAssertTrue(try transcript(folder).contains("The budget is forty thousand."))
        XCTAssertEqual(changed, 1)

        await service.look()
        let asked = await unlockServer.asked
        XCTAssertEqual(asked, 1, "an open call isn't asked about again")
    }

    func testOnFreeNothingIsAsked() async throws {
        let folder = try lockedCall()
        let unlockServer = UnlockServer(server)
        await service(unlockServer, plan: .free).look()
        let asked = await unlockServer.asked
        XCTAssertEqual(asked, 0)
        XCTAssertNotNil(store.loadRecord(in: folder)?.locked?.key)
    }

    func testACallTheNotesHoldIsLeftForLater() async throws {
        let folder = try lockedCall()
        let unlockServer = UnlockServer(server)
        let service = service(unlockServer, plan: plus)
        service.isHolding = { $0.lastPathComponent == folder.lastPathComponent }
        await service.look()
        let asked = await unlockServer.asked
        XCTAssertEqual(asked, 0)
        XCTAssertNotNil(store.loadRecord(in: folder)?.locked)
    }

    func testAtTheEndOfTheWeekItIsRemovedOnFree() async throws {
        let folder = try lockedCall()
        let week = CallLock.keptUntil(startedAt: startedAt)
        await service(UnlockServer(server), plan: .free, now: week).look()
        let part = try XCTUnwrap(store.loadRecord(in: folder)?.locked)
        XCTAssertNil(part.key)
        XCTAssertEqual(part.lines, [])
        XCTAssertEqual(part.removedAt, week)
    }

    func testACallThatWontOpenIsNotAskedAgain() async throws {
        let folder = try lockedCall()
        let unlockServer = UnlockServer(server, answers: [.wontOpen])
        let service = service(unlockServer, plan: plus)
        await service.look()
        await service.look()
        let asked = await unlockServer.asked
        XCTAssertEqual(asked, 1)
        XCTAssertNotNil(store.loadRecord(in: folder)?.locked?.key, "kept until its week ends")
    }

    func testARefusedLicenceStopsTheRoundAndAsksNextTime() async throws {
        _ = try lockedCall()
        let unlockServer = UnlockServer(server, answers: [.notPaid, .unavailable])
        let service = service(unlockServer, plan: plus)
        await service.look()
        await service.look()
        await service.look()
        let asked = await unlockServer.asked
        XCTAssertEqual(asked, 3, "neither is about the call")
    }
}
