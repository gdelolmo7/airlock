import AVFoundation
import AirlockCore
import CoreMedia
import FoundationModels
import Speech

/// The languages this Mac can listen to a call in, and which recogniser
/// listens in each (`CallLanguageFollow.listener`).
///
/// Asked once per call: the lists come from the OS and do not change while
/// it runs, and a model downloaded mid-call is checked for itself
/// (`CallListening.format`), not looked up here.
struct CallListeners: Sendable, Equatable {
    /// Locale identifiers `SpeechTranscriber` knows: 30 on this Mac.
    let speech: [String]
    /// Locale identifiers `DictationTranscriber` knows: 54, Catalan among
    /// them.
    let dictation: [String]
    /// The dictation locales whose model is on this Mac already.
    let installedDictation: Set<String>
    /// Every language either one knows, by code: what each line's language
    /// is read among (`CallLanguageFollow.language`).
    let codes: Set<String>

    init(speech: [String], dictation: [String], installedDictation: Set<String> = []) {
        self.speech = speech
        self.dictation = dictation
        self.installedDictation = installedDictation
        codes = Set((speech + dictation).compactMap { Locale.Language(identifier: $0).languageCode?.identifier })
    }

    static let none = CallListeners(speech: [], dictation: [])

    static func current() async -> CallListeners {
        async let speech = SpeechTranscriber.supportedLocales
        async let dictation = DictationTranscriber.supportedLocales
        async let installed = DictationTranscriber.installedLocales
        return await CallListeners(speech: speech.map(\.identifier).sorted(),
                                   dictation: dictation.map(\.identifier).sorted(),
                                   installedDictation: Set(installed.map(\.identifier)))
    }

    /// Dictation's locales speech does not know: the ones only the older
    /// recogniser can listen in.
    var dictationOnly: [String] {
        let speech = Set(speech)
        return dictation.filter { !speech.contains($0) }
    }
}

/// Making and preparing a recogniser for a `CallLanguageFollow.Listener`,
/// and reading its results into lines.
enum CallListening {
    /// The recogniser for `listener`, set up the way the notes need it:
    /// finished sentences, with the confidence the race and the follow
    /// decide on.
    ///
    /// `partials` adds the recogniser's running guess at the words being
    /// said, as dictation shows them, for a call's transcript to show as
    /// they come. Guesses are only ever shown: the notes, the race and the
    /// follow read the finished sentences alone. A recording being read has
    /// no one watching, so it goes without.
    ///
    /// Dictation as `.timeIndexedLongDictation` sets it up: the confidence
    /// table in `CallLanguageFollow.dictationLift` was measured with exactly
    /// this, without partials.
    static func module(for listener: CallLanguageFollow.Listener, partials: Bool = false) -> any SpeechModule {
        let locale = Locale(identifier: listener.identifier)
        switch listener.module {
        case .speech:
            // Word times too: what the other side's voices are laid over at
            // the end of a call (`CallVoices`).
            return SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                     reportingOptions: partials ? [.volatileResults] : [],
                                     attributeOptions: [.transcriptionConfidence, .audioTimeRange])
        case .dictation:
            let preset = DictationTranscriber.Preset.timeIndexedLongDictation
            let reporting = partials ? preset.reportingOptions.union([.volatileResults])
                                     : preset.reportingOptions.subtracting([.volatileResults])
            return DictationTranscriber(locale: locale, contentHints: preset.contentHints,
                                        transcriptionOptions: preset.transcriptionOptions,
                                        reportingOptions: reporting,
                                        attributeOptions: preset.attributeOptions
                                            .union([.audioTimeRange, .transcriptionConfidence]))
        }
    }

    /// The listener for a language the person picked: speech when it knows
    /// the language, dictation when only dictation does, nil when neither.
    /// Matched the way dictation matches (`SpeechSession.resolvedLocale`),
    /// so "en_US@rg=eszzzz" is en_US.
    ///
    /// Speech's match is checked against its own list: asked for Catalan it
    /// answers ca_ES, a locale it has no model for and is not among its
    /// `supportedLocales` (measured: for ca, ca_ES, ca_AD alike). Taken at
    /// its word, a Catalan call would wait for a model that never comes.
    static func resolved(_ preferred: Locale) async -> CallLanguageFollow.Listener? {
        let speech = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: preferred),
           speech.contains(match.identifier(.bcp47)) {
            return CallLanguageFollow.Listener(identifier: match.identifier, module: .speech)
        }
        if let match = await DictationTranscriber.supportedLocale(equivalentTo: preferred) {
            return CallLanguageFollow.Listener(identifier: match.identifier, module: .dictation)
        }
        return nil
    }

    /// The audio format that suits every one of `listeners`, or nil when a
    /// model is missing. The readiness check, as for dictation
    /// (`SpeechSession.analyzerFormat`): nil until the model is installed.
    static func format(for listeners: [CallLanguageFollow.Listener]) async -> AVAudioFormat? {
        await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: listeners.map { module(for: $0) })
    }

    /// Downloads `listener`'s model if it is missing, and reserves its
    /// language. False when the download failed.
    @discardableResult
    static func prepare(_ listener: CallLanguageFollow.Listener) async -> Bool {
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module(for: listener)]) {
                try await request.downloadAndInstall()
            }
        } catch {
            return false
        }
        _ = try? await AssetInventory.reserve(locale: Locale(identifier: listener.identifier))
        return true
    }

    // MARK: - Results into lines

    /// One line as a recogniser heard it, in seconds of its audio.
    struct Heard: Sendable {
        var text: String
        var start: TimeInterval?
        var end: TimeInterval?
        /// Σ confidence × characters, and the characters scored: zero when
        /// the recogniser gives no confidence (ca_ES dictation never does).
        var weighted: Double
        var scored: Int
        /// The words as the recogniser timed them, in seconds of its audio:
        /// empty when it gave no times.
        var words: [CallLanguageFollow.Timed] = []
    }

    /// A finished result as lines. Speech gives a line every sentence or
    /// two and is kept as it comes; dictation gives one result per 5–23 s
    /// and is cut where the speaker paused (`CallLanguageFollow.pieces`).
    /// Each piece carries the result's confidence for its share of the
    /// characters: dictation scores whole results, not the pieces.
    static func lines(of text: AttributedString, range: CMTimeRange, cut: Bool) -> [Heard] {
        var weighted = 0.0
        var scored = 0
        for run in text.runs {
            guard let confidence = run.transcriptionConfidence else { continue }
            let count = text[run.range].characters.count
            weighted += Double(confidence) * Double(count)
            scored += count
        }
        let mean = scored > 0 ? weighted / Double(scored) : nil
        let whole = String(text.characters)

        let runs = text.runs.map { run -> CallLanguageFollow.Timed in
            let time = run.audioTimeRange
            let start = time.map(\.start.seconds).flatMap { $0.isFinite ? $0 : nil }
            let end = time.map { ($0.start + $0.duration).seconds }.flatMap { $0.isFinite ? $0 : nil }
            return CallLanguageFollow.Timed(text: String(text[run.range].characters), start: start, end: end)
        }
        let timed = runs.filter { $0.start != nil && $0.end != nil }

        func heard(_ text: String, _ start: TimeInterval?, _ end: TimeInterval?,
                   words: [CallLanguageFollow.Timed]) -> Heard {
            let count = text.count
            return Heard(text: text, start: start, end: end,
                         weighted: mean.map { $0 * Double(count) } ?? 0, scored: mean == nil ? 0 : count,
                         words: words)
        }
        let start = range.start.seconds
        let end = (range.start + range.duration).seconds
        let resultStart = start.isFinite ? start : nil
        let resultEnd = end.isFinite ? end : nil
        guard cut, !timed.isEmpty else { return [heard(whole, resultStart, resultEnd, words: timed)] }

        return CallLanguageFollow.pieces(of: runs).map { piece in
            let inside = timed.filter { word in
                let middle = (word.start! + word.end!) / 2
                return middle >= (piece.start ?? -.infinity) && middle <= (piece.end ?? .infinity)
            }
            return heard(piece.text, piece.start, piece.end, words: inside)
        }
    }
}

/// Which languages Apple's notes writer reads (`SystemLanguageModel`):
/// 23 on this Mac, and not Catalan. Asked of a locale identifier.
enum CallNotesWriter {
    static let canRead: @Sendable (String) -> Bool = { identifier in
        SystemLanguageModel.default.supportsLocale(Locale(identifier: identifier))
    }
}
