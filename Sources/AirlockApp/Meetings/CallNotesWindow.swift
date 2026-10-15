import AppKit
import AirlockCore
import SwiftUI

/// The window "Show" opens after a call: every call's notes and transcript,
/// newest first, read from the files in `~/Airlock/Meetings/`. The menu bar's
/// "Call Notes…" and Settings open it too, on the newest call.
///
/// The files stay the record. This only reads them, so an edit made in a
/// text editor shows here on the next look, and nothing here can lose one.
/// Same black ground and see-through title bar as Settings.
@MainActor
final class CallNotesWindowController {
    private let library: CallNotesLibrary
    private var window: NSWindow?
    private var focusObserver: (any NSObjectProtocol)?

    init(store: MeetingStore) {
        library = CallNotesLibrary(store: store)
    }

    /// Opens on `folder`'s call, or with nil on the newest, whatever was
    /// showing before: nil is the way in that names no call (the menu bar,
    /// Settings), and somebody going to look at their calls expects the
    /// latest, not the one an answer pointed at last week.
    func show(folder: URL?) {
        if let folder {
            library.reload(selecting: folder.lastPathComponent)
        } else {
            library.reloadOnNewest()
        }
        present()
    }

    /// Opens on `folder`'s transcript at `time` seconds in, the turn said
    /// then lit for a moment: where an answer about the call came from.
    func show(folder: URL, saidAt time: TimeInterval) {
        library.reload(selecting: folder.lastPathComponent, saidAt: time,
                       reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        present()
    }

    /// Opens on `folder`'s call, on `tab`: from the window beside a call,
    /// which may want its transcript rather than its notes.
    func show(folder: URL, on tab: CallNotesLibrary.Tab) {
        library.reload(selecting: folder.lastPathComponent)
        library.tab = tab
        present()
    }

    /// The call notes are being taken of, drawn as it is written, and the
    /// window beside the call that "Open in a window" opens.
    func follow(_ live: CallNotesLive, openWindow: @escaping @MainActor () -> Void,
                isPaused: @escaping @MainActor () -> Bool) {
        library.live = CallNotesLibrary.Live(call: live, openWindow: openWindow, isPaused: isPaused)
    }

    /// The "Take notes" button at the foot of the list: what it says now, and
    /// pressing it.
    func takeNotes(state: @escaping @MainActor () -> MeetingNotesFlow.HandButton,
                   press: @escaping @MainActor () -> Void) {
        library.takeNotes = CallNotesLibrary.TakeNotes(state: state, press: press)
    }

    /// Where names given in the window go: through the notes model, so a
    /// call that carries on keeps them (`CallNotesLibrary.saveNames`).
    func saveNames(_ save: @escaping @MainActor (URL, [MeetingVoiceName]) -> Void) {
        library.saveNames = save
    }

    /// "Add a recording" at the foot of the list, files dropped on the
    /// window, and the page of a recording being read.
    func recordings(_ recordings: CallNotesLibrary.Recordings) {
        library.recordings = recordings
    }

    /// Notes finished while the window is up: they appear without a click.
    func refreshIfOpen() {
        guard window?.isVisible == true else { return }
        library.reload(selecting: nil)
    }

    /// The window `present` shows, sized and laid out, not yet on screen.
    static func makeWindow(_ library: CallNotesLibrary) -> NSWindow {
        let hosting = NSHostingController(rootView: CallNotesView().environment(library))
        // The window may be made smaller than the content's ideal size.
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Call notes"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(SettingsLook.ground)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        // Sized and laid out before centring, for the reason Settings
        // gives (`SettingsWindowController.present`).
        window.setContentSize(NSSize(width: 780, height: 580))
        hosting.view.layoutSubtreeIfNeeded()
        return window
    }

    private func present() {
        if window == nil {
            let window = Self.makeWindow(library)
            window.centerOnNotchScreen()
            window.setFrameAutosaveName("airlock.callNotes")
            // Back from a text editor with the notes changed: read them again.
            focusObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak library] _ in
                MainActor.assumeIsolated { library?.reload(selecting: nil) }
            }
            self.window = window
        }
        // In the Dock and in ⌘Tab while it is open, and a stage of its own
        // under Stage Manager, rather than a window stuck over another app.
        if let window { DockPresenceController.shared.willShow(window) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The calls on disk, and which one the window shows.
@MainActor
@Observable
final class CallNotesLibrary {
    struct Call: Identifiable, Equatable, Sendable {
        let folder: URL
        let record: MeetingRecord
        /// What the notes file says; nil before it is written.
        let page: String?
        var id: String { folder.lastPathComponent }
    }

    enum Tab: Hashable { case notes, transcript }

    /// The button at the foot of the list, as the Calls tab has it: notes of
    /// a meeting in the room, of the call that is on, or "Stop notes".
    struct TakeNotes {
        let state: @MainActor () -> MeetingNotesFlow.HandButton
        let press: @MainActor () -> Void
    }

    /// "Add a recording": the recording being read, and the ways to add
    /// one and stop it (`RecordingImporter`).
    struct Recordings {
        let reading: @MainActor () -> RecordingImporter.Reading?
        /// Whether a file dropped now would be read.
        let takes: @MainActor (URL) -> Bool
        let add: @MainActor () -> Void
        let drop: @MainActor (URL) -> Void
        let stop: @MainActor () -> Void
    }

    /// A file held over the window: its name and length once they are read.
    struct Dropping: Equatable {
        var fileName: String?
        var seconds: TimeInterval?
    }

    /// A line of the notes was tapped: the transcript entry it was said at,
    /// lit for a moment.
    struct Spotlight: Equatable {
        /// The call it belongs to, so another call's entry is never lit.
        let call: String
        /// Its place in `MeetingTimeline.entries(of:)`.
        let entry: Int
        /// One more on every tap, so the same line tapped twice lands twice.
        let serial: Int
        /// Full strength while true; turning false is the fade.
        var lit: Bool
    }

    private(set) var calls: [Call] = []
    /// False until the first read finishes, so an empty list is not shown
    /// as "no calls" for the moment it takes to look.
    private(set) var loaded = false
    var selection: String?
    var tab: Tab = .notes
    private(set) var spotlight: Spotlight?
    /// What the search field above the list says. Empty lists every call.
    var search = ""
    /// Nil draws no button.
    @ObservationIgnored var takeNotes: TakeNotes?
    /// The call whose voices "Who's who" is naming; nil while it is closed.
    var naming: String?
    /// The name in the transcript that was clicked to say who it is; nil
    /// while none was.
    var renaming: Renaming?
    /// Where names go. Nil writes them straight to the call's folder; the
    /// app sends them through the notes model, which may still be holding
    /// the call (`MeetingNotesModel.saveNames`).
    @ObservationIgnored var saveNames: (@MainActor (URL, [MeetingVoiceName]) -> Void)?
    /// Nil draws no "Add a recording" and takes no drops.
    @ObservationIgnored var recordings: Recordings?
    /// A file is held over the window; nil when none is.
    var dropping: Dropping?
    /// What Copy just put on the clipboard. Its button says "Copied" for a
    /// moment while that call and tab are showing, and nowhere else.
    private(set) var copied: Copied?
    /// The call notes are being taken of. Nil draws every call from disk
    /// alone, with no "Live" and no "Open in a window".
    @ObservationIgnored var live: Live?

    /// The notes model's call as it is written, and what the window can do
    /// with it.
    struct Live {
        let call: CallNotesLive
        let openWindow: @MainActor () -> Void
        let isPaused: @MainActor () -> Bool
    }

    /// `call` as it stands: while it is being written, the notes model's
    /// record, a line or two ahead of the file; once the file has caught up
    /// with its end, the file, which carries any names given since.
    func current(_ call: Call) -> Call {
        guard let live = live?.call, live.folder?.lastPathComponent == call.id, let record = live.record,
              record.endedAt == nil || call.record.endedAt == nil else { return call }
        return Call(folder: call.folder, record: record, page: call.page)
    }

    /// Whether `call` is the one being written down now.
    func isLive(_ call: Call) -> Bool {
        guard let live, live.call.folder?.lastPathComponent == call.id, let record = live.call.record else {
            return false
        }
        return CallLive.stage(of: record, paused: false, outcome: live.call.outcome).isLive
    }

    /// Whether the notes are paused now.
    var isPaused: Bool { live?.isPaused() ?? false }

    struct Copied: Equatable {
        let call: String
        let tab: Tab
    }

    /// Whether Copy above `call` should say "Copied" now.
    func justCopied(_ call: Call) -> Bool {
        copied == Copied(call: call.id, tab: tab)
    }

    /// The recording being read, read from the importer as the view draws,
    /// so the page follows it.
    var reading: RecordingImporter.Reading? { recordings?.reading() }

    /// Whether `call` is the meeting the recording being read makes.
    func isRead(_ call: Call) -> Bool {
        reading?.folder?.lastPathComponent == call.id
    }

    /// A name in the transcript, clicked: the call, and its place in
    /// `MeetingTimeline.entries(of:)`.
    struct Renaming: Equatable {
        let call: String
        let entry: Int
    }

    /// The calls the list shows: every one, or those the search finds.
    var shown: [Call] {
        let query = search
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return calls }
        return calls.filter { Self.matches(query, $0) }
    }

    /// The call chosen in the list, else the first the list shows.
    var selected: Call? {
        let shown = shown
        return shown.first { $0.id == selection } ?? shown.first
    }

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var spotlights = 0
    @ObservationIgnored private var fading: Task<Void, Never>?
    @ObservationIgnored private var copiedEnds: Task<Void, Never>?
    /// A moment to light once the calls are read. Kept until a read
    /// finishes rather than handed to one, because the window becoming key
    /// starts a second read that cancels the first.
    @ObservationIgnored private var pendingMoment: (call: String, time: TimeInterval, reduceMotion: Bool)?
    /// The newest call is to be chosen once the calls are read. Kept until a
    /// read finishes, for the same reason as `pendingMoment`.
    @ObservationIgnored private var pendingNewest = false

    init(store: MeetingStore) {
        self.store = store
    }

    /// For the state gallery: these calls, read from no disk. `spotlightAt`
    /// draws the first call as if the line of notes said then had just been
    /// tapped, its turn lit at full strength and left that way.
    /// `naming` opens "Who's who" on the first call; `renamingAt` opens the
    /// box beside that transcript entry's name.
    /// `reading` is a recording being read into the first call;
    /// `dropping`, a file held over the window; `copied`, the first call's
    /// tab just copied; `live`, the first call being written down now.
    init(previewing calls: [Call], tab: Tab = .notes, spotlightAt time: TimeInterval? = nil,
         search: String = "", hand: MeetingNotesFlow.HandButton = .takeNotes,
         naming: Bool = false, renamingAt entry: Int? = nil,
         reading: RecordingImporter.Reading? = nil, dropping: Dropping? = nil, copied: Bool = false,
         live: Bool = false, hearing: [CallLive.Hearing] = []) {
        store = MeetingStore(root: URL(fileURLWithPath: "/var/empty"))
        self.calls = calls
        self.tab = tab
        self.search = search
        takeNotes = TakeNotes(state: { hand }, press: {})
        recordings = Recordings(reading: { reading }, takes: { _ in true }, add: {}, drop: { _ in }, stop: {})
        self.dropping = dropping
        loaded = true
        if naming { self.naming = calls.first?.id }
        if copied, let call = calls.first { self.copied = Copied(call: call.id, tab: tab) }
        if live, let call = calls.first {
            self.live = Live(call: CallNotesLive(previewing: call.record, folder: call.folder, hearing: hearing),
                             openWindow: {}, isPaused: { false })
        }
        if let entry, let call = calls.first { renaming = Renaming(call: call.id, entry: entry) }
        if let time, let call = calls.first,
           let entry = MeetingTimeline.spoken(at: time, in: MeetingTimeline.entries(of: call.record)) {
            spotlight = Spotlight(call: call.id, entry: entry, serial: 0, lit: true)
        }
    }

    /// How long a tapped line's turn stays lit before it fades with Close,
    /// which takes it out over about half a second more.
    static let spotlightHold: Duration = .seconds(1)
    /// Under Reduce Motion there is no fade: the light holds this long, then
    /// is simply gone.
    static let calmSpotlight: Duration = .seconds(1.5)

    /// A line of the notes said at `time` was tapped: the transcript opens on
    /// the turn said then (or just before), lit, and the light goes after a
    /// moment. The detail view does the scrolling.
    func showSaid(at time: TimeInterval, in call: Call, reduceMotion: Bool) {
        fading?.cancel()
        spotlights += 1
        let serial = spotlights
        spotlight = MeetingTimeline.spoken(at: time, in: MeetingTimeline.entries(of: call.record))
            .map { Spotlight(call: call.id, entry: $0, serial: serial, lit: true) }
        withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) { tab = .transcript }
        guard spotlight != nil else { return }
        fading = Task { [weak self] in
            try? await Task.sleep(for: reduceMotion ? Self.calmSpotlight : Self.spotlightHold)
            guard !Task.isCancelled, let self, spotlight?.serial == serial else { return }
            guard !reduceMotion else {
                spotlight = nil
                return
            }
            withAnimation(Motion.close.animation(reduceMotion: false)) { spotlight?.lit = false }
            try? await Task.sleep(for: .seconds(Motion.close.duration(reduceMotion: false)))
            guard !Task.isCancelled, spotlight?.serial == serial else { return }
            spotlight = nil
        }
    }

    /// Reads every call again, off the main thread. `folder` names the
    /// call to show; nil keeps the one showing. With `time`, it opens on the
    /// transcript at that moment instead of the notes.
    func reload(selecting folder: String?, saidAt time: TimeInterval? = nil, reduceMotion: Bool = false) {
        guard store.root.path != "/var/empty" else { return }
        if let folder {
            selection = folder
            tab = time == nil ? .notes : .transcript
            if let time { pendingMoment = (folder, time, reduceMotion) }
            pendingNewest = false
        }
        let store = store
        loading?.cancel()
        loading = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                store.calls().map { Call(folder: $0.folder, record: $0.record, page: store.notesPage(in: $0.folder)) }
            }.value
            guard !Task.isCancelled, let self else { return }
            if found != calls { calls = found }
            loaded = true
            if pendingNewest {
                pendingNewest = false
                // Unless a call was picked in the sidebar while it read.
                if selection == nil { selection = calls.first?.id }
            }
            if let moment = pendingMoment {
                pendingMoment = nil
                if let call = calls.first(where: { $0.id == moment.call }) {
                    showSaid(at: moment.time, in: call, reduceMotion: moment.reduceMotion)
                }
            }
        }
    }

    /// Reads every call again and shows the newest, on its notes: the way in
    /// that names no call. The choice is cleared at once, so the window does
    /// not open on a call looked at before while the read runs (`selected`
    /// falls back to the first call, and the list is newest first). It is
    /// then pinned to the newest, so a call that ends while the window is up
    /// joins the list without taking the page over. With no calls at all the
    /// read still finishes, and the window says there are none yet.
    func reloadOnNewest() {
        selection = nil
        tab = .notes
        pendingMoment = nil
        pendingNewest = true
        reload(selecting: nil)
    }

    /// Waits for the read in flight. For tests, which have no window to
    /// watch it land in.
    func settled() async {
        await loading?.value
    }

    /// Whether `record`'s voices can be named: once the call is over, and
    /// only when it has voices to tell apart (`MeetingRecord.voices`).
    static func canName(_ record: MeetingRecord) -> Bool {
        record.endedAt != nil && !record.voices.isEmpty
    }

    /// Names `call`'s voices as `names` say, every voice left out going back
    /// to its number, and closes whatever asked. The transcript and the
    /// people above it change at once; the notes when the files are read
    /// again, a moment later.
    func name(_ call: Call, as names: [MeetingVoiceName]) {
        naming = nil
        renaming = nil
        var record = call.record
        record.replaceNames(with: names)
        guard Self.sorted(record.names) != Self.sorted(call.record.names) else { return }
        let preview = store.root.path == "/var/empty"
        if let index = calls.firstIndex(where: { $0.id == call.id }) {
            // The gallery has no files to read again: its page is named here.
            let page = preview ? call.page.map { MeetingNaming.apply(record, to: $0) } : call.page
            calls[index] = Call(folder: call.folder, record: record, page: page)
        }
        guard !preview else { return }
        if let saveNames {
            saveNames(call.folder, record.names)
        } else {
            try? store.saveNames(of: record, in: call.folder)
        }
        reload(selecting: nil)
    }

    private static func sorted(_ names: [MeetingVoiceName]) -> [MeetingVoiceName] {
        names.sorted { $0.voice < $1.voice }
    }

    /// The tab showing, as text, onto the clipboard, and Copy says
    /// "Copied" for a moment. With nothing to copy it says nothing.
    func copy(_ call: Call) {
        let text: String
        switch tab {
        case .notes: text = call.page ?? ""
        case .transcript: text = Self.plainTranscript(of: call.record)
        }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let done = Copied(call: call.id, tab: tab)
        copied = done
        AccessibilityNotification.Announcement("Copied").post()
        copiedEnds?.cancel()
        copiedEnds = Task { [weak self] in
            try? await Task.sleep(for: MeetingNotesBanner.flashFor)
            guard !Task.isCancelled, let self, copied == done else { return }
            copied = nil
        }
    }

    /// The file for the tab showing, picked out in Finder; the call's folder
    /// when that file is not there yet.
    func reveal(_ call: Call) {
        let name = tab == .notes ? MeetingFiles.notesName : MeetingFiles.transcriptName
        let file = call.folder.appendingPathComponent(name)
        let target = FileManager.default.fileExists(atPath: file.path) ? file : call.folder
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// What Copy puts on the clipboard from the Transcript tab: what the tab
    /// shows, typed notes, pauses and changes of language included, as plain
    /// text.
    static func plainTranscript(of record: MeetingRecord) -> String {
        MeetingTimeline.entries(of: record).map { entry in
            switch entry {
            case .speech(let turn, _):
                "\(record.label(for: turn)) · \(MeetingFiles.clock(turn.start))\n\(turn.text)"
            case .jot(let jot):
                "Your note · \(MeetingFiles.clock(jot.at))\n\(jot.text)"
            case .pause(let pause):
                MeetingTimeline.pauseLabel(pause)
            case .language(let listening):
                MeetingTimeline.languageLabel(listening)
            }
        }
        .joined(separator: "\n\n")
    }

    /// Whether the search finds `call`: in its name, its notes page, what
    /// was said and what the person typed (`CallsCard.matches`).
    static func matches(_ query: String, _ call: Call) -> Bool {
        CallsCard.matches(query, in: [MeetingFiles.title(of: call.record), call.page ?? ""]
            + call.record.segments.map(\.text) + call.record.jots.map(\.text))
    }

    /// The calls the list shows, by the day each began, in the order given
    /// (newest first): "Today", "Yesterday", "Friday 9 Oct".
    static func days(_ calls: [Call], now: Date = Date(),
                     calendar: Calendar = .current) -> [(heading: String, calls: [Call])] {
        var days: [(start: Date, calls: [Call])] = []
        for call in calls {
            let start = calendar.startOfDay(for: call.record.startedAt)
            if let last = days.indices.last, days[last].start == start {
                days[last].calls.append(call)
            } else {
                days.append((start, [call]))
            }
        }
        return days.map { (CallsCard.dayHeading($0.start, now: now, calendar: calendar), $0.calls) }
    }

    /// "Today 14:30", "Yesterday 09:05", "Mon 6 Oct 14:30" — and how long.
    /// Worded in Core beside the notch's Calls tab, so the two name a day
    /// the same way.
    static func when(_ record: MeetingRecord, now: Date = Date()) -> String {
        CallsCard.when(startedAt: record.startedAt, endedAt: record.endedAt, now: now)
    }

    /// "Today 10:02–10:16 · 14 min" under the call's title: the list's day,
    /// worded by the same rule (`CallsCard.header`).
    static func header(_ record: MeetingRecord, now: Date = Date()) -> String {
        CallsCard.header(startedAt: record.startedAt, endedAt: record.endedAt, now: now)
    }
}

// MARK: - Views

struct CallNotesView: View {
    @Environment(CallNotesLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The window's smallest size comes from an empty box, not from the
        // calls: the window asks for it again on every change, and asking the
        // calls laid the whole page out a second time, every frame of a slide.
        Color.clear
            .frame(minWidth: 640, minHeight: 420)
            .overlay { calls }
            .background(SettingsLook.ground)
            .onDrop(of: [.fileURL], delegate: CallNotesDrop(library: library, reduceMotion: reduceMotion))
            .overlay {
                if let id = library.naming, let call = library.calls.first(where: { $0.id == id }) {
                    CallNotesWhosWho(call: call)
                        .transition(.opacity)
                }
            }
    }

    private var calls: some View {
        HStack(spacing: 0) {
            CallNotesSidebar()
            Group {
                if let call = library.selected {
                    CallNotesDetail(call: library.current(call), live: library.isLive(call))
                } else if library.loaded, !library.calls.isEmpty {
                    CallNotesEmpty(title: "No calls found",
                                   detail: "No call's name, notes or transcript has those words.")
                } else if library.loaded {
                    CallNotesEmpty(title: "No call notes yet",
                                   detail: "When Airlock takes notes of a call, they appear here.",
                                   bloub: true)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if let dropping = library.dropping {
                    CallNotesDropOverlay(dropping: dropping)
                        .transition(.opacity)
                }
            }
        }
    }
}

/// The calls down the side: a search field, the calls by day with their
/// app's tile and the to-dos each left, and "Take notes" at the foot.
private struct CallNotesSidebar: View {
    @Environment(CallNotesLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight

    static let width: CGFloat = 226

    var body: some View {
        @Bindable var library = library
        VStack(spacing: 0) {
            CallNotesSearchField(text: $library.search)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(CallNotesLibrary.days(library.shown), id: \.heading) { day in
                        Text(day.heading)
                            .font(Theme.chrome(10.5, .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.top, 12)
                            .padding(.bottom, 5)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(day.calls) { call in
                            CallNotesListRow(call: call, isSelected: call.id == library.selected?.id,
                                             live: library.isLive(call), highlight: highlight,
                                             reading: library.isRead(call) ? library.reading?.progress : nil) {
                                withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) {
                                    library.selection = call.id
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            VStack(spacing: 8) {
                if let takeNotes = library.takeNotes {
                    CallNotesTakeNotes(takeNotes: takeNotes)
                }
                if let recordings = library.recordings {
                    CallNotesAddRecording(recordings: recordings, busy: library.reading != nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CallsLook.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(SettingsLook.rowStroke).frame(width: 1).ignoresSafeArea()
        }
    }
}

/// "Search calls": finds a call by its name, its notes or what was said.
private struct CallNotesSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            TextField("Search calls", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textPrimary)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .clickable()
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

/// One call in the list: its app's tile, its name over when it began and
/// how long it lasted, and the to-dos still open on its notes.
private struct CallNotesListRow: View {
    let call: CallNotesLibrary.Call
    let isSelected: Bool
    /// Being written down now: "Live" beside when it began.
    let live: Bool
    let highlight: Namespace.ID
    /// How far along the recording this meeting is read from is; nil
    /// unless it is being read.
    let reading: RecordingImport.Progress?
    let select: () -> Void

    @State private var hovered = false

    var body: some View {
        // The meeting's own name when the calendar gave one, as the header
        // and the folder have it.
        let title = MeetingFiles.title(of: call.record)
        let todos = CallsCard.openTodos(in: call.page)
        Button(action: select) {
            HStack(spacing: 9) {
                CallAppTile(kind: CallGlyph.kind(for: call.record), size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.chrome(12.5, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text(subline)
                            .font(Theme.chrome(11))
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                            .lineLimit(1)
                        if live { CallLiveChip() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let reading {
                    RecordingProgressRing(fraction: reading.fraction, size: 17)
                } else if todos > 0 {
                    Text("\(todos)")
                        .font(Theme.chrome(10.5, .bold))
                        .monospacedDigit()
                        .foregroundStyle(CallsLook.todoText)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Theme.needs.opacity(0.16)))
                        .accessibilityLabel(CallsCard.todos(todos) ?? "")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background {
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                if isSelected {
                    shape.fill(Theme.running.opacity(0.16))
                        .overlay(shape.strokeBorder(Theme.running.opacity(0.22), lineWidth: 1))
                        .matchedGeometryEffect(id: "selected", in: highlight)
                } else if hovered {
                    shape.fill(Color.white.opacity(0.04))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(MotionEffect.pointer) { hovered = inside }
        }
        .clickable()
        .help(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// "10:02 · 14 min": the day is the heading above. A recording being
    /// read is as long as the recording.
    private var subline: String {
        let start = CallsCard.time(call.record.startedAt)
        guard let end = call.record.shownEnd else { return "\(start) · now" }
        return "\(start) · \(CallsCard.length(from: call.record.startedAt, to: end))"
    }
}

/// "Take notes" across the foot of the list, as on the Calls tab; "Stop
/// notes" while notes are taken, since this window has no banner.
private struct CallNotesTakeNotes: View {
    let takeNotes: CallNotesLibrary.TakeNotes

    @State private var hovered = false

    var body: some View {
        let hand = takeNotes.state()
        if let label = CallsCard.handLabel(hand) {
            let stop = hand == .stop
            let tint = stop ? Theme.assistant : Theme.running
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            Button { takeNotes.press() } label: {
                HStack(spacing: 6) {
                    if stop {
                        NotesBreathingDot(size: 7)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(label)
                        .font(Theme.chrome(11.5, .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(stop ? CallsLook.saidText : CallsLook.takeText)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(shape.fill(tint.opacity(hovered ? 0.26 : 0.18)))
                .overlay(shape.strokeBorder(tint.opacity(0.3), lineWidth: 1))
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                withAnimation(MotionEffect.pointer) { hovered = inside }
            }
            .clickable()
            .help(CallsCard.handHelp(hand))
        }
    }
}

/// "Add a recording…" under "Take notes": a recording somebody already has,
/// read into a meeting of its own. Greyed while one is read.
private struct CallNotesAddRecording: View {
    let recordings: CallNotesLibrary.Recordings
    let busy: Bool

    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button { recordings.add() } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("Add a recording\u{2026}")
                    .font(Theme.chrome(11.5, .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(CallsLook.quietText)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(shape.fill(Color.white.opacity(hovered && !busy ? 0.09 : 0.05)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.45 : 1)
        .onHover { inside in
            withAnimation(MotionEffect.pointer) { hovered = inside }
        }
        .clickable()
        .help(busy ? "Airlock reads one recording at a time"
                   : "Get notes from a recording you already have, or drop one on this window")
    }
}

private struct CallNotesDetail: View {
    @Environment(CallNotesLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let call: CallNotesLibrary.Call
    /// Being written down now: its transcript follows the newest line.
    let live: Bool

    /// The page's side margin. The scroll view itself runs edge to edge, so
    /// a lit transcript turn can reach a little into it.
    private static let margin: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CallNotesHeader(call: call, live: live)
                .padding(.horizontal, Self.margin)
                // Over the page, for the "Copied" that hangs below an icon.
                .zIndex(1)
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if library.isRead(call), let reading = library.reading {
                            // Nothing to read on either tab yet: how far along, and what was heard.
                            CallNotesReading(reading: reading) { library.recordings?.stop() }
                        } else {
                            switch library.tab {
                            case .notes: CallNotesPage(call: call)
                            case .transcript: CallTranscript(call: call, live: live)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 18)
                    .padding(.bottom, 30)
                    .padding(.horizontal, Self.margin)
                }
                .scrollIndicators(.automatic)
                .followsNewest(said: following ? CallLive.spokenCount(MeetingTimeline.entries(of: call.record)) : 0,
                               enabled: following, ground: SettingsLook.ground, pinsShortToFoot: false)
                .task(id: library.spotlight?.serial) { await land(proxy) }
            }
            // A new call starts at its top, not where the last one was left.
            .id("\(call.id)·\(library.tab)")
        }
    }

    /// The transcript of a call being written, which keeps its newest line
    /// in view.
    private var following: Bool { live && library.tab == .transcript }

    /// Brings the turn a tapped line points to into the middle of the
    /// transcript. The short wait is for the transcript, which has only just
    /// replaced the notes and is laid out once before it can be scrolled.
    private func land(_ proxy: ScrollViewProxy) async {
        guard let spotlight = library.spotlight, spotlight.call == call.id,
              library.tab == .transcript else { return }
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        // The transcript makes only the turns in view, and guesses how tall
        // the rest are: the first scroll lands where it guesses and makes the
        // turns there, and the second, once they are measured, centres it.
        proxy.scrollTo(spotlight.entry, anchor: .center)
        try? await Task.sleep(for: .milliseconds(30))
        guard !Task.isCancelled else { return }
        withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) {
            proxy.scrollTo(spotlight.entry, anchor: .center)
        }
    }
}

/// Above a call's notes: its app, its name, when and how long, who was on
/// it, then Notes | Transcript with Copy and Show in Finder.
private struct CallNotesHeader: View {
    @Environment(CallNotesLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let call: CallNotesLibrary.Call
    let live: Bool

    var body: some View {
        @Bindable var library = library
        let title = MeetingFiles.title(of: call.record)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                CallAppTile(kind: CallGlyph.kind(for: call.record), size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Theme.chrome(21, .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .help(title)
                        .accessibilityAddTraits(.isHeader)
                    meta
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)
            HStack(alignment: .bottom, spacing: 8) {
                CallNotesTabs(tab: $library.tab)
                if live {
                    CallLiveChip(capsule: true)
                        .padding(.bottom, 10)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 12)
                // Words while they fit, then Copy and Show in Finder down to
                // their icons, then Name people too.
                ViewThatFits(in: .horizontal) {
                    tools(compact: false)
                    tools(compact: true)
                    tools(compact: true, nameCompact: true)
                }
            }
            .padding(.top, 18)
        }
        .background(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                .padding(.horizontal, -30)
        }
    }

    /// Name people (once the call is over and has voices), Copy, Show in
    /// Finder.
    private func tools(compact: Bool, nameCompact: Bool = false) -> some View {
        HStack(spacing: 8) {
            if CallNotesLibrary.canName(call.record) {
                CallNotesTool("Name people", symbol: "person.2", tone: .take, compact: nameCompact) {
                    withAnimation(Motion.open.animation(reduceMotion: reduceMotion)) { library.naming = call.id }
                }
            }
            CallNotesTool("Copy", symbol: "doc.on.doc", compact: compact,
                          confirmation: "Copied", confirmed: library.justCopied(call)) { library.copy(call) }
            if live, let open = library.live?.openWindow {
                CallNotesTool("Open in a window", symbol: "sidebar.right", tone: .live, compact: compact) { open() }
            }
            CallNotesTool("Show in Finder", symbol: "folder", compact: compact) { library.reveal(call) }
        }
        .fixedSize()
    }

    /// "Today 10:02–10:16", "14 min", "From a recording" when it was, and
    /// who was there. A recording being read is as long as the recording.
    private var meta: some View {
        let record = call.record
        let people = CallPeople.people(of: record)
        let line = CallPeople.line(people, count: CallPeople.count(of: record))
        return HStack(spacing: 14) {
            label("calendar", CallsCard.dayAndClock(startedAt: record.startedAt, endedAt: record.shownEnd))
            if live {
                // A minute at a time is all "13 min so far" can show.
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    label("clock", CallLive.soFar(record, now: context.date))
                }
            } else {
                label("clock", record.shownEnd.map { CallsCard.length(from: record.startedAt, to: $0) } ?? "now")
            }
            if record.recording != nil {
                label("waveform", "From a recording")
            }
            if let line {
                HStack(spacing: 5) {
                    HStack(spacing: -4) {
                        ForEach(Array(people.prefix(4).enumerated()), id: \.offset) { _, person in
                            CallPersonAvatar(name: person.name, seat: CallPeople.seat(of: person.name, in: people),
                                             size: 18, ring: SettingsLook.ground)
                        }
                    }
                    .padding(.trailing, people.isEmpty ? 0 : 3)
                    Text(line)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .font(Theme.chrome(11.5, .medium))
        .foregroundStyle(Theme.textSecondary)
        .monospacedDigit()
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

/// Copy, Show in Finder: quiet buttons on the tabs' line. Name people is
/// the one in blue: the thing to do next, while the voices are numbers.
/// Open in a window is in Airlock's purple, as everything about notes being
/// taken is.
private struct CallNotesTool: View {
    enum Tone { case quiet, take, live }

    let title: String
    let symbol: String
    let tone: Tone
    /// The icon alone, the words in its tooltip: for a narrow window.
    let compact: Bool
    /// What it says for a moment once it has done its job ("Copied"), with
    /// a green tick for its icon.
    let confirmation: String?
    let confirmed: Bool
    let action: () -> Void

    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, symbol: String, tone: Tone = .quiet, compact: Bool = false,
         confirmation: String? = nil, confirmed: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tone = tone
        self.compact = compact
        self.confirmation = confirmation
        self.confirmed = confirmed
        self.action = action
    }

    private var showsConfirmation: Bool { confirmed && confirmation != nil }

    private var accent: Bool { tone != .quiet }

    /// The icon's colour, and the words'.
    private var iconTint: Color {
        switch tone {
        case .quiet: Theme.textSecondary
        case .take: CallsLook.takeText
        case .live: LiveLook.liveText
        }
    }

    private var textTint: Color {
        switch tone {
        case .quiet: CallsLook.quietText
        case .take: CallsLook.takeText
        case .live: LiveLook.windowText
        }
    }

    private func fill(hovered: Bool) -> Color {
        switch tone {
        case .quiet: Color.white.opacity(hovered ? 0.1 : 0.06)
        case .take: Theme.running.opacity(hovered ? 0.24 : 0.16)
        case .live: Theme.assistant.opacity(hovered ? 0.2 : 0.12)
        }
    }

    private var stroke: Color {
        switch tone {
        case .quiet: Color.white.opacity(0.06)
        case .take: Theme.running.opacity(0.3)
        case .live: Theme.assistant.opacity(0.4)
        }
    }

    private static let height: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: showsConfirmation ? "checkmark" : symbol)
                    .font(.system(size: 11, weight: showsConfirmation ? .bold : .medium))
                    .foregroundStyle(showsConfirmation ? Theme.done : iconTint)
                    .contentTransition(.symbolEffect(.replace))
                if !compact {
                    // Sized for the longer of the two words, so the buttons
                    // beside it stay put while it says "Copied".
                    ZStack(alignment: .leading) {
                        if let confirmation {
                            Text(confirmation).hidden()
                        }
                        Text(showsConfirmation ? confirmation ?? title : title)
                            .foregroundStyle(showsConfirmation ? Theme.textPrimary : textTint)
                    }
                    .font(Theme.chrome(11.5, accent ? .semibold : .medium))
                    .lineLimit(1)
                }
            }
            .padding(.leading, compact ? 9 : 9)
            .padding(.trailing, compact ? 9 : 11)
            .frame(height: Self.height)
            .background(shape.fill(fill(hovered: hovered)))
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
            .contentShape(shape)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(compact ? title : "")
        .accessibilityLabel(showsConfirmation ? confirmation ?? title : title)
        .animation(Motion.confirm.animation(reduceMotion: reduceMotion), value: showsConfirmation)
        .confirmSettle(when: showsConfirmation)
        // An icon alone has no room for the word: it hangs just below
        // instead, over the page, so nothing on the line moves.
        .overlay(alignment: .top) {
            if compact, showsConfirmation, let confirmation {
                Text(confirmation)
                    .font(Theme.chrome(11, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Color(white: 0.17)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    .offset(y: Self.height + 6)
                    .transition(Motion.open.transition(reduceMotion: reduceMotion))
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.open.animation(reduceMotion: reduceMotion), value: showsConfirmation)
        .onHover { inside in
            withAnimation(MotionEffect.pointer) { hovered = inside }
        }
        .clickable()
        .padding(.bottom, 8)
    }
}

/// Notes | Transcript, each with its icon, the one showing underlined in
/// blue on the header's bottom line.
private struct CallNotesTabs: View {
    @Binding var tab: CallNotesLibrary.Tab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 22) {
            item("Notes", "list.bullet", .notes)
            item("Transcript", "text.quote", .transcript)
        }
    }

    private func item(_ title: String, _ symbol: String, _ value: CallNotesLibrary.Tab) -> some View {
        let on = tab == value
        return Button {
            withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) { tab = value }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? Theme.running : Theme.textTertiary)
                Text(title)
                    .font(Theme.chrome(12.5, .semibold))
                    .foregroundStyle(on ? Theme.textPrimary : Theme.textTertiary)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 12)
            // As wide as the words: the line is drawn under the label alone.
            .overlay(alignment: .bottom) {
                if on {
                    Capsule().fill(Theme.running).frame(height: 2)
                        .matchedGeometryEffect(id: "underline", in: underline)
                }
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The notes file, drawn as cards: the summary on Airlock's purple, the
/// person's own notes on paper yellow, then to-dos, decisions, open questions
/// and key points, each with its colour and icon, and the closing line under
/// a lock.
///
/// The person's own words are white; everything Airlock wrote is a step
/// under, so the two never read as one voice. A line that says when it was
/// said can be tapped to see that moment in the transcript.
private struct CallNotesPage: View {
    let call: CallNotesLibrary.Call

    var body: some View {
        if let page = call.page {
            let placed = MeetingPage.placed(MeetingPage.body(of: page, header: MeetingFiles.header(of: call.record)))
            let page = MeetingPage.sections(placed)
            let people = CallPeople.people(of: call.record)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(page.sections.enumerated()), id: \.offset) { _, section in
                    CallNotesCard(call: call, section: section, people: people)
                }
                if !page.closing.isEmpty {
                    CallNotesClosing(lines: page.closing)
                }
            }
        } else if call.record.endedAt == nil, call.record.recording == nil {
            CallNotesEmpty(title: "This call is still being written down",
                           detail: "The notes come when it ends. The transcript so far is in the other tab.")
        } else {
            CallNotesEmpty(title: "The notes are still being written",
                           detail: "They appear here on their own in a moment.")
        }
    }
}

/// A recording being read, in place of its notes: how far along, the steps
/// done and to come, how long is left with "Stop", then the last lines heard,
/// dimmed, as they come.
private struct CallNotesReading: View {
    let reading: RecordingImporter.Reading
    let stop: () -> Void

    /// The last lines heard, at most.
    private static let lines = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            card
            if !reading.lines.isEmpty {
                heard
            }
        }
    }

    private var card: some View {
        let progress = reading.progress
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CallsLook.recording)
                    .accessibilityHidden(true)
                Text(progress.heading)
                    .font(Theme.chrome(15, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(progress.percent)%")
                    .font(Theme.chrome(14, .bold))
                    .foregroundStyle(CallsLook.recording)
                    .monospacedDigit()
            }
            RecordingProgressBar(fraction: progress.fraction)
                .padding(.top, 15)
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(progress.steps.enumerated()), id: \.offset) { _, step in
                    row(step)
                }
            }
            .padding(.top, 18)
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
                .padding(.top, 18)
            HStack(spacing: 18) {
                Text(reading.stopping ? "Stopping\u{2026}" : progress.timeLeftSentence
                     + " You can close this window: Airlock carries on, and the notch shows a tick when the notes are ready.")
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RecordingStopButton(stopping: reading.stopping, action: stop)
            }
            .padding(.top, 15)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(shape.fill(CallsLook.recording.opacity(0.045)))
        .overlay(shape.strokeBorder(CallsLook.recording.opacity(0.26), lineWidth: 1))
        .textSelection(.disabled)
    }

    private func row(_ step: RecordingImport.Step) -> some View {
        HStack(spacing: 10) {
            mark(step.state)
                .frame(width: 16, height: 16)
            Text(step.text)
                .font(Theme.chrome(13, step.state == .now ? .medium : .regular))
                .foregroundStyle(step.state == .later ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let detail = step.detail {
                Text(detail)
                    .font(Theme.chrome(12.5, .semibold))
                    .foregroundStyle(CallsLook.recording)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(step.state == .done ? "Done" : step.state == .now ? "Now" : "To come")
    }

    @ViewBuilder private func mark(_ state: RecordingImport.Step.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.done)
        case .now:
            Circle()
                .fill(CallsLook.recording)
                .frame(width: 9, height: 9)
                .padding(3.5)
                .background(Circle().fill(CallsLook.recording.opacity(0.25)))
        case .later:
            Circle()
                .strokeBorder(Theme.textTertiary.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [2.2, 2.2]))
                .frame(width: 12, height: 12)
        }
    }

    /// The last lines written down, nobody's yet: the voices are told apart
    /// at the end.
    private var heard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Heard so far")
                .font(Theme.chrome(11.5, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(reading.lines.suffix(Self.lines).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 11) {
                    Circle()
                        .fill(Color.white.opacity(0.05))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().fill(Theme.textTertiary).frame(width: 2.5, height: 2.5))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(MeetingRecord.someone)
                                .font(Theme.chrome(12, .semibold))
                            Text(MeetingFiles.clock(line.start))
                                .font(Theme.chrome(11))
                                .monospacedDigit()
                        }
                        .foregroundStyle(Theme.textTertiary)
                        Text(line.text)
                            .font(Theme.chrome(13.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// A file held over the window, over the page, dimmed: what dropping it
/// does, the file and how long it is, and where a recording can come from.
private struct CallNotesDropOverlay: View {
    let dropping: CallNotesLibrary.Dropping

    var body: some View {
        let border = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let tile = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack {
            SettingsLook.ground.opacity(0.92)
            border
                .fill(CallsLook.recording.opacity(0.035))
                .overlay(border.strokeBorder(CallsLook.recording.opacity(0.7),
                                             style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])))
                .padding(18)
            VStack(spacing: 0) {
                tile
                    .fill(CallsLook.recording.opacity(0.16))
                    .background(tile.fill(SettingsLook.ground))
                    .frame(width: 72, height: 72)
                    .overlay {
                        Image(systemName: "waveform.badge.plus")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(CallsLook.recording)
                    }
                Text("Drop to get notes from this recording")
                    .font(Theme.chrome(17, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                if let name = dropping.fileName {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CallsLook.recording)
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let seconds = dropping.seconds {
                            Text("\u{00B7}")
                                .foregroundStyle(Theme.textTertiary)
                            Text(RecordingImport.length(seconds))
                                .monospacedDigit()
                        }
                    }
                    .font(Theme.chrome(12.5, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 27)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .background(Capsule().fill(SettingsLook.ground))
                    .padding(.top, 12)
                }
                Text("Voice Memos, WhatsApp voice notes, or any sound file. It stays on your Mac.")
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 44)
        }
        .allowsHitTesting(false)
    }
}

/// Files dropped on the notes window: a sound file is read into a meeting
/// of its own (`RecordingImporter`). The overlay shows while one is held
/// over the window, with its name and length once they are read. Refused
/// while a recording is being read.
private struct CallNotesDrop: DropDelegate {
    let library: CallNotesLibrary
    let reduceMotion: Bool

    func validateDrop(info: DropInfo) -> Bool {
        library.recordings != nil && library.reading == nil && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) {
            library.dropping = CallNotesLibrary.Dropping()
        }
        guard let provider = info.itemProviders(for: [.fileURL]).first else { return }
        let shown = library
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                guard shown.dropping != nil, RecordingImport.isSound(url) else { return }
                shown.dropping?.fileName = url.lastPathComponent
                let seconds = await RecordingImporter.length(of: url)
                guard shown.dropping?.fileName == url.lastPathComponent else { return }
                shown.dropping?.seconds = seconds
            }
        }
    }

    func dropExited(info: DropInfo) {
        withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) { library.dropping = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        library.dropping = nil
        guard validateDrop(info: info), let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        let target = library
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            // Any file: one that isn't sound is said so (`RecordingImport.unreadable`).
            Task { @MainActor in target.recordings?.drop(url) }
        }
        return true
    }
}

/// How a section's card is drawn, by its heading.
private struct CallNotesCardLook {
    enum Kind { case summary, yours, todos, list, loose }
    let kind: Kind
    let symbol: String?
    let tint: Color

    init(_ heading: String?) {
        switch heading {
        case nil: (kind, symbol, tint) = (.loose, nil, Theme.textSecondary)
        case MeetingFiles.summaryHeading?: (kind, symbol, tint) = (.summary, "sparkles", CallsLook.summaryText)
        case MeetingFiles.yourNotesHeading?: (kind, symbol, tint) = (.yours, "pencil", CallsLook.yours)
        case MeetingFiles.todosHeading?: (kind, symbol, tint) = (.todos, "checklist", CallsLook.todoText)
        case MeetingFiles.decisionsHeading?:
            (kind, symbol, tint) = (.list, "checkmark.seal.fill", CallsLook.decisions)
        case MeetingFiles.questionsHeading?:
            (kind, symbol, tint) = (.list, "questionmark.bubble.fill", CallsLook.questions)
        case MeetingFiles.keyPointsHeading?: (kind, symbol, tint) = (.list, "lightbulb.fill", CallsLook.keyPoints)
        // A heading the owner wrote in a text editor: a plain card.
        default: (kind, symbol, tint) = (.list, nil, Theme.textPrimary)
        }
    }
}

/// One section of the notes as a card: its heading with icon and count,
/// then its lines, a hairline between list lines.
private struct CallNotesCard: View {
    let call: CallNotesLibrary.Call
    let section: MeetingPage.Section
    let people: [CallPeople.Person]

    var body: some View {
        let look = CallNotesCardLook(section.heading)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let lines = section.lines
        VStack(alignment: .leading, spacing: 0) {
            if let heading = section.heading {
                head(heading, look: look)
                    .padding(.bottom, look.kind == .summary ? 7 : 4)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                draw(line, look: look)
                    .overlay(alignment: .top) {
                        if index > 0, Self.isItem(line), Self.isItem(lines[index - 1]) {
                            Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, look.kind == .summary ? 14 : (look.kind == .loose ? 0 : 12))
        .padding(.horizontal, look.kind == .summary ? 16 : (look.kind == .loose ? 2 : 14))
        .padding(.bottom, look.kind == .summary ? 15 : (look.kind == .loose ? 0 : 8))
        .background {
            switch look.kind {
            case .summary:
                shape.fill(LinearGradient(colors: [Theme.assistant.opacity(0.16), Theme.running.opacity(0.08)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(shape.strokeBorder(Theme.assistant.opacity(0.26), lineWidth: 1))
            case .yours:
                shape.fill(CallsLook.yours.opacity(0.045))
                    .overlay(shape.strokeBorder(CallsLook.yours.opacity(0.12), lineWidth: 1))
            case .todos, .list:
                shape.fill(Color.white.opacity(0.03))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.05), lineWidth: 1))
            case .loose:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func head(_ heading: String, look: CallNotesCardLook) -> some View {
        let count = section.lines.filter(Self.isItem).count
        return HStack(spacing: 7) {
            if let symbol = look.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(heading)
                .font(Theme.chrome(12, .bold))
            if look.kind != .summary, count > 0 {
                Text("\(count)")
                    .font(Theme.chrome(10.5, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.07)))
                    .padding(.leading, 2)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(look.tint)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func draw(_ line: MeetingPage.Placed, look: CallNotesCardLook) -> some View {
        switch line.block {
        case .paragraph(let text):
            Text(CallNotesItem.inline(text))
                .font(Theme.chrome(look.kind == .summary ? 14 : 13.5))
                .foregroundStyle(paragraphInk(look, yours: line.isYours))
                .lineSpacing(look.kind == .summary ? 4 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, look.kind == .summary ? 0 : 4)
        case .item(let text, let checked, let owner, let at):
            let item = CallNotesItem(text: text, checked: checked, owner: owner, at: at,
                                     look: look, yours: line.isYours, people: people)
            if let at {
                CallNotesJump(call: call, at: at) { item }
            } else {
                item
            }
        case .unwritten(let from, let to):
            CallNotesJump(call: call, at: from) {
                CallNotesUnwritten(stretch: MeetingNotes.Stretch(start: from, end: to))
            }
            .padding(.top, look.kind == .summary ? 10 : 4)
        case .heading(let text, _):
            // Only ever a section's own heading, drawn above; kept for a page
            // whose sections could not be told apart.
            Text(text)
                .font(Theme.chrome(12, .bold))
                .foregroundStyle(Theme.textPrimary)
        case .rule:
            EmptyView()
        }
    }

    private func paragraphInk(_ look: CallNotesCardLook, yours: Bool) -> Color {
        if yours { return Theme.textPrimary }
        switch look.kind {
        case .summary: return CallsLook.summaryBody
        case .loose: return Theme.textSecondary
        default: return CallsLook.noteText
        }
    }

    private static func isItem(_ line: MeetingPage.Placed) -> Bool {
        if case .item = line.block { return true }
        return false
    }
}

/// The closing line under the cards: how the notes were made, under a lock.
private struct CallNotesClosing: View {
    let lines: [MeetingPage.Placed]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if case .paragraph(let text) = line.block {
                        Text(CallNotesItem.inline(text))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(Theme.chrome(11.5))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }
}

/// A stretch of the call the model wrote no notes for, said plainly in
/// Airlock's grey. Tappable like any line with a time, since what is
/// missing is right there in the transcript.
private struct CallNotesUnwritten: View {
    let stretch: MeetingNotes.Stretch

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "text.badge.xmark")
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(stretch.sentence)
                .font(Theme.chrome(12.5).italic())
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One list line of the notes: its marker (a dot in the card's colour, an
/// empty circle for a to-do, a yellow bar for the person's own line), the
/// words, who it is for, and when it was said.
private struct CallNotesItem: View {
    let text: String
    let checked: Bool?
    let owner: String?
    let at: TimeInterval?
    let look: CallNotesCardLook
    let yours: Bool
    let people: [CallPeople.Person]

    /// Half the cap height of 13.5pt text: how far above the baseline a
    /// marker's middle sits, so it lines up with the first line.
    private nonisolated static let capMiddle: CGFloat = 4.8

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            marker
            Text(Self.inline(text))
                .font(Theme.chrome(13.5))
                .foregroundStyle(yours ? Theme.textPrimary : CallsLook.noteText)
                .strikethrough(checked == true, color: Theme.textTertiary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let owner {
                HStack(spacing: 5) {
                    CallPersonAvatar(name: owner, seat: CallPeople.seat(of: owner, in: people), size: 16)
                    Text(owner)
                        .font(Theme.chrome(11.5, .semibold))
                        .foregroundStyle(CallsLook.quietText)
                        .lineLimit(1)
                }
                .fixedSize()
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            if let at {
                CallNotesTimeChip(at: at)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var marker: some View {
        if yours {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(CallsLook.yours)
                .frame(width: 3, height: 16)
                .padding(.leading, 3)
                .padding(.trailing, 2)
                .alignmentGuide(.firstTextBaseline) { $0.height / 2 + Self.capMiddle }
                .accessibilityHidden(true)
        } else {
            switch checked {
            case nil:
                Circle()
                    .fill(look.tint)
                    .frame(width: 6, height: 6)
                    .padding(.horizontal, 4)
                    .alignmentGuide(.firstTextBaseline) { $0.height / 2 + Self.capMiddle }
                    .accessibilityHidden(true)
            case false?:
                Circle()
                    .strokeBorder(CallsLook.openBox, lineWidth: 1.5)
                    .frame(width: 15, height: 15)
                    .alignmentGuide(.firstTextBaseline) { $0.height / 2 + Self.capMiddle }
                    .accessibilityLabel("To-do")
            case true?:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.done)
                    .frame(width: 15, height: 15)
                    .alignmentGuide(.firstTextBaseline) { $0.height / 2 + Self.capMiddle }
                    .accessibilityLabel("Done")
            }
        }
    }

    /// Bold and italics inside a line; the words as written when that fails.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// When a line of notes was said, in Airlock's purple: "2:15".
private struct CallNotesTimeChip: View {
    let at: TimeInterval

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.quote")
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text(MeetingFiles.clock(at))
                .font(Theme.chrome(11, .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(CallsLook.saidText)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Theme.assistant.opacity(0.13)))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Said at \(MeetingFiles.clock(at))")
    }
}

/// A line of notes that says when it was said, made tappable: the pointer
/// becomes a hand, the line lights faintly under it, and a click (or the
/// accessibility action) opens the transcript at that moment.
private struct CallNotesJump<Label: View>: View {
    let call: CallNotesLibrary.Call
    let at: TimeInterval
    @ViewBuilder var label: Label
    @Environment(CallNotesLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        Button(action: jump) {
            // Not selectable: a click here means "go there".
            label.textSelection(.disabled)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.05 : 0))
                .padding(.horizontal, -8)
                .allowsHitTesting(false)
        }
        .onHover { inside in
            withAnimation(MotionEffect.pointer) { hovered = inside }
        }
        .clickable()
        .help("Show where this was said")
        .accessibilityHint("Shows where this was said, in the transcript")
        .accessibilityAction(named: "Show in transcript", jump)
    }

    private func jump() {
        library.showSaid(at: at, in: call, reduceMotion: reduceMotion)
    }
}

/// Each turn as the person's round letter in their colour, their name and
/// when, then what they said; the person's typed notes on paper yellow and
/// the pauses as a line across. A turn a mark reaches says "Marked"; the
/// turn a tapped line points to is lit in blue. While the call goes on, the
/// words being said follow in grey until they are a line.
private struct CallTranscript: View {
    let call: CallNotesLibrary.Call
    /// Being written down now: "just now" on the newest line, the words
    /// being said, and "Listening…" under them.
    let live: Bool
    @Environment(CallNotesLibrary.self) private var library

    var body: some View {
        let entries = MeetingTimeline.entries(of: call.record)
        let people = CallPeople.people(of: call.record)
        let hearing = live ? CallLive.speaking(library.live?.call.hearing ?? [:], paused: library.isPaused) : []
        if entries.isEmpty, hearing.isEmpty {
            CallNotesEmpty(title: "Nothing written down",
                           detail: call.record.endedAt == nil
                               ? "Words appear here as they are said."
                               : "No words were heard on this call.")
        } else {
            // Lazy: a long call has hundreds of turns, each name a button with
            // its own pop-up, and making them all at once held the window for
            // a second on every tab or call change.
            let newest = live ? entries.lastIndex(where: \.isSpeech) : nil
            let carried = hearing.first { CallLive.continues($0, after: entries, startedAt: call.record.startedAt) }
            let others = hearing.filter { $0 != carried }
            let headed = CallLive.headed(entries, hearing: others, in: call.record)
            // Asked once for the whole call: it reads every line, so asked
            // for each turn as it scrolled in, a long call stuttered.
            let nameable = CallNotesLibrary.canName(call.record)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    row(entry, index: index, people: people, newest: index == newest,
                        headed: headed.entries[index], nameable: nameable,
                        carryingOn: index == entries.count - 1 ? carried?.text : nil)
                        .id(index)
                }
                ForEach(Array(others.enumerated()), id: \.element.speaker) { index, heard in
                    hearingRow(heard, people: people, headed: headed.hearing[index])
                }
                if live {
                    CallLiveListening(paused: library.isPaused, size: 12.5)
                        .padding(.leading, 35)
                        .padding(.top, 10)
                }
            }
        }
    }

    /// Someone saying something that is not a line yet: as a turn, without
    /// the time, the words in grey as they come. Only the words when the
    /// line above is theirs.
    @ViewBuilder
    private func hearingRow(_ hearing: CallLive.Hearing, people: [CallPeople.Person], headed: Bool) -> some View {
        let name = call.record.label(for: hearing.speaker)
        let seat = CallPeople.seat(of: name, in: people)
        if headed {
            hearingTurn(hearing, name: name, seat: seat)
        } else {
            Text(hearing.text)
                .font(Theme.chrome(14))
                .foregroundStyle(LiveLook.hearing)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Self.underName)
                .padding(.bottom, 9)
                .accessibilityLabel("\(name): \(hearing.text)")
        }
    }

    /// Where the words under a name start: past the face (24) and its gap.
    private static let underName: CGFloat = 35

    private func hearingTurn(_ hearing: CallLive.Hearing, name: String, seat: CallPeople.Seat) -> some View {
        HStack(alignment: .top, spacing: 11) {
            CallPersonAvatar(name: name, seat: seat, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.chrome(12.5, .semibold))
                    .foregroundStyle(CallsLook.colour(for: seat))
                    .lineLimit(1)
                Text(hearing.text)
                    .font(Theme.chrome(14))
                    .foregroundStyle(LiveLook.hearing)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    /// `headed`: with the face, name and time; only the words when the line
    /// above is the same person's (`CallLive.headed`). `nameable`: a tap on
    /// the name says who it is (`CallNotesLibrary.canName`). `carryingOn`:
    /// what the same person is saying now, at the end of their turn.
    @ViewBuilder
    private func row(_ entry: MeetingTimeline.Entry, index: Int, people: [CallPeople.Person],
                     newest: Bool, headed: Bool, nameable: Bool, carryingOn: String? = nil) -> some View {
        switch entry {
        case .speech(let turn, let marked) where !headed:
            VStack(alignment: .leading, spacing: 4) {
                if marked { CallTranscriptMarked() }
                (Text(turn.text) + Text(carryingOn.map { " " + $0 } ?? "").foregroundStyle(LiveLook.hearing))
                    .font(Theme.chrome(14))
                    .foregroundStyle(CallsLook.spokenText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Self.underName)
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.running.opacity(isLit(index) ? 0.1 : 0))
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, -10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(call.record.label(for: turn)): \(turn.text)")
            .accessibilityValue(marked ? "Marked" : "")
        case .speech(let turn, let marked):
            let name = call.record.label(for: turn)
            let seat = CallPeople.seat(of: name, in: people)
            HStack(alignment: .top, spacing: 11) {
                CallPersonAvatar(name: name, seat: seat, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if nameable, let voice = call.record.voice(of: turn) {
                            CallTranscriptName(call: call, voice: voice, entry: index, name: name, seat: seat)
                        } else {
                            Text(name)
                                .font(Theme.chrome(12.5, .semibold))
                                .foregroundStyle(CallsLook.colour(for: seat))
                                .lineLimit(1)
                        }
                        if newest {
                            // "· just now" goes by itself once the line is a
                            // few seconds old, with no new line to redraw it.
                            TimelineView(.periodic(from: .now, by: 5)) { context in
                                time(turn, justNow: CallLive.isJustSaid(turn, in: call.record, now: context.date))
                            }
                        } else {
                            time(turn, justNow: false)
                        }
                        if marked { CallTranscriptMarked() }
                    }
                    (Text(turn.text) + Text(carryingOn.map { " " + $0 } ?? "").foregroundStyle(LiveLook.hearing))
                        .font(Theme.chrome(14))
                        .foregroundStyle(CallsLook.spokenText)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.running.opacity(isLit(index) ? 0.1 : 0))
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, -10)
            .accessibilityElement(children: .combine)
            .accessibilityValue(marked ? "Marked" : "")
        case .jot(let jot):
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CallsLook.yours)
                    .accessibilityHidden(true)
                Text("Your note")
                    .font(Theme.chrome(12, .semibold))
                    .foregroundStyle(CallsLook.yours)
                Text(MeetingFiles.clock(jot.at))
                    .font(Theme.chrome(11, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                Text(jot.text)
                    .font(Theme.chrome(13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(shape.fill(CallsLook.yours.opacity(0.07)))
            .overlay(shape.strokeBorder(CallsLook.yours.opacity(0.16), lineWidth: 1))
            .padding(.leading, 35)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        case .pause(let pause):
            divider("pause.fill", MeetingTimeline.pauseLabel(pause))
        case .language(let listening):
            // Quiet, like a pause: the lines below it say the rest.
            divider("globe", MeetingTimeline.languageLabel(listening))
        }
    }

    /// "12:38", and "12:38 · just now" on a line just said.
    private func time(_ turn: MeetingSegment, justNow: Bool) -> some View {
        Text(justNow ? "\(MeetingFiles.clock(turn.start)) · just now" : MeetingFiles.clock(turn.start))
            .font(Theme.chrome(11, .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.textTertiary)
    }

    /// A pause or a change of language: a word between two hairlines.
    private func divider(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
                Text(text)
                    .font(Theme.chrome(11.5, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.textTertiary)
            .fixedSize()
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func isLit(_ index: Int) -> Bool {
        guard let spotlight = library.spotlight else { return false }
        return spotlight.lit && spotlight.call == call.id && spotlight.entry == index
    }
}

/// "Marked", beside the time of a turn a mark reaches, in Airlock's purple.
/// The window beside the call has it too.
struct CallTranscriptMarked: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 8, weight: .semibold))
            Text("Marked")
                .font(Theme.chrome(10.5, .semibold))
        }
        .foregroundStyle(CallsLook.saidText)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule().fill(Theme.assistant.opacity(0.13)))
        .fixedSize()
        .accessibilityHidden(true)
    }
}

private struct CallNotesEmpty: View {
    let title: String
    let detail: String
    /// The character above the words, asleep: only for the window with no
    /// call in it at all. Over a call's notes still being written, the call
    /// is what is shown, and nothing there is empty for good.
    var bloub = false

    var body: some View {
        VStack(spacing: 6) {
            if bloub {
                // In the resting grey: nothing is happening here, and nothing
                // is wrong. Hidden from VoiceOver and still under Reduce
                // Motion by `BloubView` itself.
                BloubView(expression: .sleepy, motion: .breathing, tint: BloubTint.resting.color)
                    .frame(width: 34, height: 34)
            }
            Text(title)
                .font(Theme.chrome(14, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }
}
