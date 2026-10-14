import Foundation

/// What a question about past calls is looked up by: the words worth
/// matching, and the days it names.
///
/// "¿Qué quedamos ayer con Pablo sobre el presupuesto?" becomes the terms
/// "pablo" and "presupuesto", and yesterday. The question's own wording —
/// what, said, call, yesterday — is left out of the terms: it is in the
/// question, not in the call, and a transcript full of "what" would rank
/// first for every question.
///
/// `now` and the calendar are passed in, so "last Tuesday" has one answer
/// in a test whatever day it runs.
public struct CallQuery: Equatable, Sendable {
    /// Folded, stemmed, in the order asked, each once.
    public let terms: [String]
    /// The days the question names, or nil when it names none.
    public let range: DateInterval?

    public init(terms: [String], range: DateInterval?) {
        self.terms = terms
        self.range = range
    }

    public init(_ question: String, now: Date, calendar: Calendar) {
        self.init(terms: Self.terms(in: question),
                  range: Self.range(in: question, now: now, calendar: calendar))
    }

    // MARK: - Terms

    public static func terms(in question: String) -> [String] {
        var seen = Set<String>()
        return CallText.tokens(question).compactMap { token in
            let word = token.text
            guard word.count > 1 || word.first?.isNumber == true,
                  !Self.stopwords.contains(word) else { return nil }
            let stem = CallText.stem(word)
            guard !Self.stopwords.contains(stem), seen.insert(stem).inserted else { return nil }
            return stem
        }
    }

    /// Words that carry the question rather than what it is about, in both
    /// languages: function words, the asking itself, calls, and time.
    static let stopwords: Set<String> = Self.english.union(Self.spanish).union(Self.asking)
        .union(CallQuestion.callNouns).union(CallQuestion.weekdays)

    private static let english: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with",
        "about", "from", "by", "as", "is", "are", "was", "were", "be", "been", "being",
        "it", "its", "this", "that", "these", "those", "there", "here", "what", "which",
        "who", "whom", "whose", "when", "where", "why", "how", "do", "does", "did",
        "didn't", "done", "doing", "have", "has", "had", "i", "me", "my", "we", "us", "our",
        "you", "your", "he", "him", "his", "she", "her", "they", "them", "their", "will",
        "would", "can", "could", "should", "shall", "may", "might", "must", "not", "no",
        "yes", "so", "if", "then", "than", "too", "very", "just", "any", "some", "all",
        "also", "up", "out", "into", "over", "after", "before", "during", "while",
        "really", "get", "got", "let", "lets", "please", "thing", "things", "anything",
        "something", "everything", "happened", "happen", "going", "go", "again", "one",
        "today", "yesterday", "tomorrow", "week", "weeks", "last", "previous", "morning",
        "afternoon", "evening", "ago", "earlier", "days", "day", "two", "three",
        "four", "five", "six", "seven", "hey", "ok", "okay", "um", "uh", "like",
    ]

    private static let spanish: Set<String> = [
        "a", "al", "ante", "con", "contra", "de", "del", "desde", "en", "entre", "hacia",
        "hasta", "para", "por", "segun", "sin", "sobre", "tras", "el", "la", "los", "las",
        "lo", "un", "una", "unos", "unas", "y", "e", "o", "u", "ni", "que", "quien",
        "quienes", "cual", "cuales", "cuando", "donde", "como", "cuanto", "cuanta",
        "cuantos", "cuantas", "porque", "pero", "si", "no", "ya", "se", "me", "te", "le",
        "les", "nos", "os", "mi", "mis", "tu", "tus", "su", "sus", "nuestro", "nuestra",
        "nuestros", "nuestras", "es", "son", "fue", "fueron", "era", "ser", "estar",
        "esta", "este", "esto", "estos", "estas", "ese", "esa", "eso", "esos", "esas",
        "ha", "han", "he", "hemos", "hay", "habia", "haber", "algo", "alguien", "nada",
        "todo", "todos", "muy", "mas", "menos", "tambien", "otro", "otra", "yo", "ella",
        "ellos", "ellas", "hoy", "ayer", "anteayer", "manana", "semana", "semanas",
        "pasada", "pasado", "ultima", "ultimo", "anterior", "hace", "dia", "dias", "dos",
        "tres", "cuatro", "cinco", "seis", "siete", "pues", "bueno", "vale", "oye",
        "entonces", "eh", "favor", "porfa", "paso", "estuvo",
    ]

    /// The asking itself: "what did Marta say", "recuérdame qué dijo".
    private static let asking: Set<String> = [
        "say", "said", "says", "tell", "told", "mention", "mentioned", "talk", "talked",
        "discuss", "discussed", "agree", "agreed", "decide", "decided", "remind",
        "summarize", "summarise", "recap", "promise", "promised",
        "dijo", "dijeron", "dije", "dicho", "dijimos", "decir", "quedamos", "quedaron",
        "quedo", "quedado", "acordamos", "acordaron", "acordo", "acordado", "hablamos",
        "hablaron", "hablo", "hablado", "decidimos", "decidieron", "decidio", "decidido",
        "comento", "comentaron", "comentado", "menciono", "mencionaron", "mencionado",
        "recuerdame", "recordame", "dime", "decime", "cuentame", "contame", "resumeme",
        "prometio", "prometimos", "prometido",
    ]

    // MARK: - Days

    /// The days a question names: today, yesterday, the day before, a
    /// weekday, this week, last week, or a few days ago, in English and
    /// Spanish. The first one named wins.
    ///
    /// A weekday is the most recent one before today, unless it is what
    /// the call was about ("about Friday", "para el viernes"): asked on a Tuesday,
    /// "Tuesday" and "el martes" are a week ago, because today's call is
    /// "today". "Last Tuesday" is the same day; people use it for both, and
    /// the nearest is the one a wrong guess costs least on.
    public static func range(in question: String, now: Date, calendar: Calendar) -> DateInterval? {
        let words = CallText.tokens(question).map(\.text)
        let today = calendar.startOfDay(for: now)
        func days(back: Int) -> DateInterval? {
            guard let start = calendar.date(byAdding: .day, value: -back, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }

        for (i, word) in words.enumerated() {
            let next = i + 1 < words.count ? words[i + 1] : nil
            let previous = i > 0 ? words[i - 1] : nil
            switch word {
            case "today", "hoy":
                return days(back: 0)
            case "morning" where previous == "this":
                return days(back: 0)
            case "manana" where previous == "esta":
                return days(back: 0)
            case "yesterday", "ayer":
                // "day before yesterday", "antes de ayer"
                if i >= 2, words[i - 1] == "before" || words[i - 1] == "de",
                   words[i - 2] == "day" || words[i - 2] == "antes" {
                    return days(back: 2)
                }
                return days(back: 1)
            case "anteayer":
                return days(back: 2)
            case "week" where previous == "this" || previous == "last" || previous == "previous":
                return week(back: previous == "this" ? 0 : 1, now: now, calendar: calendar)
            case "semana":
                if next == "pasada" || next == "anterior" || previous == "ultima" {
                    return week(back: 1, now: now, calendar: calendar)
                }
                if previous == "esta" { return week(back: 0, now: now, calendar: calendar) }
            case "ago":
                if i >= 2, let count = Self.count(words[i - 2]), words[i - 1].hasPrefix("day") {
                    return days(back: count)
                }
            case "hace":
                if let next, let count = Self.count(next), i + 2 < words.count,
                   words[i + 2].hasPrefix("dia") {
                    return days(back: count)
                }
            default:
                if let weekday = Self.weekday(word), !Self.isTopic(at: i, in: words) {
                    let current = calendar.component(.weekday, from: today)
                    let back = (current - weekday + 7) % 7
                    return days(back: back == 0 ? 7 : back)
                }
            }
        }
        return nil
    }

    /// A weekday the call was about rather than on: "what did Marta say
    /// about Friday", "¿qué quedamos para el viernes?", "next Monday", "el
    /// lunes que viene".
    private static func isTopic(at i: Int, in words: [String]) -> Bool {
        if i + 2 < words.count, words[i + 1] == "que", words[i + 2] == "viene" { return true }
        var j = i - 1
        while j >= 0, ["the", "this", "el", "este"].contains(words[j]) { j -= 1 }
        guard j >= 0 else { return false }
        return Self.ahead.contains(words[j])
    }

    private static let ahead: Set<String> = [
        "about", "for", "until", "till", "by", "before", "after", "next",
        "sobre", "para", "hasta", "antes", "despues", "proximo",
    ]

    private static func week(back: Int, now: Date, calendar: Calendar) -> DateInterval? {
        guard let day = calendar.date(byAdding: .day, value: -7 * back, to: now) else { return nil }
        return calendar.dateInterval(of: .weekOfYear, for: day)
    }

    /// Calendar weekday numbers: Sunday is 1, as `Calendar` has them.
    private static func weekday(_ word: String) -> Int? {
        switch word {
        case "sunday", "domingo": 1
        case "monday", "lunes": 2
        case "tuesday", "martes": 3
        case "wednesday", "miercoles": 4
        case "thursday", "jueves": 5
        case "friday", "viernes": 6
        case "saturday", "sabado": 7
        default: nil
        }
    }

    /// A small count, in digits or words: "3 days ago", "hace dos días".
    private static func count(_ word: String) -> Int? {
        if let number = Int(word), (1...31).contains(number) { return number }
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                     "un": 1, "uno": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5,
                     "seis": 6, "siete": 7]
        return words[word]
    }
}

extension CallText {
    /// The plural taken off, so "budgets" finds "budget" and "reuniones"
    /// finds "reunión". Deliberately crude, and the same on both sides of a
    /// match, which is all a match needs.
    public static func stem(_ word: String) -> String {
        guard word.count >= 4, word.allSatisfy(\.isLetter) else { return word }
        if word.hasSuffix("iones") { return String(word.dropLast(2)) }
        for ending in ["ches", "shes", "sses", "xes"] where word.hasSuffix(ending) {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
            return String(word.dropLast())
        }
        return word
    }

    /// The words of a transcript as a search matches them: folded,
    /// stemmed, and nothing left out.
    public static func terms(_ text: String) -> [String] {
        tokens(text).map { stem($0.text) }
    }
}
