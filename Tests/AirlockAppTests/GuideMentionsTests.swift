import AirlockCore
import XCTest
@testable import AirlockApp

/// A copy without the guide never sells it or names its sounds. The public
/// download has no guide, and its payment window listed "The guide: help on
/// screen with everyday tasks" first among what a subscription buys.
@MainActor
final class GuideMentionsTests: XCTestCase {

    func testWithoutTheGuideNothingSaysGuide() {
        var lines = PurchaseView.benefits(guide: false)
        lines.append(LicensePane.pitch(guide: false))
        lines += SoundLevel.allCases.map { $0.explanation(guide: false) }
        for line in lines {
            XCTAssertNil(line.range(of: "guide", options: .caseInsensitive), line)
        }
    }

    /// The owner's copy still says everything it has.
    func testWithTheGuideItIsNamed() {
        XCTAssertTrue(PurchaseView.benefits(guide: true).first?.hasPrefix("The guide") == true)
        XCTAssertTrue(LicensePane.pitch(guide: true).contains("the guide that helps"))
        XCTAssertTrue(SoundLevel.important.explanation(guide: true).contains("the guide reaches your goal"))
        XCTAssertTrue(SoundLevel.all.explanation(guide: true).contains("the guide has to stop"))
    }

    /// Dropping the guide drops only the guide.
    func testTheRestOfTheListStays() {
        XCTAssertEqual(PurchaseView.benefits(guide: true).dropFirst().map { $0 },
                       PurchaseView.benefits(guide: false))
    }
}
