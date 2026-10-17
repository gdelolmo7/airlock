import XCTest
import AirlockCore
@testable import AirlockApp

/// The Airlock window opens where it was left: on the calls, or on the
/// Settings page that was open.
@MainActor
final class AirlockWindowPlaceTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "AirlockWindowPlaceTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// Nothing remembered yet: General, not the calls.
    func testAFirstOpenIsGeneral() {
        let model = SettingsModel(previewing: [])
        model.restorePlace(guideOn: false, defaults: defaults)
        XCTAssertEqual(model.pane, .general)
        XCTAssertFalse(model.showsCalls)
    }

    /// Left on the calls, it opens on the calls, with the page that was open
    /// before still there for "Settings…".
    func testLeftOnTheCallsOpensOnTheCalls() {
        let before = SettingsModel(previewing: [])
        before.restorePlace(guideOn: false, defaults: defaults)
        before.pane = .license
        before.showsCalls = true

        let after = SettingsModel(previewing: [])
        after.restorePlace(guideOn: false, defaults: defaults)
        XCTAssertTrue(after.showsCalls)
        XCTAssertEqual(after.pane, .license)
    }

    /// Left on a page, it opens on that page.
    func testLeftOnAPageOpensOnIt() {
        let before = SettingsModel(previewing: [])
        before.restorePlace(guideOn: false, defaults: defaults)
        before.showsCalls = true
        before.pane = .voice

        let after = SettingsModel(previewing: [])
        after.restorePlace(guideOn: false, defaults: defaults)
        XCTAssertFalse(after.showsCalls)
        XCTAssertEqual(after.pane, .voice)
    }

    /// Any way into Settings leaves the calls: a page, a link to a row, a
    /// search result.
    func testEveryWayIntoSettingsLeavesTheCalls() {
        let model = SettingsModel(previewing: [])
        model.showsCalls = true
        model.pane = .license
        XCTAssertFalse(model.showsCalls)

        model.showsCalls = true
        model.reveal(.licenceKey)
        XCTAssertFalse(model.showsCalls)
        XCTAssertEqual(model.pane, .license)

        // The page already open counts too.
        model.showsCalls = true
        model.pane = .license
        XCTAssertFalse(model.showsCalls)
    }

    /// A link to a folded page lands where it moved, leaves the calls, and
    /// is remembered there.
    func testAFoldedPageLandsWhereItMovedAndIsRememberedThere() {
        let model = SettingsModel(previewing: [])
        model.restorePlace(guideOn: false, defaults: defaults)
        model.showsCalls = true
        model.pane = .widgets
        XCTAssertEqual(model.pane, .appearance)
        XCTAssertFalse(model.showsCalls)
        XCTAssertEqual(defaults.string(forKey: SettingsModel.paneKey), SettingsPane.appearance.rawValue)
        XCTAssertFalse(defaults.bool(forKey: SettingsModel.callsKey))
    }

    /// A page the column no longer has (a guide page, in a build without
    /// the guide) or a name nothing knows opens General; a folded page opens
    /// where it moved.
    func testAPageTheColumnLacksOpensGeneral() {
        XCTAssertEqual(SettingsModel.place(pane: "guide", showsCalls: false, guideOn: false).pane, .general)
        XCTAssertEqual(SettingsModel.place(pane: "guide", showsCalls: false, guideOn: true).pane, .guide)
        XCTAssertEqual(SettingsModel.place(pane: "nonsense", showsCalls: true, guideOn: false).pane, .general)
        XCTAssertTrue(SettingsModel.place(pane: "nonsense", showsCalls: true, guideOn: false).showsCalls)
        XCTAssertEqual(SettingsModel.place(pane: "widgets", showsCalls: false, guideOn: false).pane, .appearance)
        XCTAssertEqual(SettingsModel.place(pane: nil, showsCalls: false, guideOn: false).pane, .general)
    }

    /// Nothing is written before the place is restored, so a model that
    /// never is (a preview) leaves the real preferences alone.
    func testNothingIsRememberedBeforeTheRestore() {
        let standard = UserDefaults.standard
        let pane = standard.string(forKey: SettingsModel.paneKey)
        let calls = standard.object(forKey: SettingsModel.callsKey) as? Bool
        let model = SettingsModel(previewing: [])
        model.pane = pane == SettingsPane.voice.rawValue ? .clipboard : .voice
        model.showsCalls = calls != true
        XCTAssertEqual(standard.string(forKey: SettingsModel.paneKey), pane)
        XCTAssertEqual(standard.object(forKey: SettingsModel.callsKey) as? Bool, calls)
    }
}
