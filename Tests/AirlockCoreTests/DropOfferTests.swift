import XCTest
@testable import AirlockCore

/// What each kind of drag is offered, formats and actions apart.
final class DropOfferTests: XCTestCase {
    private func offer(_ sources: [DropSource], _ abilities: DropAbilities = .everything) -> DropOffer {
        DropOffer.make(sources: sources, abilities: abilities)
    }

    func testNothingDraggedIsOfferedNothing() {
        XCTAssertEqual(offer([]), .none)
    }

    /// Every format but its own, then one PDF; the actions under them.
    func testAPhoto() {
        let photo = offer([.picture(.heic)])
        XCTAssertFalse(photo.formats.contains(.picture(.heic)), "a HEIC copy of a HEIC is the same thing")
        XCTAssertTrue(photo.formats.contains(.picture(.jpeg)))
        XCTAssertTrue(photo.formats.contains(.picture(.webp)))
        XCTAssertEqual(photo.formats.last, .onePDF)
        XCTAssertEqual(photo.actions, [.smaller, .cutOut, .copyText, .noLocation])
        XCTAssertTrue(photo.formats.allSatisfy { !$0.isAction })
        XCTAssertTrue(photo.actions.allSatisfy(\.isAction))
    }

    /// A WebP dropped in works the other way round: it can become anything else.
    func testAWebPGoesTheOtherWay() {
        let webp = offer([.picture(.webp)])
        XCTAssertFalse(webp.formats.contains(.picture(.webp)))
        XCTAssertTrue(webp.formats.contains(.picture(.jpeg)))
        XCTAssertTrue(webp.formats.contains(.picture(.png)))
    }

    /// Only what this Mac can write: without a WebP writer there's no WebP chip.
    func testOnlyFormatsThisMacWrites() {
        let abilities = DropAbilities(writablePictures: [PictureFormat.jpeg.typeIdentifier,
                                                         PictureFormat.png.typeIdentifier],
                                      cutsOut: false)
        let photo = offer([.picture(.heic)], abilities)
        XCTAssertEqual(photo.formats, [.picture(.jpeg), .picture(.png), .onePDF])
        XCTAssertFalse(photo.actions.contains(.cutOut))
    }

    /// Mixed pictures keep every format: no one format is theirs.
    func testMixedPicturesKeepEveryFormat() {
        let mixed = offer([.picture(.heic), .picture(.png)])
        XCTAssertTrue(mixed.formats.contains(.picture(.heic)))
        XCTAssertTrue(mixed.formats.contains(.picture(.png)))
        XCTAssertEqual(mixed.actions.last, .nameInOrder, "several can be named in order")
        XCTAssertEqual(mixed.count, 2)
    }

    func testAPDF() {
        let pdf = offer([.pdf])
        XCTAssertEqual(pdf.formats, [.pages(.jpeg), .pages(.png), .pages(.tiff), .textFile])
        XCTAssertEqual(pdf.actions, [.smaller, .copyText, .splitPages])
        XCTAssertTrue(offer([.pdf, .pdf]).formats.contains(.onePDF), "two PDFs can be joined")
    }

    func testAFilm() {
        XCTAssertEqual(offer([.video(isMP4: false)]).formats, [.mp4, .gif, .soundOnly])
        XCTAssertEqual(offer([.video(isMP4: true)]).formats, [.gif, .soundOnly], "no MP4 copy of an MP4")
        XCTAssertEqual(offer([.video(isMP4: false)]).actions, [.smaller, .noSound])
    }

    /// Any sound file, MP3 included.
    func testAnyAudioFile() {
        let mp3 = offer([.audio(nil)])
        XCTAssertEqual(mp3.formats, [.audio(.m4a), .audio(.wav), .audio(.aiff)])
        XCTAssertEqual(mp3.actions, [.writeItOut, .notesFromIt])
        XCTAssertEqual(offer([.audio(.wav)]).formats, [.audio(.m4a), .audio(.aiff)])
    }

    /// Without a speech model or while notes are busy, those chips aren't there.
    func testAudioActionsNeedTheMac() {
        let abilities = DropAbilities(writablePictures: [], writesOut: false, takesNotes: false)
        XCTAssertEqual(offer([.audio(nil)], abilities).actions, [])
        XCTAssertFalse(offer([.audio(nil), .audio(nil)]).actions.contains(.notesFromIt),
                       "notes are from one recording")
    }

    func testADocument() {
        let word = offer([.document(.word)])
        XCTAssertEqual(word.formats, [.documentPDF, .textFile, .rtf])
        XCTAssertEqual(word.actions, [.copyText])
        XCTAssertFalse(offer([.document(.text)]).formats.contains(.textFile))
        XCTAssertFalse(offer([.document(.rtf)]).formats.contains(.rtf))
    }

    /// Different kinds together: a zip, one PDF when every one can be pages.
    func testSeveralKindsTogether() {
        let pages = offer([.picture(.png), .pdf, .document(.word)])
        XCTAssertEqual(pages.formats, [.zip, .onePDF])
        XCTAssertEqual(pages.actions, [.nameInOrder])

        let mixed = offer([.pdf, .video(isMP4: true)])
        XCTAssertEqual(mixed.formats, [.zip])

        let folder = offer([.folder])
        XCTAssertEqual(folder.formats, [.zip])
        XCTAssertEqual(folder.actions, [], "a folder's insides aren't renamed")
    }

    /// One file the box has nothing for: the shelf and AirDrop alone.
    func testOneOtherFileIsOfferedNothing() {
        XCTAssertTrue(offer([.other]).isEmpty)
    }

    // MARK: - Plans

    func testWebPAndCutOutAreForPlus() {
        XCTAssertEqual(DropChoice.picture(.webp).needs, .plus)
        XCTAssertEqual(DropChoice.cutOut.needs, .plus)
        XCTAssertNil(DropChoice.picture(.jpeg).needs)
        XCTAssertNil(DropChoice.notesFromIt.needs, "reading recordings into notes is already free")
        XCTAssertFalse(PlanSnapshot.free.limits.dropBoxExtras)
        XCTAssertTrue(PlanSnapshot(plan: .plus, isPaid: true).limits.dropBoxExtras)
        XCTAssertTrue(PlanSnapshot(plan: .pro, isPaid: true).limits.dropBoxExtras)
    }

    func testGoingToFreeSaysTheDropBoxChanged() {
        let lost = PlanSnapshot(plan: .plus, isPaid: true).limits.lost(goingTo: PlanSnapshot.free.limits)
        XCTAssertTrue(lost.contains(.dropBoxBasics))
        XCTAssertFalse(PlanSnapshot(plan: .pro, isPaid: true).limits.lost(goingTo: PlanSnapshot(plan: .plus, isPaid: true).limits).contains(.dropBoxBasics))
    }

    // MARK: - Sentences

    func testTheSentencesReadRight() {
        XCTAssertEqual(DropChoice.picture(.avif).caption(count: 1), "Make an AVIF copy")
        XCTAssertEqual(DropChoice.audio(.m4a).caption(count: 1), "Make an M4A copy")
        XCTAssertEqual(DropChoice.onePDF.label(count: 1), "PDF")
        XCTAssertEqual(DropChoice.onePDF.label(count: 2), "One PDF")
        XCTAssertEqual(DropChoice.zip.note(count: 3), "Putting all 3 in one zip on the shelf")
        XCTAssertEqual(DropChoice.gif.note(count: 1), "Making a GIF of it (first 10 seconds) on the shelf")
        XCTAssertEqual(DropChoice.cutOut.note(count: 1), "Removing the background on the shelf")
    }
}
