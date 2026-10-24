import AVFoundation
import AirlockCore
import AppKit
import Speech
import UniformTypeIdentifiers

/// What the drop box's rows are for a drag, read off the pasteboard while the
/// file is still in hand: names, types and what macOS says each conforms to.
/// Nothing is opened, so a box over a 4 GB film opens as fast as one over a
/// screenshot.
///
/// The pictures off a web page arrive as pixels with no file behind them, and
/// are pictures like any other. A web link or a run of text gets no rows.
enum DropReader {
    /// The rows a drag gets, as the box opens.
    @MainActor
    static func offer(on pasteboard: NSPasteboard, abilities: DropAbilities) -> DropOffer {
        DropOffer.make(sources: sources(on: pasteboard), abilities: abilities)
    }

    /// What this Mac can do for the box right now. `takesNotes` is asked of
    /// the recording reader: call notes on, and nothing being read.
    @MainActor
    static func abilities(takesNotes: Bool) -> DropAbilities {
        DropAbilities(writablePictures: writablePictures,
                      cutsOut: true,
                      writesOut: SpeechTranscriber.isAvailable,
                      takesNotes: takesNotes)
    }

    /// ImageIO's encoders, plus WebP from the encoder that ships with the app.
    /// Not every format macOS reads is one it writes, which is why this is
    /// asked and not assumed.
    nonisolated static var writablePictures: Set<String> {
        WebPWriter.isAvailable
            ? PictureConverter.writableTypeIdentifiers.union([PictureFormat.webp.typeIdentifier])
            : PictureConverter.writableTypeIdentifiers
    }

    /// The extensions a copy of a picture can keep: those of the formats
    /// ImageIO writes. Smaller and No location are written by ImageIO, so a
    /// WebP comes back a JPG even where the app's own encoder makes WebP
    /// copies.
    nonisolated static var keptPictureExtensions: Set<String> {
        Set(PictureFormat.allCases.filter { PictureConverter.writableTypeIdentifiers.contains($0.typeIdentifier) }
            .flatMap { format -> [String] in
                format == .jpeg ? ["jpg", "jpeg"] : format == .tiff ? ["tif", "tiff"] : [format.fileExtension]
            })
    }

    /// The films a smaller copy, or one with no sound, can be written as.
    nonisolated static let keptVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    @MainActor
    private static func sources(on pasteboard: NSPasteboard) -> [DropSource] {
        switch TrayDropKind.classify(typeIdentifiers: pasteboard.types?.map(\.rawValue) ?? []) {
        case .files:
            return fileURLs(on: pasteboard).map(source(of:))
        case .imageData:
            // The same flavours the shelf keeps, in its order.
            let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
            guard let flavour = TrayModel.imageFlavours.first(where: { types.contains($0.identifier) })
            else { return [] }
            return [.picture(PictureFormat.of(typeIdentifier: flavour.identifier))]
        case .webLink, .text, .unknown:
            return []
        }
    }

    /// What one file is. Read from its name and the type macOS has on record,
    /// never its contents.
    nonisolated static func source(of url: URL) -> DropSource {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
        // A package (an app, a Keynote file) is a folder underneath and one
        // thing to the person: it is "other", and zips like a folder would.
        if values?.isDirectory == true, values?.isPackage != true { return .folder }
        guard let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) else {
            return .other
        }
        let ext = url.pathExtension
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) {
            // An image macOS calls one and can't open (an SVG) gets nothing
            // rather than a row of copies that all fail.
            guard PictureConverter.readableTypeIdentifiers.contains(type.identifier) else { return .other }
            return .picture(PictureFormat.of(fileExtension: ext))
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            guard AVURLAsset.audiovisualTypes().contains(AVFileType(type.identifier)) else { return .other }
            return .video(isMP4: type.conforms(to: .mpeg4Movie) && ext.lowercased() == "mp4")
        }
        if type.conforms(to: .audio) {
            guard AVURLAsset.audiovisualTypes().contains(AVFileType(type.identifier)) else { return .other }
            return .audio(AudioFormat.of(fileExtension: ext))
        }
        if let format = DocumentFormat.of(fileExtension: ext) { return .document(format) }
        if type.conforms(to: .rtf) || type.conforms(to: .flatRTFD) { return .document(.rtf) }
        if type.conforms(to: .plainText) { return .document(.text) }
        return .other
    }

    @MainActor
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self],
                               options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
