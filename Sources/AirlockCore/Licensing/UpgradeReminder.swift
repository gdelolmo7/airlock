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
    /// A week on Free without meeting a limit: what Plus would add to the
    /// parts of Airlock this Mac uses. Once, ever, and only to somebody who
    /// has had no other reminder, since those already said it about
    /// something that happened.
    case firstWeek(uses: Set<Use>)

    /// What "Not now" quiets, and what "at most once a week" counts.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case clipboard, agents, recap, week
    }

    /// A part of Airlock that Plus does more of, for the week's card.
    public enum Use: String, CaseIterable, Sendable {
        case callNotes, agents, clipboard

        /// What Plus would change about it, as the end of "On Plus, …". No
        /// commas inside, since up to three are listed in one sentence.
        var onPlus: String {
            switch self {
            case .callNotes: "call notes would cover whole calls"
            case .agents: "every coding agent could ask you here at the same time"
            case .clipboard: "the clipboard would keep up to \(UpgradeReminder.plusClipboard) copies"
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .clipboardFull: .clipboard
        case .agentInTerminal: .agents
        case .monthlyRecap: .recap
        case .firstWeek: .week
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
        case .firstWeek:
            "A week with Airlock"
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
        case let .firstWeek(uses):
            "On Plus, " + Self.list(Use.allCases.filter(uses.contains).map(\.onPlus)) + "."
        }
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ parts: [String]) -> String {
        guard let last = parts.last else { return "" }
        let rest = parts.dropLast()
        return rest.isEmpty ? last : rest.joined(separator: ", ") + " and " + last
    }

    /// Under the recap's lines.
    public static let recapClosing = "Plus would have kept all of it."

    /// Beside the buttons, where "Not now" means something: the clipboard's
    /// and the week's cards never come back anyway.
    public var notNowHint: String? {
        kind == .clipboard || kind == .week ? nil : "“Not now” hides this for \(UpgradeReminders.notNowDays) days"
    }

    // MARK: - The quiet lines

    /// Always under a full clipboard on Free, card or no card. Pinned items
    /// sit outside the limit, and the count beside this line includes them,
    /// so the line says so rather than leave "101 items" looking like a miscount.
    public static var clipboardLine: String {
        "Free keeps your last \(PlanLimits.freeClipboard), not counting pinned items. "
            + "Plus keeps up to \(plusClipboard)."
    }

    /// On an agent's row while it asks in its terminal because another had
    /// the notch. "This one" rather than the project's name: the row already
    /// says which, and a name like "website" read as "so website is asking".
    public static let agentLine = "Free answers one agent at a time, so this one is asking in its terminal. "
        + "Plus answers every agent here."

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
    /// How long after the first open on Free the week's card may show.
    public static let firstWeekDays = 7

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
    /// The first time the panel opened on Free, which starts the week's card.
    /// Nil in preferences from before it, so a copy already on Free starts
    /// its week the first time it opens after updating.
    public private(set) var firstOpenOnFree: Date?

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

    /// The panel opened on Free. Only the first time counts.
    public mutating func openedOnFree(now: Date) {
        if firstOpenOnFree == nil { firstOpenOnFree = now }
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
    /// waiting on the notch; `uses` the parts of Airlock this Mac uses now,
    /// for the week's card.
    public func due(onFree: Bool, callOn: Bool, agentAsking: Bool, uses: Set<UpgradeReminder.Use> = [],
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
        // Last, and only to somebody nothing has said Plus to yet: no
        // reminder and no "You're on Free now" card, ever. With nothing in
        // use there is nothing true to say, so it waits for something.
        if lastShown == nil, !uses.isEmpty, let first = firstOpenOnFree,
           let weekOn = calendar.date(byAdding: .day, value: Self.firstWeekDays, to: first), now >= weekOn {
            return .firstWeek(uses: uses)
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
