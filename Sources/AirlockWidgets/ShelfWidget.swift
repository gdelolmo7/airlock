import AirlockCore
import AppKit
import SwiftUI
import WidgetKit

struct ShelfEntry: TimelineEntry {
    var date: Date
    var shelf: DeskShelfFiles
}

struct ShelfProvider: TimelineProvider {
    static func read() -> DeskShelfFiles {
        guard let folder = DeskFolder.url,
              let data = try? Data(contentsOf: folder.appendingPathComponent(DeskShelfFiles.snapshotName)),
              let shelf = try? DeskShelf.decoder().decode(DeskShelfFiles.self, from: data)
        else { return .empty }
        return shelf
    }

    func placeholder(in context: Context) -> ShelfEntry { ShelfEntry(date: .now, shelf: ShelfSample.some) }

    func getSnapshot(in context: Context, completion: @escaping (ShelfEntry) -> Void) {
        let shelf = Self.read()
        completion(ShelfEntry(date: .now, shelf: context.isPreview && shelf.files.isEmpty ? ShelfSample.some : shelf))
    }

    /// One entry. Nothing on the Shelf changes by the clock; the app asks for
    /// a new timeline whenever a file comes or goes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ShelfEntry>) -> Void) {
        completion(Timeline(entries: [ShelfEntry(date: .now, shelf: Self.read())], policy: .never))
    }
}

struct ShelfWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DeskShelfFiles.widgetKind, provider: ShelfProvider()) { entry in
            ShelfEntryView(entry: entry)
        }
        .configurationDisplayName(DeskShelfWords.name)
        .description(DeskShelfWords.blurb)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ShelfEntryView: View {
    var entry: ShelfEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let look = DeskLook.make(surface: entry.shelf.surface ?? .black,
                                 faded: mode != .fullColor, fadedDark: scheme == .dark)
        let size: ShelfView.Size = switch family {
        case .systemSmall: .small
        case .systemLarge: .large
        default: .medium
        }
        ShelfView(shelf: entry.shelf, size: size, look: look, picture: Self.picture)
            .containerBackground(for: .widget) { DeskGround(look: look) }
            .widgetURL(DeskShelfFiles.openURL)
    }

    /// The picture the app made for a file, read from the shared folder by a
    /// plain name only.
    static func picture(_ file: DeskShelfFiles.File) -> NSImage? {
        guard let thumb = file.thumb, DeskShelfFiles.isPlainName(thumb), let folder = DeskFolder.url else { return nil }
        return NSImage(contentsOf: folder.appendingPathComponent(DeskShelfFiles.thumbsFolder, isDirectory: true)
            .appendingPathComponent(thumb))
    }
}

/// Made-up files for the gallery and the screenshots.
enum ShelfSample {
    private static func file(_ name: String, kb: Int64, ago minutes: Double, folder: Bool = false,
                             thumb: String? = nil) -> DeskShelfFiles.File {
        .init(name: name, size: kb * 1024, modified: .now.addingTimeInterval(-minutes * 60),
              isFolder: folder, thumb: thumb)
    }

    static let files: [DeskShelfFiles.File] = [
        file("Beach day.jpg", kb: 2_480, ago: 2, thumb: "beach"),
        file("Invoice March.pdf", kb: 182, ago: 8),
        file("Mockup v3.png", kb: 940, ago: 20, thumb: "mockup"),
        file("Project notes", kb: 5_120, ago: 45, folder: true),
        file("Demo cut.mov", kb: 48_000, ago: 70),
        file("Contract signed.pdf", kb: 320, ago: 90),
        file("Logo.svg", kb: 14, ago: 120, thumb: "logo"),
        file("Recording.m4a", kb: 3_200, ago: 180),
        file("Backup.zip", kb: 88_000, ago: 240),
    ]

    static var some: DeskShelfFiles { .make(files, isOn: true, surface: nil) }
    static var few: DeskShelfFiles { .make(Array(files.prefix(3)), isOn: true, surface: nil) }
    static var empty: DeskShelfFiles { .make([], isOn: true, surface: nil) }
    static var off: DeskShelfFiles { .make(files, isOn: false, surface: nil) }
}
