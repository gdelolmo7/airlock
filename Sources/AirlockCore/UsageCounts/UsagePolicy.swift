import Foundation

/// When usage counts are kept and sent. Pure, so the rules are tested
/// without a network or a timer.
///
/// **Only for people who say yes** (the owner's call, 2026-10-17). The answer
/// is off until the person turns it on: on the first screen of setup for a
/// new copy, on a question the notch puts once to a copy that finished setup
/// before counts existed, or in Settings › General. Nothing is counted before
/// that yes, and turned off, the waiting events and the install id are
/// thrown away and nothing more is kept.
///
/// **Nothing is sent without somewhere to send it.** The address is the
/// licence server's, which the packaging script writes into the bundle only
/// when it is given one, so `swift run`, the tests, a development package and
/// anybody building the public source never send and never show the switch.
public enum UsagePolicy {
    /// The person's answer, read as a tri-state: absent is no.
    public static func isOn(stored: Bool?) -> Bool { stored ?? false }

    /// Where counts go: the licence server's `/usage`, https only.
    public static func endpoint(apiBase: URL?) -> URL? {
        guard let apiBase, apiBase.scheme?.lowercased() == "https",
              let host = apiBase.host, !host.isEmpty else { return nil }
        return apiBase.appendingPathComponent("usage")
    }

    /// Whether events are kept and sent at all: there is somewhere to send
    /// them and the answer is yes.
    public static func keeps(endpoint: URL?, isOn: Bool) -> Bool {
        endpoint != nil && isOn
    }

    /// Whether to put the question once, in the notch: a build that could
    /// send, an answer still off, and nobody asked yet (setup's first screen
    /// counts as asking).
    public static func asks(available: Bool, isOn: Bool, alreadyAsked: Bool) -> Bool {
        available && !isOn && !alreadyAsked
    }

    /// A send is due this often while anything is waiting.
    public static let sendEvery: TimeInterval = 10 * 60
    /// ...or as soon as this many are waiting.
    public static let sendAtCount = 50
    /// The most one request carries. The server refuses more.
    public static let batchLimit = 100
    /// The most kept while nothing can be sent; the oldest go first.
    public static let queueLimit = 500
    /// A batch older than this is not worth sending.
    public static let oldestKept: TimeInterval = 30 * 24 * 3600

    public static func sendIsDue(waiting: Int, lastTry: Date?, now: Date) -> Bool {
        guard waiting > 0 else { return false }
        if waiting >= sendAtCount { return true }
        guard let lastTry else { return true }
        return now.timeIntervalSince(lastTry) >= sendEvery
    }

    /// What to do with a batch once the server answered (`status`), or did
    /// not (nil).
    public enum Outcome: Equatable, Sendable {
        /// Delivered: forget it.
        case sent
        /// The server will never take it (it was malformed): forget it too,
        /// or it blocks every batch behind it forever.
        case dropped
        /// Try again at the next send.
        case kept
    }

    public static func outcome(status: Int?) -> Outcome {
        guard let status else { return .kept }
        switch status {
        case 200..<300: return .sent
        case 429, 500...: return .kept
        default: return .dropped
        }
    }

    /// The once-a-day event is due: never sent, or last sent on another day.
    public static func dayActiveIsDue(lastSent: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastSent else { return true }
        return !calendar.isDate(lastSent, inSameDayAs: now)
    }
}

/// One kept event: what happened, when, and an id the server passes on so a
/// batch sent twice (the reply was lost) is counted once.
public struct UsageRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let at: Date
    public let properties: [String: UsageValue]

    public init(_ event: UsageEvent, at: Date, id: UUID = UUID()) {
        self.id = id
        self.name = event.name
        self.at = at
        self.properties = event.properties
    }
}

/// The events waiting to be sent, oldest first.
public struct UsageQueue: Codable, Equatable, Sendable {
    public private(set) var records: [UsageRecord] = []

    public init(records: [UsageRecord] = []) {
        self.records = Array(records.suffix(UsagePolicy.queueLimit))
    }

    public var isEmpty: Bool { records.isEmpty }
    public var count: Int { records.count }

    /// Kept at `UsagePolicy.queueLimit`; the oldest go first.
    public mutating func append(_ record: UsageRecord) {
        records.append(record)
        if records.count > UsagePolicy.queueLimit {
            records.removeFirst(records.count - UsagePolicy.queueLimit)
        }
    }

    /// The next request's worth, oldest first, leaving out anything too old
    /// to be worth sending.
    public func nextBatch(now: Date) -> [UsageRecord] {
        Array(records.lazy.filter { now.timeIntervalSince($0.at) <= UsagePolicy.oldestKept }
            .prefix(UsagePolicy.batchLimit))
    }

    /// After a send: the batch's records go, and so does anything too old,
    /// which no batch will ever carry.
    public mutating func remove(_ ids: Set<UUID>, now: Date) {
        records.removeAll { ids.contains($0.id) || now.timeIntervalSince($0.at) > UsagePolicy.oldestKept }
    }
}

/// Facts about the copy that every batch carries once, rather than every
/// event: the version, the Mac, the language and the plan. Words only, put
/// through the same door as an event's (`UsageEvent.word`).
public struct UsageContext: Equatable, Sendable {
    public let app: String
    public let build: String
    public let os: String
    public let model: String
    public let language: String
    public let plan: String

    public init(app: String, build: String, os: String, model: String, language: String,
                plan: AirlockPlan) {
        self.app = UsageEvent.word(app)
        self.build = UsageEvent.word(build)
        self.os = UsageEvent.word(os)
        self.model = UsageEvent.word(model)
        // The language, not the locale: "es", never "es_ES@calendar=…".
        let code = Locale(identifier: language).language.languageCode?.identifier ?? language
        self.language = UsageEvent.word(code)
        self.plan = plan.rawValue
    }
}

/// The request body `/usage` takes. Kept beside the Worker's own check of
/// it, which refuses anything that does not look like this.
public enum UsageWire {
    public static func body(install: String, context: UsageContext, records: [UsageRecord]) throws -> Data {
        let body = Body(install: install,
                        context: .init(app: context.app, build: context.build, os: context.os,
                                       model: context.model, lang: context.language, plan: context.plan),
                        events: records.map { .init(id: $0.id.uuidString.lowercased(), name: $0.name,
                                                    at: $0.at, props: $0.properties) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    private struct Body: Encodable {
        let install: String
        let context: Context
        let events: [Event]
    }

    private struct Context: Encodable {
        let app, build, os, model, lang, plan: String
    }

    private struct Event: Encodable {
        let id: String
        let name: String
        let at: Date
        let props: [String: UsageValue]
    }
}
