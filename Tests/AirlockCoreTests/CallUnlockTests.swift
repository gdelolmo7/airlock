import CryptoKit
import XCTest
@testable import AirlockCore

/// What the Mac does with a call's locked part: asks for its key on a paid
/// plan, removes it at the end of its week, and carries out the answer.
final class CallUnlockTests: XCTestCase {
    private let startedAt = Date(timeIntervalSince1970: 1_791_468_600)
    private let from: TimeInterval = 30 * 60
    private let server = Curve25519.KeyAgreement.PrivateKey()
    private let plus = PlanSnapshot(plan: .plus, isPaid: true)

    /// A finished call, locked at 30 minutes and heard for 12 more.
    private func locked() throws -> MeetingRecord {
        let sealer = try CallLock.Sealer(publicKey: server.publicKey, machine: "MAC-1",
                                         keptUntil: CallLock.keptUntil(startedAt: startedAt), from: from)
        var record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: startedAt)
        record.add(MeetingSegment(speaker: .them, start: 60, end: 64, text: "Before the limit."))
        record.locked = sealer.part
        record.add(MeetingSegment(speaker: .them, start: from + 10, end: from + 14, text: "After it."), sealing: sealer)
        record.endedAt = startedAt.addingTimeInterval(from + 12 * 60)
        return record
    }

    /// The key the server would send back.
    private func serverKey(_ part: LockedPart) throws -> Data {
        let key = try XCTUnwrap(part.key)
        var recipient = try HPKE.Recipient(privateKey: server, ciphersuite: CallLock.suite, info: CallLock.info,
                                           encapsulatedKey: try XCTUnwrap(Data(base64Encoded: key.encapsulated)))
        return try recipient.open(try XCTUnwrap(Data(base64Encoded: key.sealed)),
                                  authenticating: CallLock.aad(machine: part.machine, keptUntil: part.keptUntil))
    }

    // MARK: - What to do

    func testOnlyAPaidPlanAsks() {
        XCTAssertTrue(CallUnlock.opens(on: plus))
        XCTAssertTrue(CallUnlock.opens(on: PlanSnapshot(plan: .pro, isPaid: true)))
        XCTAssertFalse(CallUnlock.opens(on: .free))
        XCTAssertFalse(CallUnlock.opens(on: PlanSnapshot(plan: .plus, isPaid: false)), "overdue")
    }

    func testAFinishedLockedCallIsAskedForOnAPaidPlan() throws {
        let record = try locked()
        let now = startedAt.addingTimeInterval(3600)
        XCTAssertEqual(CallUnlock.step(for: record, plan: plus, now: now), .ask)
        XCTAssertEqual(CallUnlock.step(for: record, plan: .free, now: now), .nothing)
        XCTAssertEqual(CallUnlock.step(for: record, plan: plus, now: now, givenUp: true), .nothing)
    }

    func testACallStillBeingHeardIsLeftAlone() throws {
        var record = try locked()
        record.endedAt = nil
        XCTAssertEqual(CallUnlock.step(for: record, plan: plus, now: startedAt.addingTimeInterval(3600)), .nothing)
    }

    func testAnUnlockedCallHasNothingToDo() {
        let record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: startedAt)
        XCTAssertEqual(CallUnlock.step(for: record, plan: plus, now: startedAt), .nothing)
    }

    func testAtTheEndOfTheWeekItIsRemovedOnAnyPlan() throws {
        var record = try locked()
        let week = try XCTUnwrap(record.locked).keptUntil
        XCTAssertEqual(CallUnlock.step(for: record, plan: .free, now: week.addingTimeInterval(-1)), .nothing)
        XCTAssertEqual(CallUnlock.step(for: record, plan: .free, now: week), .remove)
        XCTAssertEqual(CallUnlock.step(for: record, plan: plus, now: week), .remove)
        record.locked?.removeIfDue(at: week)
        XCTAssertEqual(CallUnlock.step(for: record, plan: plus, now: week), .nothing, "once")
    }

    // MARK: - The answer

    func testTheKeyOpensTheCall() throws {
        var record = try locked()
        let key = try serverKey(try XCTUnwrap(record.locked))
        XCTAssertEqual(CallUnlock.apply(.key(key), to: &record), .opened(minutes: 12))
        XCTAssertNil(record.locked)
        XCTAssertEqual(record.openedMinutes, 12)
        XCTAssertEqual(record.segments.map(\.text), ["Before the limit.", "After it."])
    }

    func testAKeyThatDoesNotOpenGivesUpAndLeavesTheCallAsItWas() throws {
        var record = try locked()
        let before = record
        XCTAssertEqual(CallUnlock.apply(.key(Data(repeating: 1, count: 32)), to: &record), .givenUp)
        XCTAssertEqual(record, before)
    }

    func testTheOtherAnswers() throws {
        var record = try locked()
        XCTAssertEqual(CallUnlock.apply(.wontOpen, to: &record), .givenUp)
        XCTAssertEqual(CallUnlock.apply(.badToken, to: &record), .stop)
        XCTAssertEqual(CallUnlock.apply(.notPaid, to: &record), .stop)
        XCTAssertEqual(CallUnlock.apply(.otherMachine, to: &record), .stop)
        XCTAssertEqual(CallUnlock.apply(.unavailable, to: &record), .later)
        XCTAssertNotNil(record.locked?.key, "none of them touch the call")

        XCTAssertEqual(CallUnlock.apply(.gone, to: &record), .removed)
        XCTAssertNil(record.locked?.key)
        XCTAssertEqual(record.locked?.lines, [])
        XCTAssertEqual(record.lockedMinutes, 12, "still said once removed")
    }
}
