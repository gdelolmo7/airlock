import XCTest
@testable import AirlockCore

/// Which waiting card the keyboard answers — see `SessionState.focusedGate`.
///
/// Every card on screen used to bind Esc, ⌘Y, ⌘N and ⌘1–9. A key equivalent
/// goes to whichever bound view SwiftUI finds first, which is view order and
/// not the card being read, so with two sessions waiting ⌘Y could approve the
/// other one's command. Naming one card here is what lets the view bind the
/// keys on that card alone and print the keycaps only there; every other card
/// passes `nil` and claims nothing.
///
/// The settling window is the same fact seen from the other side. Ownership is
/// computed from the state, never from whether a button is enabled, so a card
/// that has just been replaced still owns the keys while it swallows them
/// (`PermissionCardView.answer`) — the fall-through to another session cannot
/// happen, because no other card binds them at all.
final class FocusedGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func request(_ id: String, _ command: String) -> PermissionRequest {
        PermissionRequest(id: id, toolName: "Bash", summary: "Run \(command)",
                          activity: "Running: \(command)", command: command, createdAt: t0)
    }

    private func event(_ session: String, _ seq: UInt64, at: Date? = nil,
                       _ kind: AgentEvent.Kind) -> AgentEvent {
        AgentEvent(sessionID: session, agent: .claudeCode, sequence: seq,
                   timestamp: at ?? t0, kind: kind)
    }

    /// Two sessions, both waiting: `later` was active most recently, so it is
    /// drawn on top.
    private func twoWaiting() -> SessionState {
        var state = SessionState()
        state.apply(event("earlier", 1, at: t0, .permissionRequested(request("E1", "npm test"))))
        state.apply(event("later", 1, at: t0.addingTimeInterval(5),
                          .permissionRequested(request("L1", "rm -rf ./dist"))))
        return state
    }

    func testTheKeysBelongToTheCardOnTop() throws {
        let state = twoWaiting()
        XCTAssertEqual(state.ordered.first?.id, "later")
        XCTAssertEqual(state.focusedGate, SessionState.FocusedGate(sessionID: "later", requestID: "L1"))
        XCTAssertNotNil(state.sessions["earlier"]?.pendingPermission,
                        "the other card is still on screen — it just answers to nothing")
    }

    /// Answering the focused card hands the keys to what is left, rather than
    /// leaving them bound to a card that has gone.
    func testAnsweringItHandsTheKeysToTheNextCard() throws {
        var state = twoWaiting()
        state.apply(event("later", 2, at: t0.addingTimeInterval(5),
                          .permissionResolved(requestID: "L1", decision: .allowOnce)))
        XCTAssertEqual(state.focusedGate, SessionState.FocusedGate(sessionID: "earlier", requestID: "E1"))

        state.apply(event("earlier", 2, .permissionResolved(requestID: "E1", decision: .deny)))
        XCTAssertNil(state.focusedGate, "nothing waiting, nothing bound")
    }

    /// The settling case, from the state's side: a queued gate taking the
    /// focused session's card keeps the keys in that session and moves them to
    /// the new request — never to the other session, which is where ⌘Y used to
    /// land while the promoted card sat disabled.
    func testAPromotedCardKeepsTheKeysInItsOwnSession() throws {
        var state = twoWaiting()
        state.apply(event("later", 2, at: t0.addingTimeInterval(5),
                          .permissionRequested(request("L2", "npm run deploy"))))
        XCTAssertEqual(state.sessions["later"]?.queuedPermissions?.map(\.id), ["L2"])

        state.apply(event("later", 3, at: t0.addingTimeInterval(5),
                          .permissionResolved(requestID: "L1", decision: .allowOnce)))
        XCTAssertEqual(state.focusedGate, SessionState.FocusedGate(sessionID: "later", requestID: "L2"))
    }

    /// Two sessions that arrived in the same millisecond used to be ordered by
    /// whatever the dictionary handed back, so the card the keys answered could
    /// change from one update to the next without anything happening.
    func testATieIsBrokenTheSameWayEveryTime() throws {
        var answers: Set<String> = []
        for _ in 0..<20 {
            var state = SessionState()
            for id in ["b-session", "a-session", "c-session"] {
                state.apply(event(id, 1, .permissionRequested(request("\(id)-req", "npm test"))))
            }
            answers.insert(state.focusedGate?.sessionID ?? "none")
            XCTAssertEqual(state.ordered.map(\.id), ["a-session", "b-session", "c-session"])
        }
        XCTAssertEqual(answers, ["a-session"], "one answer, every time")
    }

    func testNoCardsMeansNothingIsBound() {
        var state = SessionState()
        state.apply(event("s", 1, .activity(summary: "Working…")))
        XCTAssertNil(state.focusedGate)
    }

    // MARK: - What a listener is told about

    /// A queued gate taking a session's card is announced, because nothing else
    /// tells a listener the card under them changed.
    func testAPromotionIsFoundByTheCardThatChanged() throws {
        var state = twoWaiting()
        let before = state.shownCards
        XCTAssertNil(state.promotedGate(since: before), "nothing has moved")

        state.apply(event("later", 2, at: t0.addingTimeInterval(5),
                          .permissionRequested(request("L2", "npm run deploy"))))
        XCTAssertNil(state.promotedGate(since: before), "a gate joining a queue is not a promotion")

        state.apply(event("later", 3, at: t0.addingTimeInterval(5),
                          .permissionResolved(requestID: "L1", decision: .allowOnce)))
        XCTAssertEqual(state.promotedGate(since: before),
                       SessionState.FocusedGate(sessionID: "later", requestID: "L2"))
    }

    /// Two promotions in one update used to be resolved by asking a dictionary
    /// for its first match, which is whatever the hashing put there. It is the
    /// card at the top — the one the keyboard answers — every time.
    func testTwoPromotionsAtOnceAlwaysNameTheSameCard() throws {
        var answers: Set<String> = []
        for _ in 0..<20 {
            var state = SessionState()
            for id in ["b-session", "a-session"] {
                state.apply(event(id, 1, .permissionRequested(request("\(id)-1", "npm test"))))
                state.apply(event(id, 2, .permissionRequested(request("\(id)-2", "npm run lint"))))
            }
            let before = state.shownCards
            for id in ["b-session", "a-session"] {
                state.apply(event(id, 3, .permissionResolved(requestID: "\(id)-1", decision: .allowOnce)))
            }
            answers.insert(state.promotedGate(since: before)?.requestID ?? "none")
        }
        XCTAssertEqual(answers, ["a-session-2"], "one answer, every time, and the top card")
    }

    /// A session nobody had a card for is not a promotion: it is a new gate,
    /// and that has its own announcement, with the sound.
    func testANewCardIsNotAPromotion() throws {
        var state = SessionState()
        let before = state.shownCards
        state.apply(event("s", 1, .permissionRequested(request("R1", "npm test"))))
        XCTAssertNil(state.promotedGate(since: before))
    }
}
