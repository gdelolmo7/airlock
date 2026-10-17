import XCTest
@testable import AirlockCore

final class CallEventMatchTests: XCTestCase {
    private let callStart = Date(timeIntervalSince1970: 1_791_468_600)

    private func candidate(_ title: String, minutes: Double = 0, allDay: Bool = false,
                           link: MeetingLink.Provider? = .zoom, invited: Int = 0,
                           others: [String] = []) -> CallEventMatch.Candidate {
        let start = callStart.addingTimeInterval(minutes * 60)
        return .init(title: title, start: start, end: start.addingTimeInterval(1_800), isAllDay: allDay,
                     link: link, invited: invited, others: others)
    }

    func testAMeetingWithALinkStartingNowIsTheCall() {
        let event = CallEventMatch.pick([candidate("Budget", others: ["Ana García"])],
                                        callStart: callStart, site: nil)
        XCTAssertEqual(event, MeetingEvent(title: "Budget", start: callStart, attendees: ["Ana García"]))
    }

    func testAnAllDayEventIsNeverTheCall() {
        XCTAssertNil(CallEventMatch.pick([candidate("Offsite", allDay: true)], callStart: callStart, site: nil))
    }

    func testTheStartMustBeWithinAQuarterOfAnHour() {
        XCTAssertNotNil(CallEventMatch.pick([candidate("Early", minutes: -15)], callStart: callStart, site: nil))
        XCTAssertNotNil(CallEventMatch.pick([candidate("Late", minutes: 15)], callStart: callStart, site: nil))
        XCTAssertNil(CallEventMatch.pick([candidate("Too early", minutes: -16)], callStart: callStart, site: nil))
        XCTAssertNil(CallEventMatch.pick([candidate("Too late", minutes: 16)], callStart: callStart, site: nil))
    }

    func testWithoutALinkItNeedsTwoPeopleInvited() {
        XCTAssertNil(CallEventMatch.pick([candidate("Focus time", link: nil, invited: 0)],
                                         callStart: callStart, site: nil))
        XCTAssertNil(CallEventMatch.pick([candidate("Just me", link: nil, invited: 1)],
                                         callStart: callStart, site: nil))
        XCTAssertNotNil(CallEventMatch.pick([candidate("Phone call", link: nil, invited: 2)],
                                            callStart: callStart, site: nil))
    }

    func testTheCallsOwnServiceWinsOverANearerMeeting() {
        let picked = CallEventMatch.pick([candidate("Teams sync", minutes: 0, link: .teams),
                                          candidate("Zoom review", minutes: 10, link: .zoom)],
                                         callStart: callStart, site: .zoom)
        XCTAssertEqual(picked?.title, "Zoom review")
    }

    func testOtherwiseTheNearestStartWins() {
        let picked = CallEventMatch.pick([candidate("Ten past", minutes: 10),
                                          candidate("Five to", minutes: -5),
                                          candidate("Seven past", minutes: 7)],
                                         callStart: callStart, site: nil)
        XCTAssertEqual(picked?.title, "Five to")
        let noMatch = CallEventMatch.pick([candidate("Teams", minutes: 8, link: .teams),
                                           candidate("Meet", minutes: 3, link: .googleMeet)],
                                          callStart: callStart, site: .zoom)
        XCTAssertEqual(noMatch?.title, "Meet", "no event on the call's service: nearest still wins")
    }

    func testAnAddressIsNotAName() {
        XCTAssertEqual(CallEventMatch.displayName("  Ana García "), "Ana García")
        XCTAssertNil(CallEventMatch.displayName("ana@example.com"))
        XCTAssertNil(CallEventMatch.displayName("   "))
        XCTAssertNil(CallEventMatch.displayName(nil))
    }

    /// A course code in the invite once took a whole class's voices.
    func testACodeIsNotAName() {
        XCTAssertNil(CallEventMatch.displayName("MKT0412ESP"))
        XCTAssertNil(CallEventMatch.displayName("B-204"))
        XCTAssertEqual(CallEventMatch.displayName("JOHN"), "JOHN")
        XCTAssertEqual(CallEventMatch.displayName("Sala 2"), "Sala 2")
    }

    func testDesktopCallAppsNameTheirService() {
        XCTAssertEqual(CallEventMatch.provider(ofApp: "us.zoom.xos"), .zoom)
        XCTAssertEqual(CallEventMatch.provider(ofApp: "com.microsoft.teams2"), .teams)
        XCTAssertNil(CallEventMatch.provider(ofApp: "com.apple.FaceTime"))
        XCTAssertNil(CallEventMatch.provider(ofApp: "com.google.Chrome"))
    }
}
