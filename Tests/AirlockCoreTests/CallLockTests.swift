import CryptoKit
import XCTest
@testable import AirlockCore

/// A Free call past its notes limit is kept sealed: unreadable on the Mac,
/// and opened only with the key the server unseals for a paid plan.
final class CallLockTests: XCTestCase {
    private let startedAt = Date(timeIntervalSince1970: 1_791_468_600.75)
    private let from: TimeInterval = 30 * 60
    private let server = Curve25519.KeyAgreement.PrivateKey()

    private func sealer(machine: String? = "MAC-1") throws -> CallLock.Sealer {
        try CallLock.Sealer(publicKey: server.publicKey, machine: machine,
                            keptUntil: CallLock.keptUntil(startedAt: startedAt), from: from)
    }

    /// What the server does: the call's key, from the sealed key and what
    /// it was sealed with.
    private func serverOpens(_ part: LockedPart, machine: String?? = nil,
                             keptUntil: Date? = nil) throws -> SymmetricKey {
        let key = try XCTUnwrap(part.key)
        var recipient = try HPKE.Recipient(privateKey: server, ciphersuite: CallLock.suite, info: CallLock.info,
                                           encapsulatedKey: try XCTUnwrap(Data(base64Encoded: key.encapsulated)))
        let aad = CallLock.aad(machine: machine ?? part.machine, keptUntil: keptUntil ?? part.keptUntil)
        return SymmetricKey(data: try recipient.open(try XCTUnwrap(Data(base64Encoded: key.sealed)),
                                                     authenticating: aad))
    }

    private func record() -> MeetingRecord {
        MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: startedAt)
    }

    private func line(_ start: TimeInterval, _ text: String, _ speaker: MeetingSpeaker = .them) -> MeetingSegment {
        MeetingSegment(speaker: speaker, start: start, end: start + 4, text: text)
    }

    /// A call locked at 30 minutes, with a line before the lock and two after.
    private func locked() throws -> (MeetingRecord, CallLock.Sealer) {
        let sealer = try sealer()
        var record = record()
        record.add(line(60, "Before the limit."))
        record.locked = sealer.part
        record.add(line(from + 10, "  The budget is forty thousand.  "), sealing: sealer)
        record.add(line(from + 20, "Agreed.", .me), sealing: sealer)
        return (record, sealer)
    }

    // MARK: - Sealed

    func testLinesPastTheLockAreSealedAndOnlyTheServersKeyOpensThem() throws {
        let (record, _) = try locked()
        XCTAssertEqual(record.segments.map(\.text), ["Before the limit."])
        let part = try XCTUnwrap(record.locked)
        XCTAssertEqual(part.lines.map(\.start), [from + 10, from + 20])
        XCTAssertEqual(part.lines.map(\.speaker), [.them, .me])

        let file = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(file.contains("budget"), "the words are nowhere in the call's file")
        XCTAssertFalse(file.contains("Agreed"))

        let opened = try CallLock.open(part, with: try serverOpens(part))
        XCTAssertEqual(opened.map(\.text), ["The budget is forty thousand.", "Agreed."])
        XCTAssertEqual(opened.map(\.start), [from + 10, from + 20])
    }

    func testAnotherMacOrAnotherDateDoesNotOpenTheKey() throws {
        let (record, _) = try locked()
        let part = try XCTUnwrap(record.locked)
        XCTAssertThrowsError(try serverOpens(part, machine: "MAC-2"))
        XCTAssertThrowsError(try serverOpens(part, machine: .some(nil)))
        XCTAssertThrowsError(try serverOpens(part, keptUntil: part.keptUntil.addingTimeInterval(86_400)))
    }

    func testAWrongKeyOpensNoLine() throws {
        let (record, _) = try locked()
        XCTAssertThrowsError(try CallLock.open(try XCTUnwrap(record.locked), with: SymmetricKey(size: .bits256)))
    }

    func testEachCallHasItsOwnKey() throws {
        let one = try sealer(), two = try sealer()
        XCTAssertNotEqual(one.part.key, two.part.key)
        var part = two.part
        part.add(try one.seal(line(from + 1, "Hello")))
        XCTAssertThrowsError(try CallLock.open(part, with: try serverOpens(two.part)))
    }

    /// The date is part of what the key was sealed with, so it must read
    /// back from the file to the same second.
    func testTheLockReadsBackFromTheFileAndStillOpens() throws {
        let (record, _) = try locked()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(MeetingRecord.self, from: try encoder.encode(record))
        XCTAssertEqual(back.locked, record.locked)
        let part = try XCTUnwrap(back.locked)
        XCTAssertEqual(try CallLock.open(part, with: try serverOpens(part)).count, 2)
    }

    func testTheWeekIsCountedFromTheCallsStartInWholeSeconds() {
        let until = CallLock.keptUntil(startedAt: startedAt)
        XCTAssertEqual(until.timeIntervalSince1970, 1_791_468_600 + 7 * 86_400)
        XCTAssertEqual(String(decoding: CallLock.aad(machine: "MAC-1", keptUntil: until), as: UTF8.self),
                       "airlock-call-lock-v1|MAC-1|1792073400")
        XCTAssertEqual(String(decoding: CallLock.aad(machine: nil, keptUntil: until), as: UTF8.self),
                       "airlock-call-lock-v1||1792073400")
    }

    func testThePublicKeyIsThirtyTwoBytesOrNothing() {
        let raw = server.publicKey.rawRepresentation
        XCTAssertEqual(CallLock.publicKey(raw.base64EncodedString() + "\n")?.rawRepresentation, raw)
        XCTAssertNil(CallLock.publicKey(nil))
        XCTAssertNil(CallLock.publicKey(""))
        XCTAssertNil(CallLock.publicKey(Data(repeating: 1, count: 31).base64EncodedString()))
        XCTAssertNil(CallLock.publicKey("not base64"))
    }

    // MARK: - Nothing plain past the lock

    func testAPlainLinePastTheLockIsDropped() throws {
        var (record, _) = try locked()
        record.add(line(from + 30, "Should never be kept."))
        XCTAssertEqual(record.segments.map(\.text), ["Before the limit."])
        XCTAssertEqual(record.locked?.lines.count, 2)
    }

    func testAShadowLinePastTheLockIsDropped() throws {
        var (record, _) = try locked()
        record.addShadow(MeetingShadowLine(segment: line(50, "Antes."), language: "es_ES"))
        record.addShadow(MeetingShadowLine(segment: line(from + 10, "El presupuesto."), language: "es_ES"))
        XCTAssertEqual(record.shadow.map(\.segment.text), ["Antes."])
    }

    func testALineBegunBeforeTheLockStaysPlain() throws {
        var (record, sealer) = try locked()
        record.add(line(from - 2, "Started just before."), sealing: sealer)
        XCTAssertEqual(record.segments.map(\.text), ["Before the limit.", "Started just before."])
        record.add(line(from + 40, "   "), sealing: sealer)
        XCTAssertEqual(record.locked?.lines.count, 2, "blank is ignored")
    }

    /// One side heard again in another language from before the lock: its
    /// plain lines before the lock are replaced in plain, its sealed ones
    /// sealed, the other side's left alone, and nothing locked reaches the
    /// shadow.
    func testSwitchingLanguageOnALockedCall() throws {
        var (record, sealer) = try locked()
        record.add(line(from - 120, "Old plain."), sealing: sealer)
        record.switchLanguage(of: .them, at: from - 300, to: "es_ES",
                              lines: [line(from - 120, "Nuevo antes."), line(from + 10, "Nuevo después."),
                                      line(from + 15, "Not theirs.", .me)],
                              keptAs: "en_GB", sealing: sealer)
        XCTAssertEqual(record.segments.map(\.text), ["Before the limit.", "Nuevo antes."])
        XCTAssertEqual(record.shadow.map(\.segment.text), ["Old plain."])
        let part = try XCTUnwrap(record.locked)
        let opened = try CallLock.open(part, with: try serverOpens(part))
        XCTAssertEqual(opened.map(\.text), ["Nuevo después.", "Agreed."])
        XCTAssertEqual(record.listenings.last?.language, "es_ES")
    }

    func testWithoutALockTheSealingCallsAreThePlainOnes() throws {
        let sealer = try sealer()
        var record = record()
        record.add(line(from + 10, "Plain."), sealing: sealer)
        record.switchLanguage(of: .them, at: 0, to: "es_ES", lines: [line(from + 10, "Llano.")], sealing: sealer)
        XCTAssertEqual(record.segments.map(\.text), ["Llano."])
        XCTAssertNil(record.locked)
    }

    // MARK: - Opened, or gone after a week

    func testUnlockingMakesTheCallWholeAgain() throws {
        var (record, _) = try locked()
        record.stoppedAtLimit = from
        record.endedAt = startedAt.addingTimeInterval(from + 25 * 60)
        let part = try XCTUnwrap(record.locked)
        record.unlock(try CallLock.open(part, with: try serverOpens(part)))
        XCTAssertNil(record.locked)
        XCTAssertEqual(record.openedMinutes, 25, "what was opened is remembered, for the redo")
        XCTAssertNil(record.stoppedAtLimit)
        XCTAssertEqual(record.segments.map(\.text),
                       ["Before the limit.", "The budget is forty thousand.", "Agreed."])
        record.add(line(from + 50, "Heard again later."))
        XCTAssertEqual(record.segments.count, 4, "a plain line past the old lock is kept now")
    }

    func testAfterAWeekTheLinesAndTheKeyGo() throws {
        var (record, _) = try locked()
        var part = try XCTUnwrap(record.locked)
        XCTAssertTrue(part.opens(at: part.keptUntil.addingTimeInterval(-1)))
        XCTAssertFalse(part.removeIfDue(at: part.keptUntil.addingTimeInterval(-1)))
        XCTAssertTrue(part.removeIfDue(at: part.keptUntil))
        XCTAssertEqual(part.lines, [])
        XCTAssertNil(part.key)
        XCTAssertEqual(part.removedAt, part.keptUntil)
        XCTAssertFalse(part.opens(at: part.keptUntil.addingTimeInterval(-1)))
        XCTAssertFalse(part.removeIfDue(at: part.keptUntil.addingTimeInterval(60)), "once")
        record.locked = part
        record.endedAt = startedAt.addingTimeInterval(from + 12 * 60 + 20)
        XCTAssertEqual(record.lockedMinutes, 12, "still said once removed")
    }

    func testLockedMinutes() throws {
        var (record, _) = try locked()
        XCTAssertNil(record.lockedMinutes, "still going")
        record.endedAt = startedAt.addingTimeInterval(from + 10)
        XCTAssertEqual(record.lockedMinutes, 1, "one at least")
        record.endedAt = startedAt.addingTimeInterval(from + 90 * 60 + 31)
        XCTAssertEqual(record.lockedMinutes, 91)
        XCTAssertNil(self.record().lockedMinutes)
    }

    func testACallFromBeforeLocksOpensWithNone() throws {
        let json = #"{"bundleID":"us.zoom.xos","appName":"Zoom","startedAt":0,"segments":[]}"#
        let back = try JSONDecoder().decode(MeetingRecord.self, from: Data(json.utf8))
        XCTAssertNil(back.locked)
    }

    // MARK: - Asking the server

    func testTheUnlockRequestCarriesTheSealedKeyAndNoWords() throws {
        let (record, _) = try locked()
        let part = try XCTUnwrap(record.locked)
        let body = try XCTUnwrap(CallUnlockWire.requestBody(token: "tok", part: part))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["token", "keptUntil", "enc", "key", "machine"])
        XCTAssertEqual(object["token"] as? String, "tok")
        XCTAssertEqual(object["keptUntil"] as? Int, 1_792_073_400)
        XCTAssertEqual(object["enc"] as? String, part.key?.encapsulated)
        XCTAssertEqual(object["key"] as? String, part.key?.sealed)
        XCTAssertEqual(object["machine"] as? String, "MAC-1")
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(part.lines[0].sealed))

        let noMac = try sealer(machine: nil).part
        let other = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try XCTUnwrap(CallUnlockWire.requestBody(token: "tok", part: noMac))) as? [String: Any])
        XCTAssertNil(other["machine"])

        var gone = part
        gone.removeIfDue(at: part.keptUntil)
        XCTAssertNil(CallUnlockWire.requestBody(token: "tok", part: gone), "nothing to ask for")
    }

    func testTheServersAnswers() {
        let key = Data(repeating: 7, count: 32)
        let ok = Data(#"{"key":"\#(key.base64EncodedString())"}"#.utf8)
        XCTAssertEqual(CallUnlockWire.Reply.read(status: 200, body: ok), .key(key))
        XCTAssertEqual(CallUnlockWire.Reply.read(status: 200, body: Data(#"{"key":"AAAA"}"#.utf8)), .unavailable)
        XCTAssertEqual(CallUnlockWire.Reply.read(status: 200, body: Data("nope".utf8)), .unavailable)
        XCTAssertEqual(CallUnlockWire.Reply.read(status: 401, body: Data()), .badToken)
        XCTAssertEqual(CallUnlockWire.Reply.read(status: 402, body: Data()), .notPaid)
        XCTAssertEqual(CallUnlockWire.Reply.read(status: 403, body: Data()), .otherMachine)
        XCTAssertEqual(CallUnlockWire.Reply.read(status: 410, body: Data()), .gone)
        XCTAssertEqual(CallUnlockWire.Reply.read(status: 400, body: Data()), .wontOpen)
        XCTAssertEqual(CallUnlockWire.Reply.read(status: 422, body: Data()), .wontOpen)
        XCTAssertEqual(CallUnlockWire.Reply.read(status: 429, body: Data()), .unavailable)
        XCTAssertEqual(CallUnlockWire.Reply.read(status: 503, body: Data()), .unavailable)
        XCTAssertEqual(CallUnlockWire.Reply.key(key).logName, "opened", "never the key")
    }
}
