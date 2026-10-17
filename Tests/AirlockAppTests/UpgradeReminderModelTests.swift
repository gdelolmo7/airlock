import XCTest
import AirlockCore
@testable import AirlockApp

/// The app's half of Free's reminders: what it keeps in the preferences, and
/// when the panel opening puts a card up. The rules themselves are
/// `UpgradeReminderTests` (Core).
@MainActor
final class UpgradeReminderModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_792_000_000) // a weekday morning
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "UpgradeReminderModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func model(onFree: Bool = true) -> UpgradeReminderModel {
        let model = UpgradeReminderModel(defaults: defaults)
        model.onFree = { onFree }
        return model
    }

    func testACardWhenThePanelOpensGoneWhenItClosesAndOneADay() {
        let reminders = model()
        reminders.copiesLetGo(1, now: t0)
        XCTAssertNil(reminders.card, "nothing until the panel opens")

        reminders.islandOpened(now: t0.addingTimeInterval(60))
        XCTAssertEqual(reminders.card, .clipboardFull)
        reminders.islandClosed()
        XCTAssertNil(reminders.card)

        reminders.agentAskedInTerminal(asking: "website", answering: "storefront", now: t0.addingTimeInterval(120))
        reminders.islandOpened(now: t0.addingTimeInterval(180))
        XCTAssertNil(reminders.card, "one a day, across every kind")
    }

    func testWhatHappenedIsKeptForTheNextLaunch() {
        model().copiesLetGo(3, now: t0)
        let relaunched = model()
        relaunched.islandOpened(now: t0.addingTimeInterval(60))
        XCTAssertEqual(relaunched.card, .clipboardFull)
    }

    func testAnotherCardUpIsTheDaysOne() {
        let reminders = model()
        var otherUp = true
        reminders.otherCardUp = { otherUp }
        reminders.copiesLetGo(1, now: t0)

        reminders.islandOpened(now: t0.addingTimeInterval(60))
        XCTAssertNil(reminders.card)
        otherUp = false
        reminders.islandOpened(now: t0.addingTimeInterval(120))
        XCTAssertNil(reminders.card, "\"You're on Free now\" was today's")
    }

    func testNotNowQuietsThatKindAcrossLaunches() {
        let reminders = model()
        reminders.agentAskedInTerminal(asking: "website", answering: "storefront", now: t0)
        reminders.islandOpened(now: t0.addingTimeInterval(60))
        XCTAssertEqual(reminders.card?.kind, .agents)
        reminders.notNow(now: t0.addingTimeInterval(90))
        XCTAssertNil(reminders.card)

        let week = t0.addingTimeInterval(8 * 86_400)
        let relaunched = model()
        relaunched.agentAskedInTerminal(asking: "website", answering: "storefront", now: week)
        relaunched.islandOpened(now: week.addingTimeInterval(60))
        XCTAssertNil(relaunched.card, "quiet for \(UpgradeReminders.notNowDays) days")
    }

    func testNeverDuringACallOrWhileAnAgentAsks() {
        let reminders = model()
        var callOn = true, asking = false
        reminders.callOn = { callOn }
        reminders.agentAsking = { asking }
        reminders.copiesLetGo(1, now: t0)

        reminders.islandOpened(now: t0.addingTimeInterval(60))
        XCTAssertNil(reminders.card)
        callOn = false; asking = true
        reminders.islandOpened(now: t0.addingTimeInterval(120))
        XCTAssertNil(reminders.card)
        asking = false
        reminders.islandOpened(now: t0.addingTimeInterval(180))
        XCTAssertEqual(reminders.card, .clipboardFull, "a skipped open is not the day's one")
    }

    func testNothingOnAPaidPlan() {
        let reminders = model(onFree: false)
        reminders.copiesLetGo(5, now: t0)
        reminders.islandOpened(now: t0.addingTimeInterval(60))
        XCTAssertNil(reminders.card)
    }

    func testSeePlusOpensPlansAndTakesTheCardAway() {
        let reminders = model()
        var opened = 0
        reminders.onSeePlus = { opened += 1 }
        reminders.copiesLetGo(1, now: t0)
        reminders.islandOpened(now: t0.addingTimeInterval(60))
        reminders.seePlus()
        XCTAssertNil(reminders.card)
        XCTAssertEqual(opened, 1)
    }

    func testThePanelOpeningAndClosingDrivesIt() {
        let moments = Moments()
        let reminders = model()
        reminders.listenToTheIsland(moments)
        reminders.copiesLetGo(1)

        moments.announce(.islandOpened, now: Date())
        XCTAssertEqual(reminders.card, .clipboardFull)
        moments.announce(.islandClosed, now: Date())
        XCTAssertNil(reminders.card)
    }

    func testThePreviewKeepsNothingAndIgnoresThePanel() {
        let reminders = UpgradeReminderModel(previewing: .clipboardFull)
        reminders.islandClosed()
        XCTAssertEqual(reminders.card, .clipboardFull)
    }
}
