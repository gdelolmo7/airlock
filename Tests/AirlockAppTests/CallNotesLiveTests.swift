import XCTest
import AirlockCore
@testable import AirlockApp

/// The lines a side holds back while its language is decided: shown where
/// they were said, at once, and never kept in the call.
@MainActor
final class CallNotesLiveTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let folder = URL(fileURLWithPath: "/var/empty/live-test")

    private func call(_ segments: [MeetingSegment]) -> MeetingRecord {
        MeetingRecord(bundleID: "com.google.Chrome", appName: "Google Chrome", startedAt: start,
                      segments: segments)
    }

    private let theirs = MeetingSegment(speaker: .them, start: 1, end: 4, text: "¿Qué tal el contrato?")
    private let mine = MeetingSegment(speaker: .me, start: 5, end: 8, text: "Bien, te lo mando hoy.")
    private let later = MeetingSegment(speaker: .them, start: 9, end: 12, text: "Vale, lo miro.")

    func testHeldLinesShowAtOnceWhereTheyWereSaid() {
        let live = CallNotesLive()
        live.follow(call([theirs]), in: folder)
        // A line waiting for the hand-over goes with them, not after.
        live.follow(call([theirs, later]), in: folder)
        live.hold([mine], from: .me)
        XCTAssertEqual(live.record?.segments, [theirs, mine, later])
    }

    func testDecidedLinesReplaceTheHeldOnesWithoutShowingTwice() {
        let live = CallNotesLive()
        live.follow(call([theirs]), in: folder)
        live.hold([mine], from: .me)
        // Decided: the line comes as the notes' own, and the held one goes
        // in the same hand-over.
        live.follow(call([theirs, mine]), in: folder)
        live.hold([], from: .me)
        XCTAssertEqual(live.record?.segments, [theirs, mine])
    }

    func testNamingTheCallNeverKeepsTheHeldLines() {
        let live = CallNotesLive()
        live.follow(call([theirs]), in: folder)
        live.hold([mine], from: .me)
        live.retitle(folder, as: "Contrato")
        live.rename([MeetingVoiceName(voice: 1, name: "Jorge")], in: folder)
        live.hold([], from: .me)
        XCTAssertEqual(live.record?.segments, [theirs])
        XCTAssertEqual(live.record?.topic, "Contrato")
    }

    func testANewCallStartsWithNothingHeld() {
        let live = CallNotesLive()
        live.follow(call([theirs]), in: folder)
        live.hold([mine], from: .me)
        live.follow(call([]), in: URL(fileURLWithPath: "/var/empty/live-test-2"))
        XCTAssertEqual(live.record?.segments, [])
    }
}
