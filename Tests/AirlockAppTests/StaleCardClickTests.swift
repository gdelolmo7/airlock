import AirlockTestSupport
import XCTest
import AirlockCore
@testable import AirlockApp

/// A click on a card that has since been replaced answers nothing.
///
/// A view hands `AppModel` the session it last drew. When a second request in
/// the same session took the card between that draw and the click, the click
/// still carried the FIRST request — and `resolve` and `answer` acted on it:
/// they logged a decision that was never delivered (the bridge had already
/// handed that gate back), and applied a resolution for it that took the
/// session out of "Needs you" while the new card stood waiting.
@MainActor
final class StaleCardClickTests: XCTestCase {
    /// `seedDemo` mutates, which schedules saves, and a decision is logged to
    /// the gate log — neither may reach the real Application Support. Policy is
    /// sandboxed too, in case a regression ever lets "Always" through.
    private var sandbox: TestScratch!

    override func setUp() {
        super.setUp()
        sandbox = TestScratch("airlock-stale-card")
        setenv("AIRLOCK_STATE_HOME", sandbox.root.path, 1)
        setenv("AIRLOCK_POLICY_HOME", sandbox.root.path, 1)
    }

    override func tearDown() {
        unsetenv("AIRLOCK_STATE_HOME")
        unsetenv("AIRLOCK_POLICY_HOME")
        sandbox.remove()
        super.tearDown()
    }

    /// The demo session, as a view drew it before a newer request replaced its
    /// card: the model now holds `req-1`; the view still holds `req-0`.
    private func staleView(of model: AppModel) throws -> AgentSession {
        var session = try XCTUnwrap(model.state.sessions["demo-claude"])
        session.pendingPermission = PermissionRequest(id: "req-0", toolName: "Bash",
                                                      summary: "Run shell command",
                                                      command: "echo the old one", createdAt: Date())
        return session
    }

    func testAClickOnAReplacedCardAnswersNothing() throws {
        let model = AppModel()
        model.seedDemo(gateTimeout: .seconds(60))
        let logged = model.gateLog.records.count
        let stale = try staleView(of: model)

        model.resolve(stale, .allowOnce)
        model.resolve(stale, .deny)
        model.resolve(stale, .deferred)
        model.answer(stale, choice: "Production")

        let session = try XCTUnwrap(model.state.sessions["demo-claude"])
        XCTAssertEqual(session.pendingPermission?.id, "req-1", "the card on screen is untouched")
        XCTAssertEqual(session.status, .needsAttention)
        XCTAssertEqual(model.attentionCount, 1, "still Needs you — the island must not get out of the way")
        XCTAssertEqual(model.gateLog.records.count, logged, "a decision that was never delivered is not logged")
    }

    /// The card that IS on screen answers exactly as before.
    func testTheCardOnScreenStillAnswers() async throws {
        let model = AppModel()
        model.seedDemo(gateTimeout: .seconds(60))
        let logged = model.gateLog.records.count
        let live = try XCTUnwrap(model.state.sessions["demo-claude"])

        model.resolve(live, .deny)

        XCTAssertNil(model.state.sessions["demo-claude"]?.pendingPermission)
        XCTAssertEqual(model.attentionCount, 0)
        // The log waits to hear the decision was delivered — see
        // `AppModel.resolve`. A demo gate has nothing to deliver to and is the
        // one case where that is not a failure.
        let deadline = Date().addingTimeInterval(2)
        while model.gateLog.records.count == logged, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.gateLog.records.count, logged + 1)
    }
}
