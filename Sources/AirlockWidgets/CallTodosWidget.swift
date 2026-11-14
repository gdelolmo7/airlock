import AirlockCore
import AppIntents
import SwiftUI
import WidgetKit

/// The App Group folder, as this process sees it, or nil on a build that
/// was not given one (see `DeskShelf.infoKey`).
enum DeskFolder {
    static var url: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: DeskShelf.infoKey) as? String,
              !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    static func read() -> DeskTodos {
        let today = Calendar.current.startOfDay(for: .now)
        guard let folder = url,
              let data = try? Data(contentsOf: folder.appendingPathComponent(DeskShelf.snapshotName)),
              let todos = try? DeskShelf.decoder().decode(DeskTodos.self, from: data)
        else { return .empty(on: today) }
        return todos.on(.now)
    }

    /// The snapshot with a press applied, written back so the widget's next
    /// timeline draws it at once, and the press left for the app.
    static func record(_ tick: DeskTick, id: String) throws {
        guard let folder = url else { return }
        let ticks = folder.appendingPathComponent(DeskShelf.ticksFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: ticks, withIntermediateDirectories: true)
        try DeskShelf.encoder().encode(tick)
            .write(to: ticks.appendingPathComponent(DeskShelf.tickName(tick)), options: .atomic)
        let updated = read().setting(id, done: tick.done)
        try DeskShelf.encoder().encode(updated)
            .write(to: folder.appendingPathComponent(DeskShelf.snapshotName), options: .atomic)
    }
}

/// A press on a to-do's circle. Runs in the widget, never opens the app.
struct TickTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "Tick a to-do"
    static let isDiscoverable = false

    @Parameter(title: "To-do") var id: String
    @Parameter(title: "Call folder") var folder: String
    @Parameter(title: "Place on the page") var index: Int
    @Parameter(title: "Text") var text: String
    @Parameter(title: "Done") var done: Bool

    init() {}

    init(_ item: DeskTodos.Item, done: Bool) {
        id = item.id
        folder = item.folder
        index = item.index
        text = item.text
        self.done = done
    }

    func perform() async throws -> some IntentResult {
        try DeskFolder.record(DeskTick(folder: folder, index: index, text: text, done: done, at: .now), id: id)
        return .result()
    }
}

struct DeskEntry: TimelineEntry {
    var date: Date
    var todos: DeskTodos
}

struct DeskProvider: TimelineProvider {
    func placeholder(in context: Context) -> DeskEntry { DeskEntry(date: .now, todos: DeskSample.some) }

    func getSnapshot(in context: Context, completion: @escaping (DeskEntry) -> Void) {
        let todos = DeskFolder.read()
        completion(DeskEntry(date: .now, todos: context.isPreview && todos.items.isEmpty ? DeskSample.some : todos))
    }

    /// One entry now and one at midnight, when today's list starts empty.
    /// The app asks for a new timeline whenever notes are written or a
    /// to-do is ticked, so nothing here needs to poll.
    func getTimeline(in context: Context, completion: @escaping (Timeline<DeskEntry>) -> Void) {
        let now = Date.now
        let midnight = Calendar.current.date(byAdding: .day, value: 1,
                                             to: Calendar.current.startOfDay(for: now)) ?? now
        let today = DeskFolder.read()
        var tomorrow = DeskTodos.empty(on: midnight)
        tomorrow.surface = today.surface
        completion(Timeline(entries: [
            DeskEntry(date: now, todos: today),
            DeskEntry(date: midnight, todos: tomorrow),
        ], policy: .after(midnight)))
    }
}

struct CallTodosWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.airlock.call-todos", provider: DeskProvider()) { entry in
            CallTodosEntryView(entry: entry)
        }
        .configurationDisplayName(DeskWords.name)
        .description(DeskWords.blurb)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct CallTodosEntryView: View {
    var entry: DeskEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let look = DeskLook.make(surface: entry.todos.surface ?? .black,
                                 faded: mode != .fullColor, fadedDark: scheme == .dark)
        CallTodosView(todos: entry.todos, size: size, look: look)
            .containerBackground(for: .widget) { DeskGround(look: look) }
            .widgetURL(DeskShelf.openURL)
    }

    private var size: CallTodosView.Size {
        switch family {
        case .systemSmall: .small
        case .systemLarge, .systemExtraLarge: .large
        default: .medium
        }
    }
}

/// Made-up to-dos for the widget gallery, before any call has notes, and for
/// the screenshots.
enum DeskSample {
    static var some: DeskTodos {
        let day = Calendar.current.startOfDay(for: .now)
        func at(_ h: Int, _ m: Int) -> Date { day.addingTimeInterval(TimeInterval(h * 3600 + m * 60)) }
        let items: [DeskTodos.Item] = [
            .init(text: "Book the room for Tuesday's review", call: "Design review", at: at(10, 30), done: false, folder: "d", index: 0),
            .init(text: "Send Hoyos the revised proposal", call: "Client call", at: at(13, 0), done: false, folder: "c", index: 0),
            .init(text: "Share the recording with the team", call: "Weekly sync", at: at(16, 0), done: true, folder: "w", index: 0),
            .init(text: "Ask Jon for the budget numbers", call: "Weekly sync", at: at(16, 0), done: false, folder: "w", index: 1),
            .init(text: "Update the welcome email copy", call: "Design review", at: at(10, 30), done: true, folder: "d", index: 1),
        ]
        return DeskTodos(day: day, items: items, calls: 3)
    }

    static var allDone: DeskTodos {
        var todos = some
        for i in todos.items.indices { todos.items[i].done = true }
        return todos
    }
}
