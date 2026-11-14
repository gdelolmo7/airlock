import XCTest
@testable import AirlockApp

/// Home's tips: closed one by one, closed for good, and closed from the start
/// on a copy that was set up before they could be.
@MainActor
final class KeyMapTipsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "airlock-tests-keymap-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testAClosedTipStaysClosedAfterARestart() {
        KeyMapTips(defaults: defaults).close("tray")
        let later = KeyMapTips(defaults: defaults)
        XCTAssertTrue(later.isClosed("tray"))
        XCTAssertFalse(later.isClosed("dictate"))
    }

    func testANewCopyKeepsItsTips() {
        let tips = KeyMapTips(defaults: defaults)
        tips.settle(setUpAlready: false)
        XCTAssertTrue(tips.closed.isEmpty)
        // Finishing setup later never closes them: the age is decided once.
        tips.settle(setUpAlready: true)
        XCTAssertTrue(tips.closed.isEmpty)
    }

    func testACopySetUpBeforeStartsWithEveryTipClosed() {
        let tips = KeyMapTips(defaults: defaults)
        tips.settle(setUpAlready: true)
        XCTAssertEqual(tips.closed, Set(KeyMapTips.all))
    }

    /// Every row the card can draw has an id the tips know.
    func testEveryRowIsATip() {
        let ids = KeyMapSectionView.rows(dictation: "⌃", clipboardKey: "⌘⇧V", shelf: true).map(\.id)
        XCTAssertEqual(Set(ids), Set(KeyMapTips.all))
    }

    /// The card only prints a gesture that fires: with the Shelf off, a file
    /// dropped on the notch goes nowhere, so the row goes too.
    func testTheShelfRowFollowsTheShelfSwitch() {
        let ids = KeyMapSectionView.rows(dictation: nil, clipboardKey: nil, shelf: false).map(\.id)
        XCTAssertFalse(ids.contains("tray"))
        XCTAssertTrue(KeyMapSectionView.rows(dictation: nil, clipboardKey: nil, shelf: true)
            .map(\.id).contains("tray"))
    }
}
