import Foundation

/// Who was on a call, as far as its record can say without reading what was
/// said: you, the voices heard, and the names the calendar gave.
///
/// What the notes window's header draws as avatars ("You and Ana") and the
/// Calls tab counts. Names only, never words: a count of people is a fact
/// about the call, like its length.
public enum CallPeople {
    public struct Person: Equatable, Sendable {
        /// As the transcript names them: "You", "Ana", "Person 2", "Them".
        public let name: String
        public let isYou: Bool
        /// The voice they were heard as (`MeetingRecord.voices`): the first,
        /// when several were given one name. Their colour follows it, so
        /// naming somebody never changes the colour they are drawn in.
        public let voice: Int?

        public init(name: String, isYou: Bool = false, voice: Int? = nil) {
            self.name = name
            self.isYou = isYou
            self.voice = voice
        }
    }

    /// Who a person on the call is, for the colour their avatar and name
    /// are drawn in: you, the nth other (from 0), or nobody known.
    public enum Seat: Equatable, Sendable {
        case you
        case other(Int)
        case unknown
    }

    /// Everyone the call's own record names, you first.
    ///
    /// A call: you, then the other side when it is one voice (the one name
    /// a one-to-one invite gives, or the name given to it), else the voices
    /// told apart in the order first heard, else the names on the invite,
    /// else "Them" when anyone else spoke. In person: only the voices told
    /// apart, since nobody in the room is known to be you until somebody
    /// says which voice is theirs ("That's me", then first, as "You"), and
    /// a room that was one voice once it has a name.
    /// Voices given the same name are one person.
    public static func people(of record: MeetingRecord) -> [Person] {
        if record.isInPerson, let given = record.givenName(of: MeetingRecord.otherSide),
           let name = record.givenLabel(of: MeetingRecord.otherSide), record.isOneVoiceRoom {
            return [Person(name: name, isYou: given.isYou, voice: MeetingRecord.otherSide)]
        }
        var voices: [Person] = []
        for voice in record.voices where voice != MeetingRecord.otherSide {
            let given = record.givenName(of: voice)
            let person = Person(name: record.givenLabel(of: voice) ?? MeetingRecord.personLabel(voice),
                                isYou: given?.isYou ?? false, voice: voice)
            guard !voices.contains(where: { same($0, person) }) else { continue }
            voices.append(person)
        }
        if record.isInPerson { return voices.filter(\.isYou) + voices.filter { !$0.isYou } }

        let you = Person(name: MeetingSpeaker.me.label, isYou: true)
        let otherSide = record.givenLabel(of: MeetingRecord.otherSide)
        if let name = otherSide ?? record.otherName {
            return [you, Person(name: name, voice: MeetingRecord.otherSide)]
        }
        if !voices.isEmpty { return [you] + voices }
        let invited = (record.event?.attendees ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if invited.count > 1 { return [you] + invited.map { Person(name: $0) } }
        if record.spokenSegments.contains(where: { $0.speaker == .them }) {
            return [you, Person(name: MeetingSpeaker.them.label, voice: MeetingRecord.otherSide)]
        }
        return [you]
    }

    private static func same(_ one: Person, _ other: Person) -> Bool {
        one.isYou == other.isYou && one.name.caseInsensitiveCompare(other.name) == .orderedSame
    }

    /// How many people were on the call: those its record names, or
    /// everyone on the invite and you when that is more. A meeting in the
    /// room has no invite, so only its voices count.
    public static func count(of record: MeetingRecord) -> Int {
        let named = people(of: record).count
        guard !record.isInPerson else { return named }
        let invited = (record.event?.attendees ?? []).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return max(named, invited.count + 1)
    }

    /// The header's words for who was there: "You and Ana", "You, Ana and
    /// Tom", "You, Ana and 3 others", "Person 1 and Person 2". `count` adds
    /// the people the record could not name. Nil when nobody is known.
    public static func line(_ people: [Person], count: Int? = nil) -> String? {
        let total = max(count ?? people.count, people.count)
        guard !people.isEmpty else { return total > 1 ? String(localized: "\(total) people") : nil }
        // "Them" is a word, not a name, once something comes before it.
        let names = people.enumerated().map { index, person in
            let shown = MeetingRecord.shownLabel(person.name)
            return index > 0 && person.name == MeetingSpeaker.them.label ? shown.lowercased() : shown
        }
        if total == names.count, total <= 3 { return joined(names) }
        let shown = Array(names.prefix(min(2, names.count)))
        let others = total - shown.count
        return joined(shown + [others == 1 ? String(localized: "1 other") : String(localized: "\(others) others")])
    }

    /// Whose colour `name` is drawn in, among `people`. A to-do's owner is
    /// written by the model, so a first name or another case still finds
    /// its person ("ana" and "Ana García" are Ana). A voice keeps the seat
    /// of its number, named or not, so "Person 2" and the "Ana" it became
    /// are drawn alike.
    public static func seat(of name: String, in people: [Person]) -> Seat {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.caseInsensitiveCompare(MeetingSpeaker.me.label) == .orderedSame { return .you }
        let others = people.filter { !$0.isYou }
        func seat(at index: Int) -> Seat {
            if let voice = others[index].voice, voice > 0 { return .other(voice - 1) }
            return .other(index)
        }
        if let index = others.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return seat(at: index)
        }
        if let number = personNumber(name) { return .other(max(0, number - 1)) }
        let first = firstWord(name)
        if !first.isEmpty, name != MeetingRecord.someone,
           let index = others.firstIndex(where: { firstWord($0.name).caseInsensitiveCompare(first) == .orderedSame }) {
            return seat(at: index)
        }
        return .unknown
    }

    /// 2 for "Person 2", else nil.
    private static func personNumber(_ name: String) -> Int? {
        let prefix = MeetingRecord.personLabel(0).dropLast()
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }

    private static func firstWord(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? ""
    }

    /// "A", "A and B", "A, B and C".
    static func joined(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return String(localized: "\(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1])")
    }
}
