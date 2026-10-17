import Foundation

/// One of the gentle reminders Free gets in the notch now and then.
///
/// **Each names one real thing Plus would have done, about something that just
/// happened on this Mac**, never a bare "Upgrade". A reminder that could be
/// shown to anybody is an advert; one that says "api-server asked in its
/// terminal" is news about their own afternoon.
///
/// When one is due is `UpgradeReminders.due`, never the view's choice.
public enum UpgradeReminder: Equatable, Sendable {
    /// The clipboard let its first copy go for Free's limit. Once, ever.
    case clipboardFull
    /// An agent asked while another had the notch, so it asked in its own
    /// terminal. At most once a week. `answering` is the one on the notch,
    /// when it had a different name.
    case agentInTerminal(asking: String, answering: String?)
    /// What last month on Free let go. At most once a month.
    case monthlyRecap(FreeMonth)

    /// What "Not now" quiets, and what "at most once a week" counts.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case clipboard, agents, recap
    }

    public var kind: Kind {
        switch self {
        case .clipboardFull: .clipboard
        case .agentInTerminal: .agents
        case .monthlyRecap: .recap
        }
    }

    public var title: String {
        switch self {
        case .clipboardFull:
            "Your clipboard is full"
        case let .agentInTerminal(asking, _):
            "\(asking) asked in its terminal"
        case let .monthlyRecap(month):
            month.title
        }
    }

    /// The sentence under the title; nil for the recap, which is its lines.
    public var message: String? {
        switch self {
        case .clipboardFull:
            "Free keeps your last \(PlanLimits.freeClipboard) copies, so the oldest ones now make "
                + "room for new ones. Plus keeps up to \(Self.plusClipboard)."
        case let .agentInTerminal(asking, answering):
            (answering.map { "While \($0) was on the notch, " } ?? "Free answers one agent at a time, so ")
                + "\(asking)'s question went to its terminal. On Plus, every agent can ask you here."
        case .monthlyRecap:
            nil
        }
    }

    /// Under the recap's lines.
    public static let recapClosing = "Plus would have kept all of it."

    /// Beside the buttons, where "Not now" means something: the clipboard's
    /// card never comes back anyway.
    public var notNowHint: String? {
        kind == .clipboard ? nil : "“Not now” hides this for \(UpgradeReminders.notNowDays) days"
    }

    // MARK: - The quiet lines

    /// Always under a full clipboard on Free, card or no card.
    public static var clipboardLine: String {
        "Free keeps your last \(PlanLimits.freeClipboard). Plus keeps up to \(plusClipboard)."
    }

    /// On an agent's row while it asks in its terminal because another had
    /// the notch.
    public static func agentLine(asking: String) -> String {
        "Free answers one agent at a time, so \(asking) is asking in its terminal. "
            + "Plus answers every agent here."
    }

    /// The most a clipboard keeps on Plus: the top of the person's own setting.
    static var plusClipboard: String { PlanCatalog.thousands(ClipboardHistory.capacityRange.upperBound) }
}

/// What one month on Free let go, for the recap at the start of the next.
///
/// Three figures, each a thing Plus would have kept, counted when it happened:
/// a figure worked out later from what is left would count nothing, because
/// what Free let go is exactly what is no longer there.
public struct FreeMonth: Codable, Equatable, Sendable {
    /// The first moment of the month, in the calendar it was counted in.
    public let month: Date
    /// Calls whose notes stopped at Free's limit.
    public var callsStopped: Int
    /// Clipboard copies let go for Free's limit.
    public var copiesLetGo: Int
    /// Agents that asked in their terminal because another had the notch.
    public var agentsInTerminal: Int

    public init(month: Date, callsStopped: Int = 0, copiesLetGo: Int = 0, agentsInTerminal: Int = 0) {
        self.month = month
        self.callsStopped = callsStopped
        self.copiesLetGo = copiesLetGo
        self.agentsInTerminal = agentsInTerminal
    }

    /// Whether there is anything to say. A month that let nothing go gets no
    /// recap: "0 calls stopped" is an argument for staying on Free.
    public var isWorthShowing: Bool { callsStopped + copiesLetGo + agentsInTerminal > 0 }

    /// "Your October on Free". The month in English whatever the Mac's
    /// region, like the sentence around it.
    public var title: String { title(timeZone: .current) }

    public func title(timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(locale: Locale(identifier: "en_GB"), timeZone: timeZone)
        style = style.month(.wide)
        return "Your \(month.formatted(style)) on Free"
    }

    /// The recap's rows, skipping any that never happened.
    public var lines: [(count: Int, label: String)] {
        var lines: [(Int, String)] = []
        let minutes = Int(PlanLimits.freeNotesListen / 60)
        if callsStopped > 0 {
            lines.append((callsStopped, "\(callsStopped == 1 ? "call" : "calls") had notes stop at \(minutes) minutes"))
        }
        if copiesLetGo > 0 {
            lines.append((copiesLetGo,
                          "older \(copiesLetGo == 1 ? "copy" : "copies") let go from the clipboard"))
        }
        if agentsInTerminal > 0 {
            lines.append((agentsInTerminal,
                          "agent \(agentsInTerminal == 1 ? "question" : "questions") went to the terminal"))
        }
        return lines
    }
}

/// When Free's reminders show, kept in the preferences.
///
/// **At most one a day, counting every kind together** (and the "You're on
/// Free now" card), **and never in the way**: not during a call, not while an
/// agent is asking, never with a sound, never instead of the widgets. "Not
/// now" quiets that kind for `notNowDays`.
///
/// Pure, like `CloudNotesAllowance.noticeDue`: the app says what happened as
/// it happens, asks `due` when the panel opens, and says `shown` once it is
/// on screen. Every date comes in, so the tests own the clock.
public struct UpgradeReminders: Codable, Equatable, Sendable {
    /// How long "Not now" quiets a kind.
    public static let notNowDays = 14
    /// The agents' card shows at most this often.
    public static let agentsEveryDays = 7

    /// The last reminder of any kind, or the "You're on Free now" card.
    public private(set) var lastShown: Date?
    /// The last time each kind showed, by `Kind.rawValue`.
    public private(set) var shownAt: [String: Date] = [:]
    /// Until when "Not now" quiets each kind, by `Kind.rawValue`.
    public private(set) var quietUntil: [String: Date] = [:]
    /// The first time the clipboard let a copy go for Free's limit.
    public private(set) var clipboardFilled: Date?
    /// The last agent that asked in its terminal because another had the notch.
    public private(set) var lastInTerminal: InTerminal?
    /// The month being counted, and the one before it.
    public private(set) var thisMonth: FreeMonth?
    public private(set) var lastMonth: FreeMonth?

    public struct InTerminal: Codable, Equatable, Sendable {
        public let asking: String
        public let answering: String?
        public let at: Date
    }

    public init() {}

    // MARK: - What happened

    /// The clipboard let `count` copies go for Free's limit.
    public mutating func copiesLetGo(_ count: Int, now: Date, calendar: Calendar = .current) {
        guard count > 0 else { return }
        if clipboardFilled == nil { clipboardFilled = now }
        tally(now, calendar) { $0.copiesLetGo += count }
    }

    /// An agent asked in its terminal because another had the notch. Names
    /// are the projects'; the same name twice says nothing, so it is dropped.
    public mutating func agentAskedInTerminal(asking: String, answering: String?,
                                              now: Date, calendar: Calendar = .current) {
        lastInTerminal = InTerminal(asking: asking,
                                    answering: answering == asking ? nil : answering, at: now)
        tally(now, calendar) { $0.agentsInTerminal += 1 }
    }

    /// A call's notes stopped at Free's limit.
    public mutating func notesStopped(now: Date, calendar: Calendar = .current) {
        tally(now, calendar) { $0.callsStopped += 1 }
    }

    private mutating func tally(_ now: Date, _ calendar: Calendar, _ add: (inout FreeMonth) -> Void) {
        let start = calendar.dateInterval(of: .month, for: now)?.start ?? now
        if let current = thisMonth, !calendar.isDate(current.month, equalTo: start, toGranularity: .month) {
            lastMonth = current
            thisMonth = nil
        }
        var month = thisMonth ?? FreeMonth(month: start)
        add(&month)
        thisMonth = month
    }

    // MARK: - Showing

    /// The reminder to show now, if any. `onFree` is the plan now; `callOn`
    /// any call or notes in the room; `agentAsking` a card or question
    /// waiting on the notch.
    public func due(onFree: Bool, callOn: Bool, agentAsking: Bool,
                    now: Date, calendar: Calendar = .current) -> UpgradeReminder? {
        guard onFree, !callOn, !agentAsking else { return nil }
        if let lastShown, calendar.isDate(lastShown, inSameDayAs: now) { return nil }

        if clipboardFilled != nil, shownAt[UpgradeReminder.Kind.clipboard.rawValue] == nil,
           !isQuiet(.clipboard, now: now) {
            return .clipboardFull
        }
        if let asked = lastInTerminal, calendar.isDate(asked.at, inSameDayAs: now),
           !isQuiet(.agents, now: now) {
            let last = shownAt[UpgradeReminder.Kind.agents.rawValue]
            let weekOn = last.flatMap { calendar.date(byAdding: .day, value: Self.agentsEveryDays, to: $0) }
            if last.map({ asked.at > $0 }) ?? true, weekOn.map({ now >= $0 }) ?? true {
                return .agentInTerminal(asking: asked.asking, answering: asked.answering)
            }
        }
        if let month = recapMonth(now: now, calendar: calendar), month.isWorthShowing,
           !isQuiet(.recap, now: now),
           !(shownAt[UpgradeReminder.Kind.recap.rawValue].map {
               calendar.isDate($0, equalTo: now, toGranularity: .month)
           } ?? false) {
            return .monthlyRecap(month)
        }
        return nil
    }

    /// The month just before `now`'s, if it was counted.
    func recapMonth(now: Date, calendar: Calendar) -> FreeMonth? {
        guard let before = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
        return [thisMonth, lastMonth].compactMap { $0 }
            .first { calendar.isDate($0.month, equalTo: before, toGranularity: .month) }
    }

    /// It is on screen: nothing else today, and this kind starts its count.
    public mutating func shown(_ reminder: UpgradeReminder, now: Date) {
        lastShown = now
        shownAt[reminder.kind.rawValue] = now
    }

    /// Another card about the plan showed ("You're on Free now"): it is the
    /// day's one.
    public mutating func anotherCardShown(now: Date) {
        lastShown = now
    }

    /// "Not now": this kind is quiet for `notNowDays`.
    public mutating func notNow(_ kind: UpgradeReminder.Kind, now: Date, calendar: Calendar = .current) {
        quietUntil[kind.rawValue] = calendar.date(byAdding: .day, value: Self.notNowDays, to: now)
    }

    public func isQuiet(_ kind: UpgradeReminder.Kind, now: Date) -> Bool {
        quietUntil[kind.rawValue].map { now < $0 } ?? false
    }
}
