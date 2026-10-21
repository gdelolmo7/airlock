import Foundation

/// Who a to-do is for, when it can be for several: "You, Ana", or
/// "Everyone" for one all of them took on (`MeetingPeople.everyone`).
///
/// The page writes the owners in a to-do's tail, joined by ", ", and the
/// notes window shows the to-dos person by person. Both read them here, so
/// the order on the page and the groups in the window are the same rule:
/// you first, then each person in the order they first have something to
/// do, then everyone, then the to-dos with nobody's name on them.
public enum MeetingOwners {
    /// "You, Ana" as ["You", "Ana"]; [] for none.
    public static func split(_ owner: String?) -> [String] {
        (owner ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whose list a to-do goes in: yours when you are one of them, else the
    /// first named. Nil for nobody.
    public static func lead(_ owner: String?) -> String? {
        let names = split(owner)
        return names.first(where: isYou) ?? names.first
    }

    /// The others it is shared with, for "with Ana" under the lead's name.
    public static func others(_ owner: String?) -> [String] {
        let names = split(owner), lead = lead(owner)
        return names.filter { $0 != lead }
    }

    /// The items in groups, one per lead (`lead`), in the order above, each
    /// keeping the order the items came in.
    public static func grouped<Item>(_ items: [Item], owner: (Item) -> String?)
        -> [(owner: String?, items: [Item])] {
        var leads: [String?] = []
        var groups: [String?: [Item]] = [:]
        for item in items {
            let lead = lead(owner(item))
            if groups[lead] == nil { leads.append(lead) }
            groups[lead, default: []].append(item)
        }
        let ranked = leads.indices.sorted { (rank(leads[$0]), $0) < (rank(leads[$1]), $1) }
        return ranked.map { (leads[$0], groups[leads[$0]] ?? []) }
    }

    /// The items in that order, flat: what the page writes.
    public static func ordered<Item>(_ items: [Item], owner: (Item) -> String?) -> [Item] {
        grouped(items, owner: owner).flatMap(\.items)
    }

    public static func isYou(_ name: String) -> Bool {
        MeetingPeople.fold(name) == MeetingPeople.fold(MeetingSpeaker.me.label)
    }

    public static func isEveryone(_ name: String) -> Bool {
        MeetingPeople.fold(name) == MeetingPeople.fold(MeetingPeople.everyone)
    }

    private static func rank(_ lead: String?) -> Int {
        guard let lead else { return 3 }
        if isYou(lead) { return 0 }
        return isEveryone(lead) ? 2 : 1
    }
}
