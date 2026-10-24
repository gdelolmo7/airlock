import AirlockCore
import AppKit
import ImageIO
import UniformTypeIdentifiers
import os

/// What a picture copy is made from: a file somewhere on the Mac, or pixels
/// that came on the drag with no file behind them (a picture out of a web page).
enum PictureInput: Sendable {
    case file(URL)
    case data(Data, name: String)

    /// The name the copy is named after, and the one a failure names.
    var name: String {
        switch self {
        case .file(let url): return url.lastPathComponent
        case .data(_, let name): return name
        }
    }
}

/// Makes copies of pictures in another format, with ImageIO: the encoders
/// macOS itself uses, so nothing ships with the app to do it. Which formats
/// those are is asked of this Mac, not assumed (`writableTypeIdentifiers`).
/// WebP is the one exception: macOS reads it and cannot write it, so its copies
/// are made by `WebPWriter`, which ships inside the app.
///
/// It only ever writes NEW files. The original is read and nothing else: not
/// moved, not changed, not renamed. And a copy never replaces anything: it is
/// written whole beside the shelf and then moved onto a name nothing holds, so
/// the folder watcher never sees half a picture, and a name that got taken in
/// the meantime fails the copy rather than overwriting what took it.
enum PictureConverter {
    nonisolated static let writableTypeIdentifiers: Set<String> =
        Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
    nonisolated static let readableTypeIdentifiers: Set<String> =
        Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])

    /// What a lossy format is asked for: Preview's "high", well past where a
    /// photo looks any different, and a third the size of "best".
    nonisolated static let quality = 0.9

    private nonisolated static let log = Logger(subsystem: "com.airlock.app", category: "shelf")

    enum Failure: Error {
        case unreadable, unwritable
    }

    // MARK: - Reading the drag

    /// The format row a drag gets. Asked when the drag arrives, from what the
    /// pasteboard already says: file names and type identifiers, no file opened.
    @MainActor
    static func offer(on pasteboard: NSPasteboard) -> PictureOffer {
        PictureOffer.make(sources: sources(on: pasteboard), writable: writableTypeIdentifiers)
    }

    @MainActor
    private static func sources(on pasteboard: NSPasteboard) -> [PictureSource] {
        switch TrayDropKind.classify(typeIdentifiers: pasteboard.types?.map(\.rawValue) ?? []) {
        case .files:
            return fileURLs(on: pasteboard).map { url in
                // A picture is something macOS calls an image AND can open:
                // an SVG is the first and not the second, so it gets no row
                // rather than a row of copies that all fail.
                guard let type = UTType(filenameExtension: url.pathExtension),
                      type.conforms(to: .image),
                      readableTypeIdentifiers.contains(type.identifier) else { return .other }
                return .picture(PictureFormat.of(fileExtension: url.pathExtension))
            }
        case .imageData:
            guard let flavour = imageFlavour(on: pasteboard) else { return [] }
            return [.picture(PictureFormat.of(typeIdentifier: flavour.identifier))]
        case .webLink, .text, .unknown:
            return []
        }
    }

    /// What the conversion reads, once the drop has happened.
    @MainActor
    static func inputs(on pasteboard: NSPasteboard) -> [PictureInput] {
        switch TrayDropKind.classify(typeIdentifiers: pasteboard.types?.map(\.rawValue) ?? []) {
        case .files:
            return fileURLs(on: pasteboard).map(PictureInput.file)
        case .imageData:
            guard let flavour = imageFlavour(on: pasteboard),
                  let data = pasteboard.data(forType: NSPasteboard.PasteboardType(flavour.identifier))
            else { return [] }
            // Named the way the shelf names a dropped picture, so "puppy.jpg"
            // off a web page is copied as "puppy.png".
            let hint = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?
                .first?.lastPathComponent
            return [.data(data, name: WorkspaceLayout.droppedImageName(hint: hint,
                                                                       extension: flavour.extension))]
        case .webLink, .text, .unknown:
            return []
        }
    }

    @MainActor
    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self],
                               options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// The same flavour, in the same order, the shelf would keep.
    @MainActor
    private static func imageFlavour(on pasteboard: NSPasteboard)
        -> (identifier: String, extension: String)? {
        let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
        return TrayModel.imageFlavours.first { types.contains($0.identifier) }
    }

    // MARK: - Making the copies

    /// Off the main actor, inside `BlockingWork`: a big HEIC takes a moment to
    /// decode, and the panel does not wait for it. `names` is one per input, or
    /// one for the PDF, already chosen by `PictureCopyNames`.
    nonisolated static func run(_ inputs: [PictureInput], target: PictureTarget, names: [String],
                                tray: URL) -> PictureConversionResult {
        switch target {
        case .format(let format):
            var made = 0
            var failures: [TrayIngestResult.Failure] = []
            for (input, name) in zip(inputs, names) {
                do {
                    try write(to: tray.appendingPathComponent(name)) { temporary in
                        try convert(input, to: format, at: temporary)
                    }
                    made += 1
                } catch {
                    failures.append(.init(name: input.name, reason: reason(error)))
                }
            }
            return PictureConversionResult(target: target, made: made, failures: failures)
        case .onePDF:
            guard let name = names.first else {
                return PictureConversionResult(target: target, made: 0, failures: [])
            }
            do {
                try write(to: tray.appendingPathComponent(name)) { temporary in
                    try makePDF(of: inputs, at: temporary)
                }
                return PictureConversionResult(target: target, made: 1, failures: [])
            } catch {
                return PictureConversionResult(target: target, made: 0,
                                               failures: [.init(name: name, reason: reason(error))])
            }
        }
    }

    private nonisolated static func reason(_ error: any Error) -> String {
        switch error as? Failure {
        case .unreadable:
            return PictureConversionResult.unreadable
        case .unwritable:
            return PictureConversionResult.unwritable
        case nil:
            log.error("picture copy: \(error.localizedDescription, privacy: .private)")
            return PlainProblem.file(error)
        }
    }

    /// Written whole somewhere private on the same disk, then moved into place.
    /// `moveItem` refuses a destination that exists, which is the guarantee
    /// that a copy never lands on top of something.
    nonisolated static func write(to destination: URL,
                                          _ body: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let scratch = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent(destination.lastPathComponent)
        try body(temporary)
        try manager.moveItem(at: temporary, to: destination)
    }

    nonisolated static func source(of input: PictureInput) throws -> CGImageSource {
        let made: CGImageSource?
        switch input {
        case .file(let url): made = CGImageSourceCreateWithURL(url as CFURL, nil)
        case .data(let data, _): made = CGImageSourceCreateWithData(data as CFData, nil)
        }
        guard let source = made, CGImageSourceGetCount(source) > 0,
              CGImageSourceGetType(source) != nil else { throw Failure.unreadable }
        return source
    }

    nonisolated static func convert(_ input: PictureInput, to format: PictureFormat,
                                            at destination: URL) throws {
        let source = try source(of: input)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        if format == .webp {
            try writeWebP(source, properties, at: destination)
            return
        }
        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL, format.typeIdentifier as CFString, 1, nil) else { throw Failure.unwritable }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary

        if !format.keepsTransparency, properties[kCGImagePropertyHasAlpha] as? Bool == true {
            // A JPEG has no see-through pixels and the encoder makes them black,
            // which turns a logo on a clear background into a black square. Laid
            // on white instead, which is what a page behind it would show.
            guard let image = orientedImage(source, properties) else { throw Failure.unreadable }
            guard let flat = onWhite(image) else { throw Failure.unwritable }
            CGImageDestinationAddImage(writer, flat, options)
        } else {
            // Straight from the source, so the camera's details (when, where,
            // which way up) come along with the pixels.
            CGImageDestinationAddImageFromSource(writer, source, 0, options)
        }
        guard CGImageDestinationFinalize(writer) else { throw Failure.unwritable }
    }

    /// A WebP through the encoder that ships with the app. A PNG stays exact
    /// (a screenshot or a logo smudges when squeezed), anything else is the
    /// same "high" the other lossy formats get. Only the pixels come along:
    /// libwebp keeps no camera details.
    private nonisolated static func writeWebP(_ source: CGImageSource, _ properties: [CFString: Any],
                                              at destination: URL) throws {
        guard WebPWriter.isAvailable else { throw Failure.unwritable }
        guard let image = orientedImage(source, properties) else { throw Failure.unreadable }
        let lossless = (CGImageSourceGetType(source) as String?) == PictureFormat.png.typeIdentifier
        guard let data = WebPWriter.data(from: image, quality: Float(quality * 100), lossless: lossless) else {
            throw Failure.unwritable
        }
        do { try data.write(to: destination, options: .withoutOverwriting) } catch { throw Failure.unwritable }
    }

    /// Every picture a page of its own, sized the way it was made: its pixels
    /// at its own resolution, so a 300 dpi scan prints at the size it was
    /// scanned. All of them or none: a PDF missing a page it was asked for is
    /// worse than a message saying it couldn't be made.
    nonisolated static func makePDF(of inputs: [PictureInput], at destination: URL) throws {
        var pages: [(CGImage, CGSize)] = []
        for input in inputs {
            let source = try source(of: input)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            guard let image = orientedImage(source, properties) else { throw Failure.unreadable }
            let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
            pages.append((image, CGSize(width: Double(image.width) * 72 / dpi,
                                        height: Double(image.height) * 72 / dpi)))
        }
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw Failure.unwritable }
        for (image, size) in pages {
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
    }

    /// The picture the right way up: a phone photo is stored sideways with a
    /// note saying which way to turn it, and a page or a JPEG has nowhere to
    /// keep the note.
    nonisolated static func orientedImage(_ source: CGImageSource,
                                                  _ properties: [CFString: Any]) -> CGImage? {
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated static func onWhite(_ image: CGImage) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }
}
