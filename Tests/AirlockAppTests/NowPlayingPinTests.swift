import AirlockCore
import Observation
import XCTest
@testable import AirlockApp

/// Which app the media card is about, as the mixer below it has to read it.
///
/// One line of implementation and worth a file anyway, because the wrong
/// version of it is the bug this was written to fix rather than a variation on
/// it. `AppVolumeModel` lists apps that are AUDIBLE; a paused player is not.
/// Read the pin as "the app currently making sound" and the panel goes back to
/// naming a track over a list that omits it — green tests, working app, and a
/// media card you cannot turn down.
final class NowPlayingPinTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func track(_ player: MediaPlayerKind, playing: Bool) -> MediaPlayerState {
        MediaPlayerState(player: player, isPlaying: playing, title: "Get Free",
                         artist: "Major Lazer", artworkURL: nil,
                         position: 0, duration: 200, fetchedAt: t0)
    }

    func testAPlayingTrackPinsItsPlayer() {
        XCTAssertEqual(MediaPlayerKind.spotify.bundleID,
                       NowPlayingPin.bundleID(of: track(.spotify, playing: true)))
    }

    /// THE property. Paused is not "nothing is playing" — it is the card still
    /// showing a track, which is exactly when somebody reaches for its slider.
    func testAPausedTrackStillPinsItsPlayer() {
        XCTAssertEqual(MediaPlayerKind.spotify.bundleID,
                       NowPlayingPin.bundleID(of: track(.spotify, playing: false)))
    }

    func testNothingLoadedPinsNothing() {
        XCTAssertNil(NowPlayingPin.bundleID(of: nil))
    }

    /// The pin is delivered from `MediaWidgetModel.state`'s `didSet`, and that
    /// property is `private(set)` inside an `@Observable` class — so the
    /// Observation macro rewrites it into accessors and the observer has to
    /// survive the rewrite. It does today (`dormant` in the same file relies on
    /// it to persist), and if it ever stops the pin goes back to being written
    /// by nobody, silently, with every test in this file still green.
    ///
    /// A fixture rather than the real model, and it proves the LANGUAGE
    /// mechanism only: `state` is private(set), so no test can drive it, and
    /// the alternative — `refresh()` — sends AppleScript to whatever player
    /// happens to be running on the machine.
    @MainActor
    func testAPrivateSetObservablePropertyStillRunsItsDidSet() {
        let fixture = ObservedPinFixture()
        fixture.set("com.spotify.client")
        fixture.set("com.spotify.client")
        fixture.set(nil)
        XCTAssertEqual(fixture.seen, ["com.spotify.client", nil],
                       "One notification per CHANGE — a repeat must not churn the mixer")
    }

    /// The pin follows the card across players, so a list pinned to Spotify
    /// does not stay pinned to it once Music is the one on screen.
    func testThePinFollowsTheCardToAnotherPlayer() {
        let players = MediaPlayerKind.allCases
        guard players.count > 1 else { return }
        let ids = Set(players.map { NowPlayingPin.bundleID(of: track($0, playing: true)) })
        XCTAssertEqual(ids.count, players.count,
                       "Two players sharing a pin would put one app's slider on another's audio")
    }
}

/// The shape `MediaWidgetModel.state` is in, and nothing else. At file scope
/// because `@Observable` is an extension macro and cannot attach to a type
/// declared inside a function.
@MainActor
@Observable
private final class ObservedPinFixture {
    var seen: [String?] = []
    private(set) var value: String? {
        didSet {
            guard value != oldValue else { return }
            seen.append(value)
        }
    }
    func set(_ new: String?) { value = new }
}
