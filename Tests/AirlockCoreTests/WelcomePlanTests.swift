import XCTest
@testable import AirlockCore

final class WelcomePlanTests: XCTestCase {
    func testWalksWelcomePracticeQuestion() {
        var plan = WelcomePlan(hookStatuses: [.notInstalled])
        XCTAssertEqual(plan.step, .welcome)
        XCTAssertEqual(plan.dot, 0)

        plan.startPractice()
        XCTAssertEqual(plan.step, .practice)
        XCTAssertEqual(plan.dot, 1)

        XCTAssertEqual(plan.practiceEnded(reached: true), .ask)
        XCTAssertEqual(plan.step, .developer)
        XCTAssertEqual(plan.practice, .reached)
        XCTAssertEqual(plan.dot, 2)
        XCTAssertEqual(WelcomePlan.dots, 3)
    }

    /// A practice that went nowhere still reaches the question: setup must not
    /// hang on a permission somebody declined.
    func testAFailedPracticeStillAsks() {
        var plan = WelcomePlan(hookStatuses: [])
        plan.startPractice()
        XCTAssertEqual(plan.practiceEnded(reached: false), .ask)
        XCTAssertEqual(plan.practice, .notReached)
        XCTAssertEqual(plan.step, .developer)
    }

    /// Hooks already installed means a developer; asking them is noise.
    func testInstalledHooksSkipTheQuestion() {
        var plan = WelcomePlan(hookStatuses: [.notInstalled, .installed])
        XCTAssertFalse(plan.asksDeveloper)
        plan.startPractice()
        XCTAssertEqual(plan.practiceEnded(reached: true), .finish)
        XCTAssertEqual(plan.step, .practice, "no question screen to land on")
    }

    /// A broken install is not a working one: still asked.
    func testAConflictStillAsks() {
        XCTAssertTrue(WelcomePlan(hookStatuses: [.conflict("in the way")]).asksDeveloper)
    }

    func testBackGoesToTheWelcomeToPractiseAgain() {
        var plan = WelcomePlan(hookStatuses: [])
        plan.startPractice()
        _ = plan.practiceEnded(reached: false)
        plan.back()
        XCTAssertEqual(plan.step, .welcome)
        plan.startPractice()
        XCTAssertEqual(plan.practiceEnded(reached: true), .ask)
        XCTAssertEqual(plan.practice, .reached, "the second go is the one that counts")
    }

    func testOnlyYesConnectsAgents() {
        XCTAssertEqual(WelcomePlan.after(.yes), .connectAgents)
        XCTAssertEqual(WelcomePlan.after(.no), .done)
    }

    func testOnlyWhileTheGuideIsOn() {
        XCTAssertTrue(WelcomePlan.applies(guideEnabled: true))
        XCTAssertFalse(WelcomePlan.applies(guideEnabled: false))
    }

    // MARK: - Card B5

    /// Hooks installed and the practice did not get there: the window comes
    /// back to say so, instead of closing as if it had worked (O8).
    func testAFailedPracticeWithNoQuestionOffersAnotherGo() {
        var plan = WelcomePlan(hookStatuses: [.installed])
        plan.startPractice()
        XCTAssertEqual(plan.practiceEnded(reached: false), .offerAgain)
        XCTAssertEqual(plan.step, .welcome)
        XCTAssertEqual(plan.practice, .notReached)
    }

    /// Skip goes past the practice but not past the question that decides
    /// whether the agents half exists (O7).
    func testSkipStillAsksTheQuestion() {
        var plan = WelcomePlan(hookStatuses: [])
        XCTAssertEqual(plan.skipPractice(), .ask)
        XCTAssertEqual(plan.step, .developer)
        XCTAssertEqual(plan.practice, .notTried)
    }

    func testSkipWithNoQuestionFinishes() {
        var plan = WelcomePlan(hookStatuses: [.installed])
        XCTAssertEqual(plan.skipPractice(), .finish)
    }

    /// Quit at the question: back at the question. Quit mid-practice: back at
    /// the welcome, since a practice cannot carry on after a quit.
    func testResumesAtTheQuestionButNotMidPractice() {
        var plan = WelcomePlan(hookStatuses: [])
        XCTAssertEqual(plan.resumePoint, .welcome)
        plan.startPractice()
        XCTAssertEqual(plan.resumePoint, .welcome)
        _ = plan.practiceEnded(reached: true)
        XCTAssertEqual(plan.resumePoint, .developer)

        let resumed = WelcomePlan(hookStatuses: [], resumingAt: plan.resumePoint.rawValue)
        XCTAssertEqual(resumed.step, .developer)
        XCTAssertEqual(WelcomePlan(hookStatuses: [], resumingAt: "practice").step, .welcome)
        XCTAssertEqual(WelcomePlan(hookStatuses: [], resumingAt: nil).step, .welcome)
    }

    /// Someone who connected an agent since is not asked on resume either.
    func testResumeNeverAsksAConnectedDeveloper() {
        XCTAssertEqual(WelcomePlan(hookStatuses: [.installed], resumingAt: "developer").step, .welcome)
    }

    /// The welcome names a key only when holding it would ask (O7).
    func testAskWayPrefersTheHoldKeyAndAdmitsNone() {
        XCTAssertEqual(WelcomePlan.AskWay(holdKey: "⌃ Control", typeKey: "⌥Space"), .hold("⌃ Control"))
        XCTAssertEqual(WelcomePlan.AskWay(holdKey: nil, typeKey: "⌥Space"), .type("⌥Space"))
        XCTAssertEqual(WelcomePlan.AskWay(holdKey: nil, typeKey: nil), .notOn)
    }
}
