import AppKit
import XCTest
import DynamicNotchKit
@testable import AirlockApp

/// Which display the island lives on, and the one relation that has to hold
/// between the two windows that make it up.
///
/// The panel and the drop catcher are separate windows. The AirDrop hit test
/// compares a point delivered in the catcher's coordinates against a box laid
/// out in the panel's, with no screen conversion between them
/// (`NotchController.isOverRail`) — which is sound only because both
/// windows are `DynamicNotchOverlay.windowFrame` of the SAME screen.
/// `OverlayWindowFrameTests` already pins "same screen ⇒ same rectangle". This
/// file pins the other half, the half a display change threatens: that the two
/// pick the same screen at all.
///
/// It is a separate, pure rule because the live properties read
/// `NSScreen.screens`, which a test process cannot arrange, and because the two
/// choices are made in different files — the panel through `NotchScreen.target`
/// (also handed to the kit as its `screenProvider`, so its self-directed
/// rebuilds land in the same place), the catcher through `NotchScreen.catching`
/// and its own `hasNotch` guard.
final class NotchScreenChoiceTests: XCTestCase {
    /// Stand-ins for `NSScreen`, which cannot be constructed. The rule never
    /// looks inside a screen — only at which one it is — so identity is all a
    /// test needs.
    private let laptop = "laptop"
    private let external = "external"

    // MARK: - The relation

    /// THE INVARIANT. Whenever the catcher exists, the panel is on its screen.
    ///
    /// Swept over every arrangement rather than asserted once, because the ways
    /// this used to break were all "some other input won": the primary display
    /// was an external, `NSScreen.main` followed the pointer to the monitor, the
    /// lid-closed preference was on while the lid was open, or the island
    /// followed the main display off the laptop.
    func testThePanelAndTheCatcherNeverChooseDifferentScreens() {
        for notched in [laptop, nil] {
            for primary in [laptop, external, nil] {
                for follows in [true, false] {
                    for policy in [true, false] {
                        let panel = NotchScreenChoice.presenting(
                            physicallyNotched: notched, primary: primary, followsMain: follows,
                            allowsExternalWhenClosed: policy)
                        let catcher = NotchScreenChoice.catching(
                            physicallyNotched: notched, primary: primary, followsMain: follows,
                            allowsExternalWhenClosed: policy)

                        guard let catcher else { continue } // no cutout, no hit test
                        XCTAssertEqual(panel, catcher,
                                       "notched=\(notched ?? "-") primary=\(primary ?? "-") "
                                       + "follows=\(follows) policy=\(policy)")
                    }
                }
            }
        }
    }

    /// The same claim from the other side: the panel is never on a screen the
    /// catcher is absent from *while the catcher exists somewhere else*.
    func testTheyAreNeverBothPresentOnDifferentScreens() {
        for notched in [laptop, external, nil] {
            for primary in [laptop, external, nil] {
                for follows in [true, false] {
                    for policy in [true, false] {
                        let panel = NotchScreenChoice.presenting(
                            physicallyNotched: notched, primary: primary, followsMain: follows,
                            allowsExternalWhenClosed: policy)
                        let catcher = NotchScreenChoice.catching(
                            physicallyNotched: notched, primary: primary, followsMain: follows,
                            allowsExternalWhenClosed: policy)

                        XCTAssertTrue(panel == nil || catcher == nil || panel == catcher,
                                      "panel=\(panel ?? "-") catcher=\(catcher ?? "-")")
                    }
                }
            }
        }
    }

    // MARK: - The rule itself

    /// Following the main display (the default): a monitor set as main in
    /// System Settings takes the island even with the lid open, and the
    /// catcher stands down, since the notch it would sit over has no island.
    func testFollowingTheMainDisplayPutsTheIslandOnItAndTheCatcherAway() {
        XCTAssertEqual(NotchScreenChoice.presenting(physicallyNotched: laptop, primary: external,
                                                    followsMain: true, allowsExternalWhenClosed: false), external)
        XCTAssertNil(NotchScreenChoice.catching(physicallyNotched: laptop, primary: external,
                                                followsMain: true, allowsExternalWhenClosed: false))
        // The laptop as main: nothing changes, the catcher included.
        XCTAssertEqual(NotchScreenChoice.presenting(physicallyNotched: laptop, primary: laptop,
                                                    followsMain: true, allowsExternalWhenClosed: false), laptop)
        XCTAssertEqual(NotchScreenChoice.catching(physicallyNotched: laptop, primary: laptop,
                                                  followsMain: true, allowsExternalWhenClosed: false), laptop)
        // Lid shut: the main display, whatever the lid-closed preference says.
        XCTAssertEqual(NotchScreenChoice.presenting(physicallyNotched: nil, primary: external,
                                                    followsMain: true, allowsExternalWhenClosed: false), external)
        // Focus elsewhere never moves it: the primary, not `NSScreen.main`.
        XCTAssertEqual(NotchScreenChoice.measuring(physicallyNotched: laptop, primary: external, main: laptop,
                                                   followsMain: true, allowsExternalWhenClosed: false), external)
    }

    /// Not following it, a cutout outranks everything. This is the
    /// docked-external case: plug in a monitor that becomes the primary
    /// display, or move the pointer to it so it becomes `NSScreen.main`, and the
    /// island still belongs to the laptop.
    func testACutoutOutranksThePrimaryAndTheMain() {
        XCTAssertEqual(NotchScreenChoice.presenting(physicallyNotched: laptop, primary: external,
                                                    allowsExternalWhenClosed: false), laptop)
        XCTAssertEqual(NotchScreenChoice.presenting(physicallyNotched: laptop, primary: external,
                                                    allowsExternalWhenClosed: true), laptop)
        XCTAssertEqual(NotchScreenChoice.presenting(physicallyNotched: laptop, primary: nil,
                                                    allowsExternalWhenClosed: false), laptop)
    }

    /// Clamshell, preference off: nowhere. Nil is a real answer and not a
    /// failure — the kit's `screenProvider` reads it as "no window", and
    /// `IslandPresentation.resolve` as hidden. The whole layout is built around
    /// a physical cutout, so a plain monitor is opt-in.
    func testWithNoCutoutAndNoPreferenceThePanelPresentsNowhere() {
        XCTAssertNil(NotchScreenChoice.presenting(physicallyNotched: nil, primary: external,
                                                  allowsExternalWhenClosed: false))
    }

    /// Clamshell, preference on: the external, and only then.
    func testTheExternalFallbackIsOptIn() {
        XCTAssertEqual(NotchScreenChoice.presenting(physicallyNotched: nil, primary: external,
                                                    allowsExternalWhenClosed: true), external)
        XCTAssertNil(NotchScreenChoice.presenting(physicallyNotched: nil, primary: nil,
                                                  allowsExternalWhenClosed: true),
                     "opted in with no screen at all is still nowhere")
    }

    /// The catcher needs something to sit over and has no fallback: it is the
    /// notched screen or nothing, whatever the preference says.
    func testTheCatcherHasNoFallback() {
        XCTAssertEqual(NotchScreenChoice.catching(physicallyNotched: laptop, primary: external,
                                                  allowsExternalWhenClosed: true), laptop)
        XCTAssertNil(NotchScreenChoice.catching(physicallyNotched: String?.none, primary: external,
                                                allowsExternalWhenClosed: true))
        XCTAssertNil(NotchScreenChoice.catching(physicallyNotched: String?.none, primary: external,
                                                followsMain: true, allowsExternalWhenClosed: true))
    }

    // MARK: - Lid shut, and the layout's screen

    /// THE SECOND RELATION. The layout cancels a top inset the kit added on the
    /// panel's screen, so wherever the panel presents is the screen the layout
    /// measures — whichever display has keyboard focus. Swept like the first.
    func testTheLayoutAlwaysMeasuresThePanelsScreen() {
        for notched in [laptop, nil] {
            for primary in [laptop, external, nil] {
                for focused in [laptop, external, "other", nil] {
                    for follows in [true, false] {
                        for policy in [true, false] {
                            let panel = NotchScreenChoice.presenting(
                                physicallyNotched: notched, primary: primary, followsMain: follows,
                                allowsExternalWhenClosed: policy)
                            let measured = NotchScreenChoice.measuring(
                                physicallyNotched: notched, primary: primary, main: focused, followsMain: follows,
                                allowsExternalWhenClosed: policy)

                            guard let panel else { continue } // nowhere to draw, nothing to agree with
                            XCTAssertEqual(measured, panel,
                                           "notched=\(notched ?? "-") primary=\(primary ?? "-") "
                                           + "focused=\(focused ?? "-") follows=\(follows) policy=\(policy)")
                        }
                    }
                }
            }
        }
    }

    /// Two monitors, lid shut. `NSScreen.main` follows the keyboard, so an
    /// island that read it rested on one display and opened its panel on the
    /// other. The primary display does not move: the island, its panel and the
    /// numbers the layout reads all stay on it.
    func testWithTheLidShutFocusElsewhereDoesNotMoveTheIsland() {
        let left = "left", right = "right"
        let panel = NotchScreenChoice.presenting(physicallyNotched: nil, primary: left,
                                                 allowsExternalWhenClosed: true)
        XCTAssertEqual(panel, left)
        for focused in [left, right, nil] {
            XCTAssertEqual(NotchScreenChoice.measuring(physicallyNotched: nil, primary: left, main: focused,
                                                       allowsExternalWhenClosed: true),
                           left, "focused=\(focused ?? "-")")
        }
    }

    /// With nowhere to present, a layout still needs numbers, so measuring
    /// falls back as `NotchScreen.notched` always did: the focused display,
    /// then the primary. Nil only with no display at all.
    func testWithNowhereToPresentMeasuringStillAnswers() {
        XCTAssertEqual(NotchScreenChoice.measuring(physicallyNotched: nil, primary: external, main: "other",
                                                   allowsExternalWhenClosed: false), "other")
        XCTAssertEqual(NotchScreenChoice.measuring(physicallyNotched: nil, primary: external, main: nil,
                                                   allowsExternalWhenClosed: false), external)
        XCTAssertNil(NotchScreenChoice.measuring(physicallyNotched: String?.none, primary: nil, main: nil,
                                                 allowsExternalWhenClosed: true))
    }

    // MARK: - Why the relation is load-bearing

    /// What agreeing on a screen actually buys, and what disagreeing would cost.
    /// The shared frame function is only a guarantee for identical screens; two
    /// displays of different geometry produce two rectangles, and the hit test
    /// converts between them not at all — so the AirDrop box would silently move
    /// to somewhere the pointer never goes.
    func testTheSharedFrameFunctionOnlyAgreesOnTheSameScreen() {
        let laptopFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let externalFrame = CGRect(x: -1920, y: 300, width: 1920, height: 1080)

        XCTAssertEqual(DynamicNotchOverlay.windowFrame(inScreenFrame: laptopFrame),
                       DynamicNotchOverlay.windowFrame(inScreenFrame: laptopFrame))
        XCTAssertNotEqual(DynamicNotchOverlay.windowFrame(inScreenFrame: laptopFrame),
                          DynamicNotchOverlay.windowFrame(inScreenFrame: externalFrame),
                          "different screens, different rectangles — hence the invariant above")
    }
}
