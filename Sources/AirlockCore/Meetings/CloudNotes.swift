import CryptoKit
import Foundation

/// Notes written online for a subscriber, by a larger model than the Mac's.
///
/// The app never holds a model's key: it sends the numbered transcript and
/// the rules (`CallNotesPrompts.cloud`) to Airlock's server with the
/// subscriber's licence token, and the server asks the model. What comes
/// back is read here and checked exactly as the Mac's own lines are
/// (`MeetingLedger`): a line that cites no line of the transcript is
/// dropped, an owner nobody heard is taken off, a due date nobody said is
/// left out. Any failure, of any kind, leaves the notes to the Mac.
///
/// Here, not in the App, so reading the answer, the routing and the
/// wording are tested without a network.
public enum CloudNotes {
    /// What the model is told it may list at most; more is cut here too.
    public static let decisionLimit = 8
    public static let todoLimit = 15
    public static let questionLimit = 8
    public static let keyPointLimit = 5

    /// The most the server takes, in UTF-16 units (what it counts):
    /// 10,000 for the instructions and 400,000 for the prompt. A meeting
    /// is sent only when its prompt is within `promptLimit`, kept a little
    /// under the server's so a count that differs by a few never costs a
    /// refused request; a longer one is written on the Mac.
    public static let instructionsLimit = 10_000
    public static let promptLimit = 390_000

    /// The size the server measures.
    public static func size(_ text: String) -> Int { text.utf16.count }

    /// Whether a failed request never left the Mac: no network, so it cost
    /// nothing, and the meeting can be written online once back online.
    /// A timeout or a dropped connection may have reached the server, and
    /// is not one: a call that may have cost money is never made again.
    public static func neverLeft(_ code: URLError.Code) -> Bool {
        [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff,
         .cannotFindHost, .dnsLookupFailed].contains(code)
    }

    /// The model's answer, read but not yet checked.
    public struct Draft: Equatable, Sendable {
        public var summary: String
        /// Decisions, to-dos and open questions; no topics.
        public var lines: MeetingDraft
        public var keyPoints: [MeetingDraft.Fact]
        /// The meeting's name as written, not yet cleaned.
        public var title: String

        public init(summary: String = "", lines: MeetingDraft = MeetingDraft(),
                    keyPoints: [MeetingDraft.Fact] = [], title: String = "") {
            self.summary = summary
            self.lines = lines
            self.keyPoints = keyPoints
            self.title = title
        }
    }

    // MARK: - Reading the answer

    /// The answer read as notes, or nil when it is not the JSON asked for.
    ///
    /// Read leniently, since every slip seen from a model is a small one:
    /// the JSON fenced as code or with a line before it, a source written
    /// as the line's whole prefix ("[S12 4:05 You]") or as a bare number
    /// (12, or "12"), sources as one string, a missing list, a null owner.
    /// Only the line number of a source is read (`NumberedTranscript.id`).
    public static func parse(_ text: String) -> Draft? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let known = ["summary", "decisions", "todos", "questions", "keyPoints", "key_points"]
        guard known.contains(where: { object[$0] != nil }) else { return nil }

        let todos = list(object["todos"]).compactMap { entry -> MeetingDraft.Todo? in
            guard let item = entry as? [String: Any] else { return nil }
            let task = string(item["task"]) ?? string(item["text"]) ?? ""
            return MeetingDraft.Todo(task: task, owner: string(item["owner"]) ?? "",
                                     due: string(item["due"]) ?? "", sources: sources(item["sources"]))
        }
        return Draft(summary: string(object["summary"]) ?? "",
                     lines: MeetingDraft(decisions: facts(object["decisions"]), todos: todos,
                                         questions: facts(object["questions"])),
                     keyPoints: facts(object["keyPoints"] ?? object["key_points"]),
                     title: string(object["title"]) ?? "")
    }

    private static func list(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private static func facts(_ value: Any?) -> [MeetingDraft.Fact] {
        list(value).compactMap { entry in
            if let text = entry as? String { return MeetingDraft.Fact(text: text, sources: []) }
            guard let item = entry as? [String: Any] else { return nil }
            return MeetingDraft.Fact(text: string(item["text"]) ?? "", sources: sources(item["sources"]))
        }
    }

    /// A string, or a number written as one; nil for null and anything else.
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return number.stringValue
        default: return nil
        }
    }

    /// Sources as the ledger reads them: a list of strings or numbers, or
    /// one string that may hold several ("S3, S4").
    private static func sources(_ value: Any?) -> [String] {
        if let one = string(value) {
            return one.split(whereSeparator: { $0 == "," || $0 == ";" }).map(String.init)
        }
        return list(value).compactMap(string)
    }

    // MARK: - Checking it

    /// The notes from a draft, every line checked against the transcript
    /// as the Mac's are (`MeetingLedger.add`), with the whole transcript
    /// shown: the model read all of it. Key points must cite a line too,
    /// and one that only says a decision, to-do or question again goes
    /// (`MeetingLedger.saysAgain`). The summary is cut to three sentences.
    public static func notes(from draft: Draft, record: MeetingRecord)
        -> (notes: MeetingNotes, tally: MeetingLedger.Tally) {
        var ledger = MeetingLedger(record: record)
        let shown = Set(ledger.transcript.turns.map(\.id))
        let lines = MeetingDraft(decisions: Array(draft.lines.decisions.prefix(decisionLimit)),
                                 todos: Array(draft.lines.todos.prefix(todoLimit)),
                                 questions: Array(draft.lines.questions.prefix(questionLimit)))
        var tally = ledger.add(lines, shown: shown)
        tally.dropped += draft.lines.decisions.count + draft.lines.todos.count + draft.lines.questions.count
            - lines.decisions.count - lines.todos.count - lines.questions.count

        let lined = ledger.notes()
        let listed = (lined.todos + lined.decisions + lined.questions).map(\.text)
        var points: [MeetingNotes.Item] = []
        for draft in draft.keyPoints {
            guard points.count < keyPointLimit, var point = ledger.checked(draft, shown: shown),
                  !listed.contains(where: { MeetingLedger.saysAgain(point.text, $0) }),
                  !points.contains(where: { MeetingText.key($0.text) == MeetingText.key(point.text) })
            else {
                tally.dropped += 1
                continue
            }
            point.at = ledger.transcript.turn(point.sources[0])?.start
            points.append(point)
            tally.kept += 1
        }
        var notes = ledger.notes(summary: draft.summary, keyPoints: points)
        notes.title = draft.title
        return (notes, tally)
    }

    // MARK: - The server

    /// What is sent: the token, the rules and the question. Never a key.
    public static func requestBody(token: String, instructions: String, prompt: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["token": token, "instructions": instructions,
                                                      "prompt": prompt],
                                     options: [.sortedKeys])) ?? Data()
    }

    /// What the server said, read from its status and body.
    public enum Reply: Equatable, Sendable {
        /// 200: the model's answer, as text to `parse`.
        case notes(text: String, model: String?, usedFraction: Double?)
        /// 402: this month's online notes are used, until `resetsAt`.
        case allowanceUsed(resetsAt: Date?)
        /// 403: this licence can't have notes online.
        case notEligible
        /// 401: the token wasn't accepted.
        case badToken
        /// 413: the meeting is too long to send.
        case tooLarge
        /// 5xx, a timeout, or an answer that can't be read.
        case unavailable
        /// The request never left: no network. Not from the server; the
        /// app tells this one apart from its own error.
        case offline

        public static func read(status: Int, body: Data) -> Reply {
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            switch status {
            case 200:
                let text: String?
                if let notes = object["notes"] as? String {
                    text = notes
                } else if let notes = object["notes"], JSONSerialization.isValidJSONObject(notes),
                          let data = try? JSONSerialization.data(withJSONObject: notes) {
                    // Already read by the server: put back as text, read the same way.
                    text = String(data: data, encoding: .utf8)
                } else {
                    text = nil
                }
                guard let text else { return .unavailable }
                let used = (object["usedFraction"] as? NSNumber)?.doubleValue
                return .notes(text: text, model: object["model"] as? String,
                              usedFraction: used.map { min(1, max(0, $0)) })
            case 401: return .badToken
            case 402: return .allowanceUsed(resetsAt: CloudNotesAllowance.date(object["resetsAt"] as? String))
            case 403: return .notEligible
            case 413: return .tooLarge
            default: return .unavailable
            }
        }

        /// For the log: the kind only, never the text.
        public var logName: String {
            switch self {
            case .notes: return "notes"
            case .allowanceUsed: return "month's allowance used"
            case .notEligible: return "not eligible"
            case .badToken: return "token refused"
            case .tooLarge: return "too large"
            case .unavailable: return "unavailable"
            case .offline: return "offline"
            }
        }
    }
}

// MARK: - Routing

/// What decides where a meeting's notes are written.
public struct CloudNotesConditions: Equatable, Sendable {
    /// `meetings.cloudNotes.enabled`: on unless set to false (from 1.0.20).
    public var hiddenSwitch: Bool
    /// "Write notes online" in Settings: nil until the switch is touched,
    /// which counts as on. Only false keeps a subscriber's notes on the Mac.
    public var setting: Bool?
    public var entitlement: Entitlement
    public var hasToken: Bool
    /// The licence server's address, built into the app.
    public var hasServer: Bool
    public var online: Bool
    /// Words said in the meeting (`NumberedTranscript.wordCount`).
    public var words: Int
    /// The prompt's size as the server counts it (`CloudNotes.size`).
    public var promptSize: Int
    /// Until when this month's online notes are used (a 402).
    public var allowanceUntil: Date?
    /// Until when the server's "not eligible" is believed (a 403).
    public var notEligibleUntil: Date?
    public var now: Date

    public init(hiddenSwitch: Bool, setting: Bool?, entitlement: Entitlement, hasToken: Bool,
                hasServer: Bool, online: Bool, words: Int, promptSize: Int = 0, allowanceUntil: Date? = nil,
                notEligibleUntil: Date? = nil, now: Date) {
        self.hiddenSwitch = hiddenSwitch
        self.setting = setting
        self.entitlement = entitlement
        self.hasToken = hasToken
        self.hasServer = hasServer
        self.online = online
        self.words = words
        self.promptSize = promptSize
        self.allowanceUntil = allowanceUntil
        self.notEligibleUntil = notEligibleUntil
        self.now = now
    }
}

/// Where a meeting's notes are written: online, or on the Mac and why.
public enum CloudNotesRoute: Equatable, Sendable {
    case online
    case mac(Reason)

    public enum Reason: Equatable, Sendable {
        /// Notes online aren't switched on on this Mac: today's notes, untouched.
        case hiddenSwitchOff
        /// "Write notes online" switched off in Settings.
        case settingOff
        /// A trial, a free copy, or a subscription that has run out.
        case notSubscribed
        case noToken
        /// This build has no licence server.
        case noServer
        /// Too little was said for notes at all (`MeetingNotes.minimumWords`).
        case tooShort
        /// Too long to send (`CloudNotes.promptLimit`).
        case tooLong
        /// The server said this licence can't have them, a little while ago.
        case notEligible(until: Date)
        /// This month's online notes are used.
        case allowanceUsed(until: Date)
        case offline

        /// For the log.
        public var logName: String {
            switch self {
            case .hiddenSwitchOff: return "switched off"
            case .settingOff: return "switched off in Settings"
            case .notSubscribed: return "not a subscriber"
            case .noToken: return "no licence token"
            case .noServer: return "no server in this build"
            case .tooShort: return "too little said"
            case .tooLong: return "too long to send"
            case .notEligible: return "not eligible, remembered"
            case .allowanceUsed: return "month's allowance used"
            case .offline: return "offline"
            }
        }
    }

    /// Online only when every condition holds; otherwise the first one that
    /// doesn't, in this order. Nobody is asked: a subscriber's notes go
    /// online unless "Write notes online" was switched off in Settings.
    public static func decide(_ conditions: CloudNotesConditions) -> CloudNotesRoute {
        let now = conditions.now
        guard conditions.hiddenSwitch else { return .mac(.hiddenSwitchOff) }
        guard conditions.setting != false else { return .mac(.settingOff) }
        guard conditions.entitlement.isPaid else { return .mac(.notSubscribed) }
        guard conditions.hasToken else { return .mac(.noToken) }
        guard conditions.hasServer else { return .mac(.noServer) }
        guard conditions.words >= MeetingNotes.minimumWords else { return .mac(.tooShort) }
        guard conditions.promptSize <= CloudNotes.promptLimit else { return .mac(.tooLong) }
        if let until = conditions.notEligibleUntil, until > now { return .mac(.notEligible(until: until)) }
        if let until = conditions.allowanceUntil, until > now { return .mac(.allowanceUsed(until: until)) }
        guard conditions.online else { return .mac(.offline) }
        return .online
    }

    /// Notes the Mac writes for this reason are written online once the
    /// Mac is back online. Only for being offline: every other reason is one
    /// the Mac being online again doesn't change.
    public var waitsForOnline: Bool { self == .mac(.offline) }
}

// MARK: - The month's allowance

/// What is said when this month's online notes are used (a 402), and when.
public enum CloudNotesAllowance {
    /// How long a 403 ("not eligible") is believed before asking again, for
    /// the same licence token (`notEligibleUntil`). A licence that buys no
    /// online notes, a 100%-off friend's, would otherwise send a meeting to
    /// the server to be refused every day. A new token, renewed or bought,
    /// asks again at once.
    public static let notEligibleFor: TimeInterval = 30 * 86_400

    /// A short mark of a licence token, kept beside a 403 so the refusal is
    /// tied to the licence it was for. Not the token: it can't be read back.
    public static func tokenMark(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The 403 kept on this Mac, believed only for the token it came with:
    /// nil for any other token, for none, or for one kept without a mark.
    public static func notEligibleUntil(saved: Date?, savedMark: String?, token: String?) -> Date? {
        guard let saved, let savedMark, let token, savedMark == tokenMark(token) else { return nil }
        return saved
    }

    /// The server's date: ISO 8601 with or without fractions of a second,
    /// or a day alone ("2026-11-01").
    public static func date(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: text) { return date }
        full.formatOptions = [.withFullDate]
        return full.date(from: text)
    }

    /// Until when no notes are asked of the server: its `resetsAt`, the
    /// time to try again, whatever it is (the latest one sent wins).
    /// Without one, the first day of next month. One already past, from a
    /// clock that is off, waits an hour, so a refusal is never asked again
    /// straight away.
    public static func until(resetsAt: Date?, now: Date, calendar: Calendar = .current) -> Date {
        if let resetsAt { return resetsAt > now ? resetsAt : now.addingTimeInterval(3_600) }
        return calendar.dateInterval(of: .month, for: now)?.end ?? now.addingTimeInterval(30 * 86_400)
    }

    /// The day and month, the way the person's Mac writes them: "1 November",
    /// or "November 1" where that is the way.
    public static func day(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMMM")
        return formatter.string(from: date)
    }

    /// Whether the notice offers a bigger plan: "Upgrade for more." and an
    /// Upgrade button to the website's plans. Off because there is no higher
    /// plan to move to yet; turning it on brings both back as they were.
    public static let offersUpgrade = false

    /// Said where the notes say they are ready, never as an error.
    public static func message(until: Date, locale: Locale = .current, timeZone: TimeZone = .current,
                               offersUpgrade: Bool = CloudNotesAllowance.offersUpgrade) -> String {
        "You've used this month's online notes. Notes are written on your Mac until "
            + "\(day(until, locale: locale, timeZone: timeZone))." + (offersUpgrade ? " Upgrade for more." : "")
    }

    /// The button beside the notice, only while `offersUpgrade` is on.
    public static let upgradeButton = "Upgrade"

    /// Whether to say it: once a month, however many times the server
    /// refuses in it and whatever dates it sends.
    public static func noticeDue(lastShown: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastShown else { return true }
        return !calendar.isDate(lastShown, equalTo: now, toGranularity: .month)
    }
}

// MARK: - The switch in Settings

/// "Write notes online" in Settings, for subscribers: on until it is
/// switched off. Nothing asks under the notes; this row says where the
/// transcript goes, and is the way to keep it on the Mac.
public enum CloudNotesSetting {
    public static let title = "Write notes online"
    public static let subtitle = "When a meeting ends, its transcript goes through Airlock's server to "
        + "Google's Gemini to write better notes. Neither Airlock nor Google keeps it, and it isn't used to "
        + "train AI. Off, or without internet, notes are written on this Mac."

    /// On unless switched off: an untouched switch is on.
    public static func isOn(_ setting: Bool?) -> Bool { setting != false }
}

// MARK: - Written again once online

/// The meetings whose notes the Mac wrote while offline, written online
/// when the network comes back: newest first, a few at a time, each sent
/// once at most, so it can never become a loop. Only those: a meeting the
/// server has answered for (an error, a refusal, notes that didn't hold
/// up) is never sent again, since a failed call may already have cost money.
public enum CloudNotesRedo {
    /// Meetings written again each time the network comes back.
    public static let perReturn = 3
    /// Times one meeting is sent. Counted before it is, so a request cut
    /// short by a quit is not made again either.
    public static let maxTries = 1

    /// The meetings to write again now, newest first, at most `perReturn`:
    /// finished meetings still waiting that have not been sent.
    public static func waiting(_ calls: [(folder: URL, record: MeetingRecord)])
        -> [(folder: URL, record: MeetingRecord)] {
        let waiting = calls.filter { call in
            guard let writer = call.record.notesWriter, call.record.endedAt != nil else { return false }
            return writer.waitsForOnline && writer.onlineTries < maxTries
        }
        return Array(waiting.sorted { $0.record.startedAt > $1.record.startedAt }.prefix(perReturn))
    }

    /// Whether a change in the network is a reason to look: only coming
    /// online, from offline or from not knowing yet (the app starting).
    public static func shouldStart(wasOnline: Bool?, isOnline: Bool) -> Bool {
        isOnline && wasOnline != true
    }

    /// What to do with a waiting meeting, from where its notes would go now.
    public enum Step: Equatable, Sendable {
        /// Send it.
        case send
        /// Never: its Mac notes stay, and it stops waiting.
        case leave
        /// Not now: it keeps waiting, and so do the rest.
        case stop
    }

    public static func step(for route: CloudNotesRoute) -> Step {
        switch route {
        case .online: return .send
        // Nothing about this meeting will change.
        case .mac(.tooShort), .mac(.tooLong): return .leave
        // Offline again, this month's notes used, switched off, no longer
        // a subscriber: maybe later.
        case .mac: return .stop
        }
    }

    /// The writer once a sent meeting came back without notes: still
    /// waiting, its try given back, only when the request never left the
    /// Mac (`CloudNotes.neverLeft`); otherwise left as the Mac's.
    public static func afterFailedTry(_ writer: MeetingNotesWriter, neverLeft: Bool) -> MeetingNotesWriter {
        var writer = writer
        if neverLeft {
            writer.onlineTries = max(0, writer.onlineTries - 1)
        } else {
            writer.waitsForOnline = false
        }
        return writer
    }
}
