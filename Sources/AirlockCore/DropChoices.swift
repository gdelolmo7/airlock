import CoreGraphics
import Foundation

/// What one dragged item is, as far as the drop box's rows care. Decided by
/// the app from the file's name and what macOS says it conforms to, before
/// anything is opened.
public enum DropSource: Equatable, Sendable {
    /// A picture this Mac can open, and its format when it is one the row
    /// names. A camera's raw file is still a picture.
    case picture(PictureFormat?)
    case pdf
    /// A film AVFoundation can open. `isMP4` leaves MP4 off its own row.
    case video(isMP4: Bool)
    /// Any sound file AVFoundation can open, MP3 included. Its format when it
    /// is one the row makes.
    case audio(AudioFormat?)
    /// Something with words the Mac can lay out: Word, RTF, plain text.
    case document(DocumentFormat?)
    case folder
    /// Anything else: a spreadsheet, a zip, a film the Mac can't play.
    case other
}

/// A sound format the box can make. Not MP3: macOS can read it and has no
/// encoder for it.
public enum AudioFormat: String, CaseIterable, Sendable {
    case m4a, wav, aiff

    public var label: String { rawValue.uppercased() }
    public var fileExtension: String { rawValue }

    public static func of(fileExtension ext: String) -> AudioFormat? {
        switch ext.lowercased() {
        case "m4a": return .m4a
        case "wav", "wave": return .wav
        case "aif", "aiff", "aifc": return .aiff
        default: return nil
        }
    }
}

/// A document format the box can make, or that a document already is.
public enum DocumentFormat: String, Sendable {
    case word, rtf, text

    public static func of(fileExtension ext: String) -> DocumentFormat? {
        switch ext.lowercased() {
        case "doc", "docx", "odt": return .word
        case "rtf", "rtfd": return .rtf
        case "txt", "text", "md", "markdown": return .text
        default: return nil
        }
    }
}

/// One chip in the drop box.
///
/// **Two kinds, and they never share a row** (the owner, 2026-10-22: "always
/// differentiate between format change and actions"). A format is the same
/// thing as another kind of file; an action changes what is in it or does
/// something with it. `isAction` says which row.
public enum DropChoice: Hashable, Sendable {
    // The top row: the same thing, as another kind of file.
    /// A picture in another picture format.
    case picture(PictureFormat)
    /// Everything on the drag in one PDF: a picture as a page, two pictures
    /// as two pages, PDFs joined, documents laid out.
    case onePDF
    /// A PDF's pages as pictures.
    case pages(PictureFormat)
    /// The words, as plain text in a file.
    case textFile
    case mp4
    /// The first `DropChoice.gifSeconds` of a film, as a GIF.
    case gif
    /// A film's sound alone.
    case soundOnly
    case audio(AudioFormat)
    /// A document laid out as a PDF, the way it would print.
    case documentPDF
    case rtf
    case zip

    // The bottom row: something done to it.
    case smaller
    case cutOut
    case copyText
    case noLocation
    case splitPages
    case noSound
    case writeItOut
    case notesFromIt
    case nameInOrder

    /// How much of a film a GIF is made from: more would be a file too big
    /// to send, which is what a GIF is for.
    public static let gifSeconds = 10

    public var isAction: Bool {
        switch self {
        case .picture, .onePDF, .pages, .textFile, .mp4, .gif, .soundOnly, .audio,
             .documentPDF, .rtf, .zip:
            return false
        case .smaller, .cutOut, .copyText, .noLocation, .splitPages, .noSound,
             .writeItOut, .notesFromIt, .nameInOrder:
            return true
        }
    }

    /// The plan it comes with, or nil for every plan. Free sees it with the
    /// tag; a drop on it keeps the file on the shelf and says why.
    public var needs: AirlockPlan? {
        switch self {
        case .picture(.webp), .cutOut: return .plus
        default: return nil
        }
    }

    /// What the chip says. `count` is how many items are on the drag: one
    /// picture becomes "PDF", several become "One PDF". Format names (PNG,
    /// MP4, PDF) read the same in every language; words are translated.
    public func label(count: Int) -> String {
        switch self {
        case .picture(let format): return format.label
        case .onePDF: return count == 1 ? "PDF" : String(localized: "One PDF")
        case .pages(let format): return format.label
        case .textFile: return String(localized: "Text file")
        case .mp4: return "MP4"
        case .gif: return "GIF"
        case .soundOnly: return String(localized: "M4A (sound only)")
        case .audio(let format): return format.label
        case .documentPDF: return "PDF"
        case .rtf: return "RTF"
        case .zip: return "Zip"
        case .smaller: return String(localized: "Smaller")
        case .cutOut: return String(localized: "Remove background")
        case .copyText: return String(localized: "Copy text")
        case .noLocation: return String(localized: "No location")
        case .splitPages: return String(localized: "Split pages")
        case .noSound: return String(localized: "No sound")
        case .writeItOut: return String(localized: "Write it out")
        case .notesFromIt: return String(localized: "Notes from it")
        case .nameInOrder: return String(localized: "Name in order")
        }
    }

    /// The sentence over the rows while the file is on this chip: what a drop
    /// here makes, said before the drop rather than discovered after it.
    ///
    /// Every sentence is one whole literal, so a translation can put its
    /// words in any order.
    public func caption(count: Int) -> String {
        let many = count > 1
        switch self {
        case .picture(let format):
            return Self.copies(count, format.label)
        case .onePDF:
            return many ? String(localized: "Put all \(count) in one PDF") : String(localized: "Make a PDF of it")
        case .pages(let format):
            return Self.takesAn(format.label) ? String(localized: "Make an \(format.label) of each page")
                : String(localized: "Make a \(format.label) of each page")
        case .textFile:
            return many ? String(localized: "Make a text file of the words in each")
                : String(localized: "Make a text file of the words in it")
        case .mp4:
            return Self.copies(count, "MP4")
        case .gif:
            return String(localized: "Make a GIF of it (first \(Self.gifSeconds) seconds)")
        case .soundOnly:
            return String(localized: "Keep only the sound, as an M4A")
        case .audio(let format):
            return Self.copies(count, format.label)
        case .documentPDF:
            return Self.copies(count, "PDF")
        case .rtf:
            return Self.copies(count, "RTF")
        case .zip:
            return many ? String(localized: "Put all \(count) in one zip") : String(localized: "Put it in a zip")
        case .smaller:
            return many ? String(localized: "Make \(count) smaller copies")
                : String(localized: "Make a smaller copy, good for email")
        case .cutOut:
            return String(localized: "Remove the background, leaving it see-through")
        case .copyText:
            return String(localized: "Copy the words in it, to paste anywhere")
        case .noLocation:
            return String(localized: "Make a copy without where it was taken")
        case .splitPages:
            return String(localized: "Make a PDF of each page")
        case .noSound:
            return many ? String(localized: "Make \(count) copies with no sound")
                : String(localized: "Make a copy with no sound")
        case .writeItOut:
            return String(localized: "Write out what's said, as a text file beside it")
        case .notesFromIt:
            return String(localized: "Get notes from it, the way a call gets them")
        case .nameInOrder:
            return String(localized: "Copy them named in order: 1, 2, 3…")
        }
    }

    /// Said on a chip the plan leaves out, in place of `caption`.
    public var lockedCaption: String? {
        guard let plan = needs else { return nil }
        switch self {
        case .picture(let format): return String(localized: "\(format.label) copies come with \(plan.label)")
        case .cutOut: return String(localized: "Removing backgrounds comes with \(plan.label)")
        default: return String(localized: "This comes with \(plan.label)")
        }
    }

    /// What the box says once the drop has landed. "Making", not "made": the
    /// work is done off the main thread and may still be on its way when the
    /// box goes.
    ///
    /// Its own sentence per case, never built from `caption`: what follows a
    /// comma or a colon there is for before the drop, and the -ing form is
    /// English grammar a translation doesn't share.
    public func note(count: Int) -> String {
        let many = count > 1
        switch self {
        case .picture(let format):
            return Self.makingCopies(count, format.label)
        case .onePDF:
            return many ? String(localized: "Putting all \(count) in one PDF on the shelf")
                : String(localized: "Making a PDF of it on the shelf")
        case .pages(let format):
            return Self.takesAn(format.label) ? String(localized: "Making an \(format.label) of each page on the shelf")
                : String(localized: "Making a \(format.label) of each page on the shelf")
        case .textFile:
            return many ? String(localized: "Making a text file of the words in each on the shelf")
                : String(localized: "Making a text file of the words in it on the shelf")
        case .mp4:
            return Self.makingCopies(count, "MP4")
        case .gif:
            return String(localized: "Making a GIF of it (first \(Self.gifSeconds) seconds) on the shelf")
        case .soundOnly:
            return String(localized: "Keeping only the sound on the shelf")
        case .audio(let format):
            return Self.makingCopies(count, format.label)
        case .documentPDF:
            return Self.makingCopies(count, "PDF")
        case .rtf:
            return Self.makingCopies(count, "RTF")
        case .zip:
            return many ? String(localized: "Putting all \(count) in one zip on the shelf")
                : String(localized: "Putting it in a zip on the shelf")
        case .smaller:
            return many ? String(localized: "Making \(count) smaller copies on the shelf")
                : String(localized: "Making a smaller copy on the shelf")
        case .cutOut:
            return String(localized: "Removing the background on the shelf")
        case .copyText:
            return String(localized: "Reading the words, then they're yours to paste")
        case .noLocation:
            return String(localized: "Making a copy without where it was taken on the shelf")
        case .splitPages:
            return String(localized: "Making a PDF of each page on the shelf")
        case .noSound:
            return many ? String(localized: "Making \(count) copies with no sound on the shelf")
                : String(localized: "Making a copy with no sound on the shelf")
        case .writeItOut:
            return String(localized: "Writing it out, on the shelf soon")
        case .notesFromIt:
            return String(localized: "Getting notes from it, in Calls")
        case .nameInOrder:
            return String(localized: "Copying them named in order on the shelf")
        }
    }

    /// "Make a PNG copy", "Make an MP4 copy", "Make 3 JPG copies".
    private static func copies(_ count: Int, _ label: String) -> String {
        if count > 1 { return String(localized: "Make \(count) \(label) copies") }
        return takesAn(label) ? String(localized: "Make an \(label) copy") : String(localized: "Make a \(label) copy")
    }

    /// `copies`, once the drop has landed.
    private static func makingCopies(_ count: Int, _ label: String) -> String {
        if count > 1 { return String(localized: "Making \(count) \(label) copies on the shelf") }
        return takesAn(label) ? String(localized: "Making an \(label) copy on the shelf")
            : String(localized: "Making a \(label) copy on the shelf")
    }

    /// Whether English says "an" before the label. Only picks which of two
    /// whole sentences is looked up; a translation may say both the same way.
    private static func takesAn(_ label: String) -> Bool { article(label) == "an" }

    /// "an AVIF", "a PNG": the label is read as a word or as letters, and of
    /// these only the ones starting with A, E, I, O, M or R take "an" ("an
    /// MP4", "an RTF").
    static func article(_ label: String) -> String {
        guard let first = label.first else { return "a" }
        return "AEIOMR".contains(first) ? "an" : "a"
    }
}

/// What this Mac can do, asked of it by the app: the box offers nothing the
/// Mac would fail at.
public struct DropAbilities: Equatable, Sendable {
    /// The picture formats it can write, as type identifiers: ImageIO's, plus
    /// WebP when the app carries its own writer.
    public var writablePictures: Set<String>
    /// Vision can lift a subject off its background.
    public var cutsOut: Bool
    /// A speech model for this Mac's language is there to write a recording out.
    public var writesOut: Bool
    /// A recording can be read into call notes right now (nothing else being
    /// read).
    public var takesNotes: Bool

    public init(writablePictures: Set<String>, cutsOut: Bool = true, writesOut: Bool = true,
                takesNotes: Bool = true) {
        self.writablePictures = writablePictures
        self.cutsOut = cutsOut
        self.writesOut = writesOut
        self.takesNotes = takesNotes
    }

    /// Everything, for tests and the state gallery.
    public static let everything = DropAbilities(
        writablePictures: Set(PictureFormat.allCases.map(\.typeIdentifier)))
}

/// The two rows a drag is offered, decided once when the box opens: it sizes
/// the box, and a row that appeared under the file would move what is there.
public struct DropOffer: Equatable, Sendable {
    public let formats: [DropChoice]
    public let actions: [DropChoice]
    /// How many items are on the drag, for the sentences.
    public let count: Int

    public static let none = DropOffer(formats: [], actions: [], count: 0)

    public init(formats: [DropChoice], actions: [DropChoice], count: Int) {
        self.formats = formats
        self.actions = actions
        self.count = count
    }

    public var isEmpty: Bool { formats.isEmpty && actions.isEmpty }
    public var all: [DropChoice] { formats + actions }

    /// The rows for a drag.
    ///
    /// Items all of one kind get that kind's rows, done to each. A drag of
    /// different kinds, or holding a folder, gets the rows for several files:
    /// a zip, one PDF when every item can be pages, and copies named in order.
    /// One file of a kind the box has nothing for gets no rows: the shelf and
    /// AirDrop are all there is to do with it.
    ///
    /// The format the items already share is left out of their own row:
    /// offering PNG for a PNG would make a copy of the same thing.
    public static func make(sources: [DropSource], abilities: DropAbilities) -> DropOffer {
        guard let first = sources.first else { return .none }
        let count = sources.count
        let several = count > 1
        let inOrder: [DropChoice] = several ? [.nameInOrder] : []

        if case .picture = first, sources.allSatisfy(\.isPicture) {
            let shared = Self.shared(sources.map { source -> PictureFormat? in
                if case .picture(let format) = source { return format }
                return nil
            })
            let formats = PictureFormat.allCases
                .filter { abilities.writablePictures.contains($0.typeIdentifier) && $0 != shared }
                .map(DropChoice.picture) + [.onePDF]
            var actions: [DropChoice] = [.smaller]
            if abilities.cutsOut { actions.append(.cutOut) }
            actions += [.copyText, .noLocation]
            return DropOffer(formats: formats, actions: actions + inOrder, count: count)
        }
        if sources.allSatisfy({ $0 == .pdf }) {
            let pages = [PictureFormat.jpeg, .png, .tiff]
                .filter { abilities.writablePictures.contains($0.typeIdentifier) }
                .map(DropChoice.pages)
            return DropOffer(formats: pages + [.textFile] + (several ? [.onePDF] : []),
                             actions: [.smaller, .copyText, .splitPages] + inOrder, count: count)
        }
        if case .video = first, sources.allSatisfy(\.isVideo) {
            let allMP4 = sources.allSatisfy { $0 == .video(isMP4: true) }
            return DropOffer(formats: (allMP4 ? [] : [.mp4]) + [.gif, .soundOnly],
                             actions: [.smaller, .noSound] + inOrder, count: count)
        }
        if case .audio = first, sources.allSatisfy(\.isAudio) {
            let shared = Self.shared(sources.map { source -> AudioFormat? in
                if case .audio(let format) = source { return format }
                return nil
            })
            var actions: [DropChoice] = []
            if abilities.writesOut { actions.append(.writeItOut) }
            if abilities.takesNotes, !several { actions.append(.notesFromIt) }
            return DropOffer(formats: AudioFormat.allCases.filter { $0 != shared }.map(DropChoice.audio),
                             actions: actions + inOrder, count: count)
        }
        if case .document = first, sources.allSatisfy(\.isDocument) {
            let shared = Self.shared(sources.map { source -> DocumentFormat? in
                if case .document(let format) = source { return format }
                return nil
            })
            var formats: [DropChoice] = [.documentPDF]
            if shared != .text { formats.append(.textFile) }
            if shared != .rtf { formats.append(.rtf) }
            if several { formats.append(.onePDF) }
            return DropOffer(formats: formats, actions: [.copyText] + inOrder, count: count)
        }

        let hasFolder = sources.contains(.folder)
        guard several || hasFolder else { return .none }
        let pagesAll = sources.allSatisfy { $0.isPicture || $0 == .pdf || $0.isDocument }
        return DropOffer(formats: [.zip] + (pagesAll ? [.onePDF] : []),
                         actions: several && !hasFolder ? [.nameInOrder] : [], count: count)
    }

    /// The one value every item has, or nil when they differ or one is unknown.
    private static func shared<T: Equatable>(_ values: [T?]) -> T? {
        guard let first = values.first, let value = first,
              values.allSatisfy({ $0 == value }) else { return nil }
        return value
    }
}

extension DropSource {
    var isPicture: Bool { if case .picture = self { return true } else { return false } }
    var isVideo: Bool { if case .video = self { return true } else { return false } }
    var isAudio: Bool { if case .audio = self { return true } else { return false } }
    var isDocument: Bool { if case .document = self { return true } else { return false } }
}

/// What the results are called.
public enum DropNames {
    /// One name per file a choice writes, never one already taken and never
    /// the same twice in one drop, the way Finder names a second copy.
    /// `existing` is everything on the shelf and everything still landing.
    ///
    /// A choice that makes one file from the whole drag (one PDF, a zip) is
    /// named after the first item. A choice that makes a file per page is
    /// given a folder for each item, "Report pages", since how many pages
    /// there are is only known once it is open. Nothing is named for a choice
    /// that makes no file (copying the words, notes in Calls).
    ///
    /// A copy that keeps its item's own kind of file (a smaller one, one with
    /// no location) keeps its extension when it is in `keeps`, and takes
    /// `fallback` otherwise: this Mac reads WebP pictures and writes none, so a
    /// smaller WebP comes back a JPG. Nil `keeps` keeps every extension.
    public static func names(for sources: [String], choice: DropChoice,
                             existing: Set<String>, keeps: Set<String>? = nil,
                             fallback: String = "jpg") -> [String] {
        let desired: [String]
        switch choice {
        case .onePDF:
            desired = sources.first.map { [base($0) + ".pdf"] } ?? []
        case .zip:
            desired = sources.first.map { first in
                [(sources.count == 1 ? base(first) : String(localized: "\(base(first)) and more")) + ".zip"]
            } ?? []
        case .pages, .splitPages:
            desired = sources.map { String(localized: "\(base($0)) pages") }
        case .copyText, .notesFromIt:
            desired = []
        case .nameInOrder:
            let stem = sources.first.map(base) ?? String(localized: "File")
            desired = sources.enumerated().map { index, name in
                let ext = (name as NSString).pathExtension
                return "\(stem) \(index + 1)" + (ext.isEmpty ? "" : "." + ext)
            }
        default:
            desired = sources.map { name in
                var ext = Self.fileExtension(choice) ?? (name as NSString).pathExtension
                if Self.fileExtension(choice) == nil, let keeps, !keeps.contains(ext.lowercased()) {
                    ext = fallback
                }
                return Self.named(base(name), choice) + (ext.isEmpty ? "" : "." + ext)
            }
        }
        var taken = existing
        return desired.map { name in
            let unique = WorkspaceLayout.uniqueName(for: name, existing: taken)
            taken.insert(unique)
            return unique
        }
    }

    /// The name without its extension, with words added for an action so
    /// the copy says what it is: "Photo (smaller)". Whole names, so a
    /// translation can word them its own way.
    private static func named(_ base: String, _ choice: DropChoice) -> String {
        switch choice {
        case .smaller: return String(localized: "\(base) (smaller)")
        case .cutOut: return String(localized: "\(base) (no background)")
        case .noLocation: return String(localized: "\(base) (no location)")
        case .noSound: return String(localized: "\(base) (no sound)")
        case .writeItOut: return String(localized: "\(base) (written out)")
        case .soundOnly: return String(localized: "\(base) (sound)")
        default: return base
        }
    }

    /// The extension a choice writes, or nil to keep the item's own.
    static func fileExtension(_ choice: DropChoice) -> String? {
        switch choice {
        case .picture(let format): return format.fileExtension
        case .textFile, .writeItOut: return "txt"
        case .mp4: return "mp4"
        case .gif: return "gif"
        case .soundOnly: return "m4a"
        case .audio(let format): return format.fileExtension
        case .documentPDF, .onePDF: return "pdf"
        case .rtf: return "rtf"
        case .zip: return "zip"
        // A cut-out needs see-through pixels, which a JPEG or a HEIC from a
        // camera can't keep.
        case .cutOut: return "png"
        default: return nil
        }
    }

    private static func base(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? String(localized: "File") : base
    }
}

/// How a drop's work went, said the way the shelf says everything else.
public struct DropWorkResult: Equatable, Sendable {
    public let choice: DropChoice
    public let made: Int
    public let failures: [TrayIngestResult.Failure]
    /// The words "Copy text" read, for the clipboard. Nil for every other
    /// choice, and when no words were found.
    public let text: String?

    public init(choice: DropChoice, made: Int, failures: [TrayIngestResult.Failure], text: String? = nil) {
        self.choice = choice
        self.made = made
        self.failures = failures
        self.text = text
    }

    public static var unreadable: String { String(localized: "This Mac couldn't open it.") }
    public static var unwritable: String { String(localized: "This Mac couldn't write that.") }
    public static var noWords: String { String(localized: "There were no words in it to copy.") }
    public static var noSpeech: String { String(localized: "Nobody could be heard in it.") }
    public static var noSubject: String {
        String(localized: "It couldn't tell what to keep. Try a photo of a person, a pet or a thing.")
    }
    public static var noSound: String { String(localized: "There's no sound in it.") }
    public static var alreadySmall: String { String(localized: "It's already about as small as it gets.") }

    /// Nil when everything was made, which also clears what an earlier drop
    /// complained about. A run of failures names the first.
    public var message: String? {
        guard let first = failures.first else { return nil }
        let what = choice.label(count: 1)
        if failures.count == 1 {
            return String(localized: "\(first.name): \(what) didn't work. \(first.reason)")
        }
        return String(localized: "\(failures.count) files: \(what) didn't work. \(first.reason)")
    }
}
