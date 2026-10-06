import XCTest
@testable import AirlockCore

/// The rule that decides whether a drag off the shelf deletes a file.
///
/// The shelf is a folder, so every `.trash` here is a real file leaving a real
/// directory. These tests are mostly about the cases that must NOT do that.
final class TrayDragOutTests: XCTestCase {
    private func decide(_ operation: TrayDragOperation,
                        sourceExists: Bool = true) -> TrayDragOutcome {
        TrayDragOutcome.decide(operation: operation, sourceExists: sourceExists)
    }

    /// The destination said, in the protocol's own words, that it took the file.
    func testAMoveTrashesTheShelfsCopy() {
        XCTAssertEqual(decide(.move), .trash)
    }

    /// Let go of over the desktop, cancelled with Escape, or refused by whatever
    /// was under the pointer. All three arrive as no operation at all, and all
    /// three must leave the file exactly where it was.
    func testAnAbandonedOrCancelledDragKeepsTheFile() {
        XCTAssertEqual(decide(.declined), .keep)
        XCTAssertEqual(decide(TrayDragOperation(rawValue: 0)), .keep)
    }

    /// The case the whole rule is shaped around: a destination that took a copy
    /// still leaves us ours, and a destination that only READ the path — a
    /// terminal pasting `~/Airlock/tray/report.pdf` into a half-typed command —
    /// answers the same way. Neither may delete anything.
    func testACopyKeepsTheFile() {
        XCTAssertEqual(decide(.copy), .keep)
    }

    func testAGenericAcceptanceIsNotEnoughToDelete() {
        XCTAssertEqual(decide(.generic), .keep)
    }

    /// An alias now points AT this file. Removing it breaks the thing the drop
    /// just created.
    func testALinkKeepsTheFile() {
        XCTAssertEqual(decide(.link), .keep)
    }

    func testAPrivatelyNegotiatedDropKeepsTheFile() {
        XCTAssertEqual(decide(.unspecified), .keep)
    }

    /// A destination is meant to answer with one operation. One that answers
    /// with two has told us nothing, and "nothing" may never mean "delete".
    func testAnAmbiguousAnswerKeepsTheFile() {
        XCTAssertEqual(decide([.copy, .move]), .keep)
        XCTAssertEqual(decide([.move, .link]), .keep)
    }

    /// `NSDragOperation.every` is every bit set — the least informative answer
    /// there is, and one a destination can return by accident.
    func testEveryOperationAtOnceKeepsTheFile() {
        XCTAssertEqual(decide(TrayDragOperation(rawValue: UInt.max)), .keep)
    }

    /// The Trash. It differs from a move only in who does the removing, and our
    /// removal route is the Trash, so the file ends up in the same place either
    /// way.
    func testDroppingOnTheTrashRemovesIt() {
        XCTAssertEqual(decide(.delete), .trash)
    }

    /// Finder answers `.move` and then does the file work itself. Asking the
    /// Trash for a file that is already gone would put an error on the shelf
    /// about a drop that worked perfectly.
    func testAMoveTheDestinationAlreadyPerformedIsNotTrashedAgain() {
        XCTAssertEqual(decide(.move, sourceExists: false), .vanished)
        XCTAssertEqual(decide(.delete, sourceExists: false), .vanished)
    }

    /// A missing file is not a licence to act: if nothing claimed the file, the
    /// answer is still the one that touches nothing.
    func testAMissingSourceWithNoOperationStillDoesNothing() {
        XCTAssertEqual(decide(.declined, sourceExists: false), .keep)
        XCTAssertEqual(decide(.copy, sourceExists: false), .keep)
    }

    /// Every operation that is not a take, checked as a set rather than one at a
    /// time — a new case added to the enum without a thought is the way this
    /// rule would go wrong.
    func testNothingButMoveAndDeleteEverRemovesAnything() {
        let takes: Set<UInt> = [TrayDragOperation.move.rawValue, TrayDragOperation.delete.rawValue]
        for bit in 0 ..< 8 {
            let operation = TrayDragOperation(rawValue: 1 << UInt(bit))
            let expected: TrayDragOutcome = takes.contains(operation.rawValue) ? .trash : .keep
            XCTAssertEqual(decide(operation), expected, "operation bit \(bit)")
        }
    }
}
