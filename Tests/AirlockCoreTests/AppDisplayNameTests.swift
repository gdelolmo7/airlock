import XCTest
@testable import AirlockCore

/// The screenshot that started this: seven chips reading `com.bitwarden.desktop`
/// and `in.sinew.Enpass-Desktop` in the one list a person reads before trusting
/// a clipboard manager.
final class AppDisplayNameTests: XCTestCase {

    /// Every app Airlock ships in its skip list has a name, because it is our
    /// list. A new identifier added there without one is the bug returning.
    func testEveryDefaultIgnoredAppIsNamed() {
        for bundleID in PasteboardClassifier.defaultIgnoredApps {
            XCTAssertNotNil(AppDisplayName.known[bundleID],
                            "\(bundleID) is skipped but unnamed — it will render as an identifier")
        }
    }

    func testTheNamesAreTheOnesTheirMakersUse() {
        XCTAssertEqual(AppDisplayName.known["com.bitwarden.desktop"], "Bitwarden")
        XCTAssertEqual(AppDisplayName.known["in.sinew.Enpass-Desktop"], "Enpass")
        XCTAssertEqual(AppDisplayName.known["com.apple.keychainaccess"], "Keychain Access")
        XCTAssertEqual(AppDisplayName.known["com.agilebits.onepassword7"], "1Password 7")
    }

    // MARK: - The fallback, for apps nobody has named

    func testPlatformSuffixesAreDropped() {
        XCTAssertEqual(AppDisplayName.readable("com.bitwarden.desktop"), "Bitwarden")
        XCTAssertEqual(AppDisplayName.readable("in.sinew.Enpass-Desktop"), "Enpass")
        XCTAssertEqual(AppDisplayName.readable("com.example.Thing-Mac"), "Thing")
    }

    func testTheSellersCountryIsNotTheProduct() {
        XCTAssertEqual(AppDisplayName.readable("in.sinew.Enpass"), "Enpass")
        XCTAssertEqual(AppDisplayName.readable("io.example.Vault"), "Vault")
    }

    /// The guess is the LAST component, so an identifier that hides the product
    /// in the middle gets a poor name rather than a wrong-looking one. Live with
    /// it: the tooltip still carries the identifier, and anything worth naming
    /// properly belongs in `known` instead.
    func testAnInternalCodenameIsNotUnpickable() {
        XCTAssertEqual(AppDisplayName.readable("io.tailscale.ipn.macos"), "Ipn")
    }

    func testSpellingTheMakerChoseSurvives() {
        XCTAssertEqual(AppDisplayName.readable("com.lastpass.LastPass"), "LastPass")
        XCTAssertEqual(AppDisplayName.readable("net.antelle.keeweb"), "Keeweb")
    }

    func testNothingUsableLeavesTheIdentifierAlone() {
        XCTAssertEqual(AppDisplayName.readable(""), "")
        XCTAssertEqual(AppDisplayName.readable("Sketch"), "Sketch")
        // Every component is generic, so there is nothing better to say.
        XCTAssertEqual(AppDisplayName.readable("com.desktop"), "Desktop")
    }
}
