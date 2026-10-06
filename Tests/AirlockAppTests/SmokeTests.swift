import XCTest
@testable import AirlockApp

@MainActor
final class SmokeTests: XCTestCase {
    func testTheAppTargetCanBeImportedAtAll() {
        XCTAssertEqual(AudioOutputModel.visibleLimit, 3)
    }
}
