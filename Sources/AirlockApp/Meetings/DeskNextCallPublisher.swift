import AirlockCore
import Foundation
import WidgetKit

/// Keeps the "Next call" desktop widget current: the next timed events from
/// the calendar the notch already reads, and the newest of today's calls
/// whose notes are written.
///
/// Asked to refresh when the calendar's upcoming events change (a minute
/// tick, an edit in Calendar), when anything under the meetings folder
/// changes (the to-dos publisher watches it and passes the word on), and
/// when the notch's ground changes. The widget is asked to redraw only when
/// the snapshot changed; between those, its own timeline moves it along.
///
/// Like the to-dos publisher, nothing on a build with no App Group. Writes
/// only titles and times: no link, no attendee, no notes.
@MainActor
final class DeskNextCallPublisher {
    private let store: MeetingStore
    private let shelf: URL
    private var pending: Task<Void, Never>?
    private var last: DeskNextCall?
    private var surfaceWatch: (any NSObjectProtocol)?
    /// The calendar's upcoming events, already filtered by the person's
    /// choice of calendars and empty when the calendar is switched off.
    var events: @MainActor () -> [CalendarEvent] = { [] }
    var surface: @MainActor () -> DeskSurface = { .black }

    init?(store: MeetingStore = MeetingStore(), bundle: Bundle = .main) {
        guard let group = bundle.object(forInfoDictionaryKey: DeskShelf.infoKey) as? String, !group.isEmpty,
              let shelf = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        self.store = store
        self.shelf = shelf
    }

    func start() {
        surfaceWatch = NotificationCenter.default.addObserver(
            forName: .notchSurfaceDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        pending?.cancel()
        pending = Task { [weak self, store] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let notes = await Task.detached(priority: .utility) {
                let calls = store.calls().map { (folder: $0.folder.lastPathComponent, record: $0.record) }
                return DeskNextCall.notesReady(calls, now: .now)
            }.value
            guard let self else { return }
            let events = self.events()
                .filter { !$0.isAllDay }
                .map { DeskNextCall.Event(id: $0.id, title: $0.title, start: $0.start, end: $0.end,
                                          join: $0.meeting?.buttonTitle) }
            self.publish(DeskNextCall(events: DeskNextCall.upcoming(events, now: .now),
                                      notes: notes, surface: self.surface()))
        }
    }

    private func publish(_ next: DeskNextCall) {
        guard next != last else { return }
        last = next
        let url = shelf.appendingPathComponent(DeskNextCall.snapshotName)
        guard let data = try? DeskShelf.encoder().encode(next) else { return }
        if (try? Data(contentsOf: url)) != data { try? data.write(to: url, options: .atomic) }
        WidgetCenter.shared.reloadTimelines(ofKind: DeskNextCall.widgetKind)
    }

    func stop() {
        pending?.cancel()
        if let surfaceWatch { NotificationCenter.default.removeObserver(surfaceWatch) }
        surfaceWatch = nil
    }
}
