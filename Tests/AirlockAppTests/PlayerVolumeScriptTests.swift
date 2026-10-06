import XCTest
@testable import AirlockApp

/// The scripts that move Spotify's and Music's own volume slider. `swift test`
/// cannot send an Apple event, but it can read the string, and both hazards
/// here are in the string: a fraction where the property wants a whole number,
/// and a comma where AppleScript wants a point.
final class PlayerVolumeScriptTests: XCTestCase {
    func testSetsAWholeNumberOutOfAHundred() {
        XCTAssertEqual(MediaPlayerController.setVolumeScript(0.574, for: .spotify),
                       #"if application "Spotify" is running then tell application "Spotify" to set sound volume to 57"#)
        XCTAssertEqual(MediaPlayerController.setVolumeScript(1, for: .appleMusic),
                       #"if application "Music" is running then tell application "Music" to set sound volume to 100"#)
    }

    func testClampsWhatTheSliderCannotMean() {
        XCTAssertTrue(MediaPlayerController.setVolumeScript(-0.2, for: .spotify).hasSuffix(" to 0"))
        XCTAssertTrue(MediaPlayerController.setVolumeScript(1.7, for: .spotify).hasSuffix(" to 100"))
        XCTAssertTrue(MediaPlayerController.setVolumeScript(.nan, for: .spotify).hasSuffix(" to 100"))
    }

    /// Quitting the player between the poll's check and its turn on the
    /// AppleScript queue must not launch it again: the check is in the script.
    func testNeverLaunchesAPlayerThatHasQuit() {
        XCTAssertEqual(MediaPlayerController.volumeScript(for: .spotify),
                       #"if application "Spotify" is running then tell application "Spotify" to get sound volume"#)
        XCTAssertTrue(MediaPlayerController.setVolumeScript(0.5, for: .appleMusic)
            .hasPrefix(#"if application "Music" is running then "#))
    }

    func testReadsTheVolumeBack() {
        XCTAssertEqual(MediaPlayerController.parseVolume("57"), 0.57)
        XCTAssertEqual(MediaPlayerController.parseVolume(" 40,0\n"), 0.4)
        XCTAssertEqual(MediaPlayerController.parseVolume("120"), 1)
        XCTAssertNil(MediaPlayerController.parseVolume("missing value"))
        XCTAssertNil(MediaPlayerController.parseVolume(nil))
    }
}
