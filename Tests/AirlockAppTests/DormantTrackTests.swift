import XCTest
@testable import AirlockApp

/// The media card goes dormant instead of disappearing.
///
/// The bug this prevents is a layout one: a banner that vanishes takes ~110pt
/// with it, the console jumps up under a pointer already reaching for it, and
/// the panel reads as broken rather than as the music having stopped. The case
/// nobody would check by hand is the opposite one — a memory shown beside a
/// track that is actually playing, which would be two answers to one question.
@MainActor
final class DormantTrackTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func track(_ title: String = "Hablan de Unión, Pt. 2",
                       player: MediaPlayerKind = .spotify,
                       playing: Bool = true) -> MediaPlayerState {
        MediaPlayerState(player: player, isPlaying: playing, title: title, artist: "Kaze",
                         artworkURL: nil, position: 33, duration: 245, fetchedAt: t0)
    }

    private func next(previous: MediaPlayerState?, next state: MediaPlayerState?,
                      existing: MediaWidgetModel.DormantTrack? = nil)
    -> MediaWidgetModel.DormantTrack? {
        MediaWidgetModel.DormantTrack.next(previous: previous, next: state,
                                           existing: existing, now: t0)
    }

    func testTheLastTrackIsRememberedWhenThePlayerQuits() {
        let dormant = next(previous: track(), next: nil)
        XCTAssertEqual(dormant?.title, "Hablan de Unión, Pt. 2")
        XCTAssertEqual(dormant?.artist, "Kaze")
        XCTAssertEqual(dormant?.player, .spotify)
        XCTAssertEqual(dormant?.since, t0)
    }

    /// The one that matters. A live card and a memory of one must never be on
    /// screen together.
    func testAnythingLoadedClearsTheMemory() {
        let existing = next(previous: track(), next: nil)
        XCTAssertNotNil(existing)
        XCTAssertNil(next(previous: nil, next: track(), existing: existing))
    }

    /// Including a different player — the memory is of "what was loaded", not
    /// of one app.
    func testADifferentPlayerStartingClearsTheMemory() {
        let existing = next(previous: track(), next: nil)
        XCTAssertNil(next(previous: nil,
                          next: track("Someone Else", player: .appleMusic),
                          existing: existing))
    }

    /// Poll after poll with nothing loaded is not a transition, so the memory
    /// must not be restamped — otherwise "2h ago" would read "now" forever.
    func testAnIdlePollKeepsTheOriginalTimestamp() {
        let first = next(previous: track(), next: nil)
        let later = MediaWidgetModel.DormantTrack.next(
            previous: nil, next: nil, existing: first, now: t0.addingTimeInterval(7200))
        XCTAssertEqual(later?.since, t0, "the memory aged, it did not happen again")
        XCTAssertEqual(later?.title, first?.title)
    }

    /// The bug this file did not catch. A memory is made by a TRANSITION, so a
    /// launch with the player already closed has none to see — which is why the
    /// card has to survive a relaunch rather than being rebuilt from one.
    func testAMemoryIsWorthKeepingForADay() {
        guard let dormant = next(previous: track(), next: nil) else {
            return XCTFail("expected a memory")
        }
        XCTAssertTrue(dormant.isFresh(at: t0.addingTimeInterval(60)))
        XCTAssertTrue(dormant.isFresh(at: t0.addingTimeInterval(8 * 3600)),
                      "closed it last night, opened the panel this morning")
        XCTAssertTrue(dormant.isFresh(at: t0.addingTimeInterval(23 * 3600)))
    }

    /// And dies of old age. "Last played three weeks ago" is not context — it is
    /// a dead card holding a slot something else could use.
    func testAStaleMemoryIsNotFresh() {
        guard let dormant = next(previous: track(), next: nil) else {
            return XCTFail("expected a memory")
        }
        XCTAssertFalse(dormant.isFresh(at: t0.addingTimeInterval(25 * 3600)))
        XCTAssertFalse(dormant.isFresh(at: t0.addingTimeInterval(21 * 86_400)))
    }

    /// It has to round-trip to survive the relaunch at all.
    func testItSurvivesEncoding() throws {
        guard let dormant = next(previous: track(), next: nil) else {
            return XCTFail("expected a memory")
        }
        let data = try JSONEncoder().encode(dormant)
        let decoded = try JSONDecoder().decode(MediaWidgetModel.DormantTrack.self, from: data)
        XCTAssertEqual(decoded, dormant)
    }

    func testNothingEverLoadedLeavesNothingToRemember() {
        XCTAssertNil(next(previous: nil, next: nil))
    }

    /// A paused track that then quits is still worth remembering — pausing and
    /// closing are the same story from the card's side.
    func testAPausedTrackIsRememberedToo() {
        XCTAssertEqual(next(previous: track(playing: false), next: nil)?.title,
                       "Hablan de Unión, Pt. 2")
    }
}
