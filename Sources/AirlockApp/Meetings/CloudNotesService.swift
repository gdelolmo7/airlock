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
/// are sent again later, once the network is back (`CloudNotesRedo`).
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

    /// The licence, wired by the app delegate. Until then: not a
    /// subscriber, so nothing is sent.
    var entitlement: () -> Entitlement = { .free }
    var access: () -> (endpoint: URL, token: String)? = { nil }
    var hasServer: () -> Bool = { false }
    /// A meeting's notes were written again online: its folder, and the notes.
    var onRedone: ((URL, MeetingNotes) -> Void)?

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
        return CloudNotesConditions(hiddenSwitch: isOn, setting: setting, entitlement: entitlement(),
                                    hasToken: token != nil, hasServer: hasServer(),
                                    online: isOnline ?? true,
                                    words: NumberedTranscript(record).wordCount,
                                    promptSize: CloudNotes.size(prompt),
                                    allowanceUntil: defaults.object(forKey: Self.allowanceUntilKey) as? Date,
                                    notEligibleUntil: notEligibleUntil,
                                    now: Date())
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
            let until = CloudNotesAllowance.until(resetsAt: resetsAt, now: Date())
            defaults.set(until, forKey: Self.allowanceUntilKey)
            log("notes online: month's allowance used, until \(until.formatted(.iso8601)) (in \(took))")
            return .mac(.allowanceUsed(until: until))
        case .notEligible:
            let until = Date().addingTimeInterval(CloudNotesAllowance.notEligibleFor)
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

    // MARK: - Written again once online

    /// The meetings the Mac wrote while offline, written online now: newest
    /// first, a few at a time, each sent once (`CloudNotesRedo`). The page the
    /// Mac wrote is kept beside the new one.
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
        }
    }

    /// One run of `redoWaiting`, to the end.
    func redoNow() async {
        guard isOn else { return }
        let store = store
        let waiting = await Task.detached(priority: .utility) {
            CloudNotesRedo.waiting(store.calls())
        }.value
        await redo(waiting.map(\.folder))
    }

    private func redo(_ folders: [URL]) async {
        let log: (String) -> Void = { MeetingDiagnostics.log($0) }
        if !folders.isEmpty { log("notes online: \(folders.count) meeting(s) written offline to write again") }
        for folder in folders {
            guard isOn else { return }
            // Read again: the folder may have changed since the list was made.
            guard let record = store.keptRecord(in: folder), var writer = record.notesWriter,
                  writer.waitsForOnline, writer.onlineTries < CloudNotesRedo.maxTries else { continue }
            let prompt = Self.prompt(for: record)
            let route = CloudNotesRoute.decide(conditions(for: record, prompt: prompt))
            switch CloudNotesRedo.step(for: route) {
            case .leave:
                if case .mac(let reason) = route { log("notes online: left on the Mac, \(reason.logName)") }
                stopWaiting(folder, writer: writer, log: log)
                continue
            case .stop:
                if case .mac(let reason) = route { log("notes online: writing again stopped, \(reason.logName)") }
                return
            case .send:
                break
            }
            guard let access = access() else { return }
            // Counted before it is sent: a quit halfway doesn't send it again.
            writer.onlineTries += 1
            save(writer, in: folder, log: log)
            switch await ask(record, prompt: prompt, access: access, log: log) {
            case .written(let notes, let model):
                replaceNotes(in: folder, record: record, notes: notes, model: model, log: log)
            case .mac(.offline):
                // Never left: still waiting, its try given back.
                save(CloudNotesRedo.afterFailedTry(writer, neverLeft: true), in: folder, log: log)
                return
            case .mac, .failed:
                // The server answered: never sent again.
                stopWaiting(folder, writer: writer, log: log)
                return
            }
        }
    }

    /// The Mac's notes are the notes now: the page stops promising better.
    private func stopWaiting(_ folder: URL, writer: MeetingNotesWriter, log: (String) -> Void) {
        save(CloudNotesRedo.afterFailedTry(writer, neverLeft: false), in: folder, log: log)
        do {
            try store.dropOfflineLine(in: folder)
        } catch {
            log("notes online: offline line not removed: \(error.localizedDescription)")
        }
    }

    private func replaceNotes(in folder: URL, record: MeetingRecord, notes: MeetingNotes, model: String?,
                              log: (String) -> Void) {
        let writer = MeetingNotesWriter.online(model: model, at: Date())
        do {
            try store.dropOfflineLine(in: folder)
            let kept = try store.keepEarlierNotes(in: folder)
            try store.saveNotes(MeetingFiles.notesPage(for: record, notes: notes, writer: writer), in: folder)
            save(writer, in: folder, log: log)
            do {
                try store.saveTopic(notes.title, in: folder)
            } catch {
                log("notes online: title not saved: \(error.localizedDescription)")
            }
            log("notes online: written again online" + (kept == nil ? "" : ", the Mac's page kept beside them"))
            onRedone?(folder, notes)
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
