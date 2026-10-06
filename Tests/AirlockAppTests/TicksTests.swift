import AppKit
import XCTest
import AirlockCore
@testable import AirlockApp

/// The tick wiring (card D3): each ticking moment reaches the actuator once,
/// with its strength, and the Settings switch silences all of them. Neither a
/// real preference nor the real actuator is touched.
@MainActor
final class TicksTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testEachTickingMomentBumpsOnceWithItsStrength() {
        let moments = Moments()
        var felt: [NSHapticFeedbackManager.FeedbackPattern] = []
        Ticks.listen(to: moments, enabled: { true }, perform: { felt.append($0) })

        moments.announce(.approved, now: t0)
        moments.announce(.approved, now: t0.addingTimeInterval(0.1))
        moments.announce(.fileDropped, now: t0)
        moments.announce(.tabChanged, now: t0)
        XCTAssertEqual(felt, [.levelChange, .generic, .alignment])
    }

    func testBackgroundMomentsDoNotReachTheTrackpad() {
        let moments = Moments()
        var felt = 0
        Ticks.listen(to: moments, enabled: { true }, perform: { _ in felt += 1 })
        moments.announce(.gateArrived, now: t0)
        moments.announce(.agentFinished, now: t0)
        moments.announce(.copied, now: t0)
        XCTAssertEqual(felt, 0)
    }

    func testTheSwitchSilencesEveryTick() {
        let moments = Moments()
        var on = false
        var felt = 0
        Ticks.listen(to: moments, enabled: { on }, perform: { _ in felt += 1 })
        moments.announce(.denied, now: t0)
        moments.announce(.scrolledToEnd, now: t0)
        XCTAssertEqual(felt, 0)
        on = true
        moments.announce(.denied, now: t0.addingTimeInterval(1))
        XCTAssertEqual(felt, 1)
    }
}
