import Foundation

/// On Free, the quiet word that Plus would have told a call's voices apart:
/// a box under the transcript's first "Them", and a line on the notes-ready
/// card (folded into the limit's line when Free's limit stopped the notes,
/// `MeetingNotesFlow.LimitWord.line(voicesToo:)`).
///
/// Only where it is true: the plan now doesn't tell voices apart, the call
/// is over, everyone on the other side was heard as one "Them" nobody has
/// named since, and the calendar invite names two or more other people. A
/// one-to-one call's "Them" is one person, and a call with no invite may be,
/// so neither says it. In person the lines are "Someone", not "Them".
public enum FreeVoicesHint {
    /// What Plus does, after the words saying who was "Them".
    public static let plusTells = String(localized: "Plus tells each voice apart: Person 1, Person 2\u{2026}")
    /// On the notes-ready card of a call Free's limit didn't stop.
    public static let afterCall = String(localized: "Everyone else was \u{201C}Them\u{201D} on Free.") + " " + plusTells

    /// Whether `record` gets the hints on `plan`, the plan now: whoever pays
    /// today never sees them, whatever plan the call started on.
    public static func shows(for record: MeetingRecord, plan: PlanSnapshot) -> Bool {
        !plan.limits.tellsVoicesApart && record.endedAt != nil && !record.isInPerson
            && invited(record).count >= 2
            && record.voices == [MeetingRecord.otherSide]
            && record.givenLabel(of: MeetingRecord.otherSide) == nil
    }

    /// The transcript box's first line, who showed as "Them". `plusTells`
    /// is its second.
    public static func who(of record: MeetingRecord) -> String {
        who(invited(record))
    }

    /// "Ana and Tom both show as “Them” on Free.", "Ana, Marc and Lucía all
    /// show…", "Ana, Marc and 3 others all show…". First names, unless two
    /// of them are the same. Fewer than two: "Everyone else shows…".
    static func who(_ names: [String]) -> String {
        guard names.count >= 2 else { return String(localized: "Everyone else shows as \u{201C}Them\u{201D} on Free.") }
        let firsts = names.map { $0.split(separator: " ").first.map(String.init) ?? $0 }
        let shared = Set(firsts.map { $0.lowercased() }).count < firsts.count
        let called = shared ? names : firsts
        let shown = called.count <= 3 ? called
            : Array(called.prefix(2)) + [String(localized: "\(called.count - 2) others")]
        let list = CallPeople.joined(shown)
        return names.count == 2
            ? String(localized: "\(list) both show as \u{201C}Them\u{201D} on Free.")
            : String(localized: "\(list) all show as \u{201C}Them\u{201D} on Free.")
    }

    /// The other people the invite names.
    static func invited(_ record: MeetingRecord) -> [String] {
        (record.event?.attendees ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
