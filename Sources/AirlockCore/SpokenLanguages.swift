import Foundation

/// Which second language to OFFER for dictation, read from what the Mac is
/// already set up for.
///
/// Dictation recognises ONE language unless it is told about a second — there is
/// no automatic detection to switch on, `SpeechTranscriber` takes a single
/// locale — and that choice only ever existed in Settings › Dictation. So a
/// first attempt in the other language produced nothing at all, with nothing on
/// screen to say why: reported from a clean install on 2026-09-18, an English
/// Mac spoken to in Spanish. The wizard asks now, and this is what it puts in
/// the question.
///
/// **A suggestion, never an answer.** A second language downloads another model
/// and costs ~1.3× on every hold (`DictationModel.secondaryLocaleIdentifier`),
/// so it stays off until somebody says yes. The Mac's own language list is the
/// best evidence available — a person who reads Spanish on an English Mac is a
/// fair bet to speak it — and evidence is all it is.
public enum SpokenLanguages {

    /// - Parameters:
    ///   - preferred: `Locale.preferredLanguages`, in the order macOS ranks them.
    ///   - primary: what dictation already listens for; empty means "follow the
    ///     system", which is the first preferred language.
    ///   - available: the identifiers speech models actually exist for.
    /// - Returns: an identifier taken from `available`, or nil when the Mac
    ///   gives no reason to think a second language is wanted.
    public static func suggestedSecond(preferred: [String], primary: String,
                                       available: [String]) -> String? {
        let spoken = languageCode(primary.isEmpty ? (preferred.first ?? "") : primary)

        for candidate in preferred {
            let code = languageCode(candidate)
            // The same language in another region is the same language to
            // speak. Offering "English (UK)" to an English speaker is noise,
            // and the race would spend 1.3× deciding between two spellings of
            // the same yes.
            guard !code.isEmpty, code != spoken else { continue }

            let matches = available.filter { languageCode($0) == code }
            guard !matches.isEmpty else { continue }

            // Their own region first — someone in Spain should be offered
            // Spanish (Spain) rather than whichever Spanish sorts first — then
            // any region at all, because a model that exists beats an exact
            // match that does not.
            let region = Locale(identifier: candidate).region?.identifier
            return matches.first { Locale(identifier: $0).region?.identifier == region }
                ?? matches.sorted().first
        }
        return nil
    }

    /// `Locale.preferredLanguages` speaks BCP-47 (`es-ES`) and the speech list
    /// speaks ICU (`es_ES`). `Locale(identifier:)` reads both, so the codes can
    /// be compared without either side being rewritten first.
    private static func languageCode(_ identifier: String) -> String {
        Locale(identifier: identifier).language.languageCode?.identifier ?? ""
    }
}
