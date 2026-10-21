import AirlockCore
import Foundation
import Observation

/// How a batch leaves the Mac: a POST that answers with a status, or nil when
/// no answer came. `URLSessionUsageTransport` in the app, a fake in the tests.
protocol UsageTransport: Sendable {
    func post(_ body: Data, to url: URL) async -> Int?
}

/// Usage counts: which features get used, where setup stops, who keeps
/// using Airlock. Never what anybody typed, said, copied or saw, which the
/// event's shape already rules out (`UsageEvent`).
///
/// **Only for people who say yes** (the owner's call, 2026-10-17). The
/// answer is `enabledKey`, absent meaning no, asked on the first screen of
/// setup for a new copy, once in the notch for a copy that finished setup
/// before counts existed (`hasQuestionWaiting`), and on Settings › General.
/// Nothing is counted before the yes. Switched off, the waiting events and
/// the install id are thrown away and nothing more is kept.
///
/// **Only from a build that has somewhere to send them.** The address is the
/// licence server's `/usage` (`UsagePolicy.endpoint`), which only a release
/// package carries, so `swift run`, the tests, a development package and the
/// public source keep nothing and show no switch (`isAvailable`).
///
/// Events wait in memory and go every ten minutes, or at fifty; the ones
/// still waiting at quit go to a file and are sent after the next launch.
/// The server forwards them to the counting service without the Mac's
/// address.
///
/// On the owner's own Macs every batch also carries the owner's mark
/// (`OwnerMark`), kept in a file beside the waiting one, so their own use
/// can be left out of the numbers. Switching counts off leaves it there.
@MainActor
@Observable
final class UsageCounts {
    static let shared = UsageCounts()

    /// The person's answer. Absent is no.
    nonisolated static let enabledKey = "usage.enabled"
    /// The question has been put: on setup's first screen or in the notch.
    /// Not again after that; Settings is where they change their mind.
    nonisolated static let askedKey = "usage.asked"
    /// A random id for this copy, so a week of events reads as one Mac. Not
    /// the licence, not the Mac's serial: made at the yes, thrown away when
    /// counts are switched off, and a new one made at the next yes.
    nonisolated static let installKey = "usage.install"
    /// When the once-a-day event last went.
    nonisolated static let dayKey = "usage.dayActiveAt"

    /// Where this build sends counts, if anywhere. Nonisolated so Settings
    /// search can ask from anywhere.
    nonisolated static var bundleEndpoint: URL? {
        guard AppBundle.isBundled else { return nil }
        let base = (Bundle.main.object(forInfoDictionaryKey: "ALLicenseAPIURL") as? String)
            .flatMap(URL.init(string:))
        return UsagePolicy.endpoint(apiBase: base)
    }

    /// The build could send counts. When false nothing here keeps anything
    /// and no surface offers the switch.
    let isAvailable: Bool

    /// The person's answer. Changed through `choose(_:from:)`, which knows
    /// where the answer was given.
    private(set) var isEnabled: Bool

    /// The plan, the version and the Mac every batch carries once. Set by
    /// the app delegate, which knows the plan.
    @ObservationIgnored var context: () -> UsageContext = { UsageCounts.context(plan: .free) }
    /// What is set up, for the once-a-day event. nil sends no daily event.
    @ObservationIgnored var daySnapshot: () -> UsageEvent? = { nil }

    @ObservationIgnored private let endpoint: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: UsageTransport
    @ObservationIgnored private let queueFile: URL
    /// Beside the waiting file: the app's own folder, or a test's.
    @ObservationIgnored private let ownerFile: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let roundEvery: Duration?
    @ObservationIgnored private var queue = UsageQueue()
    @ObservationIgnored private var lastTry: Date?
    @ObservationIgnored private var sending = false
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// When each `recordOnceADay` key was last kept, this run.
    @ObservationIgnored private var keptToday: [String: Date] = [:]

    /// `roundEvery` nil runs no rounds of its own, for the tests, which call
    /// `round()` when they mean to.
    init(endpoint: URL?, defaults: UserDefaults, transport: UsageTransport, queueFile: URL,
         now: @escaping () -> Date = Date.init, roundEvery: Duration? = .seconds(60)) {
        self.endpoint = endpoint
        self.defaults = defaults
        self.transport = transport
        self.queueFile = queueFile
        ownerFile = queueFile.deletingLastPathComponent().appendingPathComponent(OwnerMark.fileName)
        self.now = now
        self.roundEvery = roundEvery
        isAvailable = endpoint != nil
        isEnabled = endpoint != nil
            && UsagePolicy.isOn(stored: defaults.object(forKey: Self.enabledKey) as? Bool)
    }

    /// The app's own: the bundle's address, the real defaults, a plain
    /// request, and the waiting file next to the app's other files.
    convenience init() {
        self.init(endpoint: Self.bundleEndpoint, defaults: .standard,
                  transport: URLSessionUsageTransport(),
                  queueFile: URL(fileURLWithPath: NSHomeDirectory())
                      .appendingPathComponent("Library/Application Support/Airlock/usage-waiting.json"))
    }

    // MARK: - The answer

    /// Yes or no, from setup, the notch's question or Settings. Either way
    /// the question counts as asked. No throws away everything waiting and
    /// the install id; yes counts from this moment on, starting with the yes
    /// itself.
    func choose(_ on: Bool, from origin: UsageEvent.Origin) {
        // A build that cannot send keeps no answer: the switch is not shown
        // there, and a yes saved by a development copy would be read by the
        // installed one if they shared a domain.
        guard isAvailable else { return }
        questionAsked()
        guard on != isEnabled else { return }
        isEnabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            record(.countsStarted(from: origin))
            startRounds()
        } else {
            forget()
        }
    }

    /// The question has been put, answered or not: setup's first screen was
    /// left, or the notch's question shown.
    func questionAsked() {
        guard isAvailable else { return }
        defaults.set(true, forKey: Self.askedKey)
    }

    /// The question for a copy that finished setup before counts existed: a
    /// build that sends, an answer still off, and nobody asked yet.
    var hasQuestionWaiting: Bool {
        UsagePolicy.asks(available: isAvailable, isOn: isEnabled,
                         alreadyAsked: defaults.bool(forKey: Self.askedKey))
    }

    // MARK: - Recording

    /// Whether events are kept right now.
    private var keeps: Bool { UsagePolicy.keeps(endpoint: endpoint, isOn: isEnabled) }

    /// Keeps one event to send. Nothing before `launch()`, so the state
    /// gallery and the snapshot runs, which never launch, count nothing.
    func record(_ event: UsageEvent) {
        guard launched, keeps else { return }
        queue.append(UsageRecord(event, at: now()))
        if queue.count >= UsagePolicy.sendAtCount { Task { await send() } }
    }

    /// Keeps an event that can happen many times in a row (Free's clipboard
    /// lets a copy go at every copy once it is full) once a day per `key`.
    /// Remembered for this run only: a relaunch may count it once more.
    func recordOnceADay(_ event: UsageEvent, key: String) {
        guard launched, keeps else { return }
        let at = now()
        if let last = keptToday[key], Calendar.current.isDate(last, inSameDayAs: at) { return }
        keptToday[key] = at
        record(event)
    }

    // MARK: - Lifecycle

    /// At launch: picks up what the last run left waiting, counts the start,
    /// and begins the rounds. Once per run.
    func launch() {
        guard isAvailable, !launched else { return }
        launched = true
        let waiting = (try? Data(contentsOf: queueFile))
            .flatMap { try? JSONDecoder.usage.decode(UsageQueue.self, from: $0) }
        try? FileManager.default.removeItem(at: queueFile)
        guard keeps else { return }
        if let waiting { queue = waiting }
        record(.appOpened)
        startRounds()
    }

    /// Every minute: the daily event when a new day has started, and a send
    /// when one is due. Started at launch with a yes, or at the yes. The first
    /// round waits a minute too, so a launch, which is busy enough, makes no
    /// request of its own.
    private func startRounds() {
        guard launched, loop == nil, let roundEvery else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: roundEvery)
                guard !Task.isCancelled else { return }
                await self?.round()
            }
        }
    }

    /// At quit: what is still waiting goes to a file, for the next launch.
    func willQuit() {
        loop?.cancel()
        loop = nil
        guard launched, keeps, !queue.isEmpty,
              let data = try? JSONEncoder.usage.encode(queue) else { return }
        try? FileManager.default.createDirectory(at: queueFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: queueFile, options: [.atomic])
    }

    /// One round: the daily event when a new day has started, then a send if
    /// one is due.
    func round() async {
        guard launched, keeps else { return }
        let at = now()
        if UsagePolicy.dayActiveIsDue(lastSent: defaults.object(forKey: Self.dayKey) as? Date, now: at),
           let snapshot = daySnapshot() {
            record(snapshot)
            defaults.set(at, forKey: Self.dayKey)
        }
        if UsagePolicy.sendIsDue(waiting: queue.count, lastTry: lastTry, now: at) {
            await send()
        }
    }

    /// Sends the oldest batch, if the answer is still yes.
    func send() async {
        guard !sending, let endpoint, keeps else { return }
        let at = now()
        let batch = queue.nextBatch(now: at)
        guard !batch.isEmpty else {
            queue.remove([], now: at)
            return
        }
        guard let body = try? UsageWire.body(install: installID, context: context(), records: batch,
                                             owner: ownerMark)
        else { return }
        sending = true
        lastTry = at
        let status = await transport.post(body, to: endpoint)
        sending = false
        // Switched off while it was out: everything is already gone.
        guard keeps else { return }
        switch UsagePolicy.outcome(status: status) {
        case .sent, .dropped: queue.remove(Set(batch.map(\.id)), now: now())
        case .kept: break
        }
    }

    /// How many are waiting. For the tests.
    var waitingCount: Int { queue.count }

    // MARK: - The owner's mark

    /// The owner's mark, if this Mac has one. Read from the file at every
    /// send, so a mark another copy kept counts at once.
    var ownerMark: String? {
        (try? String(contentsOf: ownerFile, encoding: .utf8)).flatMap(OwnerMark.valid)
    }

    /// Keeps `mark` as this Mac's, once the person has said yes to it. Kept
    /// whether or not counts are on, and in a build that cannot send: the
    /// file is the one every copy on the Mac reads.
    @discardableResult
    func keepOwnerMark(_ mark: String) -> Bool {
        guard let mark = OwnerMark.valid(mark) else { return false }
        do {
            try FileManager.default.createDirectory(at: ownerFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("\(mark)\n".utf8).write(to: ownerFile, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private

    /// This copy's id, made the first time it is needed.
    private var installID: String {
        if let id = defaults.string(forKey: Self.installKey) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Self.installKey)
        return id
    }

    /// Off: nothing waiting, no id, no file, no rounds. The owner's mark
    /// stays: it says whose Mac this is, not anything it did.
    private func forget() {
        loop?.cancel()
        loop = nil
        queue = UsageQueue()
        defaults.removeObject(forKey: Self.installKey)
        defaults.removeObject(forKey: Self.dayKey)
        try? FileManager.default.removeItem(at: queueFile)
    }

    /// The version, macOS, the Mac's model and its language, with `plan`.
    static func context(plan: AirlockPlan) -> UsageContext {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return UsageContext(
            app: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            os: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            model: SupportDiagnostics.hardwareModel(),
            language: Locale.preferredLanguages.first ?? Locale.current.identifier,
            plan: plan)
    }
}

/// A plain POST, nothing kept on disk: no cache, no cookies.
struct URLSessionUsageTransport: UsageTransport {
    static let timeout: TimeInterval = 20

    func post(_ body: Data, to url: URL) async -> Int? {
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        PretendOutage.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }
}

private extension JSONEncoder {
    static var usage: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var usage: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
