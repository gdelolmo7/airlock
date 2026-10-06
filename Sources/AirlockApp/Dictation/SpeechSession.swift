import AVFoundation
import Speech
import AirlockCore

/// One dictation: set up the analyzer, pump results into a transcript, shut down
/// in the one order that does not deadlock.
///
/// All of the awkwardness here was measured rather than guessed:
///
/// - `SpeechAnalyzer` is an `actor` and **every** member is isolated, including
///   the ones that look synchronous.
/// - `finalizeAndFinishThroughEndOfInput()` **blocks until the input sequence
///   terminates**. Called before the audio stream is closed it never returns —
///   observed still hung after six seconds, returning within three of the close.
///   The ordering in `finish()` is therefore not a style choice.
/// - Readiness is `bestAvailableAudioFormat != nil`, **not**
///   `AssetInventory.status`, which reported `.supported` for a locale whose
///   model was installed and working.
@MainActor
final class SpeechSession {
    enum Failure: LocalizedError {
        case noSupportedLocale(String)
        case noModel(String)

        var errorDescription: String? {
            switch self {
            case .noSupportedLocale(let locale):
                return "Dictation doesn't support \(locale) yet."
            case .noModel(let locale):
                return "The speech model for \(locale) isn't installed."
            }
        }
    }

    /// One per locale in the race — see `begin`. Index 0 is always the primary.
    private var takes: [Take] = []
    private var analyzer: SpeechAnalyzer?

    /// A transcriber, its pump, and the confidence it accumulated.
    private final class Take {
        let localeIdentifier: String
        let transcriber: SpeechTranscriber
        var transcript = DictationTranscript()
        var pump: Task<Void, Never>?
        /// Σ (confidence × characters) and the characters, so the mean stays
        /// character-weighted without keeping every run.
        var weighted = 0.0
        var characters = 0
        var confidence: Double { characters > 0 ? weighted / Double(characters) : 0 }
        /// The mean confidence of the LATEST result carrying any, replaced
        /// rather than accumulated.
        ///
        /// A second score, for the live preview only, because the one above
        /// cannot serve it: that one counts finals exclusively and so reads zero
        /// for both takes until the first final lands — which on a short hold
        /// can be most of the time the user spends talking. Replacing rather
        /// than summing is what makes it safe to feed volatile results in:
        /// volatile results are revised in place, so *adding* them would count
        /// the same audio repeatedly and favour whichever transcriber churned
        /// more. Taking the newest one instead just reads the current estimate.
        ///
        /// Stays at zero if the recogniser attaches no confidence to volatile
        /// results — in which case the preview simply waits for the first final
        /// before it can switch, which is the old behaviour and no worse.
        var liveConfidence = 0.0

        init(localeIdentifier: String, transcriber: SpeechTranscriber) {
            self.localeIdentifier = localeIdentifier
            self.transcriber = transcriber
        }
    }

    /// The live transcript. Pure type, main-actor owned, updated as results
    /// arrive so the panel can show words appearing.
    ///
    /// **Follows whichever take is currently winning, not always the primary.**
    /// It used to be hardwired to index 0, which made speaking the secondary
    /// language a strange experience: the race worked and delivered the right
    /// Spanish at the end, but for the whole time you were talking you watched
    /// the English transcriber's attempt at Spanish audio appear word by word.
    /// The product was right and the progress indicator was nonsense.
    ///
    /// Still a progress indicator, so it can change its mind — see
    /// `TranscriptRace.liveChoice`. `finish()` remains the product, and the
    /// final decision is made over the whole hold rather than on partial
    /// evidence, so the last live frame and the delivered text can still differ.
    private(set) var transcript = DictationTranscript()
    private(set) var lastError: String?

    /// The locale the preview is following. Primary until something earns the
    /// switch.
    private var showingLocaleIdentifier = ""

    // MARK: - Readiness

    /// `Locale.current` is not safe to hand over directly — measured as
    /// `en_US@rg=eszzzz` on this machine (US language, Spain region), which is
    /// not a locale the recogniser knows. Normalising is mandatory, not tidy.
    static func resolvedLocale(preferred: Locale = .current) async -> Locale? {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) {
            return match
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
    }

    /// The audio format the analyzer wants, or nil when no model can serve these
    /// locales. Doubles as the readiness check — a non-nil format is the only
    /// trustworthy signal that transcription will actually work.
    ///
    /// Takes every locale in the race, not just the primary. One analyzer feeds
    /// both transcribers from one tap, so the format has to satisfy both; asking
    /// only about the primary would configure the converter for a format the
    /// secondary cannot read, and the secondary would lose every race by
    /// producing nothing. (Measured for en-US + es-ES: 16 kHz mono suits both.)
    static func analyzerFormat(for locales: [Locale]) async -> AVAudioFormat? {
        let probes = locales.map { SpeechTranscriber(locale: $0, preset: .progressiveTranscription) }
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: probes)
    }

    /// Install the model for a locale if it is missing, and reserve it.
    ///
    /// Reservations are per-process and empty at every launch, so this runs on
    /// each start rather than once ever — measured at 0.55s warm against 2.9s
    /// cold. Failure is not fatal: `analyzerFormat` is what decides whether we
    /// can proceed.
    static func prepareModel(for locale: Locale) async {
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try? await request.downloadAndInstall()
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    // MARK: - Lifecycle

    /// Begin analysing `input`. Results stream into `transcript` until `finish`.
    ///
    /// `secondary`, when set, is recognised over the same audio in the same pass
    /// and may win at `finish()` — see `TranscriptRace`. One analyzer hosts both
    /// transcribers, which is what keeps this at ~1.3× the cost of one rather
    /// than a second recording or a second pass.
    ///
    /// `vocabulary` is names the recogniser should expect — installed apps,
    /// site aliases, Shortcut names, and the product names people say at a
    /// notch that drives coding agents. Without it "Claude" is transcribed as
    /// whatever English sounds alike ("cloud", "clot", "clawed" — all
    /// observed), and every match downstream is against a word nobody said.
    /// One context serves every transcriber in the race, so the biasing holds
    /// in the secondary language too — which is most of what "works in other
    /// languages" needs from this layer.
    func begin(locale: Locale, secondary: Locale? = nil,
               vocabulary: [String] = [],
               input: AsyncStream<AnalyzerInput>) async throws {
        transcript.reset()
        lastError = nil

        // Explicit options rather than a preset: `.volatileResults` gives live
        // partials for the indicator and `.fastResults` shortens the wait for a
        // final, and no preset combines exactly those two.
        // `.transcriptionConfidence` is what the race is decided on.
        let locales = [locale] + (secondary.map { [$0] } ?? [])
        takes = locales.map { locale in
            Take(localeIdentifier: locale.identifier,
                 transcriber: SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: [.transcriptionConfidence]))
        }
        showingLocaleIdentifier = locale.identifier

        let analysisContext = AnalysisContext()
        if !vocabulary.isEmpty {
            analysisContext.contextualStrings = [.general: vocabulary]
        }
        let analyzer = SpeechAnalyzer(inputSequence: input,
                                      modules: takes.map(\.transcriber),
                                      analysisContext: analysisContext)
        self.analyzer = analyzer

        // Results are read independently of the analyzer, one task per take.
        for take in takes {
            let transcriber = take.transcriber
            take.pump = Task { [weak self, weak take] in
                do {
                    for try await result in transcriber.results {
                        guard let self, let take else { return }
                        let text = String(result.text.characters)
                        // `result.text` is CUMULATIVE over its range, not a
                        // delta — DictationTranscript is what keeps that from
                        // becoming "AppApproveApprove the".
                        take.transcript.apply(text: text, isFinal: result.isFinal)

                        // Scored once, read twice — the two scores differ only
                        // in whether they accumulate, so computing the run loop
                        // separately for each would be the same arithmetic done
                        // twice and a chance for them to disagree.
                        var weighted = 0.0
                        var characters = 0
                        for run in result.text.runs {
                            guard let confidence = run.transcriptionConfidence else { continue }
                            let count = result.text[run.range].characters.count
                            weighted += Double(confidence) * Double(count)
                            characters += count
                        }
                        if characters > 0 {
                            // Every result, volatile included: the preview has
                            // to pick a language WHILE the words appear.
                            take.liveConfidence = weighted / Double(characters)
                            // Finals only. Volatile results are revised in
                            // place, so accumulating them would count the same
                            // audio repeatedly and weight whichever transcriber
                            // happened to churn more.
                            if result.isFinal {
                                take.weighted += weighted
                                take.characters += characters
                            }
                        }
                        self.refreshLivePreview()
                    }
                } catch {
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    /// Point the preview at whichever take is ahead, and copy its text out.
    ///
    /// A copy rather than a computed property reading `takes`, so `transcript`
    /// survives `finish()` clearing them — the ticker in `DictationModel` polls
    /// every 120ms and would otherwise blank the panel in the window between the
    /// analyzer finishing and listening being switched off.
    private func refreshLivePreview() {
        guard takes.count > 1 else {
            transcript = takes.first?.transcript ?? transcript
            return
        }
        let candidates = takes.map {
            TranscriptRace.Candidate(localeIdentifier: $0.localeIdentifier,
                                     text: $0.transcript.display,
                                     confidence: $0.liveConfidence)
        }
        let choice = TranscriptRace.liveChoice(among: candidates,
                                               showing: showingLocaleIdentifier)
        if choice != showingLocaleIdentifier {
            dictationLog("  live preview → \(choice) " + candidates
                .map { String(format: "%@ %.3f", $0.localeIdentifier, $0.confidence) }
                .joined(separator: " · "))
            showingLocaleIdentifier = choice
        }
        guard let take = takes.first(where: { $0.localeIdentifier == choice }) else { return }
        transcript = take.transcript
    }

    /// Close down and return what was said, within a bounded time.
    ///
    /// The caller MUST have closed the audio stream first — `AudioCapture.stop`
    /// does it. `finalizeAndFinishThroughEndOfInput` waits on the input sequence
    /// ending, so calling it against a live stream hangs forever.
    ///
    /// **And it can hang anyway.** Observed on a short hold with no speech in
    /// it, stream already closed: the finalize simply never returned. Everything
    /// that ends a dictation sits after this call, so one stall left `isListening`
    /// true forever — the panel stuck open over a microphone that had already
    /// been stopped, every later hold refused as "a hold is already running",
    /// and the serial gesture chain blocked behind a task that would never
    /// complete. Dictation was dead until the app was relaunched.
    ///
    /// So it is bounded. The limit is generous because a real two-minute
    /// dictation has a lot to finalise, and overrunning it is not a disaster:
    /// the partial transcript has been accumulating in `Take` all along, so a
    /// timeout still delivers approximately the right words rather than none.
    @discardableResult
    func finish(within limit: Duration = .seconds(10)) async -> String {
        if !(await settles(within: limit)) {
            dictationLog("  finish TIMED OUT after \(limit) — abandoning the analyzer")
            // Out of band and never awaited: whatever is wedged in there must
            // not become the caller's problem a second time.
            let stuck = analyzer
            analyzer = nil
            for take in takes { take.pump?.cancel() }
            Task { await stuck?.cancelAndFinishNow() }
        }

        let candidates = takes.map {
            TranscriptRace.Candidate(localeIdentifier: $0.localeIdentifier,
                                     text: $0.transcript.deliverable,
                                     confidence: $0.confidence)
        }
        let primary = takes.first?.localeIdentifier ?? ""
        let winner = TranscriptRace.winner(among: candidates, primary: primary)
        if takes.count > 1 {
            dictationLog("  race " + candidates
                .map { String(format: "%@ %.3f", $0.localeIdentifier, $0.confidence) }
                .joined(separator: " · ")
                + " → \(winner?.localeIdentifier ?? "nothing")")
        }

        takes = []
        analyzer = nil
        return winner?.text ?? transcript.deliverable
    }

    /// True if the analyzer shut down inside `limit`.
    ///
    /// A one-shot stream rather than a task group, and that is the whole point:
    /// a group waits for its LOSER at scope exit, so racing a hang inside one
    /// hangs the race too. Both tasks below are unstructured, so the stuck one
    /// is simply left behind — suspended, harming nothing, holding no caller.
    private func settles(within limit: Duration) async -> Bool {
        let (signal, done) = AsyncStream<Void>.makeStream()
        Task { @MainActor [weak self] in
            await self?.drain()
            done.yield()
            done.finish()
        }
        Task {
            try? await Task.sleep(for: limit)
            done.finish() // no yield: finishing empty IS the timeout
        }
        for await _ in signal { return true }
        return false
    }

    private func drain() async {
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                lastError = error.localizedDescription
            }
        }
        // Only now: the pumps end on their own when the results sequences
        // terminate, which the finalize above is what causes.
        for take in takes { await take.pump?.value }
    }

    /// Abandon without delivering — a tap, or a cancelled hold.
    func abandon() async {
        for take in takes { take.pump?.cancel() }
        if let analyzer { await analyzer.cancelAndFinishNow() }
        takes = []
        analyzer = nil
        transcript.reset()
    }
}
