import XCTest
@testable import AirlockCore

/// A fader that vanishes when its app goes quiet moves every fader below it.
///
/// That is the bug the well exists for, and it is a pointer bug rather than a
/// cosmetic one: a video ending mid-reach turns the slider you were going for
/// into a different app's. These pin the two properties that make the well
/// worth having — position is preserved EXACTLY, and a live app is never shown
/// as idle.
final class MixSlotTests: XCTestCase {
    private func app(_ name: String, _ bundle: String) -> AudibleApp {
        AudibleApp(bundleID: bundle, pids: [1], name: name)
    }

    private var chrome: AudibleApp { app("Chrome", "com.google.Chrome") }
    private var spotify: AudibleApp { app("Spotify", "com.spotify.client") }
    private var zoom: AudibleApp { app("Zoom", "us.zoom.xos") }

    func testAQuietAppKeepsItsColumn() {
        let slots = AppMix.slots(live: [chrome], idle: [zoom],
                                      playing: nil, limit: 4).shown
        XCTAssertEqual(slots.map(\.app.name), ["Chrome", "Zoom"])
        XCTAssertEqual(slots.map(\.isIdle), [false, true])
    }

    /// THE property. The idle app must sit exactly where its fader sat, which
    /// means going through the same ordering rule rather than being appended.
    func testAnIdleAppHoldsItsAlphabeticalPlaceRatherThanMovingToTheEnd() {
        let slots = AppMix.slots(live: [zoom], idle: [chrome],
                                      playing: nil, limit: 4).shown
        XCTAssertEqual(slots.map(\.app.name), ["Chrome", "Zoom"],
                       "Chrome went quiet but must not jump behind Zoom")
        XCTAssertEqual(slots.first?.isIdle, true)
    }

    /// The pinned now-playing app still outranks everything, idle or not.
    func testThePinnedPlayerStaysFirst() {
        let slots = AppMix.slots(live: [chrome, spotify], idle: [],
                                      playing: spotify.bundleID, limit: 4).shown
        XCTAssertEqual(slots.first?.app.name, "Spotify")
    }

    /// An app cannot be both. Live always wins, so a stale idle entry for
    /// something that started again is ignored rather than duplicated.
    func testAnAppThatCameBackIsNeverAlsoIdle() {
        let slots = AppMix.slots(live: [chrome], idle: [chrome],
                                      playing: nil, limit: 4).shown
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots.first?.isIdle, false)
    }

    /// The case the pin exists for, all the way through the console.
    ///
    /// A PAUSED Spotify is not audible, so it arrives here as a row with no
    /// processes behind it while four other apps are making noise — and four is
    /// the whole console. Without the pin the cap hides precisely the app whose
    /// artwork the media card is showing, which is the panel contradicting
    /// itself: named up top, unturndownable below.
    ///
    /// Had no live caller for months: `AppVolumeModel.playingBundleID` was
    /// declared, read in three places, and assigned by nobody, so every call
    /// into here passed `playing: nil` and this rule never ran in the app.
    func testThePausedPlayerTheCardIsNamingSurvivesTheCap() {
        let noisy = (1...4).map { app("App\($0)", "com.test.app\($0)") }
        let paused = AudibleApp(bundleID: spotify.bundleID, pids: [], name: "Spotify")
        let result = AppMix.slots(live: noisy + [paused], idle: [],
                                  playing: spotify.bundleID, limit: 4)
        XCTAssertEqual(result.shown.first?.app.name, "Spotify")
        XCTAssertEqual(result.shown.count, 4)
        XCTAssertEqual(result.hidden, 1)
        XCTAssertEqual(result.shown.map(\.isIdle), [false, false, false, false],
                       "A pinned app with no audio behind it is not a well — it is a "
                       + "fader for something that is about to make sound again")
    }

    /// A pin outranks the cap even when the pinned app is a well: the reach it
    /// protects is the same one, and an app that went quiet two seconds ago is
    /// the likeliest thing on the card.
    func testAPinnedWellIsNotCappedEither() {
        let noisy = (1...4).map { app("App\($0)", "com.test.app\($0)") }
        let result = AppMix.slots(live: noisy, idle: [spotify],
                                  playing: spotify.bundleID, limit: 4)
        XCTAssertEqual(result.shown.first?.app.name, "Spotify")
        XCTAssertEqual(result.shown.first?.isIdle, true)
        XCTAssertEqual(result.hidden, 1)
    }

    func testWellsCountTowardsTheLimitLikeAnythingElse() {
        let extras = (1...4).map { app("App\($0)", "com.test.app\($0)") }
        let result = AppMix.slots(live: extras, idle: [zoom], playing: nil, limit: 4)
        XCTAssertEqual(result.shown.count, 4)
        XCTAssertEqual(result.hidden, 1)
    }

    func testNothingPlayingAndNothingRememberedIsEmpty() {
        XCTAssertTrue(AppMix.slots(live: [], idle: [], playing: nil, limit: 4).shown.isEmpty)
    }
}
