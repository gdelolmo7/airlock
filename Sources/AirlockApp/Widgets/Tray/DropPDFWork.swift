import AirlockCore
import Foundation
import ImageIO
import PDFKit

/// The drop box's work on PDFs, with PDFKit, and the one PDF made from a drag
/// of pictures, PDFs and documents together.
enum DropPDFWork {
    /// Pages are drawn at twice their print size: a page of text stays sharp
    /// on a Retina screen, and an A4 page is about 1650 by 2340 pixels.
    static let pageScale: CGFloat = 2
    /// How many pages of a scanned PDF are read for words. Reading a page takes
    /// about a second, and a 300-page scan would hold the shelf for minutes.
    static let readPagesAtMost = 40

    static func document(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            throw DropWork.Failure.unreadable
        }
        return document
    }

    /// Every page as a picture, "Page 1.png", "Page 2.png"…, in a folder
    /// named after the PDF (`destination`), since how many there are is only
    /// known once it is open.
    static func pages(of url: URL, as format: PictureFormat, into destination: URL) throws {
        let document = try document(url)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let image = picture(of: page) else {
                throw DropWork.Failure.unreadable
            }
            let file = destination.appendingPathComponent(String(localized: "Page \(index + 1)") + "." + format.fileExtension)
            guard let writer = CGImageDestinationCreateWithURL(file as CFURL, format.typeIdentifier as CFString,
                                                               1, nil) else { throw DropWork.Failure.unwritable }
            CGImageDestinationAddImage(writer, image,
                                       [kCGImageDestinationLossyCompressionQuality: PictureConverter.quality]
                                           as CFDictionary)
            guard CGImageDestinationFinalize(writer) else { throw DropWork.Failure.unwritable }
        }
    }

    /// Every page a PDF of its own, "Report page 1.pdf"…, in the folder.
    static func split(_ url: URL, into destination: URL) throws {
        let document = try document(url)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let base = url.deletingPathExtension().lastPathComponent
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { throw DropWork.Failure.unreadable }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let file = destination.appendingPathComponent(String(localized: "\(base) page \(index + 1)") + ".pdf")
            guard single.write(to: file) else { throw DropWork.Failure.unwritable }
        }
    }

    /// The pictures in it squeezed to what a screen needs, as JPEGs. The text
    /// stays text. A PDF of nothing but text is already small, and is said so
    /// rather than copied.
    static func smaller(_ url: URL, at destination: URL) throws {
        let document = try document(url)
        guard document.write(to: destination, withOptions: [
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true,
        ]) else { throw DropWork.Failure.unwritable }
        if let before = DropPictureWork.fileSize(url), let after = DropPictureWork.fileSize(destination),
           Double(after) > Double(before) * 0.95 {
            throw DropWork.Failure.alreadySmall
        }
    }

    /// The words in it. A scan has none of its own, so its pages are read the
    /// way a picture's are.
    static func text(of url: URL) throws -> String {
        let document = try document(url)
        let own = document.string ?? ""
        guard own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return own }
        var read: [String] = []
        for index in 0..<min(document.pageCount, readPagesAtMost) {
            guard let page = document.page(at: index), let image = picture(of: page) else { continue }
            read.append(try DropPictureWork.text(in: image))
        }
        return read.joined(separator: "\n\n")
    }

    /// Everything on the drag as the pages of one PDF, in drag order: a
    /// picture a page at the size it was made, a PDF all its pages, a document
    /// laid out the way it would print. All of it or none.
    static func join(_ inputs: [PictureInput], at destination: URL) throws {
        let joined = PDFDocument()
        // Kept until the end: a page belongs to the document it came from.
        var held: [PDFDocument] = []
        for input in inputs {
            let part: PDFDocument
            switch DropWork.kind(of: input) {
            case .pdf:
                part = try document(DropWork.url(input))
            case .document:
                guard let made = PDFDocument(data: try DropDocumentWork.pdfData(of: DropWork.url(input))) else {
                    throw DropWork.Failure.unreadable
                }
                part = made
            case .picture:
                let page = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".pdf")
                defer { try? FileManager.default.removeItem(at: page) }
                try PictureConverter.makePDF(of: [input], at: page)
                guard let data = try? Data(contentsOf: page), let made = PDFDocument(data: data) else {
                    throw DropWork.Failure.unwritable
                }
                part = made
            default:
                throw DropWork.Failure.unreadable
            }
            held.append(part)
            for index in 0..<part.pageCount {
                guard let page = part.page(at: index)?.copy() as? PDFPage else { throw DropWork.Failure.unreadable }
                joined.insert(page, at: joined.pageCount)
            }
        }
        guard joined.pageCount > 0, joined.write(to: destination) else { throw DropWork.Failure.unwritable }
    }

    /// A page drawn on white at `pageScale`.
    static func picture(of page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width * pageScale), height = Int(box.height * pageScale)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: pageScale, y: pageScale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
