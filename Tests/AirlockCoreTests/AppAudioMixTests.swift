import XCTest
@testable import AirlockCore

/// The rules that decide whether Airlock is in somebody's audio path.
///
/// `needsTap` is the one that matters. Taking an app's audio over costs a
/// process tap, an aggregate device and a realtime thread — and puts a bug in
/// this app between a person and their music. At unity, unmuted, the answer has
/// to be no, or every audible app on the machine gets routed through us for the
/// privilege of being multiplied by one.
final class AppAudioMixTests: XCTestCase {

    // MARK: - When to take over

    func testUnityAndUnmutedNeedsNoTap() {
        XCTAssertFalse(AppMix.needsTap(gain: 1, isMuted: false))
    }

    func testFloatingPointNoiseAroundUnityStillNeedsNoTap() {
        // A slider dragged and released near the middle lands on 0.9999997, not
        // 1.0. Without a tolerance that silently routes audio through us forever
        // — the worst kind of "on", because nothing on screen says so.
        XCTAssertFalse(AppMix.needsTap(gain: 1.0000001, isMuted: false))
        XCTAssertFalse(AppMix.needsTap(gain: 0.9999997, isMuted: false))
    }

    func testAnyRealChangeNeedsATap() {
        XCTAssertTrue(AppMix.needsTap(gain: 0.5, isMuted: false))
        XCTAssertTrue(AppMix.needsTap(gain: 0, isMuted: false))
    }

    func testThereIsNoBoostAndAskingForOneIsNotATap() {
        // The ceiling is unity: above it this is gain into a hard clamp with no
        // limiter, which is distortion rather than loudness — and a 0–200 app
        // slider beside a 0–100 output slider made 90 sit left of 62. A stale
        // preference asking for 1.5 must land on unity, and unity means we stay
        // out of the audio path entirely.
        XCTAssertEqual(AppMix.unity, AppMix.maxGain)
        XCTAssertEqual(AppMix.unity, AppMix.clamp(1.5))
        XCTAssertFalse(AppMix.needsTap(gain: 1.5, isMuted: false),
                       "a clamped-to-unity level is no reason to take over an app's audio")
    }

    func testMuteNeedsATapEvenAtUnity() {
        // Mute is not "gain 0" — the level survives it, so the gain stays where
        // the person left it and only the tap enforces silence.
        XCTAssertTrue(AppMix.needsTap(gain: 1, isMuted: true))
    }

    // MARK: - What the level means

    func testMuteBeatsGain() {
        XCTAssertEqual(0, AppMix.multiplier(gain: 1.8, isMuted: true))
    }

    func testGainIsClampedToTheCeiling() {
        XCTAssertEqual(AppMix.maxGain, AppMix.clamp(99))
        XCTAssertEqual(0, AppMix.clamp(-1))
    }

    func testNonFiniteGainFallsBackToUnityRatherThanSilence() {
        // A NaN reaching the audio thread is a multiply that poisons the buffer.
        // Unity is the safe answer: it is what the app asked for in the first
        // place, and it is the value at which we get out of the way entirely.
        XCTAssertEqual(AppMix.unity, AppMix.clamp(.nan))
        XCTAssertEqual(AppMix.unity, AppMix.clamp(.infinity))
        XCTAssertFalse(AppMix.needsTap(gain: .nan, isMuted: false))
    }

    // MARK: - Which rows, in what order

    private func app(_ id: String, _ name: String) -> AudibleApp {
        AudibleApp(bundleID: id, pids: [1], name: name)
    }

    // MARK: - Keeping a running tap honest

    func testAHealthyTapIsLeftAlone() {
        XCTAssertEqual(.keep, AppMix.supervise(outputChanged: false,
                                               processesChanged: false,
                                               callbacksAdvancing: true,
                                               hasSomewhereToWrite: true))
    }

    func testAMovedOutputDeviceRebuilds() {
        // The aggregate names its output device once, at creation. Switch to
        // AirPods and this tap keeps writing to the speakers — and the app
        // cannot be heard anywhere else, because `.mutedWhenTapped` took its own
        // path away.
        XCTAssertEqual(.rebuild, AppMix.supervise(outputChanged: true,
                                                  processesChanged: false,
                                                  callbacksAdvancing: true,
                                                  hasSomewhereToWrite: true))
    }

    func testNewProcessesRebuild() {
        XCTAssertEqual(.rebuild, AppMix.supervise(outputChanged: false,
                                                  processesChanged: true,
                                                  callbacksAdvancing: true,
                                                  hasSomewhereToWrite: true))
    }

    func testATapThatStoppedDeliveringIsAbandonedRatherThanRebuilt() {
        // Abandon, not rebuild: it stopped for a reason we cannot name, and the
        // app is muted for as long as the tap exists. Destroying it is what
        // unmutes them, so the fail-open move is to let go.
        XCTAssertEqual(.abandon, AppMix.supervise(outputChanged: false,
                                                  processesChanged: false,
                                                  callbacksAdvancing: false,
                                                  hasSomewhereToWrite: true))
    }

    func testAStallIsExplainedByADeviceChangeAndRebuildsInstead() {
        // The precedence that makes this a function rather than two `if`s at the
        // call site. Switching output stops the old aggregate, so the very check
        // that spots a dead tap fires on a healthy one mid-switch. Abandoning
        // there would drop an app that was about to work again — and the level
        // the person set would silently stop applying.
        XCTAssertEqual(.rebuild, AppMix.supervise(outputChanged: true,
                                                  processesChanged: false,
                                                  callbacksAdvancing: false,
                                                  hasSomewhereToWrite: false))
        XCTAssertEqual(.rebuild, AppMix.supervise(outputChanged: false,
                                                  processesChanged: true,
                                                  callbacksAdvancing: false,
                                                  hasSomewhereToWrite: false))
    }

    func testCallbacksWithNowhereToWriteAreNotHealth() {
        // MEASURED, rebuilding onto an aggregate output device: buffers arrived
        // at the usual ninety a second with an output list of ZERO buffers. The
        // callback counter said healthy; every sample was dropped and the app
        // stayed muted. Liveness is being called AND having somewhere to write.
        XCTAssertEqual(.abandon, AppMix.supervise(outputChanged: false,
                                                  processesChanged: false,
                                                  callbacksAdvancing: true,
                                                  hasSomewhereToWrite: false))
    }

    // MARK: - Getting from a helper process to the app it belongs to

    func testPidsAreSortedSoAnUnchangedAppComparesEqual() {
        // The owner rebuilds the tap when the process set changes. Enumeration
        // order is not stable, so without sorting every refresh would look like
        // a change and tear down a working tap twice a second.
        XCTAssertEqual(AudibleApp(bundleID: "x", pids: [9, 3, 7], name: "X"),
                       AudibleApp(bundleID: "x", pids: [3, 7, 9], name: "X"))
    }

    func testAHelperResolvesToTheAppItIsNamedAfter() {
        // The case that made YouTube invisible: Chrome's audio comes from
        // `com.google.Chrome.helper`, which is not itself a running application.
        XCTAssertEqual("com.google.Chrome",
                       AppMix.owningBundleID(forHelper: "com.google.Chrome.helper",
                                             among: ["com.google.Chrome", "com.spotify.client"]))
    }

    func testLongestMatchWinsSoTheRowLandsOnTheRightApp() {
        XCTAssertEqual("com.brave.Browser",
                       AppMix.owningBundleID(forHelper: "com.brave.Browser.helper.renderer",
                                             among: ["com.brave", "com.brave.Browser"]))
    }

    func testAnAppIsItsOwnOwner() {
        XCTAssertEqual("com.spotify.client",
                       AppMix.owningBundleID(forHelper: "com.spotify.client",
                                             among: ["com.spotify.client"]))
    }

    func testNoGuessingWhenNothingMatches() {
        // Safari's media lives in `com.apple.WebKit.WebContent`, which shares no
        // prefix with `com.apple.Safari`. Returning nil loses the row; returning
        // a guess would put Safari's slider on somebody else's audio.
        XCTAssertNil(AppMix.owningBundleID(forHelper: "com.apple.WebKit.WebContent",
                                           among: ["com.apple.Safari", "com.google.Chrome"]))
    }

    func testAPrefixThatIsNotADottedBoundaryIsNotAMatch() {
        // "com.foo" must not adopt "com.foobar" — they are different vendors.
        XCTAssertNil(AppMix.owningBundleID(forHelper: "com.foobar.helper",
                                           among: ["com.foo"]))
    }

    func testThePlayingAppIsNeverTheOneTheCapHides() {
        let apps = [app("a", "Aaa"), app("b", "Bbb"), app("c", "Ccc"),
                    app("z", "Zzz")]
        let rows = AppMix.rows(apps, playing: "z", limit: 2)
        XCTAssertEqual(["z", "a"], rows.shown.map(\.bundleID))
        XCTAssertEqual(2, rows.hidden)
    }

    /// The pin is a bundle ID from the media card, and the media card can name
    /// a player that is not in this list at all — quit between one poll and the
    /// next, or simply running and silent. That has to be inert: no phantom
    /// row, no reordering, no crash on the way past.
    func testAPinNamingSomethingAbsentChangesNothing() {
        let apps = [app("a", "Aaa"), app("b", "Bbb"), app("c", "Ccc")]
        let rows = AppMix.rows(apps, playing: "com.nobody.here", limit: 2)
        XCTAssertEqual(["a", "b"], rows.shown.map(\.bundleID))
        XCTAssertEqual(1, rows.hidden)
    }

    func testOrderIsAlphabeticalAndDoesNotDependOnAnythingThatMoves() {
        // Sorting by level or loudness makes rows swap under the pointer
        // mid-drag. Boring and still beats clever and jumpy.
        let apps = [app("c", "Chrome"), app("a", "Ardour"), app("b", "Books")]
        XCTAssertEqual(["Ardour", "Books", "Chrome"],
                       AppMix.rows(apps, playing: nil, limit: 10).shown.map(\.name))
    }

    func testTiedNamesFallBackToBundleIDSoOrderIsStable() {
        let apps = [app("z.dup", "Same"), app("a.dup", "Same")]
        XCTAssertEqual(["a.dup", "z.dup"],
                       AppMix.rows(apps, playing: nil, limit: 10).shown.map(\.bundleID))
    }

    func testNothingIsHiddenWhenEverythingFits() {
        let apps = [app("a", "A"), app("b", "B")]
        let rows = AppMix.rows(apps, playing: nil, limit: 4)
        XCTAssertEqual(2, rows.shown.count)
        XCTAssertEqual(0, rows.hidden)
    }

    // MARK: - Who is not an app

    func testSystemAudioClientsAreNotOfferedAsApps() {
        // Core Audio's process list on an idle Mac is mostly daemons. A mixer
        // offering to mute the speech server is noise; offering to mute us is a
        // feedback loop.
        XCTAssertTrue(AppMix.isSystemProcess(bundleID: "com.apple.controlcenter"))
        XCTAssertTrue(AppMix.isSystemProcess(bundleID: "com.apple.CoreSpeech"))
        XCTAssertTrue(AppMix.isSystemProcess(bundleID: "com.airlock.app"))
        XCTAssertTrue(AppMix.isSystemProcess(bundleID: "com.agenticnotch.app"),
                      "pre-rename installs still exist — see IdentityMigration")
    }

    func testRealAppsAreNotFilteredOut() {
        XCTAssertFalse(AppMix.isSystemProcess(bundleID: "com.spotify.client"))
        XCTAssertFalse(AppMix.isSystemProcess(bundleID: "com.apple.Music"))
        XCTAssertFalse(AppMix.isSystemProcess(bundleID: "com.google.Chrome"))
    }
}
