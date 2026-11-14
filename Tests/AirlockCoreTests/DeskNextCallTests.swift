import Foundation
import Testing
@testable import AirlockCore

@Suite struct DeskNextCallTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func event(_ id: String, _ start: Date, minutes: Double = 30, join: String? = "Join Zoom") -> DeskNextCall.Event {
        .init(id: id, title: id, start: start, end: start.addingTimeInterval(minutes * 60), join: join)
    }

    @Test func nextThenNowThenClear() {
        let a = event("a", at(14, 10)), b = event("b", at(14, 11))
        let next = DeskNextCall(events: [b, a])
        #expect(next.moment(at: at(14, 9, 50)) == .next(a, then: b))
        #expect(next.moment(at: at(14, 10, 5)) == .now(a, then: b))
        #expect(next.moment(at: at(14, 10, 30)) == .next(b, then: nil))
        #expect(next.moment(at: at(14, 11, 30)) == .clear)
        #expect(DeskNextCall.empty.moment(at: at(14, 9)) == .clear)
    }

    @Test func redrawsAtEveryStartAndEndStillToCome() {
        let a = event("a", at(14, 10)), b = event("b", at(14, 10, 30))
        let next = DeskNextCall(events: [a, b])
        // On a: b's countdown, its start (a's end) and its end.
        let during = next.changes(after: at(14, 10, 5))
        #expect(during.contains(at(14, 10, 30)) && during.contains(at(14, 11)))
        #expect(during.first == at(14, 10, 6))
        #expect(!during.contains(at(14, 10, 5)))
    }

    @Test func countsDownEachMinuteOfTheLastHour() {
        let next = DeskNextCall(events: [event("a", at(14, 12))])
        let ticks = next.changes(after: at(14, 10))
        #expect(ticks.first == at(14, 11, 0))
        #expect(ticks.contains(at(14, 11, 59)))
        #expect(ticks.contains(at(14, 12)) && ticks.contains(at(14, 12, 30)))
        #expect(ticks.count == 60 + 2)
    }

    @Test func startsInWholeMinutesRoundedUp() {
        #expect(DeskCallWords.startsIn(20) == "in 1 min")
        #expect(DeskCallWords.startsIn(11 * 60 + 59) == "in 12 min")
        #expect(DeskCallWords.startsIn(3600) == "in 1 h")
        #expect(DeskCallWords.startsIn(3600 + 5 * 60) == "in 1 h 5 min")
    }

    @Test func upcomingDropsEndedAndKeepsThreeInOrder() {
        let events = [event("d", at(14, 15)), event("old", at(14, 8)), event("c", at(14, 13)),
                      event("b", at(14, 12)), event("a", at(14, 11))]
        #expect(DeskNextCall.upcoming(events, now: at(14, 10)).map(\.id) == ["a", "b", "c"])
    }

    @Test func joinLinkNamesTheEventOnly() throws {
        let url = try #require(event("ev/1?x", at(14, 10)).joinURL)
        #expect(DeskNextCall.eventID(from: url) == "ev/1?x")
        #expect(event("a", at(14, 10), join: nil).joinURL == nil)
        #expect(DeskNextCall.eventID(from: URL(string: "airlock://join")!) == nil)
        #expect(DeskNextCall.eventID(from: URL(string: "airlock://join?event=")!) == nil)
        #expect(DeskNextCall.eventID(from: URL(string: "https://join?event=a")!) == nil)
    }

    @Test func notesLinkTakesAPlainFolderNameOnly() throws {
        let url = try #require(DeskNextCall.Notes(call: "x", folder: "2026-11-14 Design", at: at(14, 9)).openURL)
        #expect(DeskNextCall.callFolder(from: url) == "2026-11-14 Design")
        for bad in ["../x", ".hidden", "a/b", ""] {
            let link = DeskNextCall.Notes(call: "x", folder: bad, at: at(14, 9)).openURL!
            #expect(DeskNextCall.callFolder(from: link) == nil)
        }
    }

    @Test func notesReadyIsTodaysNewestWrittenCall() {
        func record(_ start: Date, topic: String, writer: MeetingNotesWriter?) -> MeetingRecord {
            var record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start, topic: topic)
            record.notesWriter = writer
            return record
        }
        let written = MeetingNotesWriter(place: .mac, model: nil, writtenAt: at(14, 9))
        let waiting = MeetingNotesWriter(place: .online, model: nil, writtenAt: at(14, 12), noNotesYet: .offline)
        let calls: [(folder: String, record: MeetingRecord)] = [
            ("yesterday", record(at(13, 18), topic: "Yesterday", writer: written)),
            ("morning", record(at(14, 9), topic: "Design review", writer: written)),
            ("waiting", record(at(14, 12), topic: "Waiting", writer: waiting)),
            ("none", record(at(14, 13), topic: "Unwritten", writer: nil)),
        ]
        let notes = DeskNextCall.notesReady(calls, now: at(14, 15), calendar: calendar)
        #expect(notes?.folder == "morning")
        #expect(DeskNextCall.notesReady(Array(calls.prefix(1)), now: at(14, 15), calendar: calendar) == nil)
    }

    @Test func snapshotRoundTrips() throws {
        let next = DeskNextCall(events: [event("a", at(14, 10))],
                                notes: .init(call: "c", folder: "f", at: at(14, 9)), surface: .lightGlass)
        let data = try DeskShelf.encoder().encode(next)
        #expect(try DeskShelf.decoder().decode(DeskNextCall.self, from: data) == next)
    }
}
