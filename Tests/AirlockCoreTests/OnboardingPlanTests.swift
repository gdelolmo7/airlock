import XCTest
@testable import AirlockCore

final class OnboardingPlanTests: XCTestCase {
    func testStartsAtWelcome() {
        XCTAssertEqual(OnboardingPlan().step, .welcome)
        XCTAssertTrue(OnboardingPlan().isFirst)
        XCTAssertFalse(OnboardingPlan().isLast)
    }

    func testAdvanceWalksEveryStepInOrder() {
        var plan = OnboardingPlan()
        var seen: [OnboardingPlan.Step] = [plan.step]
        while !plan.isLast {
            plan.advance()
            seen.append(plan.step)
        }
        XCTAssertEqual(seen, [.welcome, .agents, .features, .permissions, .finish])
    }

    /// Both ends clamp instead of trapping — the buttons that drive this are
    /// disabled at the ends, and a disabled-state bug must not be a crash.
    func testAdvancePastTheEndStays() {
        var plan = OnboardingPlan(index: OnboardingPlan.Step.allCases.count - 1)
        XCTAssertTrue(plan.isLast)
        plan.advance()
        XCTAssertEqual(plan.step, .finish)
    }

    func testRetreatBeforeTheStartStays() {
        var plan = OnboardingPlan()
        plan.retreat()
        XCTAssertEqual(plan.step, .welcome)
    }

    func testOutOfRangeInitClamps() {
        XCTAssertEqual(OnboardingPlan(index: 99).step, .finish)
        XCTAssertEqual(OnboardingPlan(index: -4).step, .welcome)
    }

    /// The counter the in-panel wizard prints. 1-based and ending exactly at
    /// `stepCount`, because "step 0 of 5" and "step 6 of 5" are both reachable
    /// from an index the view does its own arithmetic on.
    func testPositionIsOneBasedAndEndsAtStepCount() {
        var plan = OnboardingPlan()
        XCTAssertEqual(plan.position, 1)
        var seen: [Int] = [plan.position]
        while !plan.isLast {
            plan.advance()
            seen.append(plan.position)
        }
        XCTAssertEqual(seen, [1, 2, 3, 4, 5])
        XCTAssertEqual(plan.position, plan.stepCount)
    }

    func testJumpMovesToNamedStep() {
        var plan = OnboardingPlan()
        plan.jump(to: .permissions)
        XCTAssertEqual(plan.step, .permissions)
        XCTAssertFalse(plan.isFirst)
    }

    // MARK: - Suppression

    func testFreshInstallIsPresented() {
        XCTAssertTrue(OnboardingPlan.shouldPresent(hasCompletedSetup: false,
                                                   hookStatuses: [.notInstalled, .notInstalled]))
    }

    func testCompletedSetupIsNeverPresentedAgain() {
        XCTAssertFalse(OnboardingPlan.shouldPresent(hasCompletedSetup: true,
                                                    hookStatuses: [.notInstalled]))
    }

    /// Someone who ran `airlock-setup install` by hand already did the one
    /// step that matters. Greeting that with a wizard is noise.
    func testExistingHookInstallSuppresses() {
        XCTAssertFalse(OnboardingPlan.shouldPresent(hasCompletedSetup: false,
                                                    hookStatuses: [.notInstalled, .installed]))
    }

    /// A conflict is a broken install, not a finished one — the agents step is
    /// where there is room to explain what is in the way.
    func testConflictStillPresents() {
        XCTAssertTrue(OnboardingPlan.shouldPresent(
            hasCompletedSetup: false,
            hookStatuses: [.conflict("hook points somewhere else"), .notInstalled]))
    }

    /// No registered agents at all shouldn't wedge the app shut on first run.
    func testNoAgentsStillPresents() {
        XCTAssertTrue(OnboardingPlan.shouldPresent(hasCompletedSetup: false, hookStatuses: []))
    }

    // MARK: - Resume (card B5)

    /// Quit halfway, open again: the same step, not the welcome.
    func testResumesAtTheSavedStep() {
        XCTAssertEqual(OnboardingPlan(resumingAt: "permissions").step, .permissions)
        XCTAssertEqual(OnboardingPlan(resumingAt: "finish").step, .finish)
    }

    /// Nothing saved, or a step that no longer exists, starts at the
    /// beginning rather than guessing.
    func testUnknownOrMissingStartsAtTheWelcome() {
        XCTAssertEqual(OnboardingPlan(resumingAt: nil).step, .welcome)
        XCTAssertEqual(OnboardingPlan(resumingAt: "dictation").step, .welcome)
        XCTAssertEqual(OnboardingPlan(resumingAt: "").step, .welcome)
    }

    /// Every step's raw value survives the trip, so whatever is saved resumes.
    func testEveryStepRoundTrips() {
        for step in OnboardingPlan.Step.allCases {
            XCTAssertEqual(OnboardingPlan(resumingAt: step.rawValue).step, step)
        }
    }

    /// Connected an agent at step two, then quit: still picked up, because
    /// the saved step says setup was under way rather than done elsewhere.
    func testSetupLeftHalfwayOutranksAnInstalledHook() {
        XCTAssertTrue(OnboardingPlan.shouldPresent(hasCompletedSetup: false,
                                                   hookStatuses: [.installed], leftHalfway: true))
        XCTAssertFalse(OnboardingPlan.shouldPresent(hasCompletedSetup: true,
                                                    hookStatuses: [], leftHalfway: true),
                       "finished is finished")
    }
}
