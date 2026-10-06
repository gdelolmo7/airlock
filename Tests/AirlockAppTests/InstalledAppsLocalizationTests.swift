import XCTest
@testable import AirlockApp

/// The format assumptions behind localized app aliases, checked against the
/// system's own bundles — the one part of the alias feature that can rot
/// under a macOS update without any code changing.
///
/// Deliberately reads real bundles rather than fixtures: the claim under test
/// is "macOS system apps carry their Spanish names in `InfoPlist.loctable`,
/// keyed by language code", and a fixture would only prove the parser agrees
/// with itself. Skips rather than fails where a bundle is absent, so an
/// unusual install does not read as a regression.
final class InstalledAppsLocalizationTests: XCTestCase {

    func testMusicCarriesItsSpanishName() throws {
        let path = "/System/Applications/Music.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                          "no Music.app on this system")
        let aliases = InstalledApps.localizedNames(appPath: path, name: "Music",
                                                   languages: ["es"])
        XCTAssertEqual(aliases, ["Música"],
                       "the loctable format assumption no longer holds")
    }

    func testNoLanguagesMeansNoReads() {
        XCTAssertEqual(InstalledApps.localizedNames(appPath: "/System/Applications/Music.app",
                                                    name: "Music", languages: []),
                       [])
    }

    func testAnUnlocalizedAppContributesNothing() throws {
        // Spotify is Spotify everywhere; absent, any app without an es
        // localization would do, but asserting on a named one keeps the
        // failure message meaningful.
        let path = "/Applications/Spotify.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                          "no Spotify.app on this system")
        XCTAssertEqual(InstalledApps.localizedNames(appPath: path, name: "Spotify",
                                                    languages: ["es"]),
                       [])
    }
}
