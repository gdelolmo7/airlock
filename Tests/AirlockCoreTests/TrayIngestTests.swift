import XCTest
@testable import AirlockCore

final class TrayIngestTests: XCTestCase {
    private let tray = URL(fileURLWithPath: "/Users/someone/Airlock/tray", isDirectory: true)

    private func source(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testPlansOneCopyPerSource() {
        let plan = TrayIngestPlan.plan(
            sources: [source("/Users/someone/Desktop/shot.png"),
                      source("/Users/someone/Downloads/notes.md")],
            tray: tray, existing: [], gesture: .drag(allowsMove: true))
        XCTAssertEqual(plan.names, ["shot.png", "notes.md"])
        XCTAssertEqual(plan.items.first?.destination.path,
                       "/Users/someone/Airlock/tray/shot.png")
    }

    /// Dragging an item off the shelf and back over the notch must not leave
    /// "shot 2.png" behind. A file already here is already here.
    func testSkipsSourcesAlreadyInTheTray() {
        let plan = TrayIngestPlan.plan(
            sources: [source("/Users/someone/Airlock/tray/shot.png"),
                      source("/Users/someone/Desktop/other.png")],
            tray: tray, existing: ["shot.png"], gesture: .drag(allowsMove: true))
        XCTAssertEqual(plan.names, ["other.png"])
    }

    /// A trailing slash and a `//` are the same directory; the standardized
    /// comparison is what makes the check hold for the URLs AppKit hands over.
    func testSkipIsInsensitiveToPathSpelling() {
        let plan = TrayIngestPlan.plan(
            sources: [source("/Users/someone/Airlock/tray/../tray/shot.png")],
            tray: tray, existing: [], gesture: .drag(allowsMove: true))
        XCTAssertTrue(plan.isEmpty)
    }

    func testRenamesAroundWhatIsAlreadyOnTheShelf() {
        let plan = TrayIngestPlan.plan(
            sources: [source("/Users/someone/Desktop/shot.png")],
            tray: tray, existing: ["shot.png"], gesture: .drag(allowsMove: true))
        XCTAssertEqual(plan.names, ["shot 2.png"])
    }

    /// Two files with the same name from different folders, in one drop. The
    /// second has to be renamed against the first even though the first does
    /// not exist yet.
    func testRenamesWithinASinglePlan() {
        let plan = TrayIngestPlan.plan(
            sources: [source("/Users/someone/Desktop/shot.png"),
                      source("/Users/someone/Downloads/shot.png")],
            tray: tray, existing: [], gesture: .drag(allowsMove: true))
        XCTAssertEqual(plan.names, ["shot.png", "shot 2.png"])
    }

    /// In-flight names count as taken. Two drops a moment apart would otherwise
    /// both pick "shot.png", and the second copy would fail against a file the
    /// first one had just written.
    func testInFlightNamesAreTaken() {
        let plan = TrayIngestPlan.plan(
            sources: [source("/Users/someone/Desktop/shot.png")],
            tray: tray, existing: Set(["shot.png"]).union(["shot 2.png"]),
            gesture: .drag(allowsMove: true))
        XCTAssertEqual(plan.names, ["shot 3.png"])
    }

    func testEmptyDropPlansNothing() {
        XCTAssertTrue(TrayIngestPlan.plan(sources: [], tray: tray, existing: [],
                                          gesture: .drag(allowsMove: true)).isEmpty)
    }

    /// Nothing to say is what clears the previous drop's complaint, so a clean
    /// result must report `nil` rather than an empty string.
    func testCleanResultSaysNothing() {
        XCTAssertNil(TrayIngestResult(added: 2, failures: []).message)
    }

    func testSingleFailureNamesTheFile() {
        let result = TrayIngestResult(
            added: 0, failures: [.init(name: "shot.png", reason: "Your Mac is out of space.")])
        XCTAssertEqual(result.message, "shot.png couldn't go on the Shelf. Your Mac is out of space.")
    }

    /// A run of failures counts them and explains one — the shelf is 200pt
    /// wide, and the cause is usually the same for the whole drop.
    func testSeveralFailuresAreCountedAndOneIsExplained() {
        let result = TrayIngestResult(added: 1, failures: [
            .init(name: "a.png", reason: "Your Mac is out of space."),
            .init(name: "b.png", reason: "Your Mac is out of space."),
        ])
        XCTAssertEqual(result.message, "2 items couldn't go on the Shelf. Your Mac is out of space.")
    }

    /// A partly successful drop is still a failed drop as far as the message is
    /// concerned: the files that did not arrive are the news.
    func testPartialSuccessStillReports() {
        let result = TrayIngestResult(added: 3, failures: [.init(name: "a.png", reason: "Denied")])
        XCTAssertNotNil(result.message)
    }

    // MARK: - Move or copy

    /// The decision the whole change turns on: a plain drag takes the file, so
    /// dragging something out of Downloads empties that slot in Downloads.
    func testAPlainDragMoves() {
        XCTAssertEqual(
            TrayIngestDisposition.decide(source: source("/Users/someone/Downloads/shot.png"),
                                         tray: tray, gesture: .drag(allowsMove: true)),
            .move)
    }

    /// Option is expressed by the source withdrawing `.move`, which is also how
    /// a source that will not give the file up reads. Both mean copy.
    func testADragThatWillNotGiveTheFileUpCopies() {
        XCTAssertEqual(
            TrayIngestDisposition.decide(source: source("/Volumes/Installer/App.app"),
                                         tray: tray, gesture: .drag(allowsMove: false)),
            .copy)
    }

    /// No gesture, no Option key, no way to say "leave the original" — so the
    /// non-destructive answer is the only safe one. `open -a Airlock <file>`,
    /// a share sheet, an agent handing over a path.
    func testAHandoffCopies() {
        XCTAssertEqual(
            TrayIngestDisposition.decide(source: source("/Users/someone/Downloads/shot.png"),
                                         tray: tray, gesture: .handoff),
            .copy)
    }

    // MARK: - Reading a pointer drag

    /// The catcher over the cutout can see the source's operation mask, so it
    /// is allowed to promise a move — and only when the mask says so.
    func testAMoveNeedsBothTheSourceAndTheKeyboardToAgree() {
        XCTAssertEqual(TrayIngestGesture.fromPointerDrag(sourceAllowsMove: true, optionHeld: false),
                       .drag(allowsMove: true))
        XCTAssertEqual(TrayIngestGesture.fromPointerDrag(sourceAllowsMove: true, optionHeld: true),
                       .drag(allowsMove: false))
        XCTAssertEqual(TrayIngestGesture.fromPointerDrag(sourceAllowsMove: false, optionHeld: false),
                       .drag(allowsMove: false))
    }

    /// The defect this rule exists for: SwiftUI's `DropInfo` exposes no source
    /// operation mask, so the open panel is asking about a drag that may be
    /// copy-only. It used to read "no Option, therefore move", badge `.move`
    /// and take the file. Unknown is copy, with or without the key held.
    func testAnUnknownSourceMaskCopies() {
        for optionHeld in [true, false] {
            XCTAssertEqual(
                TrayIngestGesture.fromPointerDrag(sourceAllowsMove: nil, optionHeld: optionHeld),
                .drag(allowsMove: false), "optionHeld: \(optionHeld)")
        }
    }

    /// End to end, because the badge and the file have to agree: the gesture
    /// the panel builds is one `decide` answers `.copy` for.
    func testAPanelDropLeavesTheOriginalWhereItWas() {
        XCTAssertEqual(
            TrayIngestDisposition.decide(
                source: source("/Users/someone/Downloads/shot.png"), tray: tray,
                gesture: .fromPointerDrag(sourceAllowsMove: nil, optionHeld: false)),
            .copy)
    }

    /// A file already on the shelf is refused whatever the gesture was — moving
    /// it onto itself is the one way a drop could end with nothing anywhere.
    func testAFileAlreadyOnTheShelfIsRefusedForEveryGesture() {
        let onShelf = source("/Users/someone/Airlock/tray/shot.png")
        for gesture: TrayIngestGesture in [.drag(allowsMove: true), .drag(allowsMove: false), .handoff] {
            XCTAssertEqual(TrayIngestDisposition.decide(source: onShelf, tray: tray, gesture: gesture),
                           .refuse, "\(gesture)")
        }
    }

    /// A promise-backed drag materialises into a temp file that may not exist
    /// yet. The rule never asks the filesystem anything, so "not there yet"
    /// cannot be mistaken for "cannot be moved" — the answer is the same for a
    /// path that exists and one that does not.
    func testTheRuleNeverConsultsTheFilesystem() {
        let promised = source("/private/var/folders/T/dropped-\(UUID().uuidString)/image.png")
        XCTAssertEqual(
            TrayIngestDisposition.decide(source: promised, tray: tray, gesture: .drag(allowsMove: true)),
            .move)
    }

    func testThePlanCarriesTheDispositionOntoEveryItem() {
        let moved = TrayIngestPlan.plan(
            sources: [source("/Users/someone/Desktop/a.png"), source("/Users/someone/Desktop/b.png")],
            tray: tray, existing: [], gesture: .drag(allowsMove: true))
        XCTAssertEqual(moved.items.map(\.disposition), [.move, .move])

        let copied = TrayIngestPlan.plan(
            sources: [source("/Users/someone/Desktop/a.png")],
            tray: tray, existing: [], gesture: .handoff)
        XCTAssertEqual(copied.items.map(\.disposition), [.copy])
    }

    /// Nothing planned is ever a refusal: the refused sources are the ones that
    /// never became items.
    func testAPlanNeverCarriesARefusal() {
        let plan = TrayIngestPlan.plan(
            sources: [source("/Users/someone/Airlock/tray/here.png"),
                      source("/Users/someone/Desktop/away.png")],
            tray: tray, existing: [], gesture: .drag(allowsMove: true))
        XCTAssertEqual(plan.names, ["away.png"])
        XCTAssertFalse(plan.items.contains { $0.disposition == .refuse })
    }

    // MARK: - When a move fails

    /// The rename landed and the call reported an error anyway. The file is at
    /// the destination and gone from the source: copying from a source that no
    /// longer exists would turn a success into a failure.
    func testAMoveThatLandedIsASuccess() {
        XCTAssertEqual(
            TrayMoveRecovery.after(sourceExists: false, destinationExists: true,
                                   destinationPredated: false),
            .succeeded)
    }

    /// The ordinary refusal: a read-only volume, a mounted DMG, somebody else's
    /// directory. The source is untouched, so copy from it and call the drop a
    /// success with the original left in place.
    func testARefusedMoveFallsBackToCopying() {
        XCTAssertEqual(
            TrayMoveRecovery.after(sourceExists: true, destinationExists: false,
                                   destinationPredated: false),
            .copy(clearingDestination: false))
    }

    /// A cross-volume move is a copy-then-delete underneath, so a failure
    /// partway leaves a half-written destination beside an intact source. That
    /// debris is ours and this instant's, so it is cleared before the retry —
    /// otherwise the copy fails against our own leftovers and the file arrives
    /// nowhere.
    func testAHalfWrittenDestinationIsClearedBeforeRetrying() {
        XCTAssertEqual(
            TrayMoveRecovery.after(sourceExists: true, destinationExists: true,
                                   destinationPredated: false),
            .copy(clearingDestination: true))
    }

    /// Occupied before we started. Whatever is there belongs to someone else,
    /// and the source still has the file, so nothing is lost by refusing —
    /// while overwriting would destroy something nobody asked us to touch.
    func testAPreexistingDestinationIsNeverOverwritten() {
        XCTAssertEqual(
            TrayMoveRecovery.after(sourceExists: true, destinationExists: true,
                                   destinationPredated: true),
            .giveUp)
    }

    /// No source and nothing arrived — a promise that never materialised, or a
    /// path that was wrong to begin with. There is nothing to copy from, so the
    /// failure is reported rather than dressed up as a success.
    func testNothingAnywhereIsAFailure() {
        XCTAssertEqual(
            TrayMoveRecovery.after(sourceExists: false, destinationExists: false,
                                   destinationPredated: false),
            .giveUp)
    }

    /// The source is gone but the destination was already occupied before the
    /// attempt, so what is sitting there is not the file we were handed.
    /// Claiming success would put someone else's file on the shelf under our
    /// name and report a drop that never happened.
    func testAPreexistingDestinationIsNotEvidenceTheMoveLanded() {
        XCTAssertEqual(
            TrayMoveRecovery.after(sourceExists: false, destinationExists: true,
                                   destinationPredated: true),
            .giveUp)
    }
}
