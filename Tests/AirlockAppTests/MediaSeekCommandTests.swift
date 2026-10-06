import XCTest
@testable import AirlockApp

/// The seek command as it leaves for the player, and the capability that
/// decides whether it leaves at all.
///
/// An Apple event cannot be delivered from `swift test`, so what is checkable
/// here is the string — which is where the one failure that reaches other
/// people lives. A position written with a comma is a syntax error rather than
/// a wrong number, and it appears only on a Mac whose region uses one.
final class MediaSeekCommandTests: XCTestCase {

    func testSeekWritesAnAbsolutePositionIntoThePlayer() {
        XCTAssertEqual(MediaPlayerController.script(.seek(90.5), for: .spotify),
                       #"tell application "Spotify" to set player position to 90.500"#)
        XCTAssertEqual(MediaPlayerController.script(.seek(90.5), for: .appleMusic),
                       #"tell application "Music" to set player position to 90.500"#)
    }

    /// The separator is a period whatever the region is set to. `String(format:)`
    /// with no locale argument does not localize — this is what pins that, so
    /// swapping in a `NumberFormatter` or a locale-aware helper goes red here
    /// rather than in a bug report from France.
    func testThePositionNeverCarriesALocalisedSeparator() {
        for seconds in [0.5, 12.25, 3_600.125] {
            let script = MediaPlayerController.script(.seek(seconds), for: .spotify)
            XCTAssertNotNil(script)
            XCTAssertFalse(script?.contains(",") ?? true, "\(seconds)")
            XCTAssertTrue(script?.contains(".") ?? false, "\(seconds)")
        }
    }

    /// A drag released past the left edge, or a VoiceOver decrement at 0:00.
    /// The model clamps too; this is the second line, because a negative
    /// `player position` is refused by both players rather than treated as zero.
    func testANegativePositionNeverLeaves() {
        XCTAssertEqual(MediaPlayerController.script(.seek(-30), for: .appleMusic),
                       #"tell application "Music" to set player position to 0.000"#)
    }

    /// The transport is untouched by the seek case existing beside it.
    func testTheOtherCommandsAreUnchanged() {
        XCTAssertEqual(MediaPlayerController.script(.togglePlay, for: .spotify),
                       #"tell application "Spotify" to playpause"#)
        XCTAssertEqual(MediaPlayerController.script(.next, for: .appleMusic),
                       #"tell application "Music" to next track"#)
        XCTAssertEqual(MediaPlayerController.script(.previous, for: .appleMusic),
                       #"tell application "Music" to previous track"#)
    }

    /// Both shipping players declare `player position` writable — verified
    /// against their own dictionaries, not assumed. The property exists so that
    /// a player which cannot is a `false` here rather than a bar that silently
    /// swallows drags; the day one is added, `script` returns nil for it and
    /// `MediaWidgetModel.canSeek` stops offering the gesture.
    func testEveryShippingPlayerCanSeek() {
        for kind in MediaPlayerKind.allCases {
            XCTAssertTrue(kind.canSeek, "\(kind)")
            XCTAssertNotNil(MediaPlayerController.script(.seek(1), for: kind), "\(kind)")
        }
    }
}
