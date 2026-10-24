import Foundation
import XCTest
@testable import AirlockCore

/// On Free, the transcript and the notes-ready card say Plus would have told
/// the other side's voices apart, only where that is true and Free's
/// (`FreeVoicesHint`).
final class FreeVoicesHintTests: XCTestCase {
    private static let paid: [(name: String, plan: PlanSnapshot)] = [
        ("Plus", PlanSnapshot(plan: .plus, isPaid: true)),
        ("Pro", PlanSnapshot(plan: .pro, isPaid: true)),
        ("a trial from before plans", PlanSnapshot(plan: .plus, isPaid: false)),
    ]

    /// A finished call with `attendees` on the calendar, heard as Free hears
    /// it: everything from the other side one voice, "Them".
    private func call(attendees: [String]? = ["Ana García", "Tom Reed"], person: Int? = nil,
                      bundleID: String = "us.zoom.xos", ended: Bool = true,
                      theySpoke: Bool = true) -> MeetingRecord {
        let started = Date(timeIntervalSince1970: 1_790_413_200)
        return MeetingRecord(
            bundleID: bundleID, appName: "Zoom", startedAt: started,
            endedAt: ended ? started.addingTimeInterval(600) : nil,
            segments: [MeetingSegment(speaker: .me, start: 1, end: 4, text: "Morning, both.")]
                + (theySpoke ? [MeetingSegment(speaker: .them, start: 5, end: 9, text: "Morning!", person: person)]
                             : []),
            event: attendees.map { MeetingEvent(title: "Launch stand-up", start: started, attendees: $0) })
    }

    func testFreeCallWithTwoOthersOnTheInviteGetsTheHint() {
        XCTAssertTrue(FreeVoicesHint.shows(for: call(), plan: .free))
        XCTAssertTrue(FreeVoicesHint.shows(for: call(attendees: ["Ana", "Marc", "Lucía"]), plan: .free))
    }

    func testNobodyWhoPaysSeesIt() {
        for (name, plan) in Self.paid {
            XCTAssertFalse(FreeVoicesHint.shows(for: call(), plan: plan), name)
        }
    }

    func testNotWhereItWouldBeWrong() {
        XCTAssertFalse(FreeVoicesHint.shows(for: call(attendees: ["Mariana"]), plan: .free),
                       "one-to-one: \"Them\" is one person")
        XCTAssertFalse(FreeVoicesHint.shows(for: call(attendees: nil), plan: .free),
                       "no invite: it may have been one person")
        XCTAssertFalse(FreeVoicesHint.shows(for: call(attendees: []), plan: .free))
        XCTAssertFalse(FreeVoicesHint.shows(for: call(attendees: ["Ana", "  "]), plan: .free),
                       "a blank name is nobody")
        XCTAssertFalse(FreeVoicesHint.shows(for: call(bundleID: OngoingCall.inPersonBundleID), plan: .free),
                       "in person the lines are \"Someone\"")
        XCTAssertFalse(FreeVoicesHint.shows(for: call(ended: false), plan: .free), "still going")
        XCTAssertFalse(FreeVoicesHint.shows(for: call(theySpoke: false), plan: .free),
                       "nobody on the other side spoke")
        XCTAssertFalse(FreeVoicesHint.shows(for: call(person: 1), plan: .free),
                       "a call from a paid plan already told them apart")
    }

    /// Named in "Who's who", the other side is no longer "Them".
    func testNotOnceTheOtherSideHasAName() {
        var named = call()
        named.name(MeetingRecord.otherSide, as: "Ana and Tom")
        XCTAssertFalse(FreeVoicesHint.shows(for: named, plan: .free))
    }

    func testTheTranscriptLineNamesWhoWasThem() {
        XCTAssertEqual(FreeVoicesHint.who(of: call()), "Ana and Tom both show as \u{201C}Them\u{201D} on Free.")
        XCTAssertEqual(FreeVoicesHint.plusTells, "Plus tells each voice apart: Person 1, Person 2\u{2026}")
        XCTAssertEqual(FreeVoicesHint.who(["Ana", "Marc", "Lucía"]),
                       "Ana, Marc and Lucía all show as \u{201C}Them\u{201D} on Free.")
        XCTAssertEqual(FreeVoicesHint.who(["Ana", "Marc", "Lucía", "Joan", "Tom"]),
                       "Ana, Marc and 3 others all show as \u{201C}Them\u{201D} on Free.")
        XCTAssertEqual(FreeVoicesHint.who(["Ana", "Marc", "Lucía", "Joan"]),
                       "Ana, Marc and 2 others all show as \u{201C}Them\u{201D} on Free.")
    }

    func testTwoPeopleWithOneFirstNameKeepTheirWholeNames() {
        XCTAssertEqual(FreeVoicesHint.who(["Ana García", "ana López"]),
                       "Ana García and ana López both show as \u{201C}Them\u{201D} on Free.")
    }

    func testWithoutNamesItSaysEveryoneElse() {
        XCTAssertEqual(FreeVoicesHint.who([]), "Everyone else shows as \u{201C}Them\u{201D} on Free.")
    }

    /// Over Free's limit the card already has a Plus line: the voices join
    /// it, rather than a second line under it.
    func testTheLimitLineTakesTheVoicesIn() {
        let stopped = MeetingNotesFlow.LimitWord.stopped
        XCTAssertEqual(stopped.line(voicesToo: false), stopped.line)
        XCTAssertEqual(stopped.line(voicesToo: true),
                       "The first 30 minutes are saved. Plus takes notes of the whole call and tells each voice apart.")
        XCTAssertEqual(MeetingNotesFlow.LimitWord.stopsSoon.line(voicesToo: true),
                       MeetingNotesFlow.LimitWord.stopsSoon.line, "only once the call is over")
        XCTAssertEqual(FreeVoicesHint.afterCall,
                       "Everyone else was \u{201C}Them\u{201D} on Free. Plus tells each voice apart: Person 1, Person 2\u{2026}")
    }
}
