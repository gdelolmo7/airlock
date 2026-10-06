import XCTest
@testable import AirlockCore

/// The race decides which language the user actually spoke. Getting it wrong
/// types a phonetic mangling of their sentence, so the bias is toward the
/// locale they chose.
final class TranscriptRaceTests: XCTestCase {
    private func candidate(_ locale: String, _ text: String, _ confidence: Double)
    -> TranscriptRace.Candidate {
        TranscriptRace.Candidate(localeIdentifier: locale, text: text, confidence: confidence)
    }

    /// The measured Spanish-audio case: es-ES 0.676 against en-US 0.373.
    func testClearlyBetterSecondaryTakesOver() {
        let winner = TranscriptRace.winner(among: [
            candidate("en_US", "Necesito, K revises LR Chivo, Deconfiguracion", 0.373),
            candidate("es_ES", "Necesito que revises el archivo de configuración", 0.676),
        ], primary: "en_US")
        XCTAssertEqual(winner?.localeIdentifier, "es_ES")
    }

    /// The measured English-audio case: both transcribers return English, and
    /// the primary is only modestly ahead. It must still win.
    func testPrimaryKeepsAModestLead() {
        let winner = TranscriptRace.winner(among: [
            candidate("en_US", "I need you to check the configuration file", 0.961),
            candidate("es_ES", "I need you to check the configura configuration file", 0.867),
        ], primary: "en_US")
        XCTAssertEqual(winner?.localeIdentifier, "en_US")
    }

    /// The asymmetry is the point: a secondary that is merely ahead does not get
    /// to switch the user's language out from under them.
    func testSecondaryWinningByLessThanTheMarginDoesNotTakeOver() {
        let winner = TranscriptRace.winner(among: [
            candidate("en_US", "run the tests", 0.80),
            candidate("es_ES", "ron the tests", 0.80 + TranscriptRace.takeoverMargin - 0.01),
        ], primary: "en_US")
        XCTAssertEqual(winner?.localeIdentifier, "en_US")
    }

    func testExactlyTheMarginIsNotEnough() {
        let winner = TranscriptRace.winner(among: [
            candidate("en_US", "run the tests", 0.80),
            candidate("es_ES", "ron the tests", 0.80 + TranscriptRace.takeoverMargin),
        ], primary: "en_US")
        XCTAssertEqual(winner?.localeIdentifier, "en_US")
    }

    /// Nothing to protect — a silent primary means the secondary is all there is,
    /// however low its confidence.
    func testSilentPrimaryYieldsToTheSecondary() {
        let winner = TranscriptRace.winner(among: [
            candidate("en_US", "   ", 0.99),
            candidate("es_ES", "corre las pruebas", 0.30),
        ], primary: "en_US")
        XCTAssertEqual(winner?.localeIdentifier, "es_ES")
    }

    func testNobodyHeardAnything() {
        XCTAssertNil(TranscriptRace.winner(among: [
            candidate("en_US", "", 0.9),
            candidate("es_ES", "  \n ", 0.9),
        ], primary: "en_US"))
    }

    /// The single-locale case still has to work — the race is opt-in.
    func testLoneCandidateWins() {
        let winner = TranscriptRace.winner(among: [
            candidate("en_US", "run the tests", 0.42),
        ], primary: "en_US")
        XCTAssertEqual(winner?.text, "run the tests")
    }

    /// A primary that never produced a candidate at all (no model, say) must not
    /// take the whole race down with it.
    func testMissingPrimaryFallsBackToBest() {
        let winner = TranscriptRace.winner(among: [
            candidate("es_ES", "corre las pruebas", 0.40),
            candidate("fr_FR", "corres les preuves", 0.55),
        ], primary: "en_US")
        XCTAssertEqual(winner?.localeIdentifier, "fr_FR")
    }

    // MARK: - The live preview

    /// The preview follows the race now. It used to be hardwired to the primary,
    /// so speaking Spanish meant watching the English transcriber's attempt at
    /// Spanish audio appear word by word — the delivered text was right and
    /// everything shown while talking was nonsense.
    func testLivePreviewFollowsAClearlyBetterSecondary() {
        XCTAssertEqual(TranscriptRace.liveChoice(among: [
            candidate("en_US", "Necesito, K revises LR Chivo", 0.373),
            candidate("es_ES", "Necesito que revises el archivo", 0.676),
        ], showing: "en_US"), "es_ES")
    }

    /// English audio scores en 0.961 / es 0.867 — a 0.094 gap, inside the
    /// margin. Speaking the primary language must never drag the preview away.
    func testLivePreviewStaysOnThePrimaryForTheLanguageItChose() {
        XCTAssertEqual(TranscriptRace.liveChoice(among: [
            candidate("en_US", "run the tests", 0.961),
            candidate("es_ES", "ran de tests", 0.867),
        ], showing: "en_US"), "en_US")
    }

    /// **Before any confidence exists, nothing moves.** Confidence is scored
    /// from results that carry it, so both takes read zero for the first few
    /// frames of every hold.
    func testNoEvidenceKeepsTheCurrentChoice() {
        XCTAssertEqual(TranscriptRace.liveChoice(among: [
            candidate("en_US", "", 0),
            candidate("es_ES", "", 0),
        ], showing: "en_US"), "en_US")
    }

    /// **Zero means "not scored yet", not "scored badly".** Taken verbatim from
    /// a real dictation log: the preview handed over to Spanish on `en_US 0.000
    /// · es_ES 0.846`, and the final race then scored the same hold `en_US 0.883
    /// · es_ES 0.846` — English, spoken in English, previewed in Spanish. The
    /// two transcribers do not start producing confidence at the same instant,
    /// so a challenger with a real number must not beat an incumbent whose
    /// number is merely unknown.
    func testAnUnscoredCurrentTakeIsNotBeatenByAScoredOne() {
        XCTAssertEqual(TranscriptRace.liveChoice(among: [
            candidate("en_US", "I was speaking English", 0),
            candidate("es_ES", "Ay guas espiquin inglish", 0.846),
        ], showing: "en_US"), "en_US",
        "0.000 is the absence of a measurement, not a bad one")
    }

    /// And once it does have a score, the switch works as intended — the fix
    /// above delays the decision, it must not prevent it. The numbers are the
    /// measured Spanish-audio case.
    func testOnceBothAreScoredTheSwitchStillHappens() {
        XCTAssertEqual(TranscriptRace.liveChoice(among: [
            candidate("en_US", "Necesito, K revises", 0.311),
            candidate("es_ES", "Necesito que revises", 0.914),
        ], showing: "en_US"), "es_ES")
    }

    /// Text arriving from one take first is timing, not evidence.
    ///
    /// Unlike `winner`, where an empty primary hands over unconditionally: both
    /// transcribers hear the same audio and emit partials within a frame of each
    /// other, so acting on who spoke first would flip the preview to the wrong
    /// language on a race.
    func testAnEmptyCurrentTakeDoesNotHandOverOnItsOwn() {
        XCTAssertEqual(TranscriptRace.liveChoice(among: [
            candidate("en_US", "", 0),
            candidate("es_ES", "Necesito", 0),
        ], showing: "en_US"), "en_US")
    }

    /// Hysteresis: whatever is on screen is protected by the same margin, so two
    /// takes scoring near each other cannot flicker the preview between
    /// languages mid-sentence.
    func testTheShownLocaleIsProtectedOnceItHasSwitched() {
        // es took over earlier; en creeping back up must not be enough.
        XCTAssertEqual(TranscriptRace.liveChoice(among: [
            candidate("en_US", "hello", 0.70),
            candidate("es_ES", "hola", 0.66),
        ], showing: "es_ES"), "es_ES")
        // Beating it by more than the margin is.
        XCTAssertEqual(TranscriptRace.liveChoice(among: [
            candidate("en_US", "hello", 0.80),
            candidate("es_ES", "hola", 0.66),
        ], showing: "es_ES"), "en_US")
    }

    /// Exactly the margin is not more than the margin — the same boundary
    /// `winner` uses, so the two decisions cannot drift apart on the one number
    /// they share.
    func testTheMarginBoundaryMatchesTheFinalRace() {
        let onTheLine = [candidate("en_US", "a", 0.50),
                         candidate("es_ES", "b", 0.50 + TranscriptRace.takeoverMargin)]
        XCTAssertEqual(TranscriptRace.liveChoice(among: onTheLine, showing: "en_US"), "en_US")
        XCTAssertEqual(TranscriptRace.winner(among: onTheLine, primary: "en_US")?.localeIdentifier,
                       "en_US")
    }

    /// One locale is the common case and must be untouched by any of this.
    func testASingleCandidateIsAlwaysWhatIsShown() {
        XCTAssertEqual(TranscriptRace.liveChoice(among: [candidate("en_US", "run", 0.42)],
                                                 showing: "en_US"), "en_US")
    }
}
