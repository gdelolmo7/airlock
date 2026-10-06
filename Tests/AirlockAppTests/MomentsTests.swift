import XCTest
import AirlockCore
@testable import AirlockApp

/// The announcer's own contract: listeners hear a moment once per burst,
/// and only the moment they listen to.
@MainActor
final class MomentsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testAListenerHearsABurstOnce() {
        let moments = Moments()
        var heard = 0
        moments.listen(to: .gateArrived) { heard += 1 }
        moments.announce(.gateArrived, now: t0)
        moments.announce(.gateArrived, now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(heard, 1)
        moments.announce(.gateArrived, now: t0.addingTimeInterval(1))
        XCTAssertEqual(heard, 2)
    }

    func testAListenerHearsOnlyItsMoment() {
        let moments = Moments()
        var ticks = 0
        moments.listen(to: .pointerArrived) { ticks += 1 }
        moments.announce(.islandOpened, now: t0)
        moments.announce(.gateArrived, now: t0)
        XCTAssertEqual(ticks, 0)
        moments.announce(.pointerArrived, now: t0)
        XCTAssertEqual(ticks, 1)
    }
}
