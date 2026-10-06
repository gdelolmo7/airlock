import SwiftUI
import XCTest
import AirlockCore
@testable import AirlockApp

/// The two visibility rules the day-one panel added, tested against stub
/// widgets rather than the real ones.
///
/// Deliberately not `AgentsWidget`: its basis is derived from hook files on the
/// machine running the tests, so an assertion about "no hooks installed" would
/// pass or fail depending on whether the developer uses Claude Code. The tri-
/// state itself is `AgentsPresenceTests`; what is unproven without these is the
/// wiring — that `isUnconfigured` reaches `visibleTabs()`, and that a fallback
/// actually yields.
@MainActor
final class WidgetVisibilityTests: XCTestCase {
    private func ids(_ sections: [(id: String, view: AnyView)]) -> [String] {
        sections.map(\.id)
    }

    // MARK: - Fallback

    /// The key map's whole reason for existing: fill an empty column, and get
    /// out of the way the moment the column has something real.
    func testAFallbackYieldsToARealSectionInTheSameColumn() {
        let registry = WidgetRegistry(widgets: [
            StubWidget(id: "media", column: .leading),
            StubWidget(id: "keymap", column: .leading, isFallback: true),
        ])
        let sections = registry.sections(.tab, in: .stack, tab: .home, column: .leading)
        XCTAssertEqual(ids(sections), ["media"],
                       "a fallback beside real content is filler, which is what it must never be")
    }

    func testAFallbackDrawsWhenItsColumnIsOtherwiseEmpty() {
        let registry = WidgetRegistry(widgets: [
            StubWidget(id: "media", column: .leading, rendersSection: false),
            StubWidget(id: "keymap", column: .leading, isFallback: true),
        ])
        let sections = registry.sections(.tab, in: .stack, tab: .home, column: .leading)
        XCTAssertEqual(ids(sections), ["keymap"])
    }

    /// Decided on what RENDERED, not on what is switched on. A widget that is
    /// enabled and has nothing to say this second — media with nothing playing —
    /// is exactly the case the fallback exists to fill, and an `isEnabled` test
    /// would have left the column blank.
    func testAnEnabledWidgetWithNothingToShowStillLetsTheFallbackThrough() {
        let registry = WidgetRegistry(widgets: [
            StubWidget(id: "media", column: .leading, isEnabled: true, rendersSection: false),
            StubWidget(id: "keymap", column: .leading, isFallback: true),
        ])
        XCTAssertEqual(ids(registry.sections(.tab, in: .stack, tab: .home, column: .leading)),
                       ["keymap"])
    }

    /// Per column, not per tab — the day-one home has a calendar in the trailing
    /// column and the key map in the leading one, at the same time.
    func testAFallbackIsUnaffectedByAnotherColumnsContent() {
        let registry = WidgetRegistry(widgets: [
            StubWidget(id: "calendar", column: .trailing),
            StubWidget(id: "keymap", column: .leading, isFallback: true),
        ])
        XCTAssertEqual(ids(registry.sections(.tab, in: .stack, tab: .home, column: .leading)),
                       ["keymap"])
    }

    // MARK: - Unconfigured

    /// The Agents tab on a fresh install: switched off by derivation, but the
    /// only place that explains how to switch it on.
    func testAnUnconfiguredWidgetKeepsItsTabInTheStrip() {
        let registry = WidgetRegistry(widgets: [
            StubWidget(id: "agents", tab: .agents, isEnabled: false, isUnconfigured: true),
        ])
        XCTAssertTrue(registry.visibleTabs().contains(.agents))
        XCTAssertEqual(ids(registry.sections(.tab, in: .stack, tab: .agents, column: .full)),
                       ["agents"])
    }

    /// An explicit no is the one thing that hides it. Without this the switch
    /// would be decorative.
    func testASwitchedOffWidgetLeavesTheStrip() {
        let registry = WidgetRegistry(widgets: [
            StubWidget(id: "agents", tab: .agents, isEnabled: false, isUnconfigured: false),
        ])
        XCTAssertFalse(registry.visibleTabs().contains(.agents))
        XCTAssertTrue(registry.sections(.tab, in: .stack, tab: .agents, column: .full).isEmpty)
    }

    /// Home is exempt whatever anything else says — it is where a vanished tab
    /// lands and the only route back to settings.
    func testHomeSurvivesEverythingBeingOff() {
        let registry = WidgetRegistry(widgets: [
            StubWidget(id: "media", isEnabled: false),
        ])
        XCTAssertEqual(registry.visibleTabs(), [.home])
    }
}

private struct StubWidget: NotchWidget {
    let id: String
    var tab: NotchTab = .home
    var column: WidgetColumn = .full
    var isEnabledValue: Bool = true
    var isUnconfigured: Bool = false
    var isFallback: Bool = false
    var rendersSection: Bool = true

    init(id: String, tab: NotchTab = .home, column: WidgetColumn = .full,
         isEnabled: Bool = true, isUnconfigured: Bool = false,
         isFallback: Bool = false, rendersSection: Bool = true) {
        self.id = id
        self.tab = tab
        self.column = column
        self.isEnabledValue = isEnabled
        self.isUnconfigured = isUnconfigured
        self.isFallback = isFallback
        self.rendersSection = rendersSection
    }

    var displayName: String { id }
    var tier: WidgetTier { .ambient }
    var isToggleable: Bool { true }
    var isEnabled: Bool {
        get { isEnabledValue }
        nonmutating set { }
    }

    func panelSection() -> AnyView? {
        guard isVisible, rendersSection else { return nil }
        return AnyView(EmptyView())
    }
}
