import XCTest
@testable import AirlockApp

/// Which player the idle music card opens. The card replaces nothing at all,
/// so a wrong pick is the whole failure: one click that opens the app this
/// person never uses.
@MainActor
final class IdlePlayerChoiceTests: XCTestCase {
    private func pick(running: Set<MediaPlayerKind> = [], lastUsed: MediaPlayerKind? = nil,
                      installed: Set<MediaPlayerKind> = [.appleMusic]) -> MediaPlayerKind {
        IdlePlayerChoice.pick(running: running, lastUsed: lastUsed, isInstalled: installed.contains)
    }

    func testAMacWithOnlyMusicGetsMusic() {
        XCTAssertEqual(pick(), .appleMusic)
    }

    func testSpotifyInstalledAndNeverUsedGetsSpotify() {
        XCTAssertEqual(pick(installed: [.spotify, .appleMusic]), .spotify)
    }

    func testTheLastPlayerUsedWinsOverSpotifyBeingInstalled() {
        XCTAssertEqual(pick(lastUsed: .appleMusic, installed: [.spotify, .appleMusic]), .appleMusic)
    }

    func testALastPlayerSinceUninstalledIsSkipped() {
        XCTAssertEqual(pick(lastUsed: .spotify, installed: [.appleMusic]), .appleMusic)
    }

    func testAnOpenPlayerWinsOverTheLastOneUsed() {
        // Spotify sits open with nothing loaded: opening Music beside it
        // would be the odd thing to do.
        XCTAssertEqual(pick(running: [.spotify], lastUsed: .appleMusic,
                            installed: [.spotify, .appleMusic]), .spotify)
    }

    func testOfTwoOpenPlayersTheLastOneUsedWins() {
        XCTAssertEqual(pick(running: [.spotify, .appleMusic], lastUsed: .appleMusic,
                            installed: [.spotify, .appleMusic]), .appleMusic)
    }

    func testOfTwoOpenPlayersWithNoHistorySpotifyWins() {
        XCTAssertEqual(pick(running: [.spotify, .appleMusic], installed: [.spotify, .appleMusic]), .spotify)
    }

    func testNothingInstalledStillAnswersMusic() {
        // Music ships with macOS; a Mac that reports neither is answered with
        // the one most likely to come back.
        XCTAssertEqual(pick(installed: []), .appleMusic)
    }
}
