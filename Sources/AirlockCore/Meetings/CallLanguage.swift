import Foundation
import NaturalLanguage

/// Which language a call is in: the languages it is listened for in while it
/// runs, and the one its notes are written in once it has ended.
///
/// **Apple's recogniser cannot tell a language by ear.** `SpeechTranscriber`
/// transcribes in the locale it is handed, so the languages to listen for have
/// to come from somewhere: the call languages picked in Settings or, left
/// alone, dictation's, which is what every call used before there was a
/// choice. A call is often not in the language somebody dictates in.
///
/// **And the model that writes the notes has to be told the language by
/// name.** Told only to "write in the language of the transcript", Apple's
/// on-device model answered a Spanish call in English; told "Write them in
/// Spanish.", it writes Spanish. So before the notes are written, the
/// transcript's own text is read for its language and weighed against the
/// language the recogniser was listening in (`decide`).
public enum CallLanguage {
    /// The language calls are in, as a locale identifier. Empty: the same as
    /// dictation.
    public static let primaryKey = "meetings.locale"
    /// A second language calls are listened for in. Empty: none. Read only
    /// while `primaryKey` is set.
    public static let secondaryKey = "meetings.locale.secondary"

    // MARK: - Listening

    /// The languages a call is listened for in, before they are matched to a
    /// model this Mac can run.
    public struct Wanted: Equatable, Sendable {
        /// Empty means the Mac's own language, as dictation reads it.
        public var primary: String
        /// Empty means none.
        public var secondary: String
        /// Nothing was picked for calls, so these are dictation's.
        public var fromDictation: Bool

        public init(primary: String, secondary: String, fromDictation: Bool) {
            self.primary = primary
            self.secondary = secondary
            self.fromDictation = fromDictation
        }
    }

    /// The call languages when one is picked, dictation's otherwise, and
    /// always as a pair: "same as dictation" brings dictation's second
    /// language along, and a call language of your own never picks up
    /// dictation's second, which was chosen for a different conversation.
    public static func wanted(callPrimary: String, callSecondary: String,
                              dictationPrimary: String, dictationSecondary: String) -> Wanted {
        guard !callPrimary.isEmpty else {
            return Wanted(primary: dictationPrimary, secondary: dictationSecondary, fromDictation: true)
        }
        return Wanted(primary: callPrimary, secondary: callSecondary, fromDictation: false)
    }

    // MARK: - Writing the notes

    /// What a call's text says about its own language.
    public struct Reading: Equatable, Sendable {
        /// The likeliest languages by code ("es"), each with its probability.
        public var hypotheses: [String: Double]
        /// How much text that was read from.
        public var characters: Int

        public init(hypotheses: [String: Double], characters: Int) {
            self.hypotheses = hypotheses
            self.characters = characters
        }

        /// The likeliest language, if the text leans anywhere at all.
        public var top: (code: String, probability: Double)? {
            hypotheses.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
                .map { ($0.key, $0.value) }
        }
    }

    /// The language the notes are written in, and what said so.
    public struct Decision: Equatable, Sendable {
        public enum Source: String, Sendable {
            /// The transcript's text, long and sure enough to be trusted.
            case text
            /// The language the recogniser was listening in.
            case engine
        }

        /// The language's code, e.g. "es".
        public var code: String
        /// Its name in English, the way the prompt says it: "Spanish".
        public var name: String
        public var source: Source
    }

    /// Characters of text before its own language outranks the recogniser's:
    /// about a paragraph. Shorter, a few words can lean to a neighbouring
    /// language ("Hola. Sí. Vale." is part Catalan to the recogniser).
    public static let enoughText = 200
    /// How sure the text has to be. A call in one language scores 0.99; one
    /// that switches between two scores well below this.
    public static let sureEnough = 0.8
    /// With nothing from the recogniser at all, how clearly the text has to
    /// lean before it is named.
    static let leansEnough = 0.5

    /// The text's language when there is enough of it and it is sure; the
    /// recogniser's otherwise. Nil when neither can say, and the prompt then
    /// asks for the transcript's language without naming it.
    ///
    /// The text wins when it is sure because the text is all the model reads:
    /// a recogniser set to Spanish that heard an English call still writes
    /// English words, and notes in Spanish about them would be a translation
    /// nobody asked for.
    public static func decide(engine: [String], reading: Reading) -> Decision? {
        if let top = reading.top, reading.characters >= enoughText, top.probability >= sureEnough,
           let decision = decision(top.code, .text) {
            return decision
        }
        // Each side of a call settles on its own language, so the two may
        // differ. The one the text leans to, then; the first on a tie.
        let heard = engine.compactMap { code(of: $0) }.reduce(into: [String]()) { kept, code in
            if !kept.contains(code) { kept.append(code) }
        }
        if var best = heard.first {
            for code in heard.dropFirst()
            where reading.hypotheses[code, default: 0] > reading.hypotheses[best, default: 0] {
                best = code
            }
            return decision(best, .engine)
        }
        if let top = reading.top, top.probability >= leansEnough {
            return decision(top.code, .text)
        }
        return nil
    }

    /// What `NLLanguageRecognizer` makes of `text`. Scripts of one language
    /// ("zh-Hans", "zh-Hant") count as that language.
    public static func reading(of text: String) -> Reading {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        var hypotheses: [String: Double] = [:]
        for (language, probability) in recognizer.languageHypotheses(withMaximum: 5)
        where language != .undetermined {
            guard let base = code(of: language.rawValue) else { continue }
            hypotheses[base, default: 0] += probability
        }
        return Reading(hypotheses: hypotheses, characters: text.count)
    }

    /// The whole check for one call, as the summariser runs it.
    public struct Check: Equatable, Sendable {
        /// The recogniser's languages as the record has them: the one each
        /// side settled on, or every one listened for when the app quit
        /// before the call ended.
        public var engine: [String]
        public var reading: Reading
        public var decision: Decision?

        /// For meetings.log: languages, scores and a length, never a word of
        /// what was said.
        public var logLine: String {
            let heard = engine.isEmpty ? "none" : engine.joined(separator: " + ")
            let text = reading.top.map { "\($0.code) " + String(format: "%.2f", $0.probability) } ?? "none"
            let outcome = decision.map { "\($0.name), from the \($0.source == .text ? "text" : "engine")" }
                ?? "not named"
            return "language check: engine \(heard), text \(text) over \(reading.characters) chars → \(outcome)"
        }
    }

    public static func check(_ record: MeetingRecord) -> Check {
        let text = record.spokenSegments.map(\.text).joined(separator: " ")
        let reading = reading(of: text)
        return Check(engine: record.languages, reading: reading,
                     decision: decide(engine: record.languages, reading: reading))
    }

    /// "es" for "es_ES", "es-MX" or "es". Nil for an empty identifier.
    static func code(of identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        return Locale.Language(identifier: identifier).languageCode?.identifier
    }

    /// Only a language with a name can be asked for by name.
    private static func decision(_ code: String, _ source: Decision.Source) -> Decision? {
        guard let name = Locale(identifier: "en").localizedString(forLanguageCode: code),
              name != code else { return nil }
        return Decision(code: code, name: name, source: source)
    }
}
