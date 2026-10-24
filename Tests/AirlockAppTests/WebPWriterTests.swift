import CoreGraphics
import ImageIO
import XCTest
@testable import AirlockApp

/// The vendored encoder against the Mac's own decoder: a WebP is only a WebP
/// if ImageIO, which everything else on the Mac reads pictures with, agrees.
final class WebPWriterTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A 4×2 picture, columns left to right: clear, clear, half-clear red, red.
    /// The red is sRGB's own: `CGColor(red:green:blue:alpha:)` is Generic RGB,
    /// whose red lands in sRGB with some green in it.
    private func picture() -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: 4, height: 2))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 0.5])!)
        context.fill(CGRect(x: 2, y: 0, width: 1, height: 2))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 3, y: 0, width: 1, height: 2))
        return context.makeImage()!
    }

    /// What ImageIO makes of the bytes: its type, and the picture itself.
    private func decode(_ data: Data) throws -> (type: String, image: CGImage) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try XCTUnwrap(CGImageSourceGetType(source)) as String
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (type, image)
    }

    /// The top row's pixels as premultiplied red-green-blue-alpha, four bytes
    /// each: a half-clear full red reads back as red 128, and as 64 if the
    /// writer had handed the encoder premultiplied colour.
    private func topRow(of image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Array(pixels[0..<(image.width * 4)])
    }

    func testIsAvailable() {
        XCTAssertTrue(WebPWriter.isAvailable)
    }

    func testLosslessKeepsSizeAndSeeThrough() throws {
        let data = try XCTUnwrap(WebPWriter.data(from: picture(), lossless: true))
        let (type, image) = try decode(data)
        XCTAssertEqual(type, "org.webmproject.webp")
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 2)

        let row = topRow(of: image)
        XCTAssertEqual(row[3], 0, "a clear pixel stays clear")
        XCTAssertEqual(row[7], 0, "a clear pixel stays clear")
        XCTAssertEqual(Double(row[11]), 128, accuracy: 1, "a half-clear pixel stays half-clear")
        XCTAssertEqual(Double(row[8]), 128, accuracy: 2, "and keeps its colour, not a darker one")
        XCTAssertEqual(Array(row[12..<16]), [255, 0, 0, 255], "an opaque pixel is exact")
    }

    func testLossyMakesAReadableWebP() throws {
        let data = try XCTUnwrap(WebPWriter.data(from: picture(), quality: 80))
        let (type, image) = try decode(data)
        XCTAssertEqual(type, "org.webmproject.webp")
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 2)
        XCTAssertLessThan(topRow(of: image)[3], 16, "lossy WebP keeps see-through pixels too")
    }

    /// The shelf's own path: a PNG on disk made into a WebP copy beside it,
    /// exact because a PNG is, and the original left as it was.
    func testTheShelfMakesAWebPCopyOfAPNG() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("Logo.png")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, picture(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let before = try Data(contentsOf: png)

        let copy = folder.appendingPathComponent("Logo.webp")
        try PictureConverter.convert(.file(png), to: .webp, at: copy)
        let (type, image) = try decode(try Data(contentsOf: copy))
        XCTAssertEqual(type, "org.webmproject.webp")
        XCTAssertEqual(topRow(of: image)[15], 255, "lossless keeps the red exactly")
        XCTAssertEqual(try Data(contentsOf: png), before, "the original is not touched")
        XCTAssertTrue(DropReader.writablePictures.contains("org.webmproject.webp"))
    }
}
