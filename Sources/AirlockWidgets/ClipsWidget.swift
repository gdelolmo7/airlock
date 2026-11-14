import AirlockCore
import AppKit
import SwiftUI
import WidgetKit

struct ClipsEntry: TimelineEntry {
    var date: Date
    var clips: DeskClips
}

struct ClipsProvider: TimelineProvider {
    static func read() -> DeskClips {
        guard let folder = DeskFolder.url,
              let data = try? Data(contentsOf: folder.appendingPathComponent(DeskClips.snapshotName)),
              let clips = try? DeskShelf.decoder().decode(DeskClips.self, from: data)
        else { return .empty }
        return clips
    }

    func placeholder(in context: Context) -> ClipsEntry { ClipsEntry(date: .now, clips: ClipsSample.some) }

    func getSnapshot(in context: Context, completion: @escaping (ClipsEntry) -> Void) {
        let clips = Self.read()
        completion(ClipsEntry(date: .now, clips: context.isPreview && clips.clips.isEmpty ? ClipsSample.some : clips))
    }

    /// One entry. The app asks for a new timeline whenever something is copied.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ClipsEntry>) -> Void) {
        completion(Timeline(entries: [ClipsEntry(date: .now, clips: Self.read())], policy: .never))
    }
}

struct ClipsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DeskClips.widgetKind, provider: ClipsProvider()) { entry in
            ClipsEntryView(entry: entry)
        }
        .configurationDisplayName(DeskClipsWords.name)
        .description(DeskClipsWords.blurb)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ClipsEntryView: View {
    var entry: ClipsEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let look = DeskLook.make(surface: entry.clips.surface ?? .black,
                                 faded: mode != .fullColor, fadedDark: scheme == .dark)
        let size: ClipsView.Size = switch family {
        case .systemSmall: .small
        case .systemLarge: .large
        default: .medium
        }
        ClipsView(clips: entry.clips, size: size, look: look, picture: Self.picture)
            .containerBackground(for: .widget) { DeskGround(look: look) }
            .widgetURL(Self.link(entry.clips, size: size))
    }

    /// The small size is one copy, so a click there copies it again; the
    /// others open the notch on the Clipboard anywhere but a row.
    static func link(_ clips: DeskClips, size: ClipsView.Size) -> URL {
        if size == .small, clips.isOn, let newest = clips.clips.first { return newest.copyURL }
        return DeskClips.openURL
    }

    static func picture(_ clip: DeskClips.Clip) -> NSImage? {
        guard let thumb = clip.thumb, DeskShelfFiles.isPlainName(thumb), let folder = DeskFolder.url else { return nil }
        return NSImage(contentsOf: folder.appendingPathComponent(DeskClips.thumbsFolder, isDirectory: true)
            .appendingPathComponent(thumb))
    }
}

/// Made-up copies for the gallery and the screenshots.
enum ClipsSample {
    private static func clip(_ kind: DeskClips.Clip.Kind, _ text: String?, app: String, ago minutes: Double,
                             hidden: Int? = nil, pinned: Bool = false, thumb: String? = nil) -> DeskClips.Clip {
        .init(id: UUID(), kind: kind, text: text, hiddenLength: hidden, app: app,
              copiedAt: .now.addingTimeInterval(-minutes * 60), pinned: pinned, thumb: thumb,
              width: kind == .image ? 1440 : nil, height: kind == .image ? 900 : nil)
    }

    static let clips: [DeskClips.Clip] = [
        clip(.text, "Let's move the review to Thursday at 10, the room on the third floor is free.",
             app: "Mail", ago: 1),
        clip(.text, nil, app: "Terminal", ago: 4, hidden: 51),
        clip(.text, "https://useairlock.app/download", app: "Safari", ago: 9),
        clip(.image, nil, app: "Screenshot", ago: 15, thumb: "beach"),
        clip(.file, "Invoice March.pdf", app: "Finder", ago: 32),
        clip(.text, "Calle Mayor 14, 2º B, 28013 Madrid", app: "Notes", ago: 60, pinned: true),
    ]

    static var some: DeskClips { DeskClips(clips: clips) }
    static var secretFirst: DeskClips { DeskClips(clips: Array(clips.dropFirst())) }
    static var pictureFirst: DeskClips { DeskClips(clips: Array(clips.dropFirst(3))) }
    static var empty: DeskClips { DeskClips(clips: []) }
    static var off: DeskClips { DeskClips(clips: [], isOn: false) }
}
