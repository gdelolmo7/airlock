import Foundation

/// What a finished line from the recogniser needs before it is kept.
///
/// Apple's recogniser was checked with generated audio before any of this was
/// written, because the usual fixes are for a different kind of model:
/// - **It does not make text up over silence.** Three minutes of digital
///   silence, room noise, white noise up to a loud hiss, mains hum, keyboard
///   clicks and a tone melody gave nothing at all, in English and in Spanish,
///   and two minutes of silence between sentences stayed empty. The phrases
///   models trained on video subtitles are known to invent ("thanks for
///   watching", a subtitling credit) are dropped anyway: nobody says them on
///   a call, and a model update could bring them.
/// - **Nor does it stutter.** Said three times, "thank you" was written three
///   times; it never repeated anything on its own. A run of the same words is
///   still kept once, for the same reason as the phrases.
/// - **A finished line already ends at a pause.** None spanned more than about
///   two seconds of silence, so there is nothing to split.
/// - **It can start a line in lowercase.** When the first word is clipped or
///   too quiet (unmuting mid-word, a call app's noise gate), the line begins
///   with whatever it did catch: "app shipped on Tuesday", "del iPhone salió
///   el martes". That is the one fix here that answers something measured.
///
/// Pure, and applied to each line as it is heard, so a line reads the same in
/// the transcript, the summary and the echo check.
public enum MeetingWords {
    /// A run of the same words this many times in a row is kept once.
    public static let repeatsToCollapse = 3
    /// The longest run, in words, that is looked for.
    public static let longestRepeat = 4
    /// A credit line is short; anything longer is somebody talking.
    public static let longestCredit = 10

    /// The line to keep for `text`, heard in `locale`, or nil when nothing in
    /// it was said.
    public static func kept(_ text: String, in locale: Locale) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words(line).isEmpty, !isInvented(line) else { return nil }
        return capitalised(collapsingRepeats(line), in: locale)
    }

    // MARK: - Invented phrases

    /// True when every sentence of `line` is a stock phrase or a credit.
    /// Whole sentences only: the same words inside real speech are speech.
    public static func isInvented(_ line: String) -> Bool {
        let parts = sentences(line).map(words).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { isStock($0) || isCredit($0) }
    }

    /// Written as heard and folded the same way as what they are matched
    /// against. Things people do say on a call ("thank you", "see you next
    /// time", "thanks for listening") are left out on purpose.
    static let stockPhrases: Set<String> = Set([
        "Thanks for watching", "Thank you for watching",
        "Thank you so much for watching", "Thank you very much for watching",
        "Please subscribe", "Subscribe to my channel", "Please subscribe to my channel",
        "Subscribe to the channel", "Please subscribe to the channel",
        "Like and subscribe", "Please like and subscribe",
        "Don't forget to subscribe", "Don't forget to like and subscribe",
        "See you in the next video",
        "Gracias por ver", "Gracias por ver el vídeo", "Gracias por ver este vídeo",
        "Muchas gracias por ver", "Muchas gracias por ver el vídeo",
        "Gracias por vernos", "Gracias por mirar",
        "Suscríbete", "Suscríbete al canal", "Suscríbete a mi canal",
        "No olvides suscribirte", "No olvides suscribirte al canal",
        "Dale like y suscríbete", "Nos vemos en el próximo vídeo", "Hasta el próximo vídeo",
        "Danke fürs Zuschauen", "Vielen Dank fürs Zuschauen",
        "Merci d'avoir regardé", "Merci d'avoir regardé cette vidéo", "Abonnez-vous",
        "Grazie per la visione", "Grazie per aver guardato", "Iscriviti al canale",
        "Obrigado por assistir", "Obrigada por assistir", "Inscreva-se no canal",
    ].map { words($0).joined(separator: " ") })

    /// How a subtitling credit begins.
    static let creditOpenings: [[String]] = [
        "Subtitles by", "Subtitled by", "Captions by", "Captioning by",
        "Subtítulos por", "Subtítulos realizados por", "Subtitulado por",
        "Untertitel im Auftrag", "Untertitel der", "Untertitel von",
        "Sous-titres réalisés par", "Sous-titres par",
        "Sottotitoli creati", "Sottotitoli a cura di",
        "Legendas pela", "Legendas por",
    ].map(words)

    static func isStock(_ words: [String]) -> Bool {
        stockPhrases.contains(words.joined(separator: " "))
    }

    /// The community subtitling credit turns up in every language, so its
    /// site name counts wherever it sits in a short sentence.
    static func isCredit(_ words: [String]) -> Bool {
        guard words.count <= longestCredit else { return false }
        if zip(words, words.dropFirst()).contains(where: { $0 == "amara" && $1 == "org" }) { return true }
        return creditOpenings.contains { words.starts(with: $0) }
    }

    // MARK: - Repeats

    /// The same one to four words three or more times in a row, kept once.
    /// The first time keeps its own capital and the last time's punctuation,
    /// so "No, no, no, no." becomes "No." and a run mid-sentence leaves the
    /// sentence intact. Numbers are never collapsed: "5 5 5" is a phone number.
    public static func collapsingRepeats(_ line: String) -> String {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        let keys: [String?] = tokens.map { token in
            token.contains(where: \.isLetter) ? words(token).joined() : nil
        }
        var kept: [String] = []
        var collapsed = false
        var index = 0
        scan: while index < tokens.count {
            for size in 1...longestRepeat where index + size * repeatsToCollapse <= tokens.count {
                let run = keys[index..<index + size]
                guard !run.contains(nil) else { continue }
                var times = 1
                while index + (times + 1) * size <= tokens.count,
                      keys[(index + times * size)..<(index + (times + 1) * size)].elementsEqual(run) {
                    times += 1
                }
                guard times >= repeatsToCollapse else { continue }
                var once = Array(tokens[index..<index + size])
                once[size - 1] = trimmingTrail(once[size - 1]) + trail(tokens[index + times * size - 1])
                kept += once
                collapsed = true
                index += times * size
                continue scan
            }
            kept.append(tokens[index])
            index += 1
        }
        return collapsed ? kept.joined(separator: " ") : line
    }

    // MARK: - Capitals

    /// Languages written without capitals. Their letters have no case, so
    /// nothing would change anyway; this keeps a Latin word that opens one of
    /// their lines exactly as the recogniser wrote it.
    static let uncased: Set<String> = ["ja", "ko", "zh", "yue"]

    /// Abbreviations that end in a full stop without ending a sentence.
    static let abbreviations: Set<String> = ["etc", "vs", "approx", "aprox", "bzw", "usw", "cf"]

    /// A capital for the first letter of the line and of each sentence in it.
    /// Only a word written all in lowercase gets one: "iPhone" or "macOS"
    /// opening a sentence stays as it is, and nothing mid-sentence is touched.
    public static func capitalised(_ line: String, in locale: Locale) -> String {
        if let language = locale.language.languageCode?.identifier, uncased.contains(language) {
            return line
        }
        let characters = Array(line)
        var result = ""
        var opening = true
        for (index, character) in characters.enumerated() {
            if opening, character.isLetter || character.isNumber {
                opening = false
                if character.isLowercase, !hasCapital(characters, from: index + 1) {
                    result += String(character).capitalized(with: locale)
                    continue
                }
            } else if !opening, endsSentence(characters, at: index) {
                opening = true
            }
            result.append(character)
        }
        return result
    }

    /// Whether the rest of the word from `index` has a capital in it.
    private static func hasCapital(_ characters: [Character], from index: Int) -> Bool {
        characters[index...].prefix { !$0.isWhitespace }.contains(where: \.isUppercase)
    }

    /// A question mark, an exclamation mark, or a full stop after a word that
    /// is not an abbreviation, with a space after it. Not "3.5", "a.m." or "…".
    private static func endsSentence(_ characters: [Character], at index: Int) -> Bool {
        let mark = characters[index]
        guard mark == "." || mark == "?" || mark == "!",
              index + 1 < characters.count, characters[index + 1].isWhitespace else { return false }
        guard mark == "." else { return true }
        let word = characters[..<index].reversed().prefix { !$0.isWhitespace }.reversed()
        guard word.last?.isLetter == true, !word.contains(".") else { return false }
        return !abbreviations.contains(String(word.filter(\.isLetter)).lowercased())
    }

    // MARK: - Text

    /// Lowercased, accents folded, punctuation dropped, the same folding as
    /// `MeetingEcho.words`: the recogniser writes "vídeo" one day and "video"
    /// the next, with or without the comma.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// The line cut after each ".", "?" or "!" that has a space or the end
    /// after it, so "Amara.org" stays one word.
    static func sentences(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        let characters = Array(line)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let last = index + 1 == characters.count
            if "?!.".contains(character), last || characters[index + 1].isWhitespace {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// The punctuation a word ends with, and the word without it.
    private static func trail(_ token: String) -> String {
        String(token.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
    }

    private static func trimmingTrail(_ token: String) -> String {
        String(token.dropLast(trail(token).count))
    }
}
