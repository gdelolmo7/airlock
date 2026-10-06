import XCTest
@testable import AirlockApp

/// The widget sentences that change with what is going on, rather than being
/// one fixed line: each must say the thing that is true right now.
@MainActor
final class WidgetSentenceTests: XCTestCase {
    // MARK: - Media (W6)

    /// Spotify open with nothing loaded is not "last played in" it, and the
    /// button must not offer to open what is already open.
    func testAnOpenPlayerIsNotSpokenOfAsClosed() {
        XCTAssertTrue(MediaWidgetModel.dormantCaption(player: "Spotify", ago: "2 min ago", isRunning: true)
            .hasPrefix("Stopped in Spotify"))
        XCTAssertEqual(MediaWidgetModel.dormantButton(player: "Spotify", isRunning: true), "Show Spotify")
        XCTAssertTrue(MediaWidgetModel.dormantCaption(player: "Spotify", ago: "2 min ago", isRunning: false)
            .hasPrefix("Last played in Spotify"))
        XCTAssertEqual(MediaWidgetModel.dormantButton(player: "Spotify", isRunning: false), "Open Spotify")
    }

    // MARK: - Calendar header (W26)

    private var cal: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return cal
    }

    /// Noon on a fixed Tuesday, so "tomorrow" never crosses a DST edge.
    private var now: Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))!
    }

    func testTheRollingAgendaIsHeadedByItsSpan() {
        XCTAssertEqual(CalendarWidgetModel.scopeLabel(selectedDay: nil, now: now, calendar: cal), "Next 24 hours")
    }

    func testAPickedDayIsHeadedByThatDay() {
        let today = cal.startOfDay(for: now)
        let day = { (offset: Int) in self.cal.date(byAdding: .day, value: offset, to: today)! }
        XCTAssertEqual(CalendarWidgetModel.scopeLabel(selectedDay: day(0), now: now, calendar: cal), "Today")
        XCTAssertEqual(CalendarWidgetModel.scopeLabel(selectedDay: day(1), now: now, calendar: cal), "Tomorrow")
        XCTAssertEqual(CalendarWidgetModel.scopeLabel(selectedDay: day(-1), now: now, calendar: cal), "Yesterday")
        let later = CalendarWidgetModel.scopeLabel(selectedDay: day(3), now: now, calendar: cal)
        XCTAssertNotEqual(later, "Next 24 hours")
        XCTAssertTrue(later.contains("9"), later)
    }
}
