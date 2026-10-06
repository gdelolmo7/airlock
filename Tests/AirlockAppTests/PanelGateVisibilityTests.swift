import SwiftUI
import AirlockTestSupport
import XCTest
import AirlockCore
@testable import AirlockApp

/// A blocking gate stays reachable while an answer owns the panel.
///
/// `PanelStackContentTests` (Core) covers the rule; this covers the wiring —
/// that `.attentionOnly` actually produces the permission card's section, and
/// keeps producing it with the agents widget switched off. Both halves have to
/// hold, because the bug was not a wrong rule: the panel dropped its whole
/// widget region on `assistant.isPresenting`, so an arriving gate was never
/// drawn and `NotchController.focusPendingGate` could not reveal it either. The
/// agent stayed blocked until `ask_timeout`.
@MainActor
final class PanelGateVisibilityTests: XCTestCase {
    /// `seedDemo` mutates, which schedules a save — see `DemoGateTests` for why
    /// that must not reach the real Application Support directory. The agents
    /// choice is a real UserDefaults key for the same reason: switching the
    /// widget off here must not switch it off for whoever ran the tests.
    private var previousChoice: Any?

    private var sandbox: TestScratch!

    override func setUp() {
        super.setUp()
        sandbox = TestScratch("airlock-panel-gate")
        setenv("AIRLOCK_STATE_HOME", sandbox.root.path, 1)
        previousChoice = UserDefaults.standard.object(forKey: Self.agentsChoiceKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(previousChoice, forKey: Self.agentsChoiceKey)
        unsetenv("AIRLOCK_STATE_HOME")
        sandbox.remove()
        super.tearDown()
    }

    private static let agentsChoiceKey = "widget.agents.enabled"

    private func gatedRegistry() -> (AppModel, AgentsWidgetModel, WidgetRegistry) {
        let model = AppModel()
        model.seedDemo(gateTimeout: .seconds(60))
        let agents = AgentsWidgetModel()
        let registry = WidgetRegistry(widgets: [
            AgentsWidget(model: model, agents: agents, isEntitled: { true }),
            QuietWidget(),
        ])
        return (model, agents, registry)
    }

    private func ids(_ sections: [(id: String, view: AnyView)]) -> [String] {
        sections.map(\.id)
    }

    /// THE regression. An answer is up, a gate arrives, and the card is drawn.
    func testAPendingGateIsStillDrawnWhileAnAnswerOwnsThePanel() {
        let (model, _, registry) = gatedRegistry()
        XCTAssertEqual(model.attentionCount, 1)
        XCTAssertTrue(registry.demandsAttention)

        let content = PanelStackContent.resolve(dictating: false, answering: true,
                                                demandsAttention: registry.demandsAttention)
        let sections = registry.sections(content, in: .stack, tab: .agents, column: .full)
        XCTAssertTrue(ids(sections).contains("agents"),
                      "the card that unblocks the agent has to be on screen")
    }

    /// And it is a NARROWED region, not the whole tab: an answer is still up and
    /// still has to fit. Everything not blocking stays out of the way.
    func testNothingButTheBlockingWidgetSharesThePanelWithTheAnswer() {
        let (_, _, registry) = gatedRegistry()
        let sections = registry.sections(.attentionOnly, in: .stack, tab: .agents, column: .full)
        XCTAssertEqual(ids(sections), ["agents"])
        XCTAssertEqual(ids(registry.sections(.tab, in: .stack, tab: .agents, column: .full)),
                       ["agents", "quiet"],
                       "with nothing owning the panel the whole tab is drawn as before")
    }

    /// The widget contract's own override, through the new path: "switching a
    /// widget off is a statement about clutter, not consent to hang."
    func testItSurvivesTheAgentsWidgetBeingSwitchedOff() {
        let (_, agents, registry) = gatedRegistry()
        agents.choose(false)
        XCTAssertFalse(agents.isEnabled)

        XCTAssertTrue(registry.demandsAttention)
        XCTAssertEqual(ids(registry.sections(.attentionOnly, in: .stack, tab: .agents, column: .full)),
                       ["agents"])
    }

    /// Resolved, and the panel goes back to the answer alone — otherwise every
    /// answer after the first gate would be sharing the panel with a stale card.
    func testAnsweringTheGateGivesThePanelBack() {
        let (model, _, registry) = gatedRegistry()
        guard let session = model.state.sessions["demo-claude"] else {
            return XCTFail("no demo session")
        }
        model.resolve(session, .allowOnce)

        XCTAssertEqual(model.attentionCount, 0)
        XCTAssertFalse(registry.demandsAttention)
        XCTAssertEqual(
            PanelStackContent.resolve(dictating: false, answering: true,
                                      demandsAttention: registry.demandsAttention),
            .none)
    }

    /// `.none` draws nothing at all, whatever is switched on — that is the
    /// greedy-ScrollView fix the original condition existed for, and it has to
    /// survive this change.
    func testTheRegionIsEmptyWhenNothingIsBlocking() {
        let (_, _, registry) = gatedRegistry()
        XCTAssertTrue(registry.sections(.none, in: .stack, tab: .agents, column: .full).isEmpty)
    }
}

/// A widget with nothing to say. Stands in for the ambient half of the tab —
/// the git rows, the media card — so "only what is blocking" is asserted
/// against something that would otherwise have been drawn.
@MainActor
private struct QuietWidget: NotchWidget {
    var id: String { "quiet" }
    var displayName: String { "Quiet" }
    var tier: WidgetTier { .ambient }
    var isToggleable: Bool { true }
    var tab: NotchTab { .agents }
    var isEnabled: Bool {
        get { true }
        nonmutating set { }
    }

    func panelSection() -> AnyView? { AnyView(EmptyView()) }
}
