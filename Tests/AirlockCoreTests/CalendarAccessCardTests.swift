import XCTest
@testable import AirlockCore

final class CalendarAccessCardTests: XCTestCase {
    private func card(_ status: CalendarAuthorization,
                      _ outcome: CalendarAccessOutcome? = nil) -> CalendarAccessCard? {
        CalendarAccessCard.card(status: status, outcome: outcome)
    }

    func testFullAccessShowsTheAgendaNotACard() {
        XCTAssertNil(card(.fullAccess))
        XCTAssertNil(card(.fullAccess, .granted))
    }

    func testNeverAskedIsAnOfferNotAProblem() {
        let first = card(.notDetermined)
        XCTAssertEqual(first?.remedy, .ask)
        XCTAssertEqual(first?.isProblem, false)
    }

    /// W20: a refusal says it was one, and the button uses macOS's own name.
    func testARefusalSaysSoAndOpensSystemSettings() {
        for outcome in [nil, CalendarAccessOutcome.declined, .standingDenial] {
            let refused = card(.denied, outcome)
            XCTAssertEqual(refused?.sentence, CalendarAccessCard.refused)
            XCTAssertEqual(refused?.remedy, .openSystemSettings)
            XCTAssertEqual(refused?.remedy.button, "Open System Settings")
        }
        XCTAssertTrue(CalendarAccessCard.refused.contains("refused"))
    }

    /// W21: the switch is greyed out, so there is nowhere to send anyone.
    func testAManagedMacGetsNoButton() {
        for outcome in [nil, CalendarAccessOutcome.standingDenial] {
            let managed = card(.restricted, outcome)
            XCTAssertEqual(managed?.sentence, CalendarAccessCard.managed)
            XCTAssertEqual(managed?.remedy, .nothing)
            XCTAssertNil(managed?.remedy.button)
        }
    }

    /// W22: add-only is its own state, not "never asked" with a Grant button.
    func testAddOnlyAccessHasItsOwnSentenceAndNoGrantButton() {
        for outcome in [nil, CalendarAccessOutcome.inconclusive] {
            let addOnly = card(.writeOnly, outcome)
            XCTAssertEqual(addOnly?.sentence, CalendarAccessCard.addOnly)
            XCTAssertEqual(addOnly?.remedy, .openSystemSettings)
            XCTAssertEqual(addOnly?.isProblem, true)
        }
    }

    /// The status reads denied, but nothing is on file, so the Privacy page
    /// would have no Airlock row; and asking again from the same launch is
    /// refused the same way. Reopening is the route, and the sentence says so.
    func testASuppressedDialogIsNotSentToSystemSettings() {
        let suppressed = card(.denied, .promptSuppressed)
        XCTAssertEqual(suppressed?.sentence, CalendarAccessCard.suppressed)
        XCTAssertEqual(suppressed?.remedy, .nothing)
    }

    func testOnlyRefusalsAndAddOnlyOfferSystemSettings() {
        let all: [CalendarAuthorization] = [.notDetermined, .denied, .restricted, .fullAccess, .writeOnly, .other]
        let outcomes: [CalendarAccessOutcome?] = [nil, .granted, .promptSuppressed, .declined, .standingDenial, .inconclusive]
        for status in all {
            for outcome in outcomes {
                guard let shown = card(status, outcome), shown.remedy == .openSystemSettings else { continue }
                XCTAssertTrue(status == .denied || status == .writeOnly, "\(status) \(String(describing: outcome))")
            }
        }
    }

    func testTheSentencesUseTheHouseWords() {
        typealias C = CalendarAccessCard
        let sentences = [C.invitation, C.refused, C.managed, C.addOnly, C.suppressed, C.couldNotAsk]
        for sentence in sentences {
            XCTAssertFalse(sentence.contains("Privacy Settings"), sentence)
            XCTAssertFalse(sentence.localizedCaseInsensitiveContains("island"), sentence)
            XCTAssertFalse(sentence.contains("—"), "one sentence, not a clause bolted on: \(sentence)")
        }
    }

    // MARK: - The week strip

    /// The inventory's case: a column a little over nine cells wide drew a
    /// sliver of the tenth day.
    func testTheStripShowsOnlyWholeDays() {
        let width = 297.0
        let cell = DayStripFit.cellWidth(for: width, minimum: 30, spacing: 2)
        XCTAssertGreaterThanOrEqual(cell, 30)
        let days = (width + 2) / (cell + 2)
        XCTAssertEqual(days, days.rounded(), accuracy: 0.0001, "a whole number of days fills the width")
        XCTAssertEqual(days.rounded(), 9)
    }

    func testAnExactFitIsLeftAlone() {
        // Seven 30pt cells and six 2pt gaps.
        XCTAssertEqual(DayStripFit.cellWidth(for: 222, minimum: 30, spacing: 2), 30, accuracy: 0.0001)
    }

    func testDegenerateWidthsFallBackToTheMinimum() {
        XCTAssertEqual(DayStripFit.cellWidth(for: 0, minimum: 30, spacing: 2), 30)
        XCTAssertEqual(DayStripFit.cellWidth(for: 12, minimum: 30, spacing: 2), 30)
        XCTAssertEqual(DayStripFit.cellWidth(for: .infinity, minimum: 30, spacing: 2), 30)
        XCTAssertEqual(DayStripFit.cellWidth(for: .nan, minimum: 30, spacing: 2), 30)
    }
}
