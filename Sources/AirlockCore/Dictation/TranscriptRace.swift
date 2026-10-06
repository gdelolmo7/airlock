import Foundation

/// Choosing between two transcripts of the same audio, recognised in different
/// languages.
///
/// `SpeechTranscriber` takes exactly one locale and has no multilingual mode, so
/// "detect the language automatically" has to be built. What makes it cheap is
/// that one `SpeechAnalyzer` hosts several transcribers over the same audio —
/// measured at 1.3× the cost of one, not 2× — so both languages are recognised
/// in the same pass and this decides which one the user actually spoke.
///
/// The signal is the recogniser's own confidence, not language detection of the
/// output. That distinction is load-bearing: fed English audio, an es-ES
/// transcriber still returns English words, and `NLLanguageRecognizer` scores
/// both takes "en 99%" — it identifies the language spoken, never which
/// transcriber heard it better. Confidence separates them cleanly (measured):
///
/// | audio   | en-US | es-ES |
/// |---------|-------|-------|
/// | Spanish | 0.373 | 0.676 |
/// | English | 0.961 | 0.867 |
///
/// Pure, like the rest of the dictation core.
public enum TranscriptRace {
    /// How far the secondary must beat the primary before it takes over.
    ///
    /// Not symmetric, on purpose. The primary is the language the user chose, so
    /// the tie goes to it and the secondary has to earn the switch. The measured
    /// gap on a genuine language switch was 0.30, while the widest gap seen when
    /// both transcribers heard the *same* language was 0.094 — so this sits
    /// above the second and a comfortable distance below the first.
    public static let takeoverMargin = 0.10

    public struct Candidate: Sendable, Equatable {
        public let localeIdentifier: String
        public let text: String
        /// Character-weighted mean of the recogniser's per-run confidence.
        ///
        /// Weighted rather than a plain mean because runs vary in length, and a
        /// one-word run recognised badly should not count the same as a clause
        /// recognised well.
        public let confidence: Double

        public init(localeIdentifier: String, text: String, confidence: Double) {
            self.localeIdentifier = localeIdentifier
            self.text = text
            self.confidence = confidence
        }

        var isUsable: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The take to deliver, or nil when nobody heard anything.
    public static func winner(among candidates: [Candidate],
                              primary primaryIdentifier: String) -> Candidate? {
        let usable = candidates.filter(\.isUsable)
        guard let best = usable.max(by: { $0.confidence < $1.confidence }) else { return nil }

        // The primary not producing text at all is the one case where the
        // secondary takes over unconditionally — there is nothing to protect.
        guard let primary = usable.first(where: { $0.localeIdentifier == primaryIdentifier })
        else { return best }

        return best.confidence > primary.confidence + takeoverMargin ? best : primary
    }

    /// Which take the **live preview** should follow, while the words are still
    /// appearing.
    ///
    /// A different decision from `winner`, which is why it is a different
    /// function. `winner` is made once, at the end, over everything that was
    /// said; this one is made continuously, on partial evidence, and is allowed
    /// to change its mind. Speaking Spanish with an English primary used to show
    /// the English transcriber's take letter by letter — the right words arrived
    /// only at the end, so the whole time you were talking you watched nonsense
    /// being typed out.
    ///
    /// Two rules, and both are about not making that worse:
    ///
    /// - **Only confidence moves it.** Unlike `winner`, an empty take is not a
    ///   reason to hand over. Both transcribers hear the same audio and produce
    ///   partials within a frame of each other, so "the other one has text and
    ///   this one doesn't yet" is a race, not a signal — and acting on it would
    ///   switch the preview to the wrong language on the strength of timing.
    /// - **Whatever is showing is protected by `takeoverMargin`.** Hysteresis,
    ///   so a preview cannot flicker between two languages whose scores are
    ///   sitting near each other. It settles rather than oscillates.
    ///
    /// **Zero means "not scored yet", not "scored badly", and the difference is
    /// a bug that shipped for an afternoon.** The two transcribers do not start
    /// producing confidence at the same moment, so there is a window where one
    /// has a real number and the other still has nothing. Comparing those two
    /// is comparing a measurement against a blank: observed in a real log as
    /// `en_US 0.000 · es_ES 0.846` handing the preview to Spanish, on a hold the
    /// final race then scored `en_US 0.883 · es_ES 0.846` — English, spoken in
    /// English, previewed in Spanish. The inverse of the bug this was written to
    /// fix, which is a good reason to be careful with the word "zero".
    ///
    /// So nothing moves until the take on screen has a score of its own. It
    /// costs a beat at the start of a hold and it is the only way the comparison
    /// means anything.
    ///
    /// - Parameter showing: the locale currently on screen.
    /// - Returns: the locale to show now — `showing` itself when nothing has
    ///   earned the switch.
    public static func liveChoice(among candidates: [Candidate], showing: String) -> String {
        guard let current = candidates.first(where: { $0.localeIdentifier == showing }),
              current.confidence > 0 else { return showing }
        guard let best = candidates.max(by: { $0.confidence < $1.confidence }),
              best.localeIdentifier != showing else { return showing }
        return best.confidence > current.confidence + takeoverMargin ? best.localeIdentifier : showing
    }
}
