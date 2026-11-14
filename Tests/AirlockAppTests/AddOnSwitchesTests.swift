import AppKit
import XCTest
import AirlockCore
@testable import AirlockApp

/// The app side of the add-on list: that the UI-free facts in Core name real
/// things here, and that the Shelf's new switch takes its tab with it.
@MainActor
final class AddOnSwitchesTests: XCTestCase {
    private var savedShelfSwitch: Any?
    private var root: URL!

    override func setUp() {
        super.setUp()
        // Flipping a model's switch writes the test process's own defaults;
        // put back whatever was there so no other test sees it.
        savedShelfSwitch = UserDefaults.standard.object(forKey: TrayModel.enabledKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("addon-switches-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let savedShelfSwitch {
            UserDefaults.standard.set(savedShelfSwitch, forKey: TrayModel.enabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: TrayModel.enabledKey)
        }
        super.tearDown()
    }

    /// Core keeps tabs as strings because the tab type lives here. A renamed
    /// tab must break this, not leave an add-on pointing nowhere.
    func testEveryAddOnTabIsARealTab() {
        for addOn in AddOn.allCases {
            guard let raw = addOn.tabID else { continue }
            XCTAssertNotNil(NotchTab(rawValue: raw), "\(addOn) names a tab that does not exist: \(raw)")
        }
    }

    /// Home and Dashboard are the base app, never an add-on's tab.
    func testNoAddOnBringsHomeOrDashboard() {
        let tabs = AddOn.allCases.compactMap { $0.tabID.flatMap(NotchTab.init(rawValue:)) }
        XCTAssertFalse(tabs.contains(.home))
        XCTAssertFalse(tabs.contains(.dashboard))
    }

    /// One key each. Two add-ons sharing a key would switch each other.
    func testEachAddOnHasItsOwnKey() {
        let keys = AddOn.allCases.map(AddOnSwitches.key(for:))
        XCTAssertEqual(Set(keys).count, AddOn.allCases.count)
    }

    /// The keys are the models' own, pinned here so a renamed key in a model
    /// cannot leave the seed and the Add-ons page reading one nobody writes.
    func testTheKeysAreTheOnesTheModelsRead() {
        XCTAssertEqual(AddOnSwitches.key(for: .shelf), "tray.enabled")
        XCTAssertEqual(AddOnSwitches.key(for: .clipboard), "widget.clipboard.enabled")
        XCTAssertEqual(AddOnSwitches.key(for: .meetingNotes), "meetings.enabled")
        XCTAssertEqual(AddOnSwitches.key(for: .codingAgents), "widget.agents.enabled")
        XCTAssertEqual(AddOnSwitches.key(for: .windowLayouts), "windowLayouts.enabled")
        XCTAssertEqual(AddOnSwitches.key(for: .dictation), "dictation.enabled")
    }

    // MARK: - Shelf switch

    private func shelf() -> TrayModel {
        TrayModel(previewing: [], layout: WorkspaceLayout(root: root))
    }

    func testTheShelfWidgetFollowsItsSwitch() {
        let tray = shelf()
        tray.isEnabled = true
        let widget = TrayWidget(tray: tray)
        XCTAssertTrue(widget.isToggleable)
        XCTAssertTrue(widget.isEnabled)
        XCTAssertNotNil(widget.panelSection())

        tray.isEnabled = false
        XCTAssertFalse(widget.isEnabled)
        XCTAssertNil(widget.panelSection(), "an off shelf draws nothing")
        XCTAssertEqual(UserDefaults.standard.object(forKey: TrayModel.enabledKey) as? Bool, false,
                       "the switch is stored, so it survives a relaunch")
    }

    /// Off means no Shelf tab at all, and on brings it back.
    func testAnOffShelfTakesItsTabAway() {
        let tray = shelf()
        tray.isEnabled = true
        let registry = WidgetRegistry(widgets: [TrayWidget(tray: tray)])
        XCTAssertTrue(registry.visibleTabs().contains(.tray))

        tray.isEnabled = false
        XCTAssertFalse(registry.visibleTabs().contains(.tray))
        XCTAssertTrue(registry.visibleTabs().contains(.home), "home survives everything")
    }

    /// The controller's drop catcher and mouse watch follow the switch through
    /// this callback; it must fire on a real change only.
    func testTheShelfSwitchTellsTheControllerOncePerChange() {
        let tray = shelf()
        tray.isEnabled = true
        var calls = 0
        tray.onSwitch = { calls += 1 }
        tray.isEnabled = true
        XCTAssertEqual(calls, 0)
        tray.isEnabled = false
        XCTAssertEqual(calls, 1)
        tray.isEnabled = false
        XCTAssertEqual(calls, 1)
    }

    /// Switching off never empties: the files stay listed.
    func testSwitchingTheShelfOffKeepsItsFiles() {
        let item = TrayItem(url: root.appendingPathComponent("kept.txt"),
                            size: 1, modified: Date(), isDirectory: false)
        let tray = TrayModel(previewing: [item], layout: WorkspaceLayout(root: root))
        tray.isEnabled = false
        XCTAssertEqual(tray.items.count, 1)
    }

    // MARK: What a new Mac starts with

    /// Dictation and This Mac default to off in their own models (for the
    /// installs that never chose them), so a new Mac only starts with them
    /// because the seed writes them. Every other add-on is on by its model's
    /// own default and must be left alone, so an update never changes it.
    func testANewMacStartsWithDictationAndThisMacOn() {
        let suite = "airlock.addon-switches-seed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AddOnSwitches.seedAtLaunch(in: defaults), .freshInstall)
        XCTAssertEqual(defaults.object(forKey: DictationModel.enabledKey) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: SystemStatsWidgetModel.enabledKey) as? Bool, true)
        for addOn in AddOn.allCases where addOn != .dictation {
            XCTAssertNil(defaults.object(forKey: AddOnSwitches.key(for: addOn)),
                         "\(addOn) keeps its model's own default, which is on")
        }
    }

    /// Someone who updates keeps dictation as they left it, off included.
    func testAnUpdateNeverSwitchesDictationOn() {
        let suite = "airlock.addon-switches-seed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: OnboardingModel.completedKey)

        XCTAssertEqual(AddOnSwitches.seedAtLaunch(in: defaults), .existingInstall)
        XCTAssertNil(defaults.object(forKey: DictationModel.enabledKey))
    }

    // MARK: Coding agents

    /// The card says on exactly when the Agents tab is there. With nothing
    /// connected and nobody asked, the tab shows (asking to be set up), so the
    /// card must say on too: a card reading off beside a visible tab could
    /// not hide it, and kept the "+" showing on a Mac that had everything.
    func testTheCodingAgentsCardMatchesTheAgentsTab() {
        let model = AppModel()
        for basis: AgentsPresence.Basis in [.noHooksInstalled, .hooksInstalled, .chosen(true), .chosen(false)] {
            let agents = AgentsWidgetModel(previewing: basis)
            let switches = AddOnSwitches(tray: shelf(),
                                         clipboard: ClipboardWidgetModel(history: ClipboardHistory(items: [])),
                                         agents: agents, dictation: DictationModel())
            let registry = WidgetRegistry(widgets: [AgentsWidget(model: model, agents: agents)])
            XCTAssertEqual(switches.isOn(.codingAgents), registry.visibleTabs().contains(.agents),
                           "\(basis): the card and the tab disagree")
        }
        // And switched off by the person, both go.
        let off = AgentsWidgetModel(previewing: .chosen(false))
        XCTAssertFalse(WidgetRegistry(widgets: [AgentsWidget(model: model, agents: off)])
            .visibleTabs().contains(.agents))
        XCTAssertTrue(AgentsWidget.showsTabAtRest(AgentsWidgetModel(previewing: .noHooksInstalled)))
    }

    /// THE bug the owner saw: Coding agents off and the Agents tab still in
    /// the strip, because the git card (on by default, on that tab) counted as
    /// a reason for it. It follows the agents switch now.
    func testTheGitCardDoesNotKeepTheAgentsTabAlive() {
        let key = "widget.repository.enabled"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let model = AppModel()
        let repository = RepositoryWidgetModel(previewing: [])
        repository.isEnabled = true

        let off = AgentsWidgetModel(previewing: .chosen(false))
        let offRegistry = WidgetRegistry(widgets: [AgentsWidget(model: model, agents: off),
                                                   RepositoryWidget(repository: repository, agents: off)])
        XCTAssertFalse(offRegistry.visibleTabs().contains(.agents),
                       "agents off takes the tab, git card or not")

        let on = AgentsWidgetModel(previewing: .hooksInstalled)
        let onRegistry = WidgetRegistry(widgets: [AgentsWidget(model: model, agents: on),
                                                  RepositoryWidget(repository: repository, agents: on)])
        XCTAssertTrue(onRegistry.visibleTabs().contains(.agents))
        XCTAssertTrue(RepositoryWidget(repository: repository, agents: on).isVisible)
    }

    // MARK: Each add-on's page

    /// There is no page of all the add-ons any more: each add-on is a row of
    /// its own in the sidebar, after General and The notch, and the old
    /// page's address (a saved choice, a link from the notch) lands on the
    /// first of them rather than on nothing.
    func testEveryAddOnHasASidebarPage() {
        XCTAssertEqual(SettingsPane.sidebarCases.first, .general)
        XCTAssertEqual(SettingsPane.sidebarCases.dropFirst().first, .appearance)
        XCTAssertFalse(SettingsPane.sidebarCases.contains(.addOns))
        XCTAssertEqual(SettingsPane.addOns.resolved, AddOn.allCases[0].pane)
        XCTAssertEqual(SettingsAnchor.addOns.pane, AddOn.allCases[0].pane)
        for addOn in AddOn.allCases {
            XCTAssertTrue(SettingsPane.sidebarCases.contains(addOn.pane), "\(addOn) has no row")
        }
        XCTAssertEqual(Set(AddOn.allCases.map(\.pane)).count, AddOn.allCases.count, "two add-ons share a page")
    }

    /// A misspelt SF Symbol draws nothing at all, with no warning.
    func testEveryAddOnSymbolExists() {
        for addOn in AddOn.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: addOn.symbol, accessibilityDescription: nil),
                            "\(addOn): no symbol named \(addOn.symbol)")
        }
    }

    /// "Options" must land on a page the sidebar shows, or the window would
    /// change to a page with no row lit and no way to tell where you are.
    func testEveryOptionsButtonLandsOnASidebarPage() {
        for addOn in AddOn.allCases {
            let pane: SettingsPane
            switch addOn.options {
            case .row(let anchor): pane = anchor.pane
            case .page(let page): pane = page
            }
            XCTAssertTrue(SettingsPane.sidebarCases.contains(pane), "\(addOn) → \(pane)")
            XCTAssertNotEqual(pane, .addOns, "\(addOn)'s options would go nowhere")
        }
    }
}
