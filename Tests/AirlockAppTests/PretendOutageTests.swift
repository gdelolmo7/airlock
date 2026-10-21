import XCTest
@testable import AirlockApp

/// The test run is started without `--outage`, like every real launch, so
/// these pin that the dead server then stays out of the way.
final class PretendOutageTests: XCTestCase {
    func testOffWithoutTheFlag() {
        XCTAssertNil(PretendOutage.failure)
        XCTAssertFalse(PretendOutage.hidesAppleIntelligence)
    }

    func testSessionsAreLeftAlone() {
        let configuration = URLSessionConfiguration.ephemeral
        let before = configuration.protocolClasses?.map { ObjectIdentifier($0) }
        PretendOutage.apply(to: configuration)
        XCTAssertEqual(configuration.protocolClasses?.map { ObjectIdentifier($0) }, before)
        XCTAssertTrue(PretendOutage.shared === URLSession.shared)
    }

    func testTheDeadServerTakesNothing() {
        XCTAssertFalse(DeadServer.canInit(with: URLRequest(url: URL(string: "https://useairlock.app/")!)))
    }
}
