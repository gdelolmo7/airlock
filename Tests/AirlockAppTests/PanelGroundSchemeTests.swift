import SwiftUI
import XCTest
import AirlockCore
@testable import AirlockApp

/// The panel's light-or-dark comes from the GROUND it is drawn on, never from
/// System Settings.
///
/// Two consumers read it and they used to read different sources. `Theme`
/// resolves through the SwiftUI `colorScheme` that `NotchRootView` sets from the
/// chosen surface; the glass is AppKit material, and material resolves from the
/// window's `effectiveAppearance` — which nothing pinned, so it followed the
/// system. A Light Mode Mac on "Dark glass" therefore drew a light material
/// under a palette built for a dark one.
///
/// `groundScheme` is the one rule both now come from, kept pure so it can be
/// asserted without a window. What the controller adds is only where it lands.
final class PanelGroundSchemeTests: XCTestCase {

    // MARK: - Glass means what the setting says, in either system appearance

    func testDarkGlassExpandedIsDark() {
        XCTAssertEqual(NotchSurface.darkGlass.groundScheme(showing: .expanded), .dark)
    }

    /// Light glass is light on a Dark Mode Mac too — the mirror of the case that
    /// was measured wrong, where the window followed the system instead.
    func testLightGlassExpandedIsLight() {
        XCTAssertEqual(NotchSurface.lightGlass.groundScheme(showing: .expanded), .light)
    }

    /// The rule takes no argument for the system appearance, which is the point
    /// — there is nowhere for it to enter.
    func testSchemeFollowsTheSurfaceAndNothingElse() {
        for surface in NotchSurface.allCases {
            XCTAssertEqual(surface.groundScheme(showing: .expanded),
                           surface == .lightGlass ? .light : .dark,
                           "\(surface) expanded")
        }
    }

    // MARK: - The collapsed island is black hardware, whatever the panel is made of

    /// Glass is handed to our own view only while expanded — compact keeps the
    /// kit's black, because the island is fused to the camera cutout. So a
    /// light-glass panel must still collapse to a DARK island, or the compact
    /// glyphs go dark-on-black.
    func testLightGlassCollapsesToADarkIsland() {
        XCTAssertEqual(NotchSurface.lightGlass.groundScheme(showing: .compact), .dark)
        XCTAssertEqual(NotchSurface.lightGlass.groundScheme(showing: .hidden), .dark)
    }

    func testEverySurfaceIsDarkWhileCompact() {
        for surface in NotchSurface.allCases {
            XCTAssertEqual(surface.groundScheme(showing: .compact), .dark,
                           "\(surface) compact")
        }
    }

    /// Before the first transition there is no presentation yet. Black is the
    /// safe answer: it is the default surface and the kit's own ground.
    func testUnknownPresentationIsDark() {
        XCTAssertEqual(NotchSurface.lightGlass.groundScheme(showing: nil), .dark)
    }

    // MARK: - Black is black

    /// The reason this survived so long: the default ground is a literal colour
    /// and answers to no appearance at all, so nobody on it ever saw the fault.
    func testBlackIsDarkInEveryPresentation() {
        for showing in [IslandPresentation.expanded, .compact, .hidden] {
            XCTAssertEqual(NotchSurface.black.groundScheme(showing: showing), .dark,
                           "black \(showing)")
        }
    }
}
