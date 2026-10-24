import Foundation

/// The words Airlock itself writes on a notes page, as the screen shows them.
///
/// The page stays English: it is a file people open, search and hand to
/// agents, and the window reads its headings and lines back to know what
/// each one is. Only what is drawn follows the app's language. A line this
/// does not recognise whole is shown as it was written, never half changed.
public enum MeetingNotesShown {
    /// "Summary", "To-dos"… in the app's language; any other heading (one
    /// the person typed, a topic) as it is.
    public static func heading(_ heading: String) -> String {
        switch heading {
        case MeetingFiles.summaryHeading: String(localized: "Summary")
        case MeetingFiles.yourNotesHeading: String(localized: "Your notes")
        case MeetingFiles.todosHeading: String(localized: "To-dos")
        case MeetingFiles.decisionsHeading: String(localized: "Decisions")
        case MeetingFiles.questionsHeading: String(localized: "Open questions")
        case MeetingFiles.keyPointsHeading: String(localized: "Key points")
        case MeetingFiles.topicsHeading: String(localized: "Topics")
        case MeetingFiles.wordsHeading: String(localized: "Check these words")
        default: heading
        }
    }

    /// "Couldn't write notes for 14:05–14:17. The transcript has it all."
    public static func unwritten(_ stretch: MeetingNotes.Stretch,
                                 clock: (TimeInterval) -> String = MeetingFiles.clock) -> String {
        String(localized: "Couldn't write notes for \(clock(stretch.start))–\(clock(stretch.end)). The transcript has it all.")
    }

    /// One paragraph of the page. Italic lines keep their underscores.
    public static func line(_ text: String) -> String {
        if text.count > 2, text.hasPrefix("_"), text.hasSuffix("_") {
            let inner = String(text.dropFirst().dropLast())
            return shown(inner).map { "_\($0)_" } ?? text
        }
        return shown(text) ?? text
    }

    /// The rest of a "No notes yet. …" line, which a notice shows without its
    /// first sentence.
    public static func afterNoNotesYet(_ rest: String) -> String {
        let whole = line(MeetingFiles.noNotesYet + " " + rest)
        let lead = String(localized: "No notes yet.") + " "
        return whole.hasPrefix(lead) ? String(whole.dropFirst(lead.count)) : rest
    }

    static let footerTail = "No audio was kept. The summary is written by AI and can be wrong; "
        + "check the transcript before relying on it."

    /// `text` in the app's language, or nil when it isn't one of Airlock's.
    static func shown(_ text: String) -> String? {
        if let fixed = fixed(text) { return fixed }
        if text.hasSuffix(footerTail) {
            let by = String(text.dropLast(footerTail.count)).trimmingCharacters(in: .whitespaces)
            return writtenBy(by).map { $0 + " " + String(localized: "No audio was kept. The summary is written by AI and can be wrong; check the transcript before relying on it.") }
        }
        let tail = " " + MeetingFiles.transcriptLine
        if text.hasSuffix(tail), let lead = fixed(String(text.dropLast(tail.count))) {
            return lead + " " + String(localized: "The full transcript is in the Transcript tab.")
        }
        if let cover = cover(text) { return cover }
        if let used = allowanceUsed(text) { return used }
        if let from = writtenFrom(text) { return from }
        return nil
    }

    private static func fixed(_ text: String) -> String? {
        switch text {
        case MeetingFiles.transcriptLine: String(localized: "The full transcript is in the Transcript tab.")
        case MeetingNotes.tooLittle: String(localized: "Too little was said on this call for notes.")
        case "Nothing was heard on this call, so there is nothing to summarise.":
            String(localized: "Nothing was heard on this call, so there is nothing to summarise.")
        case "Nothing was heard yet.": String(localized: "Nothing was heard yet.")
        case "No summary this time.": String(localized: "No summary this time.")
        case MeetingFiles.turnOnAppleIntelligence:
            String(localized: "Turn on Apple Intelligence to get notes and to-dos.")
        case "Airlock writes call notes with Apple Intelligence, which is switched off.":
            String(localized: "Airlock writes call notes with Apple Intelligence, which is switched off.")
        case MeetingFiles.macCantWriteNotes:
            String(localized: "This Mac can't write notes itself. Plus writes them online, on any Mac.")
        case "Your transcripts are always kept, on every plan.":
            String(localized: "Your transcripts are always kept, on every plan.")
        case MeetingFiles.offlineLine:
            String(localized: "Written on this Mac while offline. They'll be improved once you're back online.")
        case MeetingFiles.noNotesOfflineLine:
            String(localized: "No notes yet. They'll be written online once you're back online.")
        case MeetingFiles.noNotesFailedLine:
            String(localized: "No notes yet. The online notes service didn't answer, so Airlock will try again later.")
        default: nil
        }
    }

    /// The footer's first sentence: who wrote the notes, and where.
    private static func writtenBy(_ by: String) -> String? {
        switch by {
        case "Written online by Airlock.": return String(localized: "Written online by Airlock.")
        case MeetingFiles.basicModelFooter + ".": return String(localized: "Written on your Mac.")
        case MeetingFiles.serviceDownFooter + ".":
            return String(localized: "The online notes service didn't answer, so these were written on your Mac.")
        case "Written on this Mac by Airlock.": return String(localized: "Written on this Mac by Airlock.")
        default:
            let lead = "Written online by Airlock, with "
            guard by.hasPrefix(lead), by.hasSuffix(".") else { return nil }
            let maker = String(by.dropFirst(lead.count).dropLast())
            return String(localized: "Written online by Airlock, with \(maker).")
        }
    }

    /// "These notes cover the first 30 minutes of a 42-minute call."
    private static func cover(_ text: String) -> String? {
        guard text.hasPrefix(MeetingFiles.coverLead), text.hasSuffix(".") else { return nil }
        let rest = String(text.dropFirst(MeetingFiles.coverLead.count).dropLast())
        if rest == "minute" { return String(localized: "These notes cover the first minute.") }
        let parts = rest.components(separatedBy: " minutes")
        guard parts.count == 2, let minutes = Int(parts[0]) else { return nil }
        if parts[1].isEmpty { return String(localized: "These notes cover the first \(minutes) minutes.") }
        let call = parts[1]
        guard call.hasPrefix(" of a "), call.hasSuffix("-minute call"),
              let length = Int(call.dropFirst(6).dropLast(12)) else { return nil }
        return String(localized: "These notes cover the first \(minutes) minutes of a \(length)-minute call.")
    }

    /// "This month's online notes are used up, so these were written on your
    /// Mac. Online notes are back on 1 November. Pro has twice as many.",
    /// and the same said on a page still waiting for its notes.
    private static func allowanceUsed(_ text: String) -> String? {
        var rest = text
        var said: String
        let mac = MeetingFiles.allowanceUsedMacLead + ", so these were written on your Mac."
        let waiting = MeetingFiles.noNotesAllowanceLead + ", so these will be written "
        if rest.hasPrefix(mac) {
            said = String(localized: "This month's online notes are used up, so these were written on your Mac.")
            rest = String(rest.dropFirst(mac.count))
            let back = " Online notes are back on "
            if rest.hasPrefix(back), let end = rest.range(of: ".") {
                let day = String(rest[rest.index(rest.startIndex, offsetBy: back.count)..<end.lowerBound])
                said += " " + String(localized: "Online notes are back on \(day).")
                rest = String(rest[end.upperBound...])
            }
        } else if rest.hasPrefix(waiting) {
            rest = String(rest.dropFirst(waiting.count))
            if rest.hasPrefix("once they're back.") {
                said = String(localized: "No notes yet. This month's online notes are used up, so these will be written once they're back.")
                rest = String(rest.dropFirst("once they're back.".count))
            } else if rest.hasPrefix("on "), let end = rest.range(of: ".") {
                let day = String(rest[rest.index(rest.startIndex, offsetBy: 3)..<end.lowerBound])
                said = String(localized: "No notes yet. This month's online notes are used up, so these will be written on \(day).")
                rest = String(rest[end.upperBound...])
            } else {
                return nil
            }
        } else {
            return nil
        }
        if rest == " " + MeetingFiles.proHasMore {
            said += " " + String(localized: "Pro has twice as many.")
        } else if !rest.isEmpty {
            return nil
        }
        return said
    }

    /// "Written from a Spanish version of the call, because Apple
    /// Intelligence can't read Catalan yet." The names are the page's English
    /// ones, said again in the app's language.
    private static func writtenFrom(_ text: String) -> String? {
        let tail = " version of the call, because Apple Intelligence can't read "
        guard text.hasPrefix("Written from "), text.hasSuffix(" yet."), let middle = text.range(of: tail) else {
            return nil
        }
        var from = String(text[text.index(text.startIndex, offsetBy: 13)..<middle.lowerBound])
        for article in ["a ", "an "] where from.hasPrefix(article) { from = String(from.dropFirst(article.count)) }
        let unread = String(text[middle.upperBound..<text.index(text.endIndex, offsetBy: -5)])
            .components(separatedBy: " or ")
        guard let fromName = language(from) else { return nil }
        let unreadNames = unread.compactMap(language)
        guard unreadNames.count == unread.count else { return nil }
        let names = unreadNames.count == 1 ? unreadNames[0]
            : String(localized: "\(unreadNames.dropLast().joined(separator: ", ")) or \(unreadNames[unreadNames.count - 1])")
        return String(localized: "Written from a \(fromName) version of the call, because Apple Intelligence can't read \(names) yet.")
    }

    /// An English language name ("Catalan") in the app's language, lower
    /// case as it sits mid-sentence in Spanish.
    private static func language(_ english: String) -> String? {
        let en = Locale(identifier: "en")
        guard let code = Locale.LanguageCode.isoLanguageCodes.first(where: {
            en.localizedString(forLanguageCode: $0.identifier) == english
        }) else { return nil }
        let shown = Bundle.main.preferredLocalizations.first ?? "en"
        guard shown != "en" else { return english }
        return Locale(identifier: shown).localizedString(forLanguageCode: code.identifier)
    }
}
