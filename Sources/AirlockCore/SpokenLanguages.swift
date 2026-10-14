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

    // MARK: - Naming a language

    /// The language and region a locale identifier is spoken as, without the
    /// keywords macOS adds for formats: `en_US@rg=eszzzz`, which is how a Mac
    /// set to English (US) with Spain as its region spells `Locale.current`,
    /// is `en_US`. ICU spelling (`zh_Hans_CN`), the speech lists' own, for
    /// BCP-47 input too.
    ///
    /// The keyword is about dates and currency, not speech: the speech
    /// frameworks already match `en_US@rg=eszzzz` to their en_US model
    /// (`supportedLocale(equivalentTo:)`, checked on such a Mac), and the
    /// language code reads `en` either way. What it broke is naming:
    /// `localizedString(forIdentifier:)` answers nil for it, so Settings
    /// showed the raw identifier where "English (United States)" belonged.
    ///
    /// The region is the language's own (`US`), not the override (`ES`),
    /// which is what `Locale.region` reads. A variant is kept (`ca_ES_VALENCIA`
    /// is Valencian); an identifier with no language comes back as it was.
    public static func plain(_ identifier: String) -> String {
        let components = Locale.Language.Components(identifier: identifier)
        guard let code = components.languageCode?.identifier, !code.isEmpty else { return identifier }
        let parts = [code, components.script?.identifier, components.region?.identifier,
                     Locale(identifier: identifier).variant?.identifier]
        return parts.compactMap { $0 }.joined(separator: "_")
    }

    /// "English (United States)" for `en_US` and for `en_US@rg=eszzzz` alike,
    /// in `displayLocale`'s words. Nil when nothing can name it, so the caller
    /// picks the fallback that suits its sentence.
    public static func name(_ identifier: String, displayLocale: Locale = .current) -> String? {
        guard !identifier.isEmpty,
              let name = displayLocale.localizedString(forIdentifier: plain(identifier)),
              !name.isEmpty else { return nil }
        return name
    }

    /// `Locale.preferredLanguages` speaks BCP-47 (`es-ES`) and the speech list
    /// speaks ICU (`es_ES`). `Locale(identifier:)` reads both, so the codes can
    /// be compared without either side being rewritten first.
    private static func languageCode(_ identifier: String) -> String {
        Locale(identifier: identifier).language.languageCode?.identifier ?? ""
    }
}
