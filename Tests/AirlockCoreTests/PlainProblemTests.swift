import XCTest
@testable import AirlockCore

/// macOS's sentences stay in the log; the screen gets one of a few plain causes.
final class PlainProblemTests: XCTestCase {
    func testAFullDiskSaysSo() {
        XCTAssertEqual(PlainProblem.file(domain: NSCocoaErrorDomain, code: 640), "Your Mac is out of space.")
        XCTAssertEqual(PlainProblem.file(domain: NSPOSIXErrorDomain, code: 28), "Your Mac is out of space.")
    }

    func testARefusalSaysAirlockIsNotAllowed() {
        for (domain, code) in [(NSCocoaErrorDomain, 513), (NSCocoaErrorDomain, 257),
                               (NSPOSIXErrorDomain, 13), (NSPOSIXErrorDomain, 1)] {
            XCTAssertEqual(PlainProblem.file(domain: domain, code: code), "Airlock doesn't have permission for it.")
        }
    }

    func testAVanishedFileSaysItMoved() {
        XCTAssertEqual(PlainProblem.file(domain: NSCocoaErrorDomain, code: 260), "It's no longer where it was.")
        XCTAssertEqual(PlainProblem.file(domain: NSPOSIXErrorDomain, code: 2), "It's no longer where it was.")
    }

    func testAnythingElseFallsBackToTryAgain() {
        XCTAssertEqual(PlainProblem.file(domain: "SomeDomain", code: 99), PlainProblem.fallback)
    }

    func testAnErrorValueIsReadByItsCode() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 640,
                            userInfo: [NSLocalizedDescriptionKey: "The volume is full"])
        XCTAssertEqual(PlainProblem.file(error), "Your Mac is out of space.")
    }
}
