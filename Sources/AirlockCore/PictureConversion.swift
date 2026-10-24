import CoreGraphics
import Foundation

/// A picture format the shelf can make a copy in: the row of formats a
/// dragged picture is offered when it reaches the open tray.
///
/// Type identifiers rather than `UTType`, so the rules live in Core where a
/// test can reach them. Which of these this Mac can actually WRITE is the
/// app's question, asked of ImageIO (`PictureConverter.writableTypeIdentifiers`);
/// a format it can't write is simply never offered.
public enum PictureFormat: String, CaseIterable, Sendable {
    // The row's order, and `allCases` is that order: the two everybody knows,
    // then Apple's own, then the web's, then the old ones.
    case jpeg, png, heic, webp, avif, tiff, gif, bmp

    /// What ImageIO is asked to write.
    public var typeIdentifier: String {
        switch self {
        case .jpeg: return "public.jpeg"
        case .png: return "public.png"
        case .heic: return "public.heic"
        case .tiff: return "public.tiff"
        case .gif: return "com.compuserve.gif"
        case .webp: return "org.webmproject.webp"
        case .avif: return "public.avif"
        case .bmp: return "com.microsoft.bmp"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        case .tiff: return "tiff"
        case .gif: return "gif"
        case .webp: return "webp"
        case .avif: return "avif"
        case .bmp: return "bmp"
        }
    }

    /// What the chip says. "JPG" rather than "JPEG": it is what the files are
    /// called on every Mac and phone people own.
    public var label: String {
        switch self {
        case .jpeg: return "JPG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .gif: return "GIF"
        case .webp: return "WebP"
        case .avif: return "AVIF"
        case .bmp: return "BMP"
        }
    }

    /// A JPEG can't hold see-through pixels. The encoder fills them with black,
    /// so a transparent picture is laid on white before it is written as one.
    public var keepsTransparency: Bool { self != .jpeg }

    /// The format a file already is, judged by its name.
    public static func of(fileExtension ext: String) -> PictureFormat? {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe": return .jpeg
        case "png": return .png
        case "heic", "heif", "hif": return .heic
        case "tif", "tiff": return .tiff
        case "gif": return .gif
        case "webp": return .webp
        case "avif": return .avif
        case "bmp", "dib": return .bmp
        default: return nil
        }
    }

    /// The format pixels with no file behind them arrived in.
    public static func of(typeIdentifier identifier: String) -> PictureFormat? {
        switch identifier {
        case "public.jpeg": return .jpeg
        case "public.png": return .png
        case "public.heic", "public.heif": return .heic
        case "public.tiff": return .tiff
        case "com.compuserve.gif": return .gif
        case "org.webmproject.webp", "com.google.webp", "public.webp": return .webp
        case "public.avif": return .avif
        case "com.microsoft.bmp": return .bmp
        default: return nil
        }
    }
}

/// One chip in the row: a format, or every picture in one PDF.
public enum PictureTarget: Hashable, Sendable {
    case format(PictureFormat)
    case onePDF

    public var label: String {
        switch self {
        case .format(let format): return format.label
        case .onePDF: return String(localized: "One PDF")
        }
    }

    /// The sentence under the row while the pointer is on this chip. It says
    /// what a drop here makes, and how many.
    public func action(count: Int) -> String {
        switch self {
        case .format: return String(localized: "Make \(made(count: count))")
        case .onePDF: return String(localized: "Put all \(count) in one PDF")
        }
    }

    /// What a drop here makes: "a PNG copy", "3 PNG copies", "one PDF".
    public func made(count: Int) -> String {
        switch self {
        case .format(let format):
            guard count == 1 else { return String(localized: "\(count) \(format.label) copies") }
            // "an AVIF", "a PNG": the label is read as a word or as letters,
            // and of these only AVIF starts with a vowel either way.
            if format.label.first.map({ "AEIOU".contains($0) }) == true {
                return String(localized: "an \(format.label) copy")
            }
            return String(localized: "a \(format.label) copy")
        case .onePDF:
            return String(localized: "one PDF")
        }
    }
}

/// What one dragged item is, as far as the format row cares.
public enum PictureSource: Equatable, Sendable {
    /// A picture, and its format when it is one the row names. A picture in a
    /// format it doesn't name (a BMP, a camera's raw file) is still a picture.
    case picture(PictureFormat?)
    /// Anything else: a document, a folder, a video.
    case other
}

/// The row a drag is offered, decided once when it arrives.
public struct PictureOffer: Equatable, Sendable {
    public let targets: [PictureTarget]
    /// How many pictures are on the drag, for the row's sentence.
    public let count: Int

    public static let none = PictureOffer(targets: [], count: 0)

    public var isEmpty: Bool { targets.isEmpty }

    public init(targets: [PictureTarget], count: Int) {
        self.targets = targets
        self.count = count
    }

    /// No row unless EVERY item is a picture. A drag holding a picture and a
    /// spreadsheet has no format to become; it goes on the shelf as it is.
    ///
    /// The format the pictures already share is left out: offering PNG for a
    /// PNG would make a copy of the same thing. A mixed drag keeps every format,
    /// since each one turns at least one picture into something new.
    ///
    /// "One PDF" from two pictures up. `writable` is the set of type
    /// identifiers this Mac can write; a format outside it never shows.
    public static func make(sources: [PictureSource], writable: Set<String>) -> PictureOffer {
        var formats: [PictureFormat?] = []
        for source in sources {
            guard case .picture(let format) = source else { return .none }
            formats.append(format)
        }
        guard !formats.isEmpty else { return .none }
        let shared = Set(formats).count == 1 ? formats[0] : nil
        var targets = PictureFormat.allCases
            .filter { writable.contains($0.typeIdentifier) && $0 != shared }
            .map(PictureTarget.format)
        if formats.count >= 2 { targets.append(.onePDF) }
        return PictureOffer(targets: targets, count: formats.count)
    }

    /// Which chip a point lands on. `point` and `row` are both in the panel's
    /// top-left space, the same space the rail is hit-tested in.
    public func target(at point: CGPoint, row: CGRect) -> PictureTarget? {
        guard point.y >= row.minY, point.y <= row.maxY,
              let index = PictureRowLayout.index(atX: point.x - row.minX, rowWidth: row.width,
                                                 count: targets.count) else { return nil }
        return targets[index]
    }
}

/// The row's arithmetic: equal chips with a fixed gap. The view lays the chips
/// out from this and the drop router hit-tests with it, so a drop lands on the
/// chip that lit up. Two transcriptions of the gap is how a drop aimed at PNG
/// lands on HEIC.
public enum PictureRowLayout {
    public static let spacing: CGFloat = 6
    public static let height: CGFloat = 30

    public static func chipWidth(rowWidth: CGFloat, count: Int, spacing: CGFloat = Self.spacing) -> CGFloat {
        guard count > 0 else { return 0 }
        return max(0, (rowWidth - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    /// `x` from the row's left edge. A point in a gap between two chips is nil
    /// rather than the nearer one: aiming between PNG and HEIC is a vote for
    /// neither, and the shelf is the harmless place for it to land.
    public static func index(atX x: CGFloat, rowWidth: CGFloat, count: Int,
                             spacing: CGFloat = Self.spacing) -> Int? {
        let chip = chipWidth(rowWidth: rowWidth, count: count, spacing: spacing)
        guard chip > 0, x >= 0, x <= rowWidth else { return nil }
        let pitch = chip + spacing
        let index = min(Int(x / pitch), count - 1)
        return x - CGFloat(index) * pitch <= chip ? index : nil
    }
}

/// What the copies are called.
public enum PictureCopyNames {
    /// One name per file the conversion writes, never one already taken, and
    /// never the same name twice in one drop: "Beach.heic" and "Beach.webp"
    /// made into PNG are "Beach.png" and "Beach 2.png", the way Finder names
    /// a second copy. One PDF is named after the first picture.
    ///
    /// `existing` is everything on the shelf and everything still landing.
    public static func names(for sources: [String], target: PictureTarget,
                             existing: Set<String>) -> [String] {
        let desired: [String]
        switch target {
        case .format(let format):
            desired = sources.map { base($0) + "." + format.fileExtension }
        case .onePDF:
            desired = sources.first.map { [base($0) + ".pdf"] } ?? []
        }
        var taken = existing
        return desired.map { name in
            let unique = WorkspaceLayout.uniqueName(for: name, existing: taken)
            taken.insert(unique)
            return unique
        }
    }

    private static func base(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? "Picture" : base
    }
}

/// How a conversion went, said the way the shelf says everything else.
public struct PictureConversionResult: Equatable, Sendable {
    public let target: PictureTarget
    public let made: Int
    public let failures: [TrayIngestResult.Failure]

    public init(target: PictureTarget, made: Int, failures: [TrayIngestResult.Failure]) {
        self.target = target
        self.made = made
        self.failures = failures
    }

    /// The reasons that are not a file-system problem (those come from
    /// `PlainProblem.file`).
    public static let unreadable = String(localized: "It isn't a picture this Mac can open.")
    public static let unwritable = String(localized: "This Mac couldn't write that format.")

    /// `nil` when every copy was made, which also clears what an earlier drop
    /// complained about. A run of failures names the first, for the reason
    /// `TrayIngestResult.message` does.
    public var message: String? {
        guard let first = failures.first else { return nil }
        switch target {
        case .onePDF:
            return String(localized: "The PDF couldn't be made. \(first.reason)")
        case .format(let format):
            if failures.count == 1 {
                return String(localized: "\(first.name) couldn't be copied as \(format.label). \(first.reason)")
            }
            return String(localized: "\(failures.count) pictures couldn't be copied as \(format.label). \(first.reason)")
        }
    }
}
