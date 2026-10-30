import AppKit
import AirlockCore
import SwiftUI

/// The Calls page of the Airlock window: every call's notes and transcript,
/// newest first, read from the files in `~/Airlock/Meetings/`. "Show" after a
/// call opens it, and so do the menu bar's "Call Notes…" and Settings, on
/// the newest call.
///
/// The files stay the record. This only reads them, so an edit made in a
/// text editor shows here on the next look, and nothing here can lose one.
///
/// It was a window of its own until the owner asked for one Airlock window
/// (2026-10-16). It holds no window now: it chooses the call, then asks the
/// Airlock window to show the calls (`open`, set by `AirlockWindowController`).
@MainActor
final class CallsPage {
    let library: CallNotesLibrary
    /// Shows the Airlock window on the calls.
    var open: (@MainActor () -> Void)?
    /// Whether the calls are on screen right now.
    var isShowing: (@MainActor () -> Bool)?

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

    /// Where "Use" and "Leave it" on "Check these words" go: through the
    /// notes model, for the same reason (`CallNotesLibrary.checkWord`).
    func checkWords(_ check: @escaping @MainActor (URL, CallNotesLibrary.WordAnswer) -> Void) {
        library.checkWord = check
    }

    /// What the notes offer by plan, and where their buttons go.
    func offering(_ offering: CallNotesLibrary.Offering) {
        library.offering = offering
    }

    /// "Add a recording" at the foot of the list, files dropped on the
    /// window, and the page of a recording being read.
    func recordings(_ recordings: CallNotesLibrary.Recordings) {
        library.recordings = recordings
    }

    /// Notes finished while the calls are up: they appear without a click.
    func refreshIfOpen() {
        guard isShowing?() == true else { return }
        library.reload(selecting: nil)
    }

    private func present() {
        open?()
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
        /// Its place in `MeetingTimeline.shown(of:)`.
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
    /// Bumped by ⌘F while the calls show; the search field takes the cursor.
    var searchRequest = 0
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
    /// Where a word on "Check these words" is answered. Nil writes straight
    /// to the call's folder; the app sends it through the notes model.
    @ObservationIgnored var checkWord: (@MainActor (URL, WordAnswer) -> Void)?

    /// "Use Mapa" (`use`) or "Leave it" for one word on the list.
    struct WordAnswer: Equatable, Sendable {
        let best: String
        let heard: [String]
        let use: Bool
    }
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

    /// What the notes offer by plan (`CallNotesOffers`), and where their
    /// buttons go. Nil offers nothing but what the page itself says.
    @ObservationIgnored var offering: Offering?

    struct Offering {
        /// What to offer beside a call's notes, asked as the page is drawn.
        let offers: @MainActor (Call) -> CallNotesOffers
        /// The plans, on the website.
        let showPlans: @MainActor () -> Void
        /// "What each plan writes".
        let showComparison: @MainActor () -> Void
        /// A call's notes written again online.
        let redo: @MainActor (Call) async -> CloudNotesService.Redo
        /// The plan now, for what a redo that wasn't sent says.
        let plan: @MainActor () -> PlanSnapshot
    }

    /// The call whose notes are being written again now.
    private(set) var redoing: String?
    /// What came of the last redo that has something to say, under its
    /// button, for that call only.
    private(set) var redone: Redone?

    struct Redone: Equatable {
        let call: String
        let said: String
    }

    /// What to offer beside `call`'s notes. With no offering, only what the
    /// page needs to be drawn: which card stands in for notes there are none of.
    func offers(_ call: Call) -> CallNotesOffers {
        offering?.offers(call) ?? CallNotesOffers.of(call.record, page: call.page, plan: .free, online: .none)
    }

    /// "Redo with better notes": the plans, on a plan that doesn't write
    /// notes online; otherwise the notes written again online, the page
    /// read again once they are.
    func redo(_ call: Call) {
        guard let offering, redoing == nil else { return }
        switch offers(call).redo {
        case .opensPlans?:
            offering.showPlans()
        case .rewritesOnline?:
            rewrite(call, with: offering)
        case nil:
            break
        }
    }

    /// "Try again", on notes still waiting for the online notes service:
    /// asked now, not at the next try the wait has planned.
    func tryAgain(_ call: Call) {
        guard let offering, redoing == nil else { return }
        rewrite(call, with: offering)
    }

    private func rewrite(_ call: Call, with offering: Offering) {
        redoing = call.id
        redone = nil
        Task { @MainActor [weak self] in
            let result = await offering.redo(call)
            guard let self else { return }
            redoing = nil
            if let said = Self.said(result, plan: offering.plan()) {
                redone = Redone(call: call.id, said: said)
            }
            if result == .written { reload(selecting: nil) }
        }
    }

    /// What a redo says under its button, or nil once the new notes are on
    /// the page, which says it for itself.
    static func said(_ redo: CloudNotesService.Redo, plan: PlanSnapshot, locale: Locale = .current,
                     timeZone: TimeZone = .current) -> String? {
        func usedUp(_ until: Date) -> String {
            String(localized: "This month's online notes are used up.") + " "
                + String(localized: "Online notes are back on \(CloudNotesAllowance.day(until, locale: locale, timeZone: timeZone)).")
                + (plan.plan == .plus ? " " + String(localized: "Pro has twice as many.") : "")
        }
        let offline = String(localized: "This Mac is offline. Try again once it's back online.")
        switch redo {
        case .written: return nil
        case .allowanceUsed(let until): return usedUp(until)
        case .offline: return offline
        case .failed: return String(localized: "The online notes service didn't answer. Try again in a while.")
        case .notSent(let reason):
            switch reason {
            case .allowanceUsed(let until): return usedUp(until)
            case .offline: return offline
            case .settingOff: return String(localized: "Writing notes online is switched off in Settings.")
            case .tooShort: return String(localized: "Too little was said on this call for notes.")
            case .tooLong: return String(localized: "This call is too long to send for notes online.")
            case .notSubscribed: return String(localized: "Your plan writes notes on your Mac.")
            case .hiddenSwitchOff, .noToken, .noServer, .notEligible:
                return String(localized: "Online notes aren't available on this Mac right now.")
            }
        }
    }

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
    /// `MeetingTimeline.shown(of:)`.
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

    /// For the state gallery: these calls, read from no disk. `offers` is
    /// what every call's notes offer, as on a plan; `redone`, what the first
    /// call's last redo said. `spotlightAt`
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
         live: Bool = false, hearing: [CallLive.Hearing] = [], offers: CallNotesOffers? = nil,
         redone: String? = nil) {
        store = MeetingStore(root: URL(fileURLWithPath: "/var/empty"))
        if let offers {
            offering = Offering(offers: { _ in offers }, showPlans: {}, showComparison: {},
                                redo: { _ in .written }, plan: { .free })
        }
        if let redone, let call = calls.first { self.redone = Redone(call: call.id, said: redone) }
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
           let entry = MeetingTimeline.spoken(at: time, in: MeetingTimeline.shown(of: call.record)) {
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
        spotlight = MeetingTimeline.spoken(at: time, in: MeetingTimeline.shown(of: call.record))
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

    /// One word on "Check these words" answered: with "Use", `best` in
    /// place of every way it was heard, in the notes and the transcript;
    /// either way, the line comes off the list. Shown at once, then read
    /// again from the files.
    func check(_ call: Call, _ answer: WordAnswer) {
        let preview = store.root.path == "/var/empty"
        if let index = calls.firstIndex(where: { $0.id == call.id }), let page = call.page {
            var record = call.record
            if answer.use { MeetingWordCheck.use(answer.best, for: answer.heard, in: &record) }
            calls[index] = Call(folder: call.folder, record: record, page: MeetingWordCheck.answer(
                page, best: answer.best, heard: answer.heard, use: answer.use))
        }
        guard !preview else { return }
        if let checkWord {
            checkWord(call.folder, answer)
        } else {
            _ = try? store.checkWord(answer.best, heard: answer.heard, use: answer.use, in: call.folder)
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
        case .transcript: text = Self.markdownTranscript(of: call.record)
        }
        guard !text.isEmpty else { return }
        AirlockCopy.putMarkdown(text)
        let done = Copied(call: call.id, tab: tab)
        copied = done
        AccessibilityNotification.Announcement(String(localized: "Copied")).post()
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
    /// shows, typed notes, pauses and changes of language included, as
    /// Markdown, with the same times of day. Who spoke is in bold with the
    /// time beside it, and pauses and changes of language are in italics, as
    /// the tab draws them. What was said is escaped, so a star in it stays
    /// a star.
    static func markdownTranscript(of record: MeetingRecord, calendar: Calendar = .current) -> String {
        let time = { (seconds: TimeInterval) in CallsCard.time(seconds, into: record.startedAt, calendar: calendar) }
        let said = { (who: String, at: TimeInterval, text: String) in
            "**\(MarkdownCopy.escaped(who))** · \(time(at))\n\(MarkdownCopy.escaped(text))"
        }
        return MeetingTimeline.entries(of: record).map { entry in
            switch entry {
            case .speech(let turn, _):
                said(record.label(for: turn), turn.start, turn.text)
            case .jot(let jot):
                said(String(localized: "Your note"), jot.at, jot.text)
            case .pause(let pause):
                "_\(MeetingTimeline.pauseLabel(pause, clock: time))_"
            case .language(let listening):
                "_\(MeetingTimeline.languageLabel(listening, clock: time))_"
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
    /// (newest first): "Today", "Yesterday", "Fri 9 Oct". Each day once, so
    /// its start (`day`) names it in the list: two days can share a
    /// heading, a year apart, and two calls of one day can come apart.
    static func days(_ calls: [Call], now: Date = Date(),
                     calendar: Calendar = .current) -> [(day: Date, heading: String, calls: [Call])] {
        var days: [(start: Date, calls: [Call])] = []
        for call in calls {
            let start = calendar.startOfDay(for: call.record.startedAt)
            if let index = days.firstIndex(where: { $0.start == start }) {
                days[index].calls.append(call)
            } else {
                days.append((start, [call]))
            }
        }
        return days.map { ($0.start, CallsCard.dayHeading($0.start, now: now, calendar: calendar), $0.calls) }
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
            CallNotesSearchField(text: $library.search, focusRequest: library.searchRequest)
                .padding(.horizontal, 10)
                // Its middle level with the Settings search to its left
                // (`LookSidebar`: 10 above a 26-point field).
                .padding(.top, 9)
                .padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(CallNotesLibrary.days(library.shown), id: \.day) { day in
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
    /// Changes when ⌘F is pressed; the field takes the cursor.
    var focusRequest = 0
    @FocusState private var focused: Bool

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
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
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
        .onChange(of: focusRequest) { focused = true }
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
        guard let end = call.record.shownEnd else { return String(localized: "\(start) · now") }
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
                .followsNewest(said: following ? CallLive.spokenCount(MeetingTimeline.shown(of: call.record)) : 0,
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
                CallNotesTool(String(localized: "Name people"), symbol: "person.2", tone: .take, compact: nameCompact) {
                    withAnimation(Motion.open.animation(reduceMotion: reduceMotion)) { library.naming = call.id }
                }
            }
            CallNotesTool(String(localized: "Copy"), symbol: "doc.on.doc", compact: compact,
                          confirmation: String(localized: "Copied"), confirmed: library.justCopied(call)) { library.copy(call) }
            if live, let open = library.live?.openWindow {
                CallNotesTool(String(localized: "Open in a window"), symbol: "sidebar.right", tone: .live, compact: compact) { open() }
            }
            CallNotesTool(String(localized: "Show in Finder"), symbol: "folder", compact: compact) { library.reveal(call) }
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
                label("clock", record.shownEnd.map { CallsCard.length(from: record.startedAt, to: $0) } ?? String(localized: "now"))
            }
            if record.recording != nil {
                label("waveform", String(localized: "From a recording"))
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

    private func item(_ title: LocalizedStringKey, _ symbol: String, _ value: CallNotesLibrary.Tab) -> some View {
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
    @Environment(CallNotesLibrary.self) private var library
    let call: CallNotesLibrary.Call

    var body: some View {
        if let page = call.page {
            let placed = MeetingPage.placed(MeetingPage.body(of: page, header: MeetingFiles.header(of: call.record)))
            let page = MeetingPage.sections(placed)
            // The lines under the date that say how the notes came to be
            // are drawn as notices, not as text.
            let split = CallNotesNotice.split(page.sections)
            let offers = library.offers(call)
            let people = CallPeople.people(of: call.record)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(split.notices.enumerated()), id: \.offset) { _, notice in
                    CallNotesNoticeBanner(call: call, notice: notice, offers: offers)
                }
                if let empty = offers.empty {
                    CallNotesNoModel(call: call, empty: empty, offers: offers)
                }
                ForEach(Array(MeetingPage.cards(split.sections).enumerated()), id: \.offset) { _, card in
                    switch card {
                    case .section(let section):
                        CallNotesCard(call: call, section: section, people: people)
                    case .topics(let head, let topics):
                        // A call of its own folds its own way.
                        CallNotesTopics(call: call, head: head, topics: topics)
                            .id(call.id)
                    }
                }
                // A page the Mac had no model for says it all in its card.
                if offers.empty == nil, !page.closing.isEmpty {
                    CallNotesClosing(call: call, lines: page.closing, offers: offers)
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
                Text(reading.stopping ? String(localized: "Stopping\u{2026}") : progress.timeLeftSentence + " "
                     + String(localized: "You can close this window: Airlock carries on, and the notch shows a tick when the notes are ready."))
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
                            Text(reading.startedAt.map { CallsCard.time(line.start, into: $0) }
                                 ?? MeetingFiles.clock(line.start))
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
                Text("Voice Memos, WhatsApp voice notes, or any sound file. The recording stays on your Mac.")
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
    enum Kind { case summary, yours, todos, words, list, loose }
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
        case MeetingFiles.topicsHeading?: (kind, symbol, tint) = (.list, "list.number", CallsLook.topics)
        case MeetingFiles.wordsHeading?: (kind, symbol, tint) = (.words, "text.magnifyingglass", CallsLook.words)
        // A heading the owner wrote in a text editor: a plain card.
        default: (kind, symbol, tint) = (.list, nil, Theme.textPrimary)
        }
    }
}

/// One section of the notes as a card: its heading with icon and count,
/// then its lines, a hairline between list lines. Without a call (the
/// example in "What each plan writes") the lines say no time and go nowhere.
struct CallNotesCard: View {
    let call: CallNotesLibrary.Call?
    let section: MeetingPage.Section
    let people: [CallPeople.Person]

    var body: some View {
        let look = CallNotesCardLook(section.heading)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let lines = section.lines
        VStack(alignment: .leading, spacing: 0) {
            if let heading = section.heading {
                CallNotesCardHead(heading: heading, count: lines.filter(Self.isItem).count, look: look)
                    .padding(.bottom, look.kind == .summary ? 7 : 4)
            }
            if look.kind == .todos, let groups = Self.byPerson(lines) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    CallNotesOwnerHead(owner: group.owner, count: group.lines.count, people: people)
                    list(group.lines, look: look, grouped: true)
                }
            } else {
                list(lines, look: look)
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
            case .words:
                shape.fill(CallsLook.words.opacity(0.05))
                    .overlay(shape.strokeBorder(CallsLook.words.opacity(0.16), lineWidth: 1))
            case .loose:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Lines one under the other, a hairline between list lines.
    private func list(_ lines: [MeetingPage.Placed], look: CallNotesCardLook, grouped: Bool = false) -> some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            draw(line, look: look, grouped: grouped)
                .overlay(alignment: .top) {
                    if index > 0, Self.isItem(line), Self.isItem(lines[index - 1]) {
                        Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1)
                    }
                }
        }
    }

    /// The to-dos person by person (`MeetingOwners`): you, each person,
    /// everyone, then those with no name. Nil when no to-do names anyone,
    /// which draws the plain list.
    static func byPerson(_ lines: [MeetingPage.Placed]) -> [(owner: String?, lines: [MeetingPage.Placed])]? {
        let groups = MeetingOwners.grouped(lines) { line -> String? in
            if case .item(_, _, let owner, _) = line.block { return owner }
            return nil
        }
        guard groups.contains(where: { $0.owner != nil }) else { return nil }
        return groups.map { ($0.owner, $0.items) }
    }

    @ViewBuilder
    private func draw(_ line: MeetingPage.Placed, look: CallNotesCardLook, grouped: Bool) -> some View {
        if look.kind == .words, case .item(let text, _, _, let at) = line.block, let word = MeetingPage.word(text) {
            let said = call.flatMap { call in at.map { CallsCard.time($0, into: call.record.startedAt) } }
            CallNotesWordRow(call: call, best: word.best, heard: word.heard, at: at, said: said)
        } else {
            draw(line, look: look, shared: grouped)
        }
    }
    @ViewBuilder
    private func draw(_ line: MeetingPage.Placed, look: CallNotesCardLook, shared: Bool) -> some View {
        switch line.block {
        case .paragraph(let text):
            Text(CallNotesItem.inline(MeetingNotesShown.line(text)))
                .font(Theme.chrome(look.kind == .summary ? 14 : 13.5))
                .foregroundStyle(paragraphInk(look, yours: line.isYours))
                .lineSpacing(look.kind == .summary ? 4 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, look.kind == .summary ? 0 : 4)
        case .item(let text, let checked, let owner, let at):
            let said = call.flatMap { call in at.map { CallsCard.time($0, into: call.record.startedAt) } }
            // Under its person's name, a to-do only says who else it is for;
            // an open question says what it came up in.
            let question = section.heading == MeetingFiles.questionsHeading ? MeetingPage.question(text) : nil
            let others = shared ? MeetingOwners.others(owner) : []
            let detail = question?.context ?? (others.isEmpty ? nil : String(localized: "with \(others.map(MeetingRecord.shownLabel).joined(separator: ", "))"))
            let item = CallNotesItem(text: question?.text ?? text, checked: checked, owner: shared ? nil : owner,
                                     said: said, look: look, yours: line.isYours, people: people, detail: detail)
            if let at, let call {
                CallNotesJump(call: call, at: at) { item }
            } else {
                item
            }
        case .unwritten(let from, let to):
            Group {
                if let call {
                    CallNotesJump(call: call, at: from) {
                        CallNotesUnwritten(stretch: MeetingNotes.Stretch(start: from, end: to),
                                           start: call.record.startedAt)
                    }
                } else {
                    CallNotesUnwritten(stretch: MeetingNotes.Stretch(start: from, end: to))
                }
            }
            .padding(.top, look.kind == .summary ? 10 : 4)
        case .heading(let text, _):
            // Only ever a section's own heading, drawn above; kept for a page
            // whose sections could not be told apart.
            Text(MeetingNotesShown.heading(text))
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

/// A card's heading: its icon and name in the card's colour, and how many
/// lines it has.
private struct CallNotesCardHead: View {
    let heading: String
    let count: Int
    let look: CallNotesCardLook

    var body: some View {
        HStack(spacing: 7) {
            if let symbol = look.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(MeetingNotesShown.heading(heading))
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
}

/// Whose to-dos follow, in the to-dos card: their face and name, or
/// "Everyone", or "Not assigned" for those with no name on them.
private struct CallNotesOwnerHead: View {
    let owner: String?
    let count: Int
    let people: [CallPeople.Person]

    var body: some View {
        HStack(spacing: 7) {
            if let owner, !MeetingOwners.isEveryone(owner) {
                CallPersonAvatar(name: owner, seat: CallPeople.seat(of: owner, in: people), size: 16)
            } else {
                Image(systemName: owner == nil ? "questionmark.circle" : "person.3.fill")
                    .font(.system(size: owner == nil ? 12 : 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            Text(owner.map(MeetingRecord.shownLabel) ?? String(localized: "Not assigned"))
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(CallsLook.quietText)
            Text("\(count)")
                .font(Theme.chrome(10.5, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.top, 8)
        .padding(.bottom, 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A word the transcript may have heard wrong: what the notes took it to
/// be, how it was heard, when, and "Use" or "Leave it".
private struct CallNotesWordRow: View {
    let call: CallNotesLibrary.Call?
    let best: String
    let heard: [String]
    let at: TimeInterval?
    let said: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(words)
                    .font(Theme.chrome(13.5))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let said, let at, let call {
                    CallNotesJump(call: call, at: at) { CallNotesTimeChip(time: said) }
                } else if let said {
                    CallNotesTimeChip(time: said)
                }
            }
            if let call {
                CallNotesWordButtons(call: call, best: best, heard: heard)
            }
        }
        .padding(.vertical, 7)
    }

    /// "Mapa  heard as “napa”, “mapá”", the word in bold.
    private var words: AttributedString {
        var best = AttributedString(best)
        best.font = Theme.chrome(13.5, .semibold)
        best.foregroundColor = Theme.textPrimary
        var rest = AttributedString("  \(MeetingPage.heardAs) " + heard.map { "“\($0)”" }.joined(separator: ", "))
        rest.foregroundColor = Theme.textSecondary
        return best + rest
    }
}

/// "Use Mapa" and "Leave it", for a call the window shows.
private struct CallNotesWordButtons: View {
    @Environment(CallNotesLibrary.self) private var library
    let call: CallNotesLibrary.Call
    let best: String
    let heard: [String]

    var body: some View {
        HStack(spacing: 8) {
            CallNotesOfferButton("Use “\(best)”", tone: .light) {
                library.check(call, .init(best: best, heard: heard, use: true))
            }
            .help("Write “\(best)” everywhere it was heard, in the notes and the transcript")
            CallNotesOfferButton("Leave it") {
                library.check(call, .init(best: best, heard: heard, use: false))
            }
            .help("Take it off this list and change nothing")
        }
    }
}

/// The topics of notes written online, in one card: each numbered, with
/// when it came up and what came of it, its points folded under it.
struct CallNotesTopics: View {
    let call: CallNotesLibrary.Call?
    let head: MeetingPage.Section
    let topics: [MeetingPage.Section]
    @State private var open: Set<Int> = []

    var body: some View {
        let look = CallNotesCardLook(MeetingFiles.topicsHeading)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let all = Set(topics.indices)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                CallNotesCardHead(heading: head.heading ?? MeetingFiles.topicsHeading, count: topics.count, look: look)
                Spacer(minLength: 8)
                if topics.count > 1 {
                    Button(open == all ? "Fold all" : "Open all") {
                        withAnimation(MotionEffect.pointer) { open = open == all ? [] : all }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.chrome(11.5, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .clickable()
                }
            }
            .padding(.bottom, 4)
            // Anything the person wrote under "Topics" itself.
            ForEach(Array(head.lines.enumerated()), id: \.offset) { _, line in
                if case .paragraph(let text) = line.block {
                    Text(CallNotesItem.inline(text))
                        .font(Theme.chrome(13.5))
                        .foregroundStyle(CallsLook.noteText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                }
            }
            ForEach(Array(topics.enumerated()), id: \.offset) { index, topic in
                CallNotesTopicRow(call: call, section: topic, place: index + 1, open: Binding(
                    get: { open.contains(index) },
                    set: { isOpen in
                        if isOpen { open.insert(index) } else { open.remove(index) }
                    }))
                .overlay(alignment: .top) {
                    if index > 0 { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .background {
            shape.fill(Color.white.opacity(0.03))
                .overlay(shape.strokeBorder(Color.white.opacity(0.05), lineWidth: 1))
        }
        .accessibilityElement(children: .contain)
    }
}

/// One topic: its number, its title and when it came up, a seal with how
/// many of its points were agreed, its gist, and its points when open. The
/// title opens and closes it; the time goes to the transcript.
private struct CallNotesTopicRow: View {
    let call: CallNotesLibrary.Call?
    let section: MeetingPage.Section
    /// Its place in the card, for a heading that has no number.
    let place: Int
    @Binding var open: Bool

    var body: some View {
        let topic = MeetingPage.topic(section.heading ?? "")
        let points = section.lines.filter { if case .item = $0.block { true } else { false } }
        let paragraphs = section.lines.compactMap { line -> String? in
            if case .paragraph(let text) = line.block { return text }
            return nil
        }
        let decided = points.filter { line in
            if case .item(let text, _, _, _) = line.block { return MeetingPage.point(text).decided }
            return false
        }.count
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(action: toggle) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(topic?.number ?? place)")
                            .font(Theme.chrome(11, .bold))
                            .monospacedDigit()
                            .foregroundStyle(CallsLook.topics)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(CallsLook.topics.opacity(0.14)))
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                        Text(topic?.title ?? section.heading ?? "")
                            .font(Theme.chrome(13.5, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if decided > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("\(decided)")
                                    .font(Theme.chrome(11, .semibold))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(CallsLook.decisions)
                            .fixedSize()
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(decided == 1 ? "1 decision" : "\(decided) decisions")
                        }
                        if !points.isEmpty {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .rotationEffect(.degrees(open ? 90 : 0))
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()
                .accessibilityHint(points.isEmpty ? "" : (open ? "Hides its points" : "Shows its points"))
                if let at = topic?.at {
                    let said = call.map { CallsCard.time(at, into: $0.record.startedAt) }
                        ?? MeetingFiles.clock(at)
                    if let call {
                        CallNotesJump(call: call, at: at) { CallNotesTimeChip(time: said) }
                    } else {
                        CallNotesTimeChip(time: said)
                    }
                }
            }
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, text in
                Text(CallNotesItem.inline(text))
                    .font(Theme.chrome(13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
            }
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, line in
                        point(line)
                    }
                }
                .padding(.leading, 30)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func point(_ line: MeetingPage.Placed) -> some View {
        if case .item(let text, _, _, let at) = line.block {
            let point = MeetingPage.point(text)
            let words = point.lead.map { "**\($0):** \(point.rest)" } ?? point.rest
            let said = call.flatMap { call in at.map { CallsCard.time($0, into: call.record.startedAt) } }
            let item = CallNotesItem(text: words, checked: nil, owner: nil, said: said,
                                     look: CallNotesCardLook(MeetingFiles.topicsHeading), yours: false,
                                     people: [], decided: point.decided)
            if let at, let call {
                CallNotesJump(call: call, at: at) { item }
            } else {
                item
            }
        }
    }

    private func toggle() {
        withAnimation(MotionEffect.pointer) { open.toggle() }
    }
}

/// The closing line under the cards: how the notes were made, under a lock,
/// or a chip for notes the Mac wrote. Beside those, on a plan that doesn't
/// write notes online, "See what Plus writes"; under them, "Redo with
/// better notes" (`CallNotesOffers`).
private struct CallNotesClosing: View {
    @Environment(CallNotesLibrary.self) private var library
    let call: CallNotesLibrary.Call
    let lines: [MeetingPage.Placed]
    let offers: CallNotesOffers

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: Self.byTheMac(lines) ? "cpu" : "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        if case .paragraph(let text) = line.block {
                            Group {
                                if index == 0, offers.seePlus {
                                    Text(CallNotesItem.inline(MeetingNotesShown.line(text))) + Text("  ") + seePlus
                                } else {
                                    Text(CallNotesItem.inline(MeetingNotesShown.line(text)))
                                }
                            }
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .font(Theme.chrome(11.5))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard url == Self.seePlusLink else { return .systemAction }
                library.offering?.showComparison()
                return .handled
            })
            if offers.redo != nil {
                CallNotesRedoButton(call: call, offers: offers)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }

    /// "See what Plus writes ›", a link inside the line so it wraps with it.
    private var seePlus: Text {
        var link = AttributedString(localized: "See what Plus writes ›")
        link.link = Self.seePlusLink
        link.foregroundColor = PlanTag.plusText
        link.font = Theme.chrome(11.5, .semibold)
        return Text(link)
    }

    private static let seePlusLink = URL(string: "airlock-notes://see-what-plus-writes")!

    /// Whether the foot says the Mac wrote them.
    static func byTheMac(_ lines: [MeetingPage.Placed]) -> Bool {
        lines.contains { line in
            guard case .paragraph(let text) = line.block else { return false }
            let plain = CallNotesNotice.plain(text)
            return plain.hasPrefix(MeetingFiles.basicModelFooter) || plain.hasPrefix(MeetingFiles.serviceDownFooter)
        }
    }
}

/// "Redo with better notes": a Plus tag where it opens the plans, the
/// words "Writing them again…" while it is asked, and what came of it below.
private struct CallNotesRedoButton: View {
    @Environment(CallNotesLibrary.self) private var library
    let call: CallNotesLibrary.Call
    let offers: CallNotesOffers
    var title = String(localized: "Redo with better notes")

    var body: some View {
        let busy = library.redoing == call.id
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                library.redo(call)
            } label: {
                HStack(spacing: 7) {
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    Text(busy ? String(localized: "Writing them again…") : title)
                        .font(Theme.chrome(12, .medium))
                    if offers.redoTagged { PlanTag(.plus) }
                }
                .foregroundStyle(CallsLook.quietText)
                .padding(.leading, 11)
                .padding(.trailing, offers.redoTagged ? 6 : 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.04)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(library.redoing != nil)
            .help(offers.redoTagged ? "Plus writes better notes online."
                                    : "Writes these notes again online. Counts toward this month's online notes.")
            if let redone = library.redone, redone.call == call.id {
                Text(redone.said)
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A line under the date that says how the notes came to be, as a notice:
/// how much of the call they cover, why the Mac wrote them, why there are
/// none yet, with what can be done about it.
private struct CallNotesNoticeBanner: View {
    @Environment(CallNotesLibrary.self) private var library
    let call: CallNotesLibrary.Call
    let notice: CallNotesNotice
    let offers: CallNotesOffers

    var body: some View {
        if let look {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: look.symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(look.warning ? Theme.needs : Theme.textSecondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(look.text)
                    .font(Theme.chrome(12.5))
                    .foregroundStyle(look.warning ? CallsLook.todoText : Theme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(shape.fill(look.warning ? Theme.needs.opacity(0.07) : Color.white.opacity(0.025)))
            .overlay(shape.strokeBorder(look.warning ? Theme.needs.opacity(0.3) : Color.white.opacity(0.08),
                                        lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
    }

    private struct Look {
        let symbol: String
        let text: AttributedString
        var warning = false
    }

    private var look: Look? {
        switch notice {
        case .cover(let text):
            var said = Self.bold(MeetingNotesShown.line(text), from: ["first ", "primer"], to: [" of a", " de una", "."],
                                 keepingStart: true)
            if let locked = lockedLine { said += AttributedString(" ") + locked }
            return Look(symbol: "clock", text: said)
        case .allowanceUsed(let text):
            return Look(symbol: "cloud", text: Self.bold(MeetingNotesShown.line(text), from: ["back on ", "vuelven el "],
                                                         to: ["."]))
        case .waitingForAllowance(let text):
            return Look(symbol: "clock.badge.exclamationmark",
                        text: Self.bold(MeetingNotesShown.afterNoNotesYet(text), from: ["written on ", "escribirán el "],
                                        to: ["."]),
                        warning: true)
        case .waitingForService(let text), .waitingForNetwork(let text):
            return Look(symbol: "wifi.slash", text: AttributedString(MeetingNotesShown.afterNoNotesYet(text)))
        case .improvedOnline(let text):
            return Look(symbol: "wifi.slash", text: AttributedString(MeetingNotesShown.line(text)))
        case .noModel:
            return nil
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch notice {
        case .allowanceUsed:
            if offers.seePro { seePro }
        case .waitingForAllowance:
            HStack(spacing: 10) {
                if offers.seePro { seePro }
                CallNotesOfferButton("Read the transcript") { library.tab = .transcript }
            }
        case .waitingForService:
            if library.offering != nil {
                if library.redoing == call.id {
                    ProgressView().controlSize(.small)
                } else {
                    CallNotesOfferButton("Try again") { library.tryAgain(call) }
                        .disabled(library.redoing != nil)
                }
            }
        case .cover:
            if let part = call.record.locked, part.removedAt == nil, library.offering != nil {
                seePlan("See Plus")
            }
        case .waitingForNetwork, .improvedOnline, .noModel:
            EmptyView()
        }
    }

    /// After the cover line of a Free call heard past its limit: until when
    /// the rest is kept, or that it was removed, with the day in bold.
    private var lockedLine: AttributedString? {
        guard let part = call.record.locked, let minutes = call.record.lockedMinutes else { return nil }
        if let removed = part.removedAt {
            return Self.bold(LockedCallWords.removed(minutes: minutes, on: removed),
                             from: ["removed on ", "eliminaron el ", "eliminó el "], to: ["."])
        }
        return Self.bold(LockedCallWords.kept(minutes: minutes, until: part.keptUntil), from: ["until ", "hasta el "], to: ["."])
    }

    private var seePro: some View { seePlan("See Pro") }

    private func seePlan(_ said: LocalizedStringKey) -> some View {
        Button {
            library.offering?.showPlans()
        } label: {
            HStack(spacing: 3) {
                Text(said)
                Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold))
            }
            .font(Theme.chrome(12.5, .semibold))
            .foregroundStyle(PlanTag.plusText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// `text` with the words after the first of `starts` it holds, up to the
    /// first of `ends`, in bold and in the brighter grey: the minutes, the
    /// day. The starts are the same words in each language the app speaks.
    static func bold(_ text: String, from starts: [String], to ends: [String],
                     keepingStart: Bool = false) -> AttributedString {
        var said = AttributedString(text)
        guard let opening = starts.lazy.compactMap({ said.range(of: $0) }).first else { return said }
        let rest = said[opening.upperBound...]
        guard let closing = ends.compactMap({ rest.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound })
        else { return said }
        let from = keepingStart ? opening.lowerBound : opening.upperBound
        said[from..<closing.lowerBound].font = Theme.chrome(12.5, .semibold)
        said[from..<closing.lowerBound].foregroundColor = Theme.textPrimary
        return said
    }
}

/// The card that stands in for notes the Mac had no model to write: turn
/// Apple Intelligence on, or, on a Mac that can't run it, what Plus does.
private struct CallNotesNoModel: View {
    @Environment(CallNotesLibrary.self) private var library
    let call: CallNotesLibrary.Call
    let empty: CallNotesOffers.Empty
    let offers: CallNotesOffers

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(empty == .turnOnAppleIntelligence ? CallsLook.saidText : Theme.textSecondary)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(empty == .turnOnAppleIntelligence ? Theme.assistant.opacity(0.14) : Color.white.opacity(0.06)))
                .padding(.bottom, 20)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.chrome(16, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            Text(detail)
                .font(Theme.chrome(12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.bottom, 18)
            buttons
            if empty == .cantWriteNotes, offers.seePlus {
                Text("Your transcripts are always kept, on every plan.")
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
        .padding(.bottom, 24)
        .padding(.horizontal, 24)
    }

    private var title: String {
        switch empty {
        case .turnOnAppleIntelligence: String(localized: "Turn on Apple Intelligence to get notes and to-dos")
        case .cantWriteNotes: String(localized: "This Mac can't write notes itself")
        }
    }

    private var detail: String {
        switch empty {
        case .turnOnAppleIntelligence:
            String(localized: "Airlock writes call notes with Apple Intelligence, and it's switched off. The transcript of this call is ready.")
        case .cantWriteNotes where offers.seePlus:
            String(localized: "Apple Intelligence isn't available on this Mac, for example because of its region or language. Plus writes notes online, on any Mac. The transcript is ready.")
        case .cantWriteNotes:
            String(localized: "Apple Intelligence isn't available on this Mac, for example because of its region or language. The transcript is ready.")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                switch empty {
                case .turnOnAppleIntelligence:
                    CallNotesOfferButton("Open System Settings", tone: .light) {
                        if let url = AppleIntelligenceSetup.Button.openSystemSettings.url {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    CallNotesOfferButton("Read the transcript") { library.tab = .transcript }
                case .cantWriteNotes:
                    if offers.seePlus, let offering = library.offering {
                        CallNotesOfferButton("See what Plus writes") { offering.showComparison() }
                        CallNotesOfferButton("See Plus", tone: .plus) { offering.showPlans() }
                    } else {
                        CallNotesOfferButton("Read the transcript") { library.tab = .transcript }
                    }
                }
            }
            // A plan that writes notes online can have this call's now.
            if offers.redo == .rewritesOnline {
                CallNotesRedoButton(call: call, offers: offers, title: String(localized: "Write the notes online"))
            }
        }
    }
}

/// A button on the notes window's notices and cards: an outline, a light
/// fill for the one thing to do, or Plus's blue.
struct CallNotesOfferButton: View {
    enum Tone { case outline, light, plus, pro }

    let title: LocalizedStringKey
    let tone: Tone
    let action: () -> Void

    @State private var hovered = false

    init(_ title: LocalizedStringKey, tone: Tone = .outline, action: @escaping () -> Void) {
        self.title = title
        self.tone = tone
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.chrome(12.5, .medium))
                .foregroundStyle(ink)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovered = $0 }
    }

    private var ink: Color {
        switch tone {
        case .outline: CallsLook.quietText
        case .light: Color.black.opacity(0.85)
        case .plus: .white
        case .pro: PlanTag.pro
        }
    }

    private var fill: Color {
        switch tone {
        case .outline: Color.white.opacity(hovered ? 0.08 : 0.03)
        case .light: Color.white.opacity(hovered ? 1 : 0.92)
        case .plus: PlanTag.plus.opacity(hovered ? 1 : 0.9)
        case .pro: PlanTag.pro.opacity(hovered ? 0.14 : 0.06)
        }
    }

    private var stroke: Color {
        switch tone {
        case .outline: Color.white.opacity(0.14)
        case .pro: PlanTag.pro.opacity(0.5)
        case .light, .plus: .clear
        }
    }
}

/// A stretch of the call the model wrote no notes for, said plainly in
/// Airlock's grey. Tappable like any line with a time, since what is
/// missing is right there in the transcript.
private struct CallNotesUnwritten: View {
    let stretch: MeetingNotes.Stretch
    /// When the call began, to say the stretch in times of day; nil says
    /// it as the page does.
    var start: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "text.badge.xmark")
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(MeetingNotesShown.unwritten(stretch, clock: start.map { start in { CallsCard.time($0, into: start) } }
                                                ?? MeetingFiles.clock))
                .font(Theme.chrome(12.5).italic())
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One list line of the notes: its marker (a dot in the card's colour, an
/// empty circle for a to-do, a yellow bar for the person's own line, a green
/// seal for a topic's point that was agreed), the words, who it is for, and
/// when it was said ("20:58"). Under the words, in grey, what an open
/// question came up in or who else a to-do is for.
private struct CallNotesItem: View {
    let text: String
    let checked: Bool?
    let owner: String?
    let said: String?
    let look: CallNotesCardLook
    let yours: Bool
    let people: [CallPeople.Person]
    var detail: String?
    var decided = false

    /// Half the cap height of 13.5pt text: how far above the baseline a
    /// marker's middle sits, so it lines up with the first line.
    private nonisolated static let capMiddle: CGFloat = 4.8

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            marker
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.inline(text))
                    .font(Theme.chrome(13.5))
                    .foregroundStyle(yours ? Theme.textPrimary : CallsLook.noteText)
                    .strikethrough(checked == true, color: Theme.textTertiary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(Self.inline(detail))
                        .font(Theme.chrome(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let owner {
                HStack(spacing: 5) {
                    CallPersonAvatar(name: owner, seat: CallPeople.seat(of: owner, in: people), size: 16)
                    Text(MeetingRecord.shownLabel(owner))
                        .font(Theme.chrome(11.5, .semibold))
                        .foregroundStyle(CallsLook.quietText)
                        .lineLimit(1)
                }
                .fixedSize()
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            if let said {
                CallNotesTimeChip(time: said)
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
        } else if decided {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CallsLook.decisions)
                .frame(width: 14, height: 14)
                .alignmentGuide(.firstTextBaseline) { $0.height / 2 + Self.capMiddle }
                .accessibilityLabel("Decided")
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

/// When a line of notes was said, in Airlock's purple: "20:58".
private struct CallNotesTimeChip: View {
    let time: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.quote")
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text(time)
                .font(Theme.chrome(11, .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(CallsLook.saidText)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Theme.assistant.opacity(0.13)))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Said at \(time)")
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
        let entries = MeetingTimeline.shown(of: call.record)
        let people = CallPeople.people(of: call.record)
        let hearing = live ? CallLive.speaking(library.live?.call.hearing ?? [:], paused: library.isPaused,
                                                  in: call.record) : []
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
            let offering = library.offering
            let voicesHint = offering.flatMap { offering in
                FreeVoicesHint.shows(for: call.record, plan: offering.plan())
                    ? Self.firstThem(entries, headed: headed.entries) : nil
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    row(entry, index: index, people: people, newest: index == newest,
                        headed: headed.entries[index], nameable: nameable,
                        carryingOn: index == entries.count - 1 ? carried?.text : nil)
                        .id(index)
                    if index == voicesHint, let offering {
                        CallTranscriptVoicesHint(who: FreeVoicesHint.who(of: call.record),
                                                 showPlans: offering.showPlans)
                    }
                }
                ForEach(Array(others.enumerated()), id: \.element.speaker) { index, heard in
                    hearingRow(heard, people: people, headed: headed.hearing[index])
                }
                if !live, let part = call.record.locked, part.removedAt == nil,
                   let minutes = call.record.lockedMinutes, let endedAt = call.record.endedAt {
                    CallTranscriptWaiting(minutes: minutes,
                                          from: call.record.startedAt.addingTimeInterval(part.from),
                                          to: endedAt, until: part.keptUntil,
                                          showPlans: offering?.showPlans)
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

    /// The last line of the first "Them" turn, where the box saying Plus
    /// tells voices apart goes: once a call, not under every line.
    private static func firstThem(_ entries: [MeetingTimeline.Entry], headed: [Bool]) -> Int? {
        func them(_ index: Int) -> Bool {
            if case .speech(let turn, _) = entries[index] { turn.speaker == .them } else { false }
        }
        guard var last = entries.indices.first(where: them) else { return nil }
        while last + 1 < entries.count, !headed[last + 1], them(last + 1) { last += 1 }
        return last
    }

    private func hearingTurn(_ hearing: CallLive.Hearing, name: String, seat: CallPeople.Seat) -> some View {
        HStack(alignment: .top, spacing: 11) {
            CallPersonAvatar(name: name, seat: seat, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(MeetingRecord.shownLabel(name))
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
            .accessibilityLabel("\(MeetingRecord.shownLabel(call.record.label(for: turn))): \(turn.text)")
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
                            Text(MeetingRecord.shownLabel(name))
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
                Text(clock(jot.at))
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
            divider("pause.fill", MeetingTimeline.pauseLabel(pause, clock: clock))
        case .language(let listening):
            // Quiet, like a pause: the lines below it say the rest.
            divider("globe", MeetingTimeline.languageLabel(listening, clock: clock))
        }
    }

    /// When a moment of the call was, as the clock said it: "20:58".
    private func clock(_ seconds: TimeInterval) -> String {
        CallsCard.time(seconds, into: call.record.startedAt)
    }

    /// "20:58", and "20:58 · just now" on a line just said.
    private func time(_ turn: MeetingSegment, justNow: Bool) -> some View {
        Text(justNow ? String(localized: "\(clock(turn.start)) · just now") : clock(turn.start))
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

/// On Free, under the first "Them" turn of a call the invite says had two
/// or more others on it: who showed as "Them", and that Plus tells each
/// voice apart (`FreeVoicesHint`). Quiet grey, like "Who's who" says it.
private struct CallTranscriptVoicesHint: View {
    let who: String
    let showPlans: @MainActor () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "person.2")
                .font(.system(size: 11, weight: .medium))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(who)
                Text(FreeVoicesHint.plusTells)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: showPlans) {
                HStack(spacing: 3) {
                    Text("See Plus")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                }
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(PlanTag.plusText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .clickable()
            .help("Opens Airlock's plans")
        }
        .font(Theme.chrome(12))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(shape.fill(Color.white.opacity(0.025)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.leading, 35)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }
}

/// At the end of a Free call's transcript, where the part heard past its
/// limit would be: how long it is, until when it is kept, and Plus.
private struct CallTranscriptWaiting: View {
    let minutes: Int
    let from: Date
    let to: Date
    let until: Date
    let showPlans: (@MainActor () -> Void)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(PlanTag.plusText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(LockedCallWords.waitingTitle(minutes: minutes))
                        .font(Theme.chrome(13.5, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    PlanTag(.plus)
                }
                Text(LockedCallWords.waitingDetail(from: from, to: to, until: until))
                    .font(Theme.chrome(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let showPlans {
                Button(action: showPlans) {
                    HStack(spacing: 3) {
                        Text("See Plus")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .font(Theme.chrome(12.5, .semibold))
                    .foregroundStyle(PlanTag.plusText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .clickable()
                .help("Opens Airlock's plans")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(shape.fill(PlanTag.plusText.opacity(0.06)))
        .overlay(shape.strokeBorder(PlanTag.plusText.opacity(0.28), lineWidth: 1))
        .padding(.top, 14)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
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
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
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
