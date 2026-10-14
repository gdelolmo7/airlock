import XCTest
@testable import AirlockCore

/// Who was on a call, from its record alone: the names the notes window's
/// header shows, the count the Calls tab gives, and whose colour a name is.
final class CallPeopleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600)

    private func record(with invited: [String]? = nil, voices: [Int?] = [], youSpoke: Bool = true,
                        inPerson: Bool = false) -> MeetingRecord {
        var segments: [MeetingSegment] = []
        if youSpoke { segments.append(MeetingSegment(speaker: .me, start: 0, end: 2, text: "Morning, all.")) }
        for (index, person) in voices.enumerated() {
            let at = TimeInterval(10 + index * 10)
            segments.append(MeetingSegment(speaker: .them, start: at, end: at + 4,
                                           text: "Line number \(index) from across the table.", person: person))
        }
        return MeetingRecord(bundleID: inPerson ? OngoingCall.inPersonBundleID : "us.zoom.xos",
                             appName: inPerson ? "In person" : "Zoom", startedAt: start,
                             endedAt: start.addingTimeInterval(600), segments: segments,
                             event: invited.map { MeetingEvent(title: "Sync", start: start, attendees: $0) })
    }

    private func names(_ record: MeetingRecord) -> [String] {
        CallPeople.people(of: record).map(\.name)
    }

    // MARK: - Who

    func testAOneToOneCallIsYouAndTheOtherPerson() {
        let call = record(with: ["Ana"], voices: [nil])
        XCTAssertEqual(names(call), ["You", "Ana"])
        XCTAssertEqual(CallPeople.people(of: call).map(\.isYou), [true, false])
        XCTAssertEqual(CallPeople.count(of: call), 2)
        XCTAssertEqual(CallPeople.line(CallPeople.people(of: call)), "You and Ana")
    }

    /// The one name wins even when voices were numbered: a one-to-one call
    /// is never split, as the transcript has it.
    func testTheOneNameWinsOverNumberedVoices() {
        XCTAssertEqual(names(record(with: ["Ana"], voices: [1, 2])), ["You", "Ana"])
    }

    func testVoicesToldApartAreNamedAsTheTranscriptNamesThemInTheOrderHeard() {
        let call = record(with: ["Ana", "Tom"], voices: [2, 1, 2])
        XCTAssertEqual(names(call), ["You", "Person 2", "Person 1"])
        XCTAssertEqual(CallPeople.count(of: call), 3)
    }

    func testWithNoVoicesToldApartTheInviteNamesThem() {
        let call = record(with: ["Ana", " Tom ", ""], voices: [nil])
        XCTAssertEqual(names(call), ["You", "Ana", "Tom"])
        XCTAssertEqual(CallPeople.line(CallPeople.people(of: call)), "You, Ana and Tom")
    }

    func testWithNoNamesAtAllTheOtherSideIsThem() {
        let call = record(voices: [nil])
        XCTAssertEqual(names(call), ["You", "Them"])
        XCTAssertEqual(CallPeople.line(CallPeople.people(of: call)), "You and them")
    }

    func testNobodyElseHeardIsYouAlone() {
        XCTAssertEqual(names(record()), ["You"])
        XCTAssertEqual(CallPeople.count(of: record()), 1)
    }

    /// In the room nobody is known to be you: only the voices told apart.
    func testAMeetingInTheRoomIsItsVoicesOnly() {
        let room = record(voices: [1, 2, 3, 1], youSpoke: false, inPerson: true)
        XCTAssertEqual(names(room), ["Person 1", "Person 2", "Person 3"])
        XCTAssertEqual(CallPeople.count(of: room), 3)
        XCTAssertEqual(CallPeople.line(CallPeople.people(of: room)), "Person 1, Person 2 and Person 3")

        let untold = record(voices: [nil, nil], youSpoke: false, inPerson: true)
        XCTAssertEqual(names(untold), [])
        XCTAssertEqual(CallPeople.count(of: untold), 0)
        XCTAssertNil(CallPeople.line([]))
    }

    // MARK: - How many

    /// Everyone on the invite counts, heard or not.
    func testTheInviteCountsWhenItIsBigger() {
        let call = record(with: ["Ana", "Tom", "Eva", "Raj", "Li", "Bo"], voices: [1, 2])
        XCTAssertEqual(CallPeople.count(of: call), 7)
        XCTAssertEqual(CallPeople.line(CallPeople.people(of: call), count: 7), "You, Person 1 and 5 others")
    }

    func testTheLineNamesTwoThenCountsTheRest() {
        let people = ["You", "Ana", "Tom", "Eva"].map { CallPeople.Person(name: $0, isYou: $0 == "You") }
        XCTAssertEqual(CallPeople.line(people), "You, Ana and 2 others")
        XCTAssertEqual(CallPeople.line(Array(people.prefix(2)), count: 3), "You, Ana and 1 other")
        XCTAssertEqual(CallPeople.line([], count: 4), "4 people")
        XCTAssertEqual(CallPeople.line(Array(people.prefix(1))), "You")
    }

    // MARK: - Whose colour

    func testSeatsFollowTheOrderOnTheCall() {
        let people = ["You", "Ana García", "Tom"].map { CallPeople.Person(name: $0, isYou: $0 == "You") }
        XCTAssertEqual(CallPeople.seat(of: "You", in: people), .you)
        XCTAssertEqual(CallPeople.seat(of: "you", in: people), .you)
        XCTAssertEqual(CallPeople.seat(of: "Ana García", in: people), .other(0))
        XCTAssertEqual(CallPeople.seat(of: "ana", in: people), .other(0))
        XCTAssertEqual(CallPeople.seat(of: "Tom Ruiz", in: people), .other(1))
        XCTAssertEqual(CallPeople.seat(of: "Bob", in: people), .unknown)
        XCTAssertEqual(CallPeople.seat(of: MeetingRecord.someone, in: people), .unknown)
    }

    /// A numbered voice keeps its number's colour wherever it is first heard.
    func testANumberedVoiceSitsByItsNumber() {
        XCTAssertEqual(CallPeople.seat(of: "Person 3", in: []), .other(2))
        XCTAssertEqual(CallPeople.seat(of: "Person 1", in: []), .other(0))
    }
}
