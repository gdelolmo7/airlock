import XCTest
@testable import AirlockCore

/// The trial's last day argues with the user's own history, so the figures have
/// to be defensible: a count somebody could check and find wrong is worse than
/// no count at all, on the one screen where trust is the entire ask.
final class UsageTallyTests: XCTestCase {
    /// A card offering "0 commands approved" as a reason to pay is an argument
    /// against itself, so the last day falls back to the plain line.
    func testAnEmptyTallyIsNotWorthShowing() {
        XCTAssertFalse(UsageTally().isWorthShowing)
        XCTAssertTrue(UsageTally(approvals: 1).isWorthShowing)
        XCTAssertTrue(UsageTally(dictations: 1).isWorthShowing)
    }

    /// A zero is omitted rather than printed. Somebody who never dictated does
    /// not need a row telling them so on the day they are asked for money.
    func testZeroesAreOmittedRatherThanShown() {
        let lines = UsageTally(approvals: 12, answers: 0, dictations: 3).lines
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.count), [12, 3])
        XCTAssertFalse(lines.contains { $0.label.contains("question") })
    }

    func testTheOrderIsApprovalsAnswersDictations() {
        let lines = UsageTally(approvals: 1, answers: 2, dictations: 3).lines
        XCTAssertEqual(lines.map(\.count), [1, 2, 3])
        XCTAssertTrue(lines[0].label.hasPrefix("command"))
        XCTAssertTrue(lines[1].label.hasPrefix("question"))
        XCTAssertTrue(lines[2].label.hasPrefix("dictation"))
    }

    /// One approval is a command, not "1 commands". The card is arguing that
    /// this app is careful; a plural bug there costs more than it looks.
    func testSingularsReadAsSingulars() {
        let lines = UsageTally(approvals: 1, answers: 1, dictations: 1).lines
        for line in lines {
            XCTAssertFalse(line.label.hasPrefix("commands"))
            XCTAssertFalse(line.label.hasPrefix("questions"))
            XCTAssertFalse(line.label.hasPrefix("dictations"))
        }
    }

    func testPluralsReadAsPlurals() {
        let lines = UsageTally(approvals: 2, answers: 2, dictations: 2).lines
        XCTAssertTrue(lines[0].label.hasPrefix("commands"))
        XCTAssertTrue(lines[1].label.hasPrefix("questions"))
        XCTAssertTrue(lines[2].label.hasPrefix("dictations"))
    }

    /// Each line names something the person would otherwise have done by hand.
    /// None of them describes something the app did on its own.
    func testEveryLineDescribesWorkSavedRatherThanAFeature() {
        let labels = UsageTally(approvals: 1, answers: 1, dictations: 1).lines.map(\.label)
        XCTAssertTrue(labels[0].contains("without leaving what you were doing"))
        XCTAssertTrue(labels[1].contains("from the notch"))
        XCTAssertTrue(labels[2].contains("straight into the app you were in"))
    }

    func testItRoundTripsThroughCoding() throws {
        let tally = UsageTally(approvals: 214, answers: 38, dictations: 61)
        let data = try JSONEncoder().encode(tally)
        XCTAssertEqual(try JSONDecoder().decode(UsageTally.self, from: data), tally)
    }
}
