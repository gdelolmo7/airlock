import AirlockCore
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// The drop box's actions on a picture. Everything here is ImageIO and Vision,
/// on this Mac: no picture leaves it.
enum DropPictureWork {
    /// The longest side of a smaller copy: sharp on any screen an email is read
    /// on, and a phone photo at a tenth of the size.
    static let smallerSide = 2048
    /// What a smaller lossy copy is asked for. Lower than a format copy's,
    /// because small is what was asked for.
    static let smallerQuality = 0.7

    /// The picture at `smallerSide`, in its own format when this Mac writes
    /// it (`DropNames` already picked the extension). A copy that would come
    /// out no smaller is not made: it would be a second copy of the same thing
    /// with a misleading name.
    static func smaller(_ input: PictureInput, at destination: URL) throws {
        let source = try PictureConverter.source(of: input)
        let format = PictureFormat.of(fileExtension: destination.pathExtension) ?? .jpeg
        if CGImageSourceGetCount(source) > 1, CGImageSourceGetType(source).map({ $0 as String }) == format.typeIdentifier {
            try smallerMoving(source, format: format, at: destination)
        } else {
            try smallerStill(source, format: format, at: destination)
        }
        if let before = size(of: input), let after = fileSize(destination), after >= before {
            throw DropWork.Failure.alreadySmall
        }
    }

    /// One picture, scaled.
    private static func smallerStill(_ source: CGImageSource, format: PictureFormat, at destination: URL) throws {
        guard let image = scaled(source, maxSide: smallerSide) else { throw DropWork.Failure.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let flat = !format.keepsTransparency && properties[kCGImagePropertyHasAlpha] as? Bool == true
        guard let pixels = flat ? PictureConverter.onWhite(image) : image,
              let writer = CGImageDestinationCreateWithURL(destination as CFURL, format.typeIdentifier as CFString,
                                                           1, nil) else { throw DropWork.Failure.unwritable }
        CGImageDestinationAddImage(writer, pixels,
                                   [kCGImageDestinationLossyCompressionQuality: smallerQuality] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw DropWork.Failure.unwritable }
    }

    /// Every frame of a moving picture (a GIF, mostly) scaled, each keeping
    /// its own delay and the file its loop count. Scaling only the first
    /// frame gave back a still picture under the moving one's name.
    private static func smallerMoving(_ source: CGImageSource, format: PictureFormat, at destination: URL) throws {
        let count = CGImageSourceGetCount(source)
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, format.typeIdentifier as CFString,
                                                           count, nil) else { throw DropWork.Failure.unwritable }
        if let whole = CGImageSourceCopyProperties(source, nil) { CGImageDestinationSetProperties(writer, whole) }
        for index in 0..<count {
            guard let frame = scaled(source, maxSide: smallerSide, at: index) else { throw DropWork.Failure.unreadable }
            CGImageDestinationAddImage(writer, frame, CGImageSourceCopyPropertiesAtIndex(source, index, nil))
        }
        guard CGImageDestinationFinalize(writer) else { throw DropWork.Failure.unwritable }
    }

    /// The picture with its background made see-through, the subject left where
    /// it was and the size unchanged. Always a PNG, which keeps the
    /// see-through part.
    static func cutOut(_ input: PictureInput, at destination: URL) throws {
        let source = try PictureConverter.source(of: input)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let image = PictureConverter.orientedImage(source, properties) else { throw DropWork.Failure.unreadable }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw DropWork.Failure.noSubject
        }
        let masked = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                         croppedToInstancesExtent: false)
        let picture = CIImage(cvPixelBuffer: masked)
        guard let cut = CIContext().createCGImage(picture, from: picture.extent),
              let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString,
                                                           1, nil) else { throw DropWork.Failure.unwritable }
        CGImageDestinationAddImage(writer, cut, nil)
        guard CGImageDestinationFinalize(writer) else { throw DropWork.Failure.unwritable }
    }

    /// The same picture without where it was taken. Everything else the camera
    /// noted (when, which way up, the lens) stays, and in a format ImageIO can
    /// copy without decoding, the pixels are not touched either.
    static func withoutLocation(_ input: PictureInput, at destination: URL) throws {
        let source = try PictureConverter.source(of: input)
        guard let format = PictureFormat.of(fileExtension: destination.pathExtension) else {
            throw DropWork.Failure.unwritable
        }
        let count = CGImageSourceGetCount(source)
        let sameFormat = CGImageSourceGetType(source).map { $0 as String == format.typeIdentifier } ?? false
        if sameFormat, let data = CFDataCreateMutable(nil, 0),
           let writer = CGImageDestinationCreateWithData(data, format.typeIdentifier as CFString, count, nil),
           CGImageDestinationCopyImageSource(writer, source,
                                             [kCGImageMetadataShouldExcludeGPS: true] as CFDictionary, nil) {
            try (data as Data).write(to: destination)
            return
        }
        // Not copyable as it is (or now another format): written again, with
        // the location left out of what comes along.
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, format.typeIdentifier as CFString,
                                                           count, nil) else { throw DropWork.Failure.unwritable }
        let options: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: kCFNull as Any,
            kCGImageDestinationLossyCompressionQuality: PictureConverter.quality,
        ]
        for index in 0..<count {
            CGImageDestinationAddImageFromSource(writer, source, index, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(writer) else { throw DropWork.Failure.unwritable }
    }

    /// The words in a picture, line by line, the way Live Text reads them.
    static func text(in input: PictureInput) throws -> String {
        let source = try PictureConverter.source(of: input)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let image = PictureConverter.orientedImage(source, properties) else { throw DropWork.Failure.unreadable }
        return try text(in: image)
    }

    static func text(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // MARK: -

    /// The right way up, no longer on its longest side than `maxSide`.
    private static func scaled(_ source: CGImageSource, maxSide: Int, at index: Int = 0) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    private static func size(of input: PictureInput) -> Int? {
        switch input {
        case .file(let url): return fileSize(url)
        case .data(let data, _): return data.count
        }
    }

    /// Read from the disk every time. A URL's resource values are cached on
    /// it, so a second write to the same place would still read the first's.
    static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }
}
