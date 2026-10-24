import AppKit
import CoreText
import Foundation

/// The drop box's work on documents: Word, RTF and plain text, read with the
/// same importers TextEdit uses, so nothing ships with the app to do it.
///
/// A document laid out as a PDF is its words, fonts and colours on pages of
/// this Mac's paper size. Pictures inside a Word file are not drawn: TextEdit
/// keeps them, the layout here does not, and that is said nowhere because it
/// is the rare case. Pages, tables and headers come out as the text they hold.
enum DropDocumentWork {
    static let margin: CGFloat = 72

    static func read(_ url: URL) throws -> NSAttributedString {
        do {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            throw DropWork.Failure.unreadable
        }
    }

    static func text(of url: URL) throws -> String {
        try read(url).string
    }

    static func rtf(of url: URL, at destination: URL) throws {
        let document = try read(url)
        let data = try document.data(from: NSRange(location: 0, length: document.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try data.write(to: destination)
    }

    static func pdf(of url: URL, at destination: URL) throws {
        try pdfData(of: url).write(to: destination)
    }

    /// The pages, laid out by Core Text a page at a time until the words run
    /// out.
    static func pdfData(of url: URL) throws -> Data {
        let document = try read(url)
        let data = NSMutableData()
        var page = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &page, nil) else {
            throw DropWork.Failure.unwritable
        }
        let framesetter = CTFramesetterCreateWithAttributedString(document as CFAttributedString)
        let path = CGPath(rect: page.insetBy(dx: margin, dy: margin), transform: nil)
        var start = 0
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let shown = CTFrameGetVisibleStringRange(frame).length
            // Nothing fitted (one word wider than the page): stop rather
            // than print blank pages forever.
            guard shown > 0 else { break }
            start += shown
        } while start < document.length
        context.closePDF()
        return data as Data
    }

    /// Letter where the Mac's region uses it, A4 everywhere else.
    static var paper: CGSize {
        let letter: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE"]
        return letter.contains(Locale.current.region?.identifier ?? "")
            ? CGSize(width: 612, height: 792)
            : CGSize(width: 595, height: 842)
    }
}
