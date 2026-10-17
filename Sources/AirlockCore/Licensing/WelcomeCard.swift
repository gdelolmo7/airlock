import Foundation

/// "You're on Plus. Thank you." The notch card after paying: what just
/// unlocked, in the words of the plan's own card, and an offer to write the
/// last call's notes again with the better model.
///
/// **Only for a bigger plan, and never at launch.** It is raised when a key
/// goes in or a check finds one, and only when that key is a bigger plan than
/// the one before (`due(before:after:)`): the same key pasted twice, a yearly
/// renewal or a late payment going through says nothing. It stays until "Got
/// it", so a card raised while the notch was shut is still there when it
/// opens.
public struct WelcomeCard: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        /// An SF Symbol.
        public let symbol: String
        public let sentence: String
    }

    /// Plus or Pro.
    public let plan: AirlockPlan

    /// Nil for Free, which nobody is welcomed to.
    public init?(_ plan: AirlockPlan) {
        guard plan != .free else { return nil }
        self.plan = plan
    }

    /// The small line above the title.
    public var label: String { "Welcome to \(plan.label)" }
    public var title: String { "You're on \(plan.label). Thank you." }

    public var rows: [Row] {
        switch plan {
        case .free:
            return []
        case .plus:
            let most = PlanCatalog.thousands(ClipboardHistory.capacityRange.upperBound)
            return [Row(symbol: "doc.on.clipboard",
                        sentence: "The clipboard can keep up to \(most). Choose how many in Settings › Clipboard."),
                    Row(symbol: "terminal", sentence: "Every coding agent can ask you here, not only one."),
                    Row(symbol: "waveform", sentence: "Notes cover the whole call, written online by a better model."),
                    Row(symbol: "laptopcomputer", sentence: "Works on every Mac, with or without Apple Intelligence.")]
        case .pro:
            return [Row(symbol: "sparkles", sentence: "Call notes are written by the best model we've tested."),
                    Row(symbol: "doc.on.doc", sentence: "Twice as many online notes each month."),
                    Row(symbol: "checkmark.seal", sentence: "Everything Plus has stays as it is.")]
        }
    }

    /// The question on the redo row, about one call: "Redo the notes of
    /// “Budget review” (today, 42 min) with the better model?" `when` is
    /// the call's day as the window writes it ("today", "15 October").
    public func redoQuestion(title: String, when: String, minutes: Int) -> String {
        let model = plan == .pro ? "the best model" : "the better model"
        return "Redo the notes of “\(title)” (\(when), \(minutes) min) with \(model)?"
    }

    /// The question about `record`: its name, its day as the Calls tab says
    /// it ("today", "yesterday", "Tuesday 13 Oct") and how long it ran.
    public func redoQuestion(for record: MeetingRecord, now: Date = Date(),
                             calendar: Calendar = .current) -> String {
        let end = record.endedAt ?? record.startedAt
        let minutes = max(1, Int((end.timeIntervalSince(record.startedAt) / 60).rounded()))
        var day = CallsCard.dayHeading(record.startedAt, now: now, calendar: calendar)
        // Mid-sentence: "Today" becomes "today", a weekday keeps its capital.
        if day == "Today" || day == "Yesterday" { day = day.lowercased() }
        return redoQuestion(title: MeetingFiles.title(of: record), when: day, minutes: minutes)
    }

    /// Under the question. Only the writer is named: a call Free stopped
    /// listening to at 30 minutes has no more words to write from, so
    /// promising the rest of it would be a promise the redo can't keep.
    public static let redoReason = "Its notes were written on your Mac."

    /// The call the card offers to redo: the last one, when its notes can
    /// be written again online now, on `plan`, the way the notes window
    /// would offer it (`CallNotesOffers`). Nil otherwise, and the card then
    /// has no redo row: an older call is one the person has likely moved on
    /// from, and the window offers it anyway. `page` reads a call's notes.
    public static func redoCall(_ calls: [(folder: URL, record: MeetingRecord)],
                                page: (URL) -> String?, plan: PlanSnapshot,
                                online: CallNotesOffers.Online) -> (folder: URL, record: MeetingRecord)? {
        guard let last = calls.filter({ $0.record.endedAt != nil })
            .max(by: { $0.record.startedAt < $1.record.startedAt }) else { return nil }
        let offers = CallNotesOffers.of(last.record, page: page(last.folder), plan: plan, online: online)
        return offers.redo == .rewritesOnline ? last : nil
    }
}

extension WelcomeCard {
    /// The card a change of entitlement earns, or nil.
    ///
    /// Only money known to be flowing is welcomed, and only to a plan bigger
    /// than the one before. A trial counts as Free here, because it paid for
    /// nothing: buying Plus at the end of one is the purchase this card
    /// thanks. A late payment going through is not: an overdue Plus was Plus
    /// all along, so the card would announce nothing new.
    public static func due(before: Entitlement, after: Entitlement) -> WelcomeCard? {
        guard after.isPaid else { return nil }
        let was: AirlockPlan
        if case .trialing = before { was = .free } else { was = before.plan }
        return after.plan.rank > was.rank ? WelcomeCard(after.plan) : nil
    }
}
