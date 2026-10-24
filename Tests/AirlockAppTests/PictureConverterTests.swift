import AppKit
import ImageIO
import XCTest
import AirlockCore
@testable import AirlockApp

/// Real pictures through the real encoders: what the format row promises is
/// only true if ImageIO on this Mac does it.
final class PictureConverterTests: XCTestCase {
    private var folder: URL!
    private var tray: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PictureConverterTests-\(UUID().uuidString)", isDirectory: true)
        tray = folder.appendingPathComponent("tray", isDirectory: true)
        try FileManager.default.createDirectory(at: tray, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A 4×2 picture, see-through on its left half when `clear` is set.
    private func picture(_ name: String, type: String = "public.png", clear: Bool = false) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        if clear { context.clear(CGRect(x: 0, y: 0, width: 2, height: 2)) }
        let url = folder.appendingPathComponent(name)
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(writer, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return url
    }

    private func type(of url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(CGImageSourceGetType) as String?
    }

    private func pixel(_ url: URL, x: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: 4 * image.width * image.height)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: 4 * image.width, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (bytes[4 * x], bytes[4 * x + 1], bytes[4 * x + 2])
    }

    func testThisMacWritesTheEverydayFormats() {
        for format in [PictureFormat.jpeg, .png, .tiff] {
            XCTAssertTrue(PictureConverter.writableTypeIdentifiers.contains(format.typeIdentifier), format.label)
        }
    }

    func testCopyIsInTheNewFormatAndTheOriginalIsUntouched() throws {
        let original = try picture("Logo.png")
        let before = try Data(contentsOf: original)
        let result = PictureConverter.run([.file(original)], target: .format(.tiff),
                                          names: ["Logo.tiff"], tray: tray)
        XCTAssertEqual(result.made, 1)
        XCTAssertNil(result.message)
        XCTAssertEqual(type(of: tray.appendingPathComponent("Logo.tiff")), "public.tiff")
        XCTAssertEqual(try Data(contentsOf: original), before)
    }

    /// A clear background turns white in a JPEG, not black.
    func testSeeThroughPixelsBecomeWhiteInAJPEG() throws {
        let original = try picture("Badge.png", clear: true)
        let result = PictureConverter.run([.file(original)], target: .format(.jpeg),
                                          names: ["Badge.jpg"], tray: tray)
        XCTAssertEqual(result.made, 1)
        let copy = tray.appendingPathComponent("Badge.jpg")
        XCTAssertEqual(type(of: copy), "public.jpeg")
        let clearSide = try pixel(copy, x: 0)
        XCTAssertGreaterThan(clearSide.green, 200, "the clear half went dark: \(clearSide)")
        XCTAssertGreaterThan(clearSide.blue, 200, "the clear half went dark: \(clearSide)")
        let redSide = try pixel(copy, x: 3)
        XCTAssertGreaterThan(redSide.red, 200)
        XCTAssertLessThan(redSide.green, 60)
    }

    func testPixelsWithNoFileBehindThemAreCopiedToo() throws {
        let data = try Data(contentsOf: picture("web.png"))
        let result = PictureConverter.run([.data(data, name: "puppy.png")], target: .format(.jpeg),
                                          names: ["puppy.jpg"], tray: tray)
        XCTAssertEqual(result.made, 1)
        XCTAssertEqual(type(of: tray.appendingPathComponent("puppy.jpg")), "public.jpeg")
    }

    func testPicturesGoIntoOnePDFAPageEach() throws {
        let first = try picture("Front.png")
        let second = try picture("Back.jpg", type: "public.jpeg")
        let result = PictureConverter.run([.file(first), .file(second)], target: .onePDF,
                                          names: ["Front.pdf"], tray: tray)
        XCTAssertEqual(result.made, 1)
        XCTAssertNil(result.message)
        let pdf = try XCTUnwrap(CGPDFDocument(tray.appendingPathComponent("Front.pdf") as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 2)
        // 4×2 pixels at the default 72 per inch is a 4×2 point page.
        XCTAssertEqual(pdf.page(at: 1)?.getBoxRect(.mediaBox).size, CGSize(width: 4, height: 2))
    }

    func testSomethingThatIsNotAPictureSaysSo() throws {
        let text = folder.appendingPathComponent("notes.png")
        try Data("not a picture".utf8).write(to: text)
        let result = PictureConverter.run([.file(text)], target: .format(.jpeg),
                                          names: ["notes.jpg"], tray: tray)
        XCTAssertEqual(result.made, 0)
        XCTAssertEqual(result.message,
                       "notes.png couldn't be copied as JPG. \(PictureConversionResult.unreadable)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tray.appendingPathComponent("notes.jpg").path))
    }

    /// One unreadable page means no PDF, not a PDF with a page missing.
    func testOnePDFIsAllOrNothing() throws {
        let good = try picture("a.png")
        let bad = folder.appendingPathComponent("b.png")
        try Data("nope".utf8).write(to: bad)
        let result = PictureConverter.run([.file(good), .file(bad)], target: .onePDF,
                                          names: ["a.pdf"], tray: tray)
        XCTAssertEqual(result.made, 0)
        XCTAssertEqual(result.message, "The PDF couldn't be made. \(PictureConversionResult.unreadable)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tray.appendingPathComponent("a.pdf").path))
    }

    /// A name taken between choosing it and writing fails the copy; it never
    /// replaces what took it.
    func testACopyNeverOverwrites() throws {
        let original = try picture("Photo.png")
        let squatter = tray.appendingPathComponent("Photo.tiff")
        try Data("mine".utf8).write(to: squatter)
        let result = PictureConverter.run([.file(original)], target: .format(.tiff),
                                          names: ["Photo.tiff"], tray: tray)
        XCTAssertEqual(result.made, 0)
        XCTAssertNotNil(result.message)
        XCTAssertEqual(try Data(contentsOf: squatter), Data("mine".utf8))
        // Nothing left behind beside the shelf either.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tray.path), ["Photo.tiff"])
    }

    func testHEICWhenThisMacCanWriteIt() throws {
        try XCTSkipUnless(PictureConverter.writableTypeIdentifiers.contains(PictureFormat.heic.typeIdentifier))
        let original = try picture("Shot.png")
        let result = PictureConverter.run([.file(original)], target: .format(.heic),
                                          names: ["Shot.heic"], tray: tray)
        XCTAssertEqual(result.made, 1)
        XCTAssertEqual(type(of: tray.appendingPathComponent("Shot.heic")), "public.heic")
    }

    /// The offer is read off a pasteboard: pictures get a row, anything else
    /// on the drag means none.
    @MainActor
    func testOfferReadsTheDrag() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("PictureConverterTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let photo = try picture("IMG_1.heic", type: "public.heic")
        board.clearContents()
        board.writeObjects([photo as NSURL])
        let offer = PictureConverter.offer(on: board)
        XCTAssertFalse(offer.isEmpty)
        XCTAssertFalse(offer.targets.contains(.format(.heic)))
        XCTAssertTrue(offer.targets.contains(.format(.jpeg)))

        let notes = folder.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: notes)
        board.clearContents()
        board.writeObjects([photo as NSURL, notes as NSURL])
        XCTAssertTrue(PictureConverter.offer(on: board).isEmpty)
    }

    /// A smaller moving GIF still moves: every frame scaled, each with its
    /// delay, the loop count kept.
    func testSmallerGIFKeepsEveryFrame() throws {
        let url = folder.appendingPathComponent("moving.gif")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 3, nil))
        CGImageDestinationSetProperties(writer, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
                                            as CFDictionary)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for (index, red) in [1.0, 0.5, 0.0].enumerated() {
            let context = CGContext(data: nil, width: 3000, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for x in stride(from: 0, to: 3000, by: 7) {
                context.setFillColor(CGColor(red: red, green: Double(x % 255) / 255, blue: Double(index) / 2, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: 7, height: 60))
            }
            CGImageDestinationAddImage(writer, context.makeImage()!,
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(writer))

        let smaller = tray.appendingPathComponent("moving smaller.gif")
        try DropPictureWork.smaller(.file(url), at: smaller)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(smaller as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        let frame = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 1, nil) as? [CFString: Any])
        XCTAssertEqual(frame[kCGImagePropertyPixelWidth] as? Int, DropPictureWork.smallerSide)
        let gif = try XCTUnwrap(frame[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual(gif[kCGImagePropertyGIFDelayTime] as? Double ?? 0, 0.2, accuracy: 0.01)
    }
}
