import AirlockCore
import Foundation
import Observation

/// The calls on the notch's Calls tab, read from the meetings folder off the
/// main thread and kept here, so drawing the tab never touches the disk.
///
/// Read again when the list comes on screen (every time the panel opens on
/// the Calls tab), when a call's notes are saved, and whenever the meetings
/// folder changes while the list is showing: a call folder moved to the Bin
/// leaves the list at once, not at the next open.
///
/// Holds what `CallsCard.rows` keeps and nothing more: names, times, to-do
/// and people counts, and how many calls this week. The records it reads to get them are dropped with the read.
@MainActor
@Observable
final class RecentCalls {
    private(set) var rows: [CallsCard.Row] = []
    /// Finished calls begun this week, every one on disk rather than only
    /// the rows: the "5 calls this week" beside the tab's name.
    private(set) var week = 0
    /// False until the first read finishes, so "No calls yet" is not said for
    /// the moment it takes to look.
    private(set) var loaded = false

    /// Nil for a stand-in that reads no disk.
    @ObservationIgnored private let store: MeetingStore?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var watch: DispatchSourceFileSystemObject?
    /// Lists on screen that want the folder watched: the notch's, and the
    /// island preview in Settings when it shows the Calls tab. The watch runs
    /// while any of them is up and stops with the last.
    @ObservationIgnored private var watchers = 0

    init(store: MeetingStore) {
        self.store = store
    }

    /// For the state gallery: these rows, read from no disk.
    init(previewing rows: [CallsCard.Row], week: Int? = nil) {
        store = nil
        self.rows = rows
        self.week = week ?? rows.count
        loaded = true
    }

    /// Reads the calls again, off the main thread. A read already running is
    /// dropped for this one, which sees everything it would have.
    func refresh() {
        guard let store else { return }
        loading?.cancel()
        loading = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                let calls = store.calls()
                return (rows: CallsCard.rows(from: calls) { store.notesPage(in: $0) },
                        week: CallsCard.thisWeek(calls))
            }.value
            guard !Task.isCancelled, let self else { return }
            if found.rows != rows { rows = found.rows }
            if found.week != week { week = found.week }
            loaded = true
        }
    }

    /// Waits for the read in flight. For tests, which have no list to watch
    /// it land in.
    func settled() async {
        await loading?.value
    }

    /// The list came on screen: anything touching the meetings folder (a call
    /// folder moved to the Bin, renamed, or a new call's) reads it again.
    func startWatching() {
        watchers += 1
        guard watchers == 1 else { return }
        watchFolder()
    }

    /// The list left the screen. Nothing watches a folder nobody is looking at.
    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        watch?.cancel()
        watch = nil
    }

    /// Whether the folder is being watched now. For tests.
    var isWatching: Bool { watch != nil }

    /// Without a meetings folder yet there is nothing to watch: the first
    /// call's notes, when they are saved, read it instead.
    private func watchFolder() {
        guard let store, watch == nil else { return }
        let descriptor = open(store.root.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watch = source
    }
}
