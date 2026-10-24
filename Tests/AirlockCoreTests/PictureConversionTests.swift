import XCTest
@testable import AirlockCore

final class PictureConversionTests: XCTestCase {
    /// Every format the row knows, as if this Mac could write them all.
    private let everything = Set(PictureFormat.allCases.map(\.typeIdentifier))

    // MARK: Formats

    func testFileNamesMapToTheirFormat() {
        XCTAssertEqual(PictureFormat.of(fileExtension: "JPG"), .jpeg)
        XCTAssertEqual(PictureFormat.of(fileExtension: "jpeg"), .jpeg)
        XCTAssertEqual(PictureFormat.of(fileExtension: "heif"), .heic)
        XCTAssertEqual(PictureFormat.of(fileExtension: "tif"), .tiff)
        XCTAssertEqual(PictureFormat.of(fileExtension: "WebP"), .webp)
        XCTAssertEqual(PictureFormat.of(fileExtension: "BMP"), .bmp)
        XCTAssertNil(PictureFormat.of(fileExtension: "psd"))
        XCTAssertNil(PictureFormat.of(fileExtension: ""))
    }

    func testEveryFormatReadsBackFromWhatItWrites() {
        for format in PictureFormat.allCases {
            XCTAssertEqual(PictureFormat.of(fileExtension: format.fileExtension), format)
            XCTAssertEqual(PictureFormat.of(typeIdentifier: format.typeIdentifier), format)
        }
        XCTAssertEqual(PictureFormat.of(typeIdentifier: "com.google.webp"), .webp)
        XCTAssertNil(PictureFormat.of(typeIdentifier: "com.adobe.photoshop-image"))
    }

    func testOnlyJPEGLosesTransparency() {
        XCTAssertEqual(PictureFormat.allCases.filter { !$0.keepsTransparency }, [.jpeg])
    }

    // MARK: What the row says

    func testActionSaysWhatADropMakes() {
        XCTAssertEqual(PictureTarget.format(.png).action(count: 1), "Make a PNG copy")
        XCTAssertEqual(PictureTarget.format(.avif).action(count: 1), "Make an AVIF copy")
        XCTAssertEqual(PictureTarget.format(.jpeg).action(count: 3), "Make 3 JPG copies")
        XCTAssertEqual(PictureTarget.onePDF.action(count: 4), "Put all 4 in one PDF")
        XCTAssertEqual(PictureTarget.onePDF.label, "One PDF")
    }

    // MARK: The offer

    /// A HEIC from a phone is offered every other format, not HEIC itself:
    /// a HEIC copy of a HEIC is the same picture twice.
    func testOneHEICIsOfferedEveryOtherFormat() {
        let offer = PictureOffer.make(sources: [.picture(.heic)], writable: everything)
        XCTAssertEqual(offer.targets, [.format(.jpeg), .format(.png), .format(.webp), .format(.avif),
                                       .format(.tiff), .format(.gif), .format(.bmp)])
        XCTAssertEqual(offer.count, 1)
    }

    func testFormatsThisMacCantWriteAreNeverOffered() {
        let offer = PictureOffer.make(sources: [.picture(.png)],
                                      writable: ["public.jpeg", "public.png", "public.heic"])
        XCTAssertEqual(offer.targets, [.format(.jpeg), .format(.heic)])
    }

    /// Anything that isn't a picture on the drag means no row at all: the
    /// drop goes on the shelf as it always did.
    func testAnythingButPicturesGetsNoRow() {
        XCTAssertTrue(PictureOffer.make(sources: [.picture(.png), .other], writable: everything).isEmpty)
        XCTAssertTrue(PictureOffer.make(sources: [.other], writable: everything).isEmpty)
        XCTAssertTrue(PictureOffer.make(sources: [], writable: everything).isEmpty)
        XCTAssertEqual(PictureOffer.none.count, 0)
    }

    /// Mixed formats keep every format (each changes at least one of them),
    /// and two pictures or more can be gathered into one PDF.
    func testMixedPicturesKeepEveryFormatAndGainOnePDF() {
        let offer = PictureOffer.make(sources: [.picture(.png), .picture(.heic)], writable: everything)
        XCTAssertEqual(offer.targets.count, PictureFormat.allCases.count + 1)
        XCTAssertEqual(offer.targets.last, .onePDF)
        XCTAssertEqual(offer.count, 2)
    }

    func testSameFormatPicturesDropThatFormatButKeepOnePDF() {
        let offer = PictureOffer.make(sources: [.picture(.jpeg), .picture(.jpeg)], writable: everything)
        XCTAssertFalse(offer.targets.contains(.format(.jpeg)))
        XCTAssertTrue(offer.targets.contains(.onePDF))
    }

    /// A picture in a format the row doesn't name (a BMP) is still a picture,
    /// and every named format is new to it.
    func testUnnamedPictureFormatIsOfferedEverything() {
        let offer = PictureOffer.make(sources: [.picture(nil)], writable: everything)
        XCTAssertEqual(offer.targets.count, PictureFormat.allCases.count)
        XCTAssertFalse(offer.targets.contains(.onePDF))
    }

    // MARK: The row's layout

    func testChipsShareTheWidthEvenly() {
        // 3 chips, 2 gaps of 6: (120 - 12) / 3 = 36.
        XCTAssertEqual(PictureRowLayout.chipWidth(rowWidth: 120, count: 3), 36)
        XCTAssertEqual(PictureRowLayout.chipWidth(rowWidth: 120, count: 0), 0)
    }

    func testAPointLandsOnTheChipUnderIt() {
        // Chips at 0–36, 42–78, 84–120.
        XCTAssertEqual(PictureRowLayout.index(atX: 0, rowWidth: 120, count: 3), 0)
        XCTAssertEqual(PictureRowLayout.index(atX: 36, rowWidth: 120, count: 3), 0)
        XCTAssertEqual(PictureRowLayout.index(atX: 50, rowWidth: 120, count: 3), 1)
        XCTAssertEqual(PictureRowLayout.index(atX: 120, rowWidth: 120, count: 3), 2)
    }

    /// Between two chips is neither: the shelf takes it, harmlessly.
    func testGapsAndOutsideLandOnNoChip() {
        XCTAssertNil(PictureRowLayout.index(atX: 39, rowWidth: 120, count: 3))
        XCTAssertNil(PictureRowLayout.index(atX: -1, rowWidth: 120, count: 3))
        XCTAssertNil(PictureRowLayout.index(atX: 121, rowWidth: 120, count: 3))
        XCTAssertNil(PictureRowLayout.index(atX: 10, rowWidth: 120, count: 0))
    }

    func testOfferHitTestsInPanelSpace() {
        let offer = PictureOffer.make(sources: [.picture(.heic)], writable: ["public.jpeg", "public.png"])
        let row = CGRect(x: 20, y: 200, width: 120, height: PictureRowLayout.height)
        // Two chips: 20–77 and 83–140.
        XCTAssertEqual(offer.target(at: CGPoint(x: 30, y: 210), row: row), .format(.jpeg))
        XCTAssertEqual(offer.target(at: CGPoint(x: 100, y: 210), row: row), .format(.png))
        XCTAssertNil(offer.target(at: CGPoint(x: 80, y: 210), row: row))
        XCTAssertNil(offer.target(at: CGPoint(x: 30, y: 190), row: row))
        XCTAssertNil(offer.target(at: CGPoint(x: 30, y: 231), row: row))
        XCTAssertNil(PictureOffer.none.target(at: CGPoint(x: 30, y: 210), row: row))
    }

    // MARK: Names

    func testCopiesKeepTheirNameWithTheNewEnding() {
        XCTAssertEqual(PictureCopyNames.names(for: ["IMG_0042.HEIC", "Logo.webp"],
                                              target: .format(.png), existing: []),
                       ["IMG_0042.png", "Logo.png"])
    }

    /// The original stays on the shelf beside its copy, and two pictures of
    /// the same name never fight over one copy.
    func testCopiesNeverTakeANameAlreadyUsed() {
        XCTAssertEqual(PictureCopyNames.names(for: ["Beach.heic", "Beach.webp"],
                                              target: .format(.png), existing: ["Beach.png"]),
                       ["Beach 2.png", "Beach 3.png"])
    }

    func testOnePDFIsNamedAfterTheFirstPicture() {
        XCTAssertEqual(PictureCopyNames.names(for: ["Receipt.jpg", "Back.jpg"],
                                              target: .onePDF, existing: ["Receipt.pdf"]),
                       ["Receipt 2.pdf"])
        XCTAssertEqual(PictureCopyNames.names(for: [], target: .onePDF, existing: []), [])
    }

    func testANamelessPictureIsCalledPicture() {
        XCTAssertEqual(PictureCopyNames.names(for: [""], target: .format(.jpeg), existing: []),
                       ["Picture.jpg"])
    }

    // MARK: Messages

    func testEveryCopyMadeSaysNothing() {
        XCTAssertNil(PictureConversionResult(target: .format(.png), made: 2, failures: []).message)
    }

    func testFailuresSayWhatWentWrong() {
        let one = PictureConversionResult(
            target: .format(.webp), made: 0,
            failures: [.init(name: "Scan.tiff", reason: PictureConversionResult.unwritable)])
        XCTAssertEqual(one.message, "Scan.tiff couldn't be copied as WebP. This Mac couldn't write that format.")

        let two = PictureConversionResult(
            target: .format(.png), made: 1,
            failures: [.init(name: "a.heic", reason: PictureConversionResult.unreadable),
                       .init(name: "b.heic", reason: PictureConversionResult.unreadable)])
        XCTAssertEqual(two.message, "2 pictures couldn't be copied as PNG. It isn't a picture this Mac can open.")

        let pdf = PictureConversionResult(
            target: .onePDF, made: 0,
            failures: [.init(name: "a.jpg", reason: PictureConversionResult.unreadable)])
        XCTAssertEqual(pdf.message, "The PDF couldn't be made. It isn't a picture this Mac can open.")
    }
}
