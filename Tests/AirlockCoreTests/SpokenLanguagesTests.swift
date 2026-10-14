import XCTest
@testable import AirlockCore

/// The case these exist for: an English Mac, a Spanish mouth, and a dictation
/// that heard neither until somebody opened Settings.
final class SpokenLanguagesTests: XCTestCase {
    private let available = ["de_DE", "en_GB", "en_US", "es_419", "es_ES", "fr_FR", "pt_BR"]

    // MARK: - The reported case

    func testEnglishMacThatAlsoReadsSpanishIsOfferedSpanish() {
        XCTAssertEqual(SpokenLanguages.suggestedSecond(preferred: ["en-GB", "es-ES"],
                                                       primary: "",
                                                       available: available),
                       "es_ES")
    }

    func testTheirOwnRegionWinsWhenSeveralExist() {
        // es_419 (Latin America) sorts before es_ES, so picking the first match
        // would hand a Spaniard the wrong Spanish.
        XCTAssertEqual(SpokenLanguages.suggestedSecond(preferred: ["en-US", "es-ES"],
                                                       primary: "",
                                                       available: available),
                       "es_ES")
        XCTAssertEqual(SpokenLanguages.suggestedSecond(preferred: ["en-US", "es-MX"],
                                                       primary: "",
                                                       available: available),
                       "es_419", "no es_MX model exists — any Spanish beats none")
    }

    // MARK: - When to stay quiet

    func testOneLanguageMacIsOfferedNothing() {
        XCTAssertNil(SpokenLanguages.suggestedSecond(preferred: ["en-GB"],
                                                     primary: "",
                                                     available: available))
    }

    func testAnotherRegionOfTheSameLanguageIsNotASecondLanguage() {
        XCTAssertNil(SpokenLanguages.suggestedSecond(preferred: ["en-GB", "en-US"],
                                                     primary: "",
                                                     available: available))
    }

    func testALanguageWithNoModelIsSkippedForOneThatHasIt() {
        XCTAssertEqual(SpokenLanguages.suggestedSecond(preferred: ["en-GB", "is-IS", "fr-FR"],
                                                       primary: "",
                                                       available: available),
                       "fr_FR")
        XCTAssertNil(SpokenLanguages.suggestedSecond(preferred: ["en-GB", "is-IS"],
                                                     primary: "",
                                                     available: available))
    }

    func testNothingOfferedWhenTheMacSaysNothing() {
        XCTAssertNil(SpokenLanguages.suggestedSecond(preferred: [], primary: "",
                                                     available: available))
        XCTAssertNil(SpokenLanguages.suggestedSecond(preferred: ["en-GB", "es-ES"],
                                                     primary: "", available: []))
    }

    // MARK: - A primary that was chosen by hand

    /// Someone who set dictation to Spanish on an English Mac must not then be
    /// offered Spanish as their second language — the suggestion follows what
    /// dictation LISTENS for, not what the Mac is set to.
    func testAChosenPrimaryIsWhatTheSuggestionAvoids() {
        XCTAssertEqual(SpokenLanguages.suggestedSecond(preferred: ["en-GB", "es-ES"],
                                                       primary: "es_ES",
                                                       available: available),
                       "en_GB")
    }

    func testRegionOnlyDifferenceInAChosenPrimaryStillCounts() {
        XCTAssertNil(SpokenLanguages.suggestedSecond(preferred: ["en-GB"],
                                                     primary: "en_US",
                                                     available: available))
    }

    // MARK: - Naming

    /// A Mac set to English (US) with Spain as its region calls itself
    /// `en_US@rg=eszzzz`, which `localizedString(forIdentifier:)` cannot
    /// name: Settings showed that code. The keyword is about formats, so the
    /// language is en_US, named as such.
    func testTheMacsRegionKeywordIsNotPartOfTheLanguage() {
        XCTAssertEqual(SpokenLanguages.plain("en_US@rg=eszzzz"), "en_US")
        XCTAssertEqual(SpokenLanguages.plain("en-US-u-rg-eszzzz"), "en_US")
        XCTAssertEqual(SpokenLanguages.plain("ca_ES@calendar=buddhist"), "ca_ES")
        let english = Locale(identifier: "en_GB")
        XCTAssertEqual(SpokenLanguages.name("en_US@rg=eszzzz", displayLocale: english), "English (United States)")
        XCTAssertEqual(SpokenLanguages.name("ca_ES@calendar=buddhist", displayLocale: english), "Catalan (Spain)")
        XCTAssertEqual(DictationHoldNotice.languageName("en_US@rg=eszzzz", displayLocale: english),
                       "English (United States)")
    }

    /// What the speech lists hold comes through as it is.
    func testAPlainIdentifierIsLeftAlone() {
        for identifier in ["en_US", "es_419", "zh_Hans_CN", "ca_ES_VALENCIA", "nl", ""] {
            XCTAssertEqual(SpokenLanguages.plain(identifier), identifier)
        }
        XCTAssertEqual(SpokenLanguages.plain("es-ES"), "es_ES", "BCP-47 in, the speech lists' spelling out")
        XCTAssertNil(SpokenLanguages.name(""))
    }
}
