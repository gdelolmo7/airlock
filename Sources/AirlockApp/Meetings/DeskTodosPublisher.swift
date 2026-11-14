import AirlockCore
import CoreServices
import Foundation
import WidgetKit

/// Keeps the desktop widget's to-dos current, and writes its ticks into the
/// notes pages.
///
/// Watches two folders: the meetings folder, every file under it (a call's
/// notes being saved, a box ticked in a text editor, a call moved to the
/// Bin), and the widget's ticks folder in the App Group. Either one changing
/// reads everything again a moment later, off the main thread: ticks first,
/// written into `Notes.md` and the page as written (so naming the voices
/// later keeps the tick), then today's snapshot. The widget is asked to
/// redraw only when the snapshot changed.
///
/// Does nothing on a build with no App Group (`DeskShelf.infoKey`): a dev
/// build, `swift run`, the tests. Reads and writes nothing of a call but its
/// to-do lines and its name, which is all the widget shows.
@MainActor
final class DeskTodosPublisher {
    private let store: MeetingStore
    private let shelf: URL
    private var stream: FSEventStreamRef?
    private var pending: Task<Void, Never>?
    private var last: DeskTodos?
    private var surfaceWatch: (any NSObjectProtocol)?
    /// The notch's ground, which the widget is drawn on too. Set once the
    /// appearance model exists; black until then.
    var surface: @MainActor () -> DeskSurface = { .black }
    /// Told whenever the meetings folder or the ticks change: the Next call
    /// widget reads "notes ready" from the same folder, and one watch is
    /// enough.
    var onChange: (@MainActor () -> Void)?

    /// Nil when this build has no widget.
    init?(store: MeetingStore = MeetingStore(), bundle: Bundle = .main) {
        guard let group = bundle.object(forInfoDictionaryKey: DeskShelf.infoKey) as? String, !group.isEmpty,
              let shelf = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        self.store = store
        self.shelf = shelf
    }

    func start() {
        let ticks = shelf.appendingPathComponent(DeskShelf.ticksFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: ticks, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        watch([store.root.path, ticks.path])
        // A change of ground redraws the widget, like a change of to-dos.
        surfaceWatch = NotificationCenter.default.addObserver(
            forName: .notchSurfaceDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Reads it all again, after a short pause so a burst of writes (a page
    /// saved twice, five ticks in a row) is one read.
    func refresh() {
        onChange?()
        pending?.cancel()
        pending = Task { [weak self, store, shelf] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            var todos = await Task.detached(priority: .utility) {
                Self.applyTicks(in: shelf, store: store)
                return Self.snapshot(store: store, now: .now)
            }.value
            guard let self else { return }
            todos.surface = self.surface()
            self.publish(todos)
        }
    }

    private func publish(_ todos: DeskTodos) {
        guard todos != last else { return }
        last = todos
        let url = shelf.appendingPathComponent(DeskShelf.snapshotName)
        guard let data = try? DeskShelf.encoder().encode(todos) else { return }
        // The widget writes its own copy straight after a press, so it draws
        // the tick at once; ours lands a moment later and says the same.
        if (try? Data(contentsOf: url)) != data { try? data.write(to: url, options: .atomic) }
        WidgetCenter.shared.reloadAllTimelines()
    }

    nonisolated static func snapshot(store: MeetingStore, now: Date) -> DeskTodos {
        let calendar = Calendar.current
        let calls = store.calls()
            .filter { calendar.isDate($0.record.startedAt, inSameDayAs: now) }
            .map { DeskTodos.Call(folder: $0.folder.lastPathComponent, record: $0.record,
                                  page: store.notesPage(in: $0.folder)) }
        return DeskTodos.today(calls, now: now, calendar: calendar)
    }

    /// Every tick the widget left, oldest first, written into its call's
    /// pages and then removed. A tick that no longer fits its page (the
    /// to-do was edited or the call deleted) is dropped: the widget redraws
    /// from the page, which is the truth.
    nonisolated static func applyTicks(in shelf: URL, store: MeetingStore) {
        let folder = shelf.appendingPathComponent(DeskShelf.ticksFolder, isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        for name in names {
            let file = folder.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file), data.count < 16_384,
                  let tick = try? DeskShelf.decoder().decode(DeskTick.self, from: data) else { continue }
            try? store.tick(tick)
        }
    }

    // MARK: - Watching

    private func watch(_ paths: [String]) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let publisher = Unmanaged<DeskTodosPublisher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { publisher.refresh() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Never, in practice: the publisher lives as long as the app. Here so a
    /// test that makes one leaves no stream behind.
    func stop() {
        pending?.cancel()
        if let surfaceWatch { NotificationCenter.default.removeObserver(surfaceWatch) }
        surfaceWatch = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
