import Foundation

/// What a call's notes are written from: the transcript, with any stretch in
/// a language Apple's notes writer cannot read swapped for what the other
/// listening heard over the same time (`MeetingShadowLine`).
///
/// The writer (`SystemLanguageModel`) reads 23 languages and Catalan is not
/// one: handed a Catalan transcript it refuses outright
/// (`unsupportedLanguageOrLocale`), and there is no translation framework
/// that knows Catalan either. A side that followed its call into Catalan
/// keeps its Spanish take running for exactly this. The Spanish recogniser
/// hearing Catalan writes Spanish-looking words, close enough in meaning to
/// take notes from and far from right to read, which is why it is never
/// shown, only written from.
///
/// Times are kept as heard, so a line of notes written from the shadow
/// still says when it was said, and the window still opens the transcript
/// at that moment (`MeetingTimeline.spoken`).
public struct MeetingNotesSource: Sendable {
    /// The record the notes are written from: the transcript as shown, with
    /// unreadable stretches swapped for their shadow, and the languages it
    /// is now in.
    public let record: MeetingRecord
    /// What the notes page says on top when anything was swapped: "Written
    /// from a Spanish listening — Apple's notes writer can't read Catalan
    /// yet." Nil when nothing was.
    public let line: String?
    /// Locales of stretches nothing could stand in for, "ca_ES". Left in
    /// `record` as heard, and out of `readable`.
    public let unreadable: [String]
    /// Everything said that the writer can read, echoes gone: what a
    /// question about past calls is answered from.
    public let readable: [MeetingSegment]

    /// - Parameter canRead: whether the notes writer reads a locale
    ///   identifier's language. Asked once per language.
    public init(_ original: MeetingRecord, canRead: (String) -> Bool) {
        var verdicts: [String: Bool] = [:]
        func reads(_ language: String) -> Bool {
            let key = CallLanguage.code(of: language) ?? language
            if let known = verdicts[key] { return known }
            let verdict = canRead(language)
            verdicts[key] = verdict
            return verdict
        }

        var segments: [MeetingSegment] = []
        var readable: [MeetingSegment] = []
        var swapped: [String] = []
        var standIns: [String] = []
        var unreadable: [String] = []

        for speaker in [MeetingSpeaker.me, .them] {
            let said = original.segments.filter { $0.speaker == speaker }
            let listenings = original.listenings.filter { $0.speaker == speaker }
            // A side with no listening on record (calls from before there
            // were any) is read as heard.
            guard !listenings.isEmpty else {
                segments += said
                readable += said
                continue
            }
            for (index, listening) in listenings.enumerated() {
                // The first listening also covers anything said before it.
                let from = index == 0 ? -Double.infinity : listening.from
                let until = index + 1 < listenings.count ? listenings[index + 1].from : .infinity
                let stretch = said.filter { $0.start >= from && $0.start < until }
                if reads(listening.language) {
                    segments += stretch
                    readable += stretch
                    continue
                }
                let shadow = original.shadow.filter {
                    $0.segment.speaker == speaker && $0.segment.start >= from && $0.segment.start < until
                        && reads($0.language)
                }
                let name = CallLanguageFollow.name(of: listening.language) ?? listening.language
                if shadow.isEmpty {
                    segments += stretch
                    if !stretch.isEmpty, !unreadable.contains(listening.language) {
                        unreadable.append(listening.language)
                    }
                } else {
                    segments += shadow.map(\.segment)
                    readable += shadow.map(\.segment)
                    if !swapped.contains(name) { swapped.append(name) }
                    standIns += shadow.map(\.language)
                }
            }
        }

        var record = original
        record.replaceSegments(with: segments)
        // The languages the notes are now in: the ones the writer reads, and
        // the shadow's in place of the ones it does not.
        var languages = original.languages.filter(reads)
        for language in standIns where !languages.contains(language) { languages.append(language) }
        if !languages.isEmpty { record.languages = languages }
        self.record = record
        self.unreadable = unreadable
        self.readable = MeetingEcho.removingEchoes(from: readable.sorted { $0.start < $1.start })

        // The shadow's most-used language names the listening.
        let counts = standIns.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        if let standIn = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key,
           let name = CallLanguageFollow.name(of: standIn) {
            let article = "AEIOU".contains(name.first ?? "x") ? "an" : "a"
            line = "Written from \(article) \(name) listening — Apple's notes writer can't read "
                + "\(swapped.joined(separator: " or ")) yet."
        } else {
            line = nil
        }
    }
}
