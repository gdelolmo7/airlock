import Foundation

/// What is on the Shelf, as the "Shelf" desktop widget shows it.
///
/// The widget is sandboxed and cannot read the shelf folder, so the app
/// writes this, and a small picture of each file, where the widget can read
/// them (`DeskShelf`). Names, sizes and dates only: never what is inside a
/// file, beyond the picture the Shelf itself already shows.
///
/// A click on a file opens `airlock://shelf?file=<name>`, and the app opens
/// that file only if a file of that name is on the Shelf right now. A link
/// typed by anybody can at most open something already on your Shelf.
public struct DeskShelfFiles: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable, Identifiable {
        /// The file's name on the Shelf, which is also how a link names it.
        public var name: String
        public var size: Int64
        public var modified: Date
        public var isFolder: Bool
        /// The picture's file name under `DeskShelfFiles.thumbsFolder`, or
        /// nil when none could be made (the widget draws a plain glyph).
        public var thumb: String?
        /// True when the picture is the file's icon rather than a preview of
        /// it, so the widget draws it whole instead of filling the tile.
        public var thumbIsIcon: Bool

        public init(name: String, size: Int64, modified: Date, isFolder: Bool,
                    thumb: String? = nil, thumbIsIcon: Bool = false) {
            self.name = name
            self.size = size
            self.modified = modified
            self.isFolder = isFolder
            self.thumb = thumb
            self.thumbIsIcon = thumbIsIcon
        }

        public var id: String { name }

        public var openURL: URL? {
            var parts = URLComponents()
            parts.scheme = "airlock"
            parts.host = DeskShelfFiles.host
            parts.queryItems = [URLQueryItem(name: "file", value: name)]
            return parts.url
        }

        /// The name without its extension; a folder's name whole.
        public var title: String {
            guard !isFolder else { return name }
            let stem = (name as NSString).deletingPathExtension
            return stem.isEmpty ? name : stem
        }

        /// "PDF", "PNG", "Folder": what kind of thing it is, in a word.
        public var kind: String {
            if isFolder { return DeskShelfWords.folder }
            let ext = (name as NSString).pathExtension
            return ext.isEmpty ? DeskShelfWords.file : ext.uppercased()
        }

        /// The name the picture is kept under: changes whenever the file
        /// does, so an unchanged file is never drawn twice.
        public var thumbKey: String {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in "\(name)|\(modified.timeIntervalSince1970)|\(size)".utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
            return String(hash, radix: 16) + ".png"
        }
    }

    /// Newest first, up to `limit`.
    public var files: [File]
    /// Every file on the Shelf, including those left out of `files`.
    public var count: Int
    public var totalSize: Int64
    /// The Shelf's own switch. Off, the widget says so and shows no files.
    public var isOn: Bool
    /// The notch's ground, as for the other desktop widgets.
    public var surface: DeskSurface?

    public init(files: [File], count: Int? = nil, totalSize: Int64? = nil, isOn: Bool = true,
                surface: DeskSurface? = nil) {
        self.files = files
        self.count = count ?? files.count
        self.totalSize = totalSize ?? files.reduce(0) { $0 + $1.size }
        self.isOn = isOn
        self.surface = surface
    }

    public static let empty = DeskShelfFiles(files: [])
    public static let snapshotName = "desk-shelf.json"
    public static let thumbsFolder = "shelf-thumbs"
    public static let widgetKind = "com.airlock.shelf"
    public static let host = "shelf"
    /// The most files any size draws (large: two rows of four).
    public static let limit = 8

    /// A click anywhere but a file: the notch, on the Shelf.
    public static let openURL = URL(string: "airlock://shelf")!

    /// The snapshot for the Shelf's files, newest first. Off, no file is
    /// carried at all, so an old list cannot linger on the desk.
    public static func make(_ files: [File], isOn: Bool, surface: DeskSurface?,
                            limit: Int = limit) -> DeskShelfFiles {
        guard isOn else { return DeskShelfFiles(files: [], count: 0, totalSize: 0, isOn: false, surface: surface) }
        let newest = files.sorted { $0.modified > $1.modified }
        return DeskShelfFiles(files: Array(newest.prefix(limit)), count: files.count,
                              totalSize: files.reduce(0) { $0 + $1.size }, isOn: true, surface: surface)
    }

    public static func isOpenURL(_ url: URL) -> Bool {
        url.scheme == "airlock" && url.host == host && fileName(from: url) == nil
    }

    /// The file a link names: a plain name only, never a path.
    public static func fileName(from url: URL) -> String? {
        guard url.scheme == "airlock", url.host == host,
              let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "file" })?.value,
              isPlainName(name)
        else { return nil }
        return name
    }

    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains(":") && name != "." && name != ".."
            && !name.hasPrefix(".")
    }

    /// Pictures under `thumbsFolder` no file in `files` uses any more.
    public func staleThumbs(among names: [String]) -> [String] {
        let kept = Set(files.compactMap(\.thumb))
        return names.filter { $0.hasSuffix(".png") && !kept.contains($0) }
    }
}

/// The Shelf widget's words.
public enum DeskShelfWords {
    public static let name = String(localized: "Shelf")
    public static let blurb = String(localized: "The newest files on your Shelf. Click one to open it.")
    public static let title = String(localized: "Shelf")
    public static let emptyTitle = String(localized: "Nothing on the Shelf")
    public static let emptyLine = String(localized: "Drag a file to the top of the screen to keep it here.")
    public static let offTitle = String(localized: "The Shelf is off")
    public static let offLine = String(localized: "Switch it on in Airlock's Settings.")
    public static let folder = String(localized: "Folder")
    public static let file = String(localized: "File")

    public static func files(_ n: Int) -> String {
        n == 1 ? String(localized: "1 file") : String(localized: "\(n) files")
    }

    public static let moreWord = String(localized: "more")
}
