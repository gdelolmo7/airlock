import AirlockCore
import SwiftUI
import WidgetKit

struct NextCallEntry: TimelineEntry {
    var date: Date
    var next: DeskNextCall
}

struct NextCallProvider: TimelineProvider {
    static func read() -> DeskNextCall {
        guard let folder = DeskFolder.url,
              let data = try? Data(contentsOf: folder.appendingPathComponent(DeskNextCall.snapshotName)),
              let next = try? DeskShelf.decoder().decode(DeskNextCall.self, from: data)
        else { return .empty }
        return next
    }

    func placeholder(in context: Context) -> NextCallEntry { NextCallEntry(date: .now, next: NextCallSample.soon) }

    func getSnapshot(in context: Context, completion: @escaping (NextCallEntry) -> Void) {
        let next = Self.read()
        completion(NextCallEntry(date: .now,
                                 next: context.isPreview && next.events.isEmpty ? NextCallSample.soon : next))
    }

    /// An entry now and one at every start and end, so "in 12 min" becomes
    /// "Now" and then the call after it on time. The app asks for a new
    /// timeline whenever the calendar changes; the last entry asks again an
    /// hour on in case it could not.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NextCallEntry>) -> Void) {
        let now = Date.now
        let next = Self.read()
        let entries = ([now] + next.changes(after: now)).map { NextCallEntry(date: $0, next: next) }
        let later = (entries.last?.date ?? now).addingTimeInterval(3600)
        completion(Timeline(entries: entries, policy: .after(later)))
    }
}

struct NextCallWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DeskNextCall.widgetKind, provider: NextCallProvider()) { entry in
            NextCallEntryView(entry: entry)
        }
        .configurationDisplayName(DeskCallWords.name)
        .description(DeskCallWords.blurb)
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NextCallEntryView: View {
    var entry: NextCallEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let look = DeskLook.make(surface: entry.next.surface ?? .black,
                                 faded: mode != .fullColor, fadedDark: scheme == .dark)
        NextCallView(next: entry.next, now: entry.date, size: family == .systemSmall ? .small : .medium, look: look)
            .containerBackground(for: .widget) { DeskGround(look: look) }
            .widgetURL(DeskShelf.openURL)
    }
}

/// Made-up calls for the gallery and the screenshots.
enum NextCallSample {
    private static func event(_ id: String, _ title: String, in minutes: Double, for length: Double,
                              join: String?) -> DeskNextCall.Event {
        let start = Date.now.addingTimeInterval(minutes * 60)
        return .init(id: id, title: title, start: start, end: start.addingTimeInterval(length * 60), join: join)
    }

    private static let notes = DeskNextCall.Notes(call: "Design review", folder: "d", at: .now.addingTimeInterval(-7200))

    static var soon: DeskNextCall {
        DeskNextCall(events: [
            event("a", "Client call with Hoyos", in: 12, for: 30, join: "Join Zoom"),
            event("b", "Weekly sync", in: 90, for: 45, join: "Join Meet"),
        ], notes: notes)
    }

    static var on: DeskNextCall {
        DeskNextCall(events: [
            event("a", "Client call with Hoyos", in: -8, for: 30, join: "Join Zoom"),
            event("b", "Weekly sync", in: 70, for: 45, join: "Join Meet"),
        ], notes: notes)
    }

    static var noLink: DeskNextCall {
        DeskNextCall(events: [event("c", "Lunch with Ana", in: 40, for: 60, join: nil)])
    }

    static var clear: DeskNextCall { DeskNextCall(events: [], notes: notes) }
}
