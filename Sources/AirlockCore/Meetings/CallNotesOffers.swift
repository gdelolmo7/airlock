import Foundation

/// What the notes window offers beside a call's notes, by plan and by what
/// the Mac could write: a look at what Plus writes, notes written again with
/// the better model, or what to do about a Mac that wrote none.
///
/// **Free sees every one of them and is limited**: the better model is
/// offered with a Plus tag and opens the plans, never hidden. Nothing here
/// is offered on notes written online, on notes still waiting to be written
/// online (`CloudNotesRedo` does that by itself), or in a copy with no online
/// notes at all, where the offer would lead nowhere.
///
/// Read from the page on disk and the record beside it, like the window, so
/// a page from before plans gets the same offers as a new one.
public struct CallNotesOffers: Equatable, Sendable {
    /// "Redo with better notes".
    public enum Redo: Equatable, Sendable {
        /// On a plan that doesn't write notes online: opens the plans, with
        /// a Plus tag on the button.
        case opensPlans
        /// Writes these notes again online, counted in this month's.
        case rewritesOnline
    }

    /// A page without notes because the Mac had no model to write them.
    public enum Empty: Equatable, Sendable {
        /// Apple Intelligence is switched off: turn it on in System Settings.
        case turnOnAppleIntelligence
        /// This Mac can't run Apple's model: Plus writes them online.
        case cantWriteNotes
    }

    /// What the online notes service can do from this Mac now.
    public struct Online: Equatable, Sendable {
        /// Online notes exist in this copy: switched on, with a server to ask.
        public var exists: Bool
        /// "Write notes online" is on in Settings.
        public var settingOn: Bool
        /// Not to be asked now: this month's are used up, the server said
        /// this licence can't have them, or there is no licence to ask with.
        public var blocked: Bool

        public init(exists: Bool, settingOn: Bool, blocked: Bool) {
            self.exists = exists
            self.settingOn = settingOn
            self.blocked = blocked
        }

        /// A copy with no online notes.
        public static let none = Online(exists: false, settingOn: false, blocked: true)
    }

    /// "See what Plus writes", beside notes the Mac wrote on a plan that
    /// doesn't write them online.
    public var seePlus: Bool
    /// "See Pro", on Plus, where the month's online notes ran out: beside
    /// the notes the Mac wrote instead, or the line saying when they come.
    public var seePro: Bool
    public var redo: Redo?
    public var empty: Empty?

    public init(seePlus: Bool = false, seePro: Bool = false, redo: Redo? = nil, empty: Empty? = nil) {
        self.seePlus = seePlus
        self.seePro = seePro
        self.redo = redo
        self.empty = empty
    }

    /// Whether the redo button carries the Plus tag: only where it opens
    /// the plans.
    public var redoTagged: Bool { redo == .opensPlans }

    /// What to offer beside `page`, the notes of `record`, on `plan` now.
    /// The plan now, not the one the call started on: a redo is asked for
    /// today, and whoever has stopped paying is shown the plans rather than
    /// a button the server would refuse.
    public static func of(_ record: MeetingRecord, page: String?, plan: PlanSnapshot,
                          online: Online) -> CallNotesOffers {
        guard let page else { return CallNotesOffers() }
        let writer = record.notesWriter
        let hasNotes = MeetingFiles.hasNotes(page)
        let empty = hasNotes ? nil : empty(of: page)
        let writtenOnline = writer?.place == .online
        let waiting = writer?.waitsForOnline == true
        let writesOnline = plan.limits.writesNotesOnline
        // The month's online notes ran out: on the Mac's notes, or on a page
        // waiting for them to come back.
        let ranOut = !writtenOnline && (writer?.why == .allowanceUsed || writer?.noNotesYet == .allowanceUsed)
        let seePro = online.exists && writesOnline && plan.plan == .plus && ranOut
        guard online.exists, !writtenOnline, !waiting else { return CallNotesOffers(seePro: seePro, empty: empty) }

        // Past here, any notes on the page are the Mac's.
        let macNotes = hasNotes
        let seePlus = !writesOnline && (macNotes || empty == .cantWriteNotes)

        var redo: Redo?
        let enoughSaid = NumberedTranscript(record).wordCount >= MeetingNotes.minimumWords
        if record.endedAt != nil, enoughSaid {
            if !writesOnline {
                // The empty card says what Plus does on a Mac that can't
                // write notes; here only notes there are get the button.
                if macNotes { redo = .opensPlans }
            } else if online.settingOn, !online.blocked {
                // Notes without them too: a call from before this plan, on
                // a Mac with no model, gets its first notes this way.
                redo = .rewritesOnline
            }
        }
        return CallNotesOffers(seePlus: seePlus, seePro: seePro, redo: redo, empty: empty)
    }

    /// Which "no model" page this is, from its first paragraph under the
    /// date (`MeetingFiles.noModelLines`); nil for any other.
    static func empty(of page: String) -> Empty? {
        for block in MeetingPage.blocks(of: page) {
            guard case .paragraph(let text) = block else { continue }
            if text.hasPrefix(MeetingFiles.turnOnAppleIntelligence) { return .turnOnAppleIntelligence }
            if text.hasPrefix(MeetingFiles.macCantWriteNotes) { return .cantWriteNotes }
        }
        return nil
    }
}

/// A line under the date that the window draws as a notice of its own
/// rather than as text: how much of the call the notes cover, why they were
/// written on the Mac, why there are none yet. Read back from the page's
/// own wording (`MeetingFiles`), so the file stays the record.
public enum CallNotesNotice: Equatable, Sendable {
    /// "These notes cover the first 30 minutes."
    case cover(String)
    /// The month's online notes ran out, so the Mac wrote these.
    case allowanceUsed(String)
    /// No notes yet: the month's online notes ran out. Without "No notes yet."
    case waitingForAllowance(String)
    /// No notes yet: the online notes service didn't answer.
    case waitingForService(String)
    /// No notes yet: offline when the call ended.
    case waitingForNetwork(String)
    /// The Mac's notes, to be written online once it is back online.
    case improvedOnline(String)
    /// The Mac had no model: the window's empty card says it instead
    /// (`CallNotesOffers.Empty`).
    case noModel

    /// The notice `paragraph` is, or nil for any other line.
    public static func of(_ paragraph: String) -> CallNotesNotice? {
        let text = plain(paragraph)
        let waiting = MeetingFiles.noNotesYet + " "
        if text.hasPrefix(MeetingFiles.coverLead) { return .cover(text) }
        if text.hasPrefix(MeetingFiles.allowanceUsedMacLead) { return .allowanceUsed(text) }
        if text == MeetingFiles.offlineLine { return .improvedOnline(text) }
        if text.hasPrefix(MeetingFiles.turnOnAppleIntelligence) || text.hasPrefix(MeetingFiles.macCantWriteNotes) {
            return .noModel
        }
        guard text.hasPrefix(waiting) else { return nil }
        let rest = String(text.dropFirst(waiting.count))
        if text == MeetingFiles.noNotesOfflineLine { return .waitingForNetwork(rest) }
        if text == MeetingFiles.noNotesFailedLine { return .waitingForService(rest) }
        if text.hasPrefix(MeetingFiles.noNotesAllowanceLead) || text.hasPrefix(MeetingFiles.earlierNoNotesAllowanceLead) {
            return .waitingForAllowance(rest)
        }
        return nil
    }

    /// The page's cards with the notices taken out of the lines above the
    /// first heading, and the notices in the order they were written. The
    /// lines above the first heading go when nothing else is left in them.
    public static func split(_ sections: [MeetingPage.Section])
        -> (notices: [CallNotesNotice], sections: [MeetingPage.Section]) {
        var notices: [CallNotesNotice] = []
        var kept: [MeetingPage.Section] = []
        for section in sections {
            guard section.heading == nil else {
                kept.append(section)
                continue
            }
            let lines = section.lines.filter { line in
                guard case .paragraph(let text) = line.block, let notice = of(text) else { return true }
                notices.append(notice)
                return false
            }
            if !lines.isEmpty { kept.append(MeetingPage.Section(heading: nil, lines: lines)) }
        }
        return (notices, kept)
    }

    /// The words without the italics they are written in.
    public static func plain(_ paragraph: String) -> String {
        var text = Substring(paragraph.trimmingCharacters(in: .whitespaces))
        for mark in ["_", "*"] where text.count > 2 && text.hasPrefix(mark) && text.hasSuffix(mark) {
            text = text.dropFirst().dropLast()
            break
        }
        return String(text)
    }
}
