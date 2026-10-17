import AirlockCore
import Foundation
import Network

/// Meeting notes written online, for subscribers: the transcript goes to
/// Airlock's server (the licence server's `/notes`), which has a larger model
/// write them and answers with the notes. The app never holds a model's key:
/// it asks with the licence token, and only the server holds the key.
///
/// Nothing here runs while `meetings.cloudNotes.enabled` is set to false (on
/// for everyone from 1.0.20, a switch nobody sees that turns it all off), and
/// then only when every condition in `CloudNotesRoute.decide` holds. Nobody
/// is asked: a subscriber's notes go online unless "Write notes online" is
/// switched off in Settings (`CloudNotesSetting`). Anything else, any failure
/// included, and the Mac writes the notes as it always has: the caller falls
/// back without a word, and nothing is ever shown as an error.
///
/// Each meeting is sent once. A refusal (this month's notes used, or not
/// eligible) is remembered so the next meetings don't ask; a server error is
/// not, so the next meeting asks again. Only notes the Mac wrote while offline
/// are sent again later, once the network is back (`CloudNotesRedo`), and
/// the calls of a Mac that can't write notes at all (no Apple Intelligence):
/// after a failure, a few more times, and after this month's notes are used,
/// on the day they come back (`planNextLook`).
///
/// The log (`MeetingDiagnostics`) says kinds, counts, sizes, timings and the
/// model's name, never a word of the meeting or of the notes.
@MainActor
final class CloudNotesService {
    static let shared = CloudNotesService()

    /// On unless set to false. Off: notes on the Mac only, nothing asked,
    /// nothing sent. It was set by hand on the owner's Mac while notes online
    /// were tried, and is on for everyone from 1.0.20.
    static let enabledKey = "meetings.cloudNotes.enabled"
    /// What the switch says before anybody has set it.
    static let onByDefault = true
    /// "Write notes online" in Settings, three ways (`setting`). In 1.0.20 a
    /// question under the notes wrote it too, so a "Keep on this Mac" from
    /// then is a false here, and is kept.
    static let settingKey = "meetings.cloudNotes.online"
    static let allowanceUntilKey = "meetings.cloudNotes.allowanceUntil"
    static let noticeShownKey = "meetings.cloudNotes.allowanceNoticeShown"
    static let notEligibleUntilKey = "meetings.cloudNotes.notEligibleUntil"
    /// The licence the 403 was for (`CloudNotesAllowance.tokenMark`).
    static let notEligibleTokenKey = "meetings.cloudNotes.notEligibleToken"

    /// How long one request may take: a long meeting is a long answer.
    nonisolated static let timeout: TimeInterval = 120

    /// The plan right now, wired by the app delegate. Until then: Free, so
    /// nothing is sent. A call is judged by the better of this and the plan
    /// it started on (`PlanSnapshot.kept`), so a plan that ends mid-call
    /// still gets that call's notes written the way it began.
    var plan: () -> PlanSnapshot = { .free }
    var access: () -> (endpoint: URL, token: String)? = { nil }
    var hasServer: () -> Bool = { false }
    /// A meeting's notes were written again online: its folder, the notes,
    /// and whether they are its first (a Mac that can't write notes waited).
    var onRedone: ((URL, MeetingNotes, _ first: Bool) -> Void)?
    /// The time: the clock in the app, a stand-in in tests.
    var now: () -> Date = { Date() }

    /// Sends one request and reads its answer: the network in the app, a
    /// stand-in in tests, which never reach it.
    typealias Transport = @Sendable (_ prompt: String, _ endpoint: URL, _ token: String) async -> CloudNotes.Reply

    private let defaults: UserDefaults
    private let store: MeetingStore
    private let transport: Transport
    private var monitor: NWPathMonitor?
    /// Nil until the network has been seen, and counted as online: a
    /// request is tried, and a request that can't leave says so.
    private(set) var isOnline: Bool?
    /// The run of `redoWaiting` going now, if any; tests wait on it.
    private(set) var redoing: Task<Void, Never>?
    /// Asked for while a run was going: one more run once it ends, so a
    /// meeting written offline just now isn't left for the next time.
    private var redoAgain = false
    /// The look planned for when the next meeting waiting for a date is due.
    private var wake: Task<Void, Never>?
    /// When that look is; nil when none is planned.
    private(set) var nextLookAt: Date?
    /// The longest a planned look sleeps: past it, it looks and plans again,
    /// so a clock changed meanwhile is caught up with.
    static let longestSleep: TimeInterval = 6 * 3_600

    init(defaults: UserDefaults = .standard, store: MeetingStore = MeetingStore(),
         transport: Transport? = nil) {
        self.defaults = defaults
        self.store = store
        self.transport = transport ?? { await CloudNotesService.send(prompt: $0, to: $1, token: $2) }
    }

    /// The hidden switch. `object(forKey:)`, not `bool(forKey:)`, which reads
    /// a missing key as false.
    var isOn: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? Self.onByDefault }

    /// "Write notes online" in Settings: nil until it is touched, which
    /// counts as on; false keeps the notes on the Mac.
    var setting: Bool? { Self.setting(in: defaults) }

    static func setting(in defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: settingKey) as? Bool
    }

    /// The Settings switch: on unless switched off.
    static func switchIsOn(in defaults: UserDefaults = .standard) -> Bool {
        CloudNotesSetting.isOn(setting(in: defaults))
    }

    static func setSwitch(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: settingKey)
    }

    /// Watches the network, so notes the Mac wrote offline are written online
    /// when it comes back. Only while the hidden switch is on.
    func start() {
        guard isOn, monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.airlock.cloud-notes-path"))
        self.monitor = monitor
        Task { await planNextLook() }
    }

    private func networkChanged(online: Bool) {
        let was = isOnline
        isOnline = online
        if CloudNotesRedo.shouldStart(wasOnline: was, isOnline: online) { redoWaiting() }
    }

    // MARK: - One meeting

    /// What came of asking for a meeting's notes online.
    enum Attempt {
        /// Written online, checked against the transcript.
        case written(MeetingNotes, model: String?)
        /// Not asked, or refused: the Mac writes them, and why.
        case mac(CloudNotesRoute.Reason)
        /// Asked, and no notes came back that hold up: the Mac writes them.
        case failed
    }

    /// The notes for a meeting that has just ended, written online when they
    /// can be. Never sent twice, whatever the answer.
    func write(_ record: MeetingRecord, log: @escaping (String) -> Void) async -> Attempt {
        guard isOn else { return .mac(.hiddenSwitchOff) }
        let prompt = Self.prompt(for: record)
        let route = CloudNotesRoute.decide(conditions(for: record, prompt: prompt))
        guard case .online = route, let access = access() else {
            let reason: CloudNotesRoute.Reason
            if case .mac(let said) = route { reason = said } else { reason = .noToken }
            log("notes online: no, \(reason.logName)")
            return .mac(reason)
        }
        let attempt = await ask(record, prompt: prompt, access: access, log: log)
        // Online for sure: anything written offline can follow.
        if case .written = attempt { redoWaiting() }
        return attempt
    }

    /// Said once a month at most: until when this month's online notes are
    /// used, when that hasn't been said yet this month.
    func takeAllowanceNotice(until: Date, now: Date = Date()) -> Date? {
        let shown = defaults.object(forKey: Self.noticeShownKey) as? Date
        guard CloudNotesAllowance.noticeDue(lastShown: shown, now: now) else { return nil }
        defaults.set(now, forKey: Self.noticeShownKey)
        return until
    }

    private static func prompt(for record: MeetingRecord) -> String {
        CallNotesPrompts.cloud(for: record, language: CallLanguage.check(record).decision?.name)
    }

    private func conditions(for record: MeetingRecord, prompt: String) -> CloudNotesConditions {
        let token = access()?.token
        let notEligibleUntil = CloudNotesAllowance.notEligibleUntil(
            saved: defaults.object(forKey: Self.notEligibleUntilKey) as? Date,
            savedMark: defaults.string(forKey: Self.notEligibleTokenKey), token: token)
        return CloudNotesConditions(hiddenSwitch: isOn, setting: setting,
                                    plan: PlanSnapshot.kept(startedOn: record.startedOn, now: plan()),
                                    hasToken: token != nil, hasServer: hasServer(),
                                    online: isOnline ?? true,
                                    words: NumberedTranscript(record).wordCount,
                                    promptSize: CloudNotes.size(prompt),
                                    allowanceUntil: defaults.object(forKey: Self.allowanceUntilKey) as? Date,
                                    notEligibleUntil: notEligibleUntil,
                                    now: now())
    }

    /// One request, and what its answer means for this meeting and the next.
    private func ask(_ record: MeetingRecord, prompt: String, access: (endpoint: URL, token: String),
                     log: @escaping (String) -> Void) async -> Attempt {
        let started = Date()
        log("notes online: asking, prompt \(CloudNotes.size(prompt)) units, \(record.segments.count) line(s)")
        let reply = await transport(prompt, access.endpoint, access.token)
        let took = String(format: "%.1fs", Date().timeIntervalSince(started))
        switch reply {
        case .notes(let text, let model, let used):
            let usedLine = used.map { String(format: ", %.0f%% of the month used", $0 * 100) } ?? ""
            guard let draft = CloudNotes.parse(text) else {
                log("notes online: answer unreadable (\(CloudNotes.size(text)) units) in \(took)")
                return .failed
            }
            let (notes, tally) = CloudNotes.notes(from: draft, record: record)
            log("notes online: \(model ?? "model unnamed") in \(took), kept \(tally.kept), "
                + "dropped \(tally.dropped)\(notes.title == nil ? ", no title" : "")\(usedLine)")
            guard !notes.isEmpty else {
                log("notes online: nothing held up, written on the Mac")
                return .failed
            }
            return .written(notes, model: model)
        case .allowanceUsed(let resetsAt):
            let until = CloudNotesAllowance.until(resetsAt: resetsAt, now: now())
            defaults.set(until, forKey: Self.allowanceUntilKey)
            log("notes online: month's allowance used, until \(until.formatted(.iso8601)) (in \(took))")
            return .mac(.allowanceUsed(until: until))
        case .notEligible:
            let until = now().addingTimeInterval(CloudNotesAllowance.notEligibleFor)
            defaults.set(until, forKey: Self.notEligibleUntilKey)
            defaults.set(CloudNotesAllowance.tokenMark(access.token), forKey: Self.notEligibleTokenKey)
            log("notes online: not eligible, not asked again for 30 days on this licence (in \(took))")
            return .mac(.notEligible(until: until))
        case .offline:
            log("notes online: offline, the request never left (in \(took))")
            return .mac(.offline)
        case .badToken, .tooLarge, .unavailable:
            log("notes online: \(reply.logName) in \(took), written on the Mac")
            return .failed
        }
    }

    /// The request itself, off the main actor. A request that never left
    /// the Mac (`CloudNotes.neverLeft`) is `.offline`; every other failure,
    /// a timeout included, is `.unavailable`: it may have reached the server.
    nonisolated static func send(prompt: String, to endpoint: URL, token: String) async -> CloudNotes.Reply {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = CloudNotes.requestBody(token: token, instructions: CallNotesPrompts.cloudInstructions,
                                                  prompt: prompt)
        // Nothing kept on disk: no cache, no cookies.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            return CloudNotes.Reply.read(status: http.statusCode, body: data)
        } catch let error as URLError {
            return CloudNotes.neverLeft(error.code) ? .offline : .unavailable
        } catch {
            return .unavailable
        }
    }

    // MARK: - Written again on request

    /// What the notes window may offer now (`CallNotesOffers`).
    var offering: CallNotesOffers.Online {
        let token = access()?.token
        let today = now()
        let notEligible = CloudNotesAllowance.notEligibleUntil(
            saved: defaults.object(forKey: Self.notEligibleUntilKey) as? Date,
            savedMark: defaults.string(forKey: Self.notEligibleTokenKey), token: token)
        let allowance = defaults.object(forKey: Self.allowanceUntilKey) as? Date
        let refused = [notEligible, allowance].contains { ($0 ?? .distantPast) > today }
        return CallNotesOffers.Online(exists: isOn && hasServer(), settingOn: setting != false,
                                      blocked: token == nil || refused)
    }

    /// What came of asking for a past call's notes again.
    enum Redo: Equatable {
        case written
        /// Not sent, and why: the plan, the setting, too little said.
        case notSent(CloudNotesRoute.Reason)
        /// This month's online notes are used, until then.
        case allowanceUsed(until: Date)
        /// The request never left the Mac.
        case offline
        /// Asked, and no notes came back that hold up.
        case failed
    }

    /// A past call's notes written again online, because the person asked
    /// ("Redo with better notes"): on a plan that writes notes online,
    /// under every condition the end of a call has (`CloudNotesRoute`), and
    /// counted in this month's online notes like any. The page there was is
    /// kept beside the new one when it had notes; nothing is lost if the
    /// answer doesn't hold up.
    func redo(_ folder: URL, log: @escaping (String) -> Void) async -> Redo {
        guard isOn else { return .notSent(.hiddenSwitchOff) }
        guard let record = store.keptRecord(in: folder), record.endedAt != nil else { return .failed }
        let prompt = Self.prompt(for: record)
        // The plan now: a redo is asked for today, not during the call.
        var conditions = conditions(for: record, prompt: prompt)
        conditions.plan = plan()
        let route = CloudNotesRoute.decide(conditions)
        guard case .online = route, let access = access() else {
            let reason: CloudNotesRoute.Reason
            if case .mac(let said) = route { reason = said } else { reason = .noToken }
            log("notes online: redo not sent, \(reason.logName)")
            if case .allowanceUsed(let until) = reason { return .allowanceUsed(until: until) }
            if case .offline = reason { return .offline }
            return .notSent(reason)
        }
        log("notes online: redo asked for")
        switch await ask(record, prompt: prompt, access: access, log: log) {
        case .written(let notes, let model):
            let hadNotes = store.notesPage(in: folder).map(MeetingFiles.hasNotes) ?? false
            replaceNotes(in: folder, record: record, hadNotes: hadNotes, notes: notes, model: model, log: log)
            redoWaiting()
            return .written
        case .mac(.allowanceUsed(let until)):
            return .allowanceUsed(until: until)
        case .mac(.offline):
            return .offline
        case .mac(let reason):
            return .notSent(reason)
        case .failed:
            return .failed
        }
    }

    // MARK: - Written again once online

    /// The meetings waiting to be written online, written now: newest first,
    /// a few at a time (`CloudNotesRedo`). The page the Mac wrote is kept
    /// beside the new one. Then the next look is planned.
    func redoWaiting() {
        guard isOn else { return }
        guard redoing == nil else {
            redoAgain = true
            return
        }
        redoing = Task { [weak self] in
            await self?.redoNow()
            // One more run at most, for what was asked during this one.
            if self?.redoAgain == true {
                self?.redoAgain = false
                await self?.redoNow()
            }
            self?.redoing = nil
            await self?.planNextLook()
        }
    }

    /// One run of `redoWaiting`, to the end.
    func redoNow() async {
        guard isOn else { return }
        let store = store
        let now = now()
        let waiting = await Task.detached(priority: .utility) {
            CloudNotesRedo.waiting(store.calls(), now: now)
        }.value
        await redo(waiting.map(\.folder))
    }

    /// A look at the waiting meetings when the next one waiting for a date
    /// is due (`CloudNotesRedo.nextLook`): the day this month's notes come
    /// back, or the next try after one that didn't work. Planned again after
    /// every run; none while nothing waits for a date. The clock it sleeps
    /// on keeps counting while the Mac sleeps.
    func planNextLook() async {
        guard isOn else { return }
        let store = store
        let now = now()
        let next = await Task.detached(priority: .utility) {
            CloudNotesRedo.nextLook(store.calls(), now: now)
        }.value
        wake?.cancel()
        wake = nil
        nextLookAt = next
        guard let next else { return }
        let seconds = min(max(next.timeIntervalSince(now), 1), Self.longestSleep)
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.wake = nil
            self?.redoWaiting()
        }
    }

    private func redo(_ folders: [URL]) async {
        let log: (String) -> Void = { MeetingDiagnostics.log($0) }
        if !folders.isEmpty { log("notes online: \(folders.count) meeting(s) waiting to be written online") }
        for folder in folders {
            guard isOn else { return }
            // Read again: the folder may have changed since the list was made.
            guard let record = store.keptRecord(in: folder), var writer = record.notesWriter,
                  CloudNotesRedo.isDue(writer, now: now()) else { continue }
            let prompt = Self.prompt(for: record)
            let route = CloudNotesRoute.decide(conditions(for: record, prompt: prompt))
            switch CloudNotesRedo.step(for: route, writer: writer) {
            case .leave:
                if case .mac(let reason) = route { log("notes online: left on the Mac, \(reason.logName)") }
                stopWaiting(folder, writer: writer, log: log)
                continue
            case .stop:
                if case .mac(let reason) = route { log("notes online: writing again stopped, \(reason.logName)") }
                return
            case .waitUntil(let until):
                wait(folder, writer: CloudNotesRedo.afterAllowanceUsed(writer, until: until, triedNow: false),
                     log: log)
                continue
            case .send:
                break
            }
            guard let access = access() else { return }
            // Counted before it is sent: a quit halfway doesn't send it again.
            writer.onlineTries += 1
            save(writer, in: folder, log: log)
            switch await ask(record, prompt: prompt, access: access, log: log) {
            case .written(let notes, let model):
                replaceNotes(in: folder, record: record, hadNotes: writer.noNotesYet == nil, notes: notes,
                             model: model, log: log)
            case .mac(.offline):
                // Never left: still waiting, its try given back.
                save(CloudNotesRedo.afterFailedTry(writer, neverLeft: true), in: folder, log: log)
                return
            case .mac(.allowanceUsed(let until)) where writer.noNotesYet != nil:
                // A refusal costs nothing: no notes yet, so it waits for the
                // day they come back, and the rest are told the same.
                wait(folder, writer: CloudNotesRedo.afterAllowanceUsed(writer, until: until, triedNow: true),
                     log: log)
            case .failed where writer.noNotesYet != nil:
                // No notes yet: tried again later while tries are left.
                let next = CloudNotesRedo.afterFailedTry(writer, neverLeft: false, now: now())
                if next.waitsForOnline {
                    wait(folder, writer: next, log: log)
                } else {
                    stopWaiting(folder, writer: writer, log: log)
                }
                return
            case .mac, .failed:
                // The server answered: never sent again.
                stopWaiting(folder, writer: writer, log: log)
                return
            }
        }
    }

    /// Still waiting, for another reason or until another day: the page
    /// says which (`MeetingFiles.waitingLine`).
    private func wait(_ folder: URL, writer: MeetingNotesWriter, log: (String) -> Void) {
        save(writer, in: folder, log: log)
        log("notes online: still waiting, \(writer.noNotesYet?.rawValue ?? "online")"
            + (writer.notBefore.map { " until \($0.formatted(.iso8601))" } ?? ""))
        do {
            try store.setWaitingLine(for: writer, in: folder)
        } catch {
            log("notes online: waiting line not changed: \(error.localizedDescription)")
        }
    }

    /// The notes on the page are the notes now: it stops promising more.
    private func stopWaiting(_ folder: URL, writer: MeetingNotesWriter, log: (String) -> Void) {
        save(CloudNotesRedo.stopped(writer), in: folder, log: log)
        do {
            try store.dropWaitingLine(in: folder)
        } catch {
            log("notes online: waiting line not removed: \(error.localizedDescription)")
        }
    }

    /// `hadNotes` false is a page with none (a Mac that can't write them):
    /// it is not kept beside the new one, and these are the call's first.
    private func replaceNotes(in folder: URL, record: MeetingRecord, hadNotes: Bool, notes: MeetingNotes,
                              model: String?, log: (String) -> Void) {
        let writer = MeetingNotesWriter.online(model: model, at: Date(),
                                               plan: PlanSnapshot.kept(startedOn: record.startedOn, now: plan()))
        do {
            try store.dropWaitingLine(in: folder)
            let kept = hadNotes ? try store.keepEarlierNotes(in: folder) : nil
            try store.saveNotes(MeetingFiles.notesPage(for: record, notes: notes, writer: writer), in: folder)
            save(writer, in: folder, log: log)
            do {
                try store.saveTopic(notes.title, in: folder)
            } catch {
                log("notes online: title not saved: \(error.localizedDescription)")
            }
            log("notes online: written again online" + (kept == nil ? "" : ", the Mac's page kept beside them"))
            onRedone?(folder, notes, !hadNotes)
        } catch {
            log("notes online: writing again FAILED: \(error.localizedDescription)")
            stopWaiting(folder, writer: record.notesWriter ?? writer, log: log)
        }
    }

    private func save(_ writer: MeetingNotesWriter, in folder: URL, log: (String) -> Void) {
        do {
            try store.saveNotesWriter(writer, in: folder)
        } catch {
            log("notes online: writer not saved: \(error.localizedDescription)")
        }
    }
}
