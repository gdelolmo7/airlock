import AirlockTestSupport
import XCTest
import AirlockCore
@testable import AirlockApp

/// A seeded demo gate has to end by itself.
///
/// A real gate is held by `BridgeServer` and released by `ask_timeout`. A demo
/// one never goes near the bridge, so before this there was nothing to release
/// it: it stayed pending, held `attentionCount` above zero and kept the island
/// amber until somebody answered it or quit the app. **Seed Demo Session is a
/// shipped menu item**, so clicking it and wandering off was a supported way to
/// get a permanently orange notch.
@MainActor
final class DemoGateTests: XCTestCase {
    /// `seedDemo` mutates, which schedules a save. Without this every test here
    /// would write to the real `~/Library/Application Support/Airlock` — and
    /// since demo sessions are EXCLUDED from the save, it would write an empty
    /// state over whatever the person running the tests actually had open.
    private var sandbox: TestScratch!

    override func setUp() {
        super.setUp()
        sandbox = TestScratch("airlock-demo-gate")
        setenv("AIRLOCK_STATE_HOME", sandbox.root.path, 1)
    }

    override func tearDown() {
        unsetenv("AIRLOCK_STATE_HOME")
        sandbox.remove()
        super.tearDown()
    }

    private func gate(_ model: AppModel) -> PermissionRequest? {
        model.state.sessions["demo-claude"]?.pendingPermission
    }

    func testTheDemoGateStartsPendingAndHoldsAttention() {
        let model = AppModel()
        model.seedDemo(gateTimeout: .seconds(60))
        XCTAssertNotNil(gate(model), "the gate is the point of the demo")
        XCTAssertEqual(model.attentionCount, 1)
    }

    /// THE fix. Left alone, it clears itself and gives the island back.
    func testItExpiresOnItsOwn() async throws {
        let model = AppModel()
        model.seedDemo(gateTimeout: .milliseconds(80))
        XCTAssertEqual(model.attentionCount, 1)

        try await Task.sleep(for: .milliseconds(400))

        XCTAssertNil(gate(model), "nothing was ever going to answer it")
        XCTAssertEqual(model.attentionCount, 0, "and the island goes back to normal")
    }

    /// Expiry is `.deferred` — the same ending `ask_timeout` gives a real gate.
    /// Anything else would record a decision the user never made, and
    /// `alwaysAllow` would write a policy rule off a timer.
    func testExpiryRecordsNoDecisionOfItsOwn() async throws {
        let model = AppModel()
        let before = model.gateLog.records.count
        model.seedDemo(gateTimeout: .milliseconds(80))
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(model.gateLog.records.count, before,
                       "a gate nobody answered is not a decision worth logging")
    }

    /// Answering must win. A timer that fires afterwards has to find nothing to
    /// do rather than re-resolve a gate somebody already dealt with.
    func testAnsweringBeforeTheTimerIsNotUndoneByIt() async throws {
        let model = AppModel()
        model.seedDemo(gateTimeout: .milliseconds(80))
        guard let session = model.state.sessions["demo-claude"] else {
            return XCTFail("no demo session")
        }
        model.resolve(session, .deny)
        XCTAssertNil(gate(model))

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(gate(model), "still resolved, and not resurrected")
        XCTAssertEqual(model.attentionCount, 0)
    }

    /// Re-seeding restarts the clock instead of leaving an older timer running
    /// that would cut the new gate short.
    func testReseedingRestartsTheClockRatherThanStackingTimers() async throws {
        let model = AppModel()
        model.seedDemo(gateTimeout: .milliseconds(120))
        try await Task.sleep(for: .milliseconds(60))
        model.seedDemo(gateTimeout: .seconds(60))

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(gate(model), "the first timer must not expire the second gate")
    }

    /// Clearing cancels it, so the timer cannot fire into a state it no longer
    /// belongs to.
    func testClearingSessionsCancelsTheTimer() async throws {
        let model = AppModel()
        model.seedDemo(gateTimeout: .milliseconds(80))
        model.clearAllSessions()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.state.sessions.isEmpty)
    }

    /// The demo gate has no bridge and never had one, so "nothing to deliver
    /// to" is not a failure here — answering it is still a decision, and still
    /// goes in the log that the panel's own suggestions read.
    func testAnsweringTheDemoGateIsStillLogged() async throws {
        let model = AppModel()
        model.seedDemo(gateTimeout: .seconds(60))
        guard let session = model.state.sessions["demo-claude"] else {
            return XCTFail("no demo session")
        }
        let before = model.gateLog.records.count

        model.resolve(session, .allowOnce)

        let deadline = Date().addingTimeInterval(2)
        while model.gateLog.records.count == before, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.gateLog.records.count, before + 1)
    }
}
