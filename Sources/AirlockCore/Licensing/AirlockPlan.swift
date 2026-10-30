import Foundation

/// Which plan this copy of Airlock is on: Free, Plus or Pro.
///
/// **Free is a plan, not a lock.** Until plans existed, a trial that ran out
/// stopped the app. Now nobody is stopped: a new install starts on Free, and a
/// trial that runs out, a subscription that ends and a key that no longer
/// checks out all land there too. What Free leaves out is `PlanLimits`, and
/// nothing else in the app gets to decide it.
public enum AirlockPlan: String, Codable, Sendable, CaseIterable {
    case free
    case plus
    case pro

    /// The plan a licence paid for.
    public init(_ paid: License.Plan) {
        switch paid {
        case .plus: self = .plus
        case .pro: self = .pro
        }
    }

    /// For people: a name, never a price.
    public var label: String {
        switch self {
        case .free: "Free"
        case .plus: "Plus"
        case .pro: "Pro"
        }
    }

    /// Smallest first. Each plan has everything the one below it has.
    var rank: Int {
        switch self {
        case .free: 0
        case .plus: 1
        case .pro: 2
        }
    }
}

/// What a plan may do. **The one table every feature asks, at the moment it
/// is used**, never when a setting is saved: a setting saved on Plus has to
/// stop doing its Plus part on Free without anybody touching it.
///
/// Only what is enforced belongs here. A row that described a limit nothing
/// applies would let the "You're on Free now" card promise a change that never
/// happens, and the card is built from this table.
public struct PlanLimits: Equatable, Sendable {
    /// Whether a call's notes are written online, by the licence server's
    /// model, rather than on this Mac.
    ///
    /// Only for money known to be flowing (`PlanSnapshot.isPaid`): a trial has
    /// everything Plus has but no token to ask with, and an overdue licence is
    /// refused by the server anyway.
    public let writesNotesOnline: Bool

    /// How many clipboard copies show, pinned ones aside; nil is the person's
    /// own setting. Copies past it from a bigger plan are kept out of sight,
    /// never deleted (`ClipboardHistory.fit`).
    public let clipboardShows: Int?

    /// Whether the notch answers one coding agent at a time. The first to ask
    /// keeps it until it ends; the others get no decision and ask in their own
    /// terminal, after the same deny rules and risk floor as everybody.
    public let oneAgentAtATime: Bool

    /// How long call notes listen to one call; nil is the whole call. Counted
    /// in time actually listened, so a clock change cannot stretch it.
    public let notesListenFor: TimeInterval?

    /// Whether a call's other side is told apart by voice, Person 1, Person 2…
    /// (`CallVoiceModel`), rather than all of it being "Them". Goes by the plan
    /// alone, like the clipboard: it runs on the Mac and costs nothing per call.
    public let tellsVoicesApart: Bool

    /// Whether the drop box offers its Plus chips: WebP copies and cutting a
    /// subject out (`DropChoice.needs`). Free sees them tagged, and a drop on
    /// one keeps the file on the shelf.
    public let dropBoxExtras: Bool

    /// Whether windows are put in place: dragged to the notch, by the
    /// shortcuts and from the menu bar's menu. Free sees the strip and the
    /// rows with a Plus tag, and nothing moves.
    public let movesWindows: Bool

    /// What Free keeps of the clipboard.
    public static let freeClipboard = 100
    /// How long Free's call notes listen.
    public static let freeNotesListen: TimeInterval = 30 * 60

    public init(writesNotesOnline: Bool, clipboardShows: Int? = nil,
                oneAgentAtATime: Bool = false, notesListenFor: TimeInterval? = nil,
                tellsVoicesApart: Bool = true, dropBoxExtras: Bool = true, movesWindows: Bool = true) {
        self.writesNotesOnline = writesNotesOnline
        self.clipboardShows = clipboardShows
        self.oneAgentAtATime = oneAgentAtATime
        self.notesListenFor = notesListenFor
        self.tellsVoicesApart = tellsVoicesApart
        self.dropBoxExtras = dropBoxExtras
        self.movesWindows = movesWindows
    }

    /// One thing a plan does that another does not, in words for people.
    public enum Difference: Equatable, Sendable {
        /// The clipboard showed more copies than Free does.
        case shorterClipboard
        /// Every agent asked from the notch; now one at a time does.
        case oneAgentAtATime
        /// Notes listened to the whole call; now to its first part.
        case shorterCallNotes
        /// The other side is one "Them". Said as what Free does and what Plus
        /// adds, never as something taken away: telling voices apart has only
        /// ever been on Plus and Pro, so no copy of Airlock had it for free.
        case voicesTogether
        /// The drop box makes no WebP copies and removes no backgrounds. Said, like
        /// `voicesTogether`, as what Plus adds.
        case dropBoxBasics
        /// Windows are not put in place from the notch or the keyboard. Said,
        /// like `voicesTogether`, as what Plus adds: no public build had it
        /// on Free.
        case windowsStayPut
        /// Notes were written online and are now written on the Mac.
        case notesOnTheMac

        /// What changes, said from the side of somebody who just lost it.
        /// `macWritesNotes` is whether this Mac can write notes itself
        /// (Apple Intelligence on); without it a call keeps its transcript.
        public func sentence(macWritesNotes: Bool) -> String {
            switch self {
            case .shorterClipboard:
                String(localized: "The clipboard shows your last \(PlanLimits.freeClipboard) copies. Older ones are kept out of sight for \(ClipboardHistory.outOfSightDays) days.")
            case .oneAgentAtATime:
                String(localized: "The notch answers one coding agent at a time. Others ask in their own terminal.")
            case .shorterCallNotes:
                String(localized: "Call notes cover the first \(Int(PlanLimits.freeNotesListen / 60)) minutes of each call.")
            case .voicesTogether:
                String(localized: "Everyone on the other side of a call is \u{201C}Them\u{201D}. Telling voices apart comes with Plus.")
            case .dropBoxBasics:
                String(localized: "The drop box makes no WebP copies and removes no backgrounds. Both come with Plus.")
            case .windowsStayPut:
                String(localized: "Windows aren't put in place from the notch or the keyboard. Window layouts come with Plus.")
            case .notesOnTheMac:
                macWritesNotes
                    ? String(localized: "Call notes are written on this Mac, not online.")
                    : String(localized: "Calls keep their transcript. Notes need Apple Intelligence, or Plus.")
            }
        }

        /// An SF Symbol for the row.
        public var symbol: String {
            switch self {
            case .shorterClipboard: "doc.on.clipboard"
            case .oneAgentAtATime: "terminal"
            case .shorterCallNotes: "timer"
            case .voicesTogether: "person.2"
            case .dropBoxBasics: "tray.and.arrow.down"
            case .windowsStayPut: "rectangle.split.2x1"
            case .notesOnTheMac: "text.bubble"
            }
        }
    }

    /// Everything `self` does that `smaller` does not, in a fixed order, so a
    /// card built from it reads the same way every time.
    public func lost(goingTo smaller: PlanLimits) -> [Difference] {
        var lost: [Difference] = []
        if let shows = smaller.clipboardShows, clipboardShows.map({ $0 > shows }) ?? true {
            lost.append(.shorterClipboard)
        }
        if smaller.oneAgentAtATime, !oneAgentAtATime { lost.append(.oneAgentAtATime) }
        if let listens = smaller.notesListenFor, notesListenFor.map({ $0 > listens }) ?? true {
            lost.append(.shorterCallNotes)
        }
        if tellsVoicesApart, !smaller.tellsVoicesApart { lost.append(.voicesTogether) }
        if dropBoxExtras, !smaller.dropBoxExtras { lost.append(.dropBoxBasics) }
        if movesWindows, !smaller.movesWindows { lost.append(.windowsStayPut) }
        if writesNotesOnline, !smaller.writesNotesOnline { lost.append(.notesOnTheMac) }
        return lost
    }
}

/// The plan at one moment, kept with whatever started then.
///
/// **A plan change never lands in the middle of a task.** A call keeps the
/// plan it started on (`MeetingRecord.startedOn`), so a subscription that ends
/// during a call still gets that call's notes written the way it began.
public struct PlanSnapshot: Codable, Equatable, Sendable {
    public let plan: AirlockPlan
    /// Money known to be flowing: a licence in date or in its silent grace.
    public let isPaid: Bool

    public init(plan: AirlockPlan, isPaid: Bool) {
        self.plan = plan
        self.isPaid = isPaid
    }

    public static let free = PlanSnapshot(plan: .free, isPaid: false)

    /// Free's limits go by the plan alone: a trial from before plans and an
    /// overdue licence keep everything their plan has, bar online notes, which
    /// need money known to be flowing.
    public var limits: PlanLimits {
        let free = plan == .free
        return PlanLimits(writesNotesOnline: !free && isPaid,
                          clipboardShows: free ? PlanLimits.freeClipboard : nil,
                          oneAgentAtATime: free,
                          notesListenFor: free ? PlanLimits.freeNotesListen : nil,
                          tellsVoicesApart: !free,
                          dropBoxExtras: !free,
                          movesWindows: !free)
    }

    /// The plan a task that started on `startedOn` runs under now: never less
    /// than it started with, so nothing is taken away halfway through, and
    /// more if a bigger plan was bought since, because whoever just paid
    /// expects it to count. Nil `startedOn` (a task from before plans) is
    /// `now`.
    public static func kept(startedOn: PlanSnapshot?, now: PlanSnapshot) -> PlanSnapshot {
        guard let startedOn else { return now }
        return startedOn.rank >= now.rank ? startedOn : now
    }

    /// Bigger plan first, and between the same plan, the one being paid for.
    private var rank: Int { plan.rank * 2 + (isPaid ? 1 : 0) }
}

/// What first-run setup says about money, in both wizards: there is no trial
/// to start, what Free keeps and what Plus adds. Only what `PlanLimits`
/// enforces is named, with its own numbers, for the reason the Free card's
/// rows come from that table: somebody who meets a limit a week in should
/// remember having read it here, not feel caught out.
public enum PlanSetupNote {
    public static let title = String(localized: "You start on Free")
    public static var detail: String {
        String(localized: "No trial and no card. \(free) \(plus) See Settings › Plans whenever you like.")
    }

    /// Free's three limits, in the order the Free card lists them.
    static var free: String {
        String(localized: "On Free, the clipboard shows your last \(PlanLimits.freeClipboard) copies, the notch answers one coding agent at a time, and call notes cover the first \(Int(PlanLimits.freeNotesListen / 60)) minutes of each call.")
    }

    /// What Plus adds over them, and its smaller price.
    static var plus: String {
        String(localized: "Plus covers whole calls, writes the notes online, tells voices apart, puts windows in place and answers every agent, from \(License.Period.monthly.price).")
    }
}
