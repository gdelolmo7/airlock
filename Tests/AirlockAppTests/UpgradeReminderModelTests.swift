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

    // MARK: - A week in

    /// The first open on Free starts the week, and the card a week later
    /// says what Plus adds to what this Mac uses then.
    func testTheWeeksCardAWeekAfterTheFirstOpen() {
        let reminders = model()
        reminders.uses = { [.callNotes] }
        reminders.islandOpened(now: t0)
        XCTAssertNil(reminders.card)
        reminders.islandClosed()

        let relaunched = model()
        relaunched.uses = { [.callNotes, .agents] }
        relaunched.islandOpened(now: t0.addingTimeInterval(6 * 86_400))
        XCTAssertNil(relaunched.card, "not yet a week")
        relaunched.islandOpened(now: t0.addingTimeInterval(7 * 86_400 + 3_600))
        XCTAssertEqual(relaunched.card, .firstWeek(uses: [.callNotes, .agents]))
    }

    /// Opening on Plus or Pro starts no week: the card is for Free.
    func testOpeningOnAPaidPlanStartsNoWeek() {
        let paid = model(onFree: false)
        paid.uses = { [.agents] }
        paid.islandOpened(now: t0)

        let free = model()
        free.uses = { [.agents] }
        free.islandOpened(now: t0.addingTimeInterval(7 * 86_400))
        XCTAssertNil(free.card, "the week starts at this first open on Free")
    }

    /// Nothing went wrong in a week without a limit: no sweat on the cloud.
    func testOnlyALimitWorriesTheCloud() {
        XCTAssertEqual(UpgradeReminderCard.face(for: .firstWeek(uses: [.clipboard])), .neutral)
        XCTAssertEqual(UpgradeReminderCard.face(for: .clipboardFull), .stressed)
        XCTAssertEqual(UpgradeReminderCard.face(for: .agentInTerminal(asking: "website", answering: nil)), .stressed)
    }

    // MARK: - Usage counts

    func testShownAndNotNowAreCountedWithTheirKind() {
        let reminders = model()
        var shown: [UpgradeReminder.Kind] = []
        var notNow: [UpgradeReminder.Kind] = []
        reminders.onShown = { shown.append($0) }
        reminders.onNotNow = { notNow.append($0) }
        reminders.copiesLetGo(1, now: t0)

        reminders.islandOpened(now: t0.addingTimeInterval(60))
        reminders.notNow(now: t0.addingTimeInterval(90))
        XCTAssertEqual(shown, [.clipboard])
        XCTAssertEqual(notNow, [.clipboard])

        reminders.islandOpened(now: t0.addingTimeInterval(120))
        XCTAssertEqual(shown, [.clipboard], "nothing shown, nothing counted")
    }

    func testThePreviewCountsNothing() {
        let reminders = UpgradeReminderModel(previewing: .clipboardFull)
        var counted = 0
        reminders.onNotNow = { _ in counted += 1 }
        reminders.notNow()
        XCTAssertEqual(counted, 0)
    }
}
