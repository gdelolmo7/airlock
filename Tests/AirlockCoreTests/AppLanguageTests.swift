import XCTest
@testable import AirlockCore

final class AppLanguageTests: XCTestCase {
    func testAutomaticIsSpanishOnlyWhenTheMacIsInSpanish() {
        XCTAssertEqual(AppLanguage.automatic.resolved(macLanguages: ["es-ES", "en-US"]), "es")
        XCTAssertEqual(AppLanguage.automatic.resolved(macLanguages: ["es"]), "es")
        XCTAssertEqual(AppLanguage.automatic.resolved(macLanguages: ["es-419"]), "es")
        XCTAssertEqual(AppLanguage.automatic.resolved(macLanguages: ["en-US", "es-ES"]), "en")
    }

    /// macOS alone would pick Spanish here, the first language the bundle
    /// has. The rule is the Mac's first language or English.
    func testAnotherFirstLanguageIsEnglishEvenWithSpanishFurtherDown() {
        XCTAssertEqual(AppLanguage.automatic.resolved(macLanguages: ["fr-FR", "es-ES"]), "en")
        XCTAssertEqual(AppLanguage.automatic.resolved(macLanguages: ["ca-ES", "es-ES"]), "en")
        XCTAssertEqual(AppLanguage.automatic.resolved(macLanguages: []), "en")
    }

    func testAPinnedChoiceIgnoresTheMac() {
        XCTAssertEqual(AppLanguage.spanish.resolved(macLanguages: ["en-US"]), "es")
        XCTAssertEqual(AppLanguage.english.resolved(macLanguages: ["es-ES"]), "en")
    }

    func testAMissingOrUnknownSettingIsAutomatic() {
        XCTAssertEqual(AppLanguage(storedValue: nil), .automatic)
        XCTAssertEqual(AppLanguage(storedValue: "klingon"), .automatic)
        XCTAssertEqual(AppLanguage(storedValue: "spanish"), .spanish)
    }
}
