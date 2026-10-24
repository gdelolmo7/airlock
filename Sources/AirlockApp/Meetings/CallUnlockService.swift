import AirlockCore
import Foundation

/// A Free call's locked part (`LockedPart`), looked after: on Plus or Pro
/// its key is asked of the licence server's `/unlock` and the call is opened
/// on the Mac; on any plan, it is removed at the end of its week. What is
/// done is `CallUnlock`'s; this only carries it out.
///
/// What leaves the Mac is the licence token and the call's sealed key, never
/// a word: the lines are opened here, with the key that comes back. Neither
/// key is kept or logged, and the log (`MeetingDiagnostics`) says only what
/// kind of answer came.
///
/// It looks at launch, when the plan changes, and every hour, and never at a
/// call the notes still hold (`MeetingNotesModel.isHolding`): those are the
/// notes' to write, and the next look takes them.
@MainActor
final class CallUnlockService {
    static let shared = CallUnlockService()

    /// Calls the server said won't open, by folder name, so they aren't
    /// asked about again. They are still removed at the end of their week.
    static let givenUpKey = "meetings.callLock.givenUp"
    /// How long one request may take.
    nonisolated static let timeout: TimeInterval = 30
    static let every: Duration = .seconds(3_600)

    var plan: () -> PlanSnapshot = { .free }
    var access: () -> (endpoint: URL, token: String)? = { nil }
    var isHolding: (URL) -> Bool = { _ in false }
    /// Calls were opened or removed: what shows them reads them again.
    var onChanged: () -> Void = {}
    var now: () -> Date = { Date() }

    typealias Transport = @Sendable (_ body: Data, _ endpoint: URL) async -> CallUnlockWire.Reply

    private let defaults: UserDefaults
    private let store: MeetingStore
    private let transport: Transport
    private var looking: Task<Void, Never>?
    private var again = false
    private var sweep: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, store: MeetingStore = MeetingStore(),
         transport: Transport? = nil) {
        self.defaults = defaults
        self.store = store
        self.transport = transport ?? { await CallUnlockService.send($0, to: $1) }
    }

    /// Looks now and then every hour.
    func start() {
        guard sweep == nil else { return }
        sweep = Task { [weak self] in
            while !Task.isCancelled {
                await self?.look()
                try? await Task.sleep(for: Self.every)
            }
        }
    }

    /// One look over every call, done by the time this returns. Asked for
    /// while one is going, one more follows it, so a plan bought meanwhile
    /// is seen.
    func look() async {
        if let looking {
            again = true
            await looking.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                again = false
                await round()
            } while again
        }
        looking = task
        await task.value
        looking = nil
    }

    private func round() async {
        let store = store
        let calls = await Task.detached(priority: .utility) { store.calls() }.value
        var givenUp = Set(defaults.stringArray(forKey: Self.givenUpKey) ?? [])
        var changed = false
        var asking = true
        for (folder, found) in calls where found.locked != nil && !isHolding(folder) {
            var record = found
            let name = folder.lastPathComponent
            switch CallUnlock.step(for: record, plan: plan(), now: now(), givenUp: givenUp.contains(name)) {
            case .nothing:
                continue
            case .remove:
                record.locked?.removeIfDue(at: now())
                changed = save(record, in: folder, saying: "removed at the end of its week") || changed
                givenUp.remove(name)
            case .ask:
                guard asking, let access = access(),
                      let part = record.locked,
                      let body = CallUnlockWire.requestBody(token: access.token, part: part) else { continue }
                let reply = await transport(body, access.endpoint)
                MeetingDiagnostics.log("call lock: asked, \(reply.logName)")
                // Read again: names may have been given while the server
                // answered, or the call taken up again.
                guard !isHolding(folder), let fresh = store.loadRecord(in: folder), fresh.locked == part else { continue }
                record = fresh
                switch CallUnlock.apply(reply, to: &record) {
                case .opened(let minutes):
                    changed = save(record, in: folder, saying: "opened, \(minutes) min") || changed
                case .removed:
                    changed = save(record, in: folder, saying: "removed, the server says its week is over") || changed
                case .givenUp:
                    givenUp.insert(name)
                case .stop, .later:
                    asking = false
                }
            }
        }
        // Only folders still here are remembered.
        let names = Set(calls.map { $0.folder.lastPathComponent })
        defaults.set(givenUp.intersection(names).sorted(), forKey: Self.givenUpKey)
        if changed { onChanged() }
    }

    private func save(_ record: MeetingRecord, in folder: URL, saying what: String) -> Bool {
        do {
            try store.saveTranscript(record, in: folder)
            MeetingDiagnostics.log("call lock: \(what)")
            return true
        } catch {
            MeetingDiagnostics.log("call lock: save FAILED: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated static func send(_ body: Data, to endpoint: URL) async -> CallUnlockWire.Reply {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // Nothing kept on disk: no cache, no cookies.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        PretendOutage.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            return CallUnlockWire.Reply.read(status: http.statusCode, body: data)
        } catch {
            return .unavailable
        }
    }
}
