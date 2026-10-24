import XCTest
import CoreGraphics
@testable import AirlockCore

/// The box's places: what a drop lands on is what lit up.
final class DropPocketLayoutTests: XCTestCase {
    private let photo = DropOffer.make(sources: [.picture(.heic)], abilities: .everything)
    private let three = DropOffer.make(sources: [.picture(.heic), .picture(.png), .picture(.webp)],
                                       abilities: .everything)
    private let film = DropOffer.make(sources: [.video(isMP4: false)], abilities: .everything)

    private func centre(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    func testWithoutChoicesItIsTheTwoTiles() {
        let layout = DropPocketLayout(offer: .none)
        XCTAssertEqual(layout.size, CGSize(width: DropPocketLayout.width, height: DropPocketLayout.top + DropPocketLayout.tileHeight))
        XCTAssertNil(layout.caption)
        XCTAssertNil(layout.formatRow)
        XCTAssertNil(layout.separator)
        XCTAssertNil(layout.actionRow)
        XCTAssertGreaterThan(layout.shelf.width, layout.airDrop.width, "the shelf is the wide one")
        XCTAssertFalse(layout.shelf.intersects(layout.airDrop))
    }

    /// Formats on top, a thin line, actions under it, in that order down the box.
    func testFormatsThenTheLineThenActions() throws {
        let layout = DropPocketLayout(offer: photo)
        let formats = try XCTUnwrap(layout.formatRow)
        let line = try XCTUnwrap(layout.separator)
        let actions = try XCTUnwrap(layout.actionRow)
        XCTAssertGreaterThan(try XCTUnwrap(layout.caption).minY, layout.shelf.maxY)
        XCTAssertGreaterThan(formats.minY, layout.caption!.maxY)
        XCTAssertGreaterThan(line.minY, formats.maxY)
        XCTAssertGreaterThan(actions.minY, line.maxY)
        XCTAssertEqual(layout.size.height, actions.maxY)
    }

    /// One row and no line when only one kind is offered.
    func testOneRowHasNoLine() {
        let formats = DropPocketLayout(formats: 3, actions: 0)
        XCTAssertNotNil(formats.formatRow)
        XCTAssertNil(formats.separator)
        XCTAssertNil(formats.actionRow)

        let actions = DropPocketLayout(formats: 0, actions: 2)
        XCTAssertNil(actions.formatRow)
        XCTAssertNil(actions.separator)
        XCTAssertEqual(actions.actionRow?.minY, DropPocketLayout(formats: 3, actions: 0).formatRow?.minY,
                       "the actions take the first row's place")
    }

    func testEachChipTakesItsOwnDrop() {
        let layout = DropPocketLayout(offer: three)
        XCTAssertEqual(layout.target(at: centre(layout.shelf), offer: three), .shelf)
        XCTAssertEqual(layout.target(at: centre(layout.airDrop), offer: three), .airDrop)
        for (row, chips, spacing) in [(layout.formatChips!, three.formats, DropPocketLayout.stripSpacing),
                                      (layout.actionRow!, three.actions, DropPocketLayout.actionSpacing)] {
            let width = PictureRowLayout.chipWidth(rowWidth: row.width, count: chips.count, spacing: spacing)
            for (index, choice) in chips.enumerated() {
                let x = row.minX + CGFloat(index) * (width + spacing) + width / 2
                XCTAssertEqual(layout.target(at: CGPoint(x: x, y: row.midY), offer: three), .choice(choice))
            }
        }
    }

    /// Between two chips, on the sentence, on the line, in the gap between the
    /// tiles or off the box: the shelf, the harmless place.
    func testEverywhereElseIsTheShelf() {
        let layout = DropPocketLayout(offer: three)
        let row = layout.formatChips!
        let spacing = DropPocketLayout.stripSpacing
        let width = PictureRowLayout.chipWidth(rowWidth: row.width, count: three.formats.count, spacing: spacing)
        let gap = CGPoint(x: row.minX + width + spacing / 2, y: row.midY)
        XCTAssertEqual(layout.target(at: gap, offer: three), .shelf)
        XCTAssertEqual(layout.target(at: centre(layout.caption!), offer: three), .shelf)
        XCTAssertEqual(layout.target(at: centre(layout.separator!), offer: three), .shelf)
        XCTAssertEqual(layout.target(at: CGPoint(x: 1, y: layout.formatRow!.midY), offer: three), .shelf,
                       "the strip's own edge, outside its choices")
        XCTAssertEqual(layout.target(at: CGPoint(x: layout.shelf.maxX + 2, y: layout.shelf.midY),
                                     offer: three), .shelf)
        XCTAssertEqual(layout.target(at: CGPoint(x: -10, y: -10), offer: three), .shelf)
    }

    func testWithoutChoicesTheBottomIsNotAChip() {
        let layout = DropPocketLayout(offer: .none)
        XCTAssertEqual(layout.target(at: CGPoint(x: 50, y: 100), offer: .none), .shelf)
    }

    func testAFilmGetsItsOwnRows() {
        let layout = DropPocketLayout(offer: film)
        let first = layout.formatChips!
        let width = PictureRowLayout.chipWidth(rowWidth: first.width, count: film.formats.count,
                                               spacing: DropPocketLayout.stripSpacing)
        XCTAssertEqual(layout.target(at: CGPoint(x: first.minX + width / 2, y: first.midY), offer: film),
                       .choice(.mp4))
    }

    // MARK: - What it says after

    func testTheLineSaysWhatTheDropDid() {
        XCTAssertEqual(DropPocketNote.done(.shelf, count: 1).line, "Kept on the shelf")
        XCTAssertEqual(DropPocketNote.done(.airDrop, count: 1).line, "Opening AirDrop")
        XCTAssertEqual(DropPocketNote.done(.choice(.picture(.png)), count: 1).line,
                       "Making a PNG copy on the shelf")
        XCTAssertEqual(DropPocketNote.done(.choice(.picture(.avif)), count: 1).line,
                       "Making an AVIF copy on the shelf")
        XCTAssertEqual(DropPocketNote.done(.choice(.picture(.jpeg)), count: 3).line,
                       "Making 3 JPG copies on the shelf")
        XCTAssertEqual(DropPocketNote.done(.choice(.onePDF), count: 3).line,
                       "Putting all 3 in one PDF on the shelf")
        XCTAssertEqual(DropPocketNote.done(.choice(.smaller), count: 1).line,
                       "Making a smaller copy on the shelf", "what follows the comma is for before the drop")
        XCTAssertEqual(DropPocketNote.done(.choice(.copyText), count: 1).line,
                       "Reading the words, then they're yours to paste")
        XCTAssertTrue(DropPocketNote.done(.shelf, count: 1).ok)
    }

    func testALockedChipSaysWhyAndKeepsNothing() {
        let note = DropPocketNote.locked(.picture(.webp))
        XCTAssertTrue(note.ok, "the file stays where it was, so nothing went wrong")
        XCTAssertEqual(note.line, "WebP copies come with Plus.")
    }

    func testARefusalSaysWhy() {
        let note = DropPocketNote.refused("AirDrop isn't available for Notes.txt.")
        XCTAssertFalse(note.ok)
        XCTAssertEqual(note.line, "AirDrop isn't available for Notes.txt.")
        XCTAssertEqual(DropPocketNote.refused(nil).line, "That couldn't go on the shelf.")
    }
}
