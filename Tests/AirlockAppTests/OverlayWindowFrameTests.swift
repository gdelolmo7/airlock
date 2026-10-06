import AppKit
import XCTest
import AirlockCore
import DynamicNotchKit
@testable import AirlockApp

/// The island's panel and the drop catcher are two windows that the AirDrop hit
/// test treats as one: a point delivered in the catcher's coordinates is
/// compared against a box laid out in the panel's, with no screen conversion
/// between them (`NotchController.isOverRail`). That is only sound while
/// the two windows occupy the same rectangle, in the same spaces.
///
/// Both halves used to be a comment asking two files to stay in step. These are
/// the assertions that replaced it.
final class OverlayWindowFrameTests: XCTestCase {
    /// Every screen shape, including the degenerate ones a display change can
    /// hand us mid-reconfiguration.
    private let screens: [CGRect] = [
        CGRect(x: 0, y: 0, width: 1512, height: 982),      // 14" MacBook Pro
        CGRect(x: 0, y: 0, width: 1470, height: 956),      // 13" Air
        CGRect(x: -1920, y: 300, width: 1920, height: 1080), // an external, left of origin
        CGRect(x: 0, y: 0, width: 0, height: 0),
    ]

    /// Half the screen wide, its full height, centred, flush to the top. Spelled
    /// out independently of the implementation so a "simplification" of the
    /// arithmetic has something to fail against.
    func testTheOverlayFrameIsHalfWidthFullHeightAndTopFlush() {
        for screen in screens {
            let frame = DynamicNotchOverlay.windowFrame(inScreenFrame: screen)

            XCTAssertEqual(frame.width, screen.width / 2, accuracy: 0.001, "\(screen)")
            XCTAssertEqual(frame.height, screen.height, accuracy: 0.001, "\(screen)")
            XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.001, "centred: \(screen)")
            XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.001, "top-flush: \(screen)")
        }
    }

    /// The one that matters: the catcher grown to the panel IS the panel's
    /// rectangle. Not "close enough" — the hit test does no conversion, so any
    /// offset at all silently moves the AirDrop box.
    @MainActor
    func testTheCatcherGrowsToExactlyTheKitPanelsFrame() throws {
        let screen = try XCTUnwrap(NSScreen.main)

        XCTAssertEqual(NotchDropCatcher.panelFrame(on: screen),
                       DynamicNotchOverlay.windowFrame(on: screen))
    }

    /// `PanelWidthLimit` (Core) has to know how wide the host window is, and
    /// Core cannot see the kit — so the number is transcribed. Transcriptions
    /// rot; this is the check that says so out loud.
    func testCoresTranscribedHostFractionMatchesTheKit() {
        XCTAssertEqual(PanelWidthLimit.hostWindowFraction,
                       DynamicNotchOverlay.widthFraction,
                       "PanelWidthLimit transcribes the kit's half-screen host window")
    }

    /// The decision this cluster implements: the island is wanted over
    /// full-screen apps, and `.fullScreenAuxiliary` is the only member that gets
    /// it there. `.canJoinAllSpaces` covers ordinary spaces and does not.
    func testTheOverlayIsPresentInFullScreenSpaces() {
        XCTAssertTrue(DynamicNotchOverlay.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(DynamicNotchOverlay.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(DynamicNotchOverlay.collectionBehavior.contains(.stationary))
    }
}
