import AppKit
import AirlockCore
import XCTest
@testable import AirlockApp

/// The seam between AppKit's answer and the rule that reads it.
///
/// `TrayDragOperation` mirrors `NSDragOperation` by raw value so the decision
/// can live in Core without an AppKit import, and `TrayDragOutLayer` converts
/// one to the other with nothing but `rawValue`. That conversion is silent when
/// it is wrong: a shifted bit would turn "the destination copied it" into "the
/// destination took it", and the shelf would start deleting files people still
/// had. Nothing else would fail.
final class TrayDragOutMappingTests: XCTestCase {
    func testEveryOperationMatchesAppKitsBit() {
        XCTAssertEqual(TrayDragOperation.copy.rawValue, NSDragOperation.copy.rawValue)
        XCTAssertEqual(TrayDragOperation.link.rawValue, NSDragOperation.link.rawValue)
        XCTAssertEqual(TrayDragOperation.generic.rawValue, NSDragOperation.generic.rawValue)
        XCTAssertEqual(TrayDragOperation.unspecified.rawValue, NSDragOperation.private.rawValue)
        XCTAssertEqual(TrayDragOperation.move.rawValue, NSDragOperation.move.rawValue)
        XCTAssertEqual(TrayDragOperation.delete.rawValue, NSDragOperation.delete.rawValue)
    }

    /// What AppKit reports for a drag nobody accepted.
    func testAnEmptyOperationIsTheDeclinedOne() {
        XCTAssertEqual(TrayDragOperation(rawValue: NSDragOperation([]).rawValue),
                       TrayDragOperation.declined)
    }

    /// The one square of the tile the drag layer must not take, because the
    /// remove x lives there and a press it never receives is a button that does
    /// nothing.
    @MainActor
    func testTheRemoveAffordanceKeepsTheSizeTheTileDrawsIt() {
        XCTAssertEqual(TrayDragOutLayer.removeAffordanceSide, 20,
                       "the macOS minimum control size, and the x is drawn at it")
    }
}
