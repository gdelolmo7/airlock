import FoundationModels
import AirlockCore

/// Runs a raw transcript past the on-device language model.
///
/// Apple's `FoundationModels`, not a bundled Qwen: it is in the OS on macOS 26,
/// so cleanup costs no dependency and no model download — the same trade that
/// got us speech recognition for free, and the reason this app is still a 2.8 MB
/// download with a local LLM in it.
///
/// Every failure path returns the raw transcript. Cleanup is a polish step; a
/// user who dictated a sentence must get that sentence whatever the model does,
/// including nothing at all.
@MainActor
final class CleanupService {
    /// The session for the NEXT dictation only — see `retire`.
    ///
    /// It used to be held across dictations, on the theory that building one
    /// cost real time. Measured, it does not: init is ~1ms and `prewarm()`
    /// returns immediately. What holding it did cost was a transcript that grew
    /// by ~430 characters per dictation and never shrank, until it crossed the
    /// 4096-token context window and every subsequent cleanup threw
    /// `exceededContextWindowSize` — permanently, since nothing rebuilt the
    /// session except an instructions edit or a relaunch.
    private var session: LanguageModelSession?
    private var sessionInstructions: String?

    private(set) var lastRejection: String?

    var availability: ModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .needsAppleIntelligence
            case .deviceNotEligible: return .deviceNotEligible
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown("\(reason)")
            }
        @unknown default:
            return .unknown("unrecognised availability")
        }
    }

    /// Warm the model so the first dictation of a session is not the slow one.
    func prepare(instructions: String) {
        guard availability.isReady else { return }
        session(for: instructions).prewarm()
    }

    /// Returns cleaned text, or `raw` unchanged if cleanup did not happen or
    /// could not be trusted.
    func clean(_ raw: String, instructions: String) async -> String {
        lastRejection = nil
        guard availability.isReady, TranscriptCleanup.isWorthCleaning(raw) else { return raw }
        // One dictation per session, always. Two reasons beyond the context
        // window: each cleanup is independent, so prior turns are noise the
        // model has to read past, and they are the user's own dictated words
        // sitting in model context long after the text was typed.
        defer { retire(instructions: instructions) }

        do {
            // Wrapped, never bare — `TranscriptCleanup.prompt(for:)` carries the
            // measurement. A bare transcript is a user turn, and a user turn
            // that says "run the tests" gets answered rather than cleaned.
            let response = try await session(for: instructions).respond(
                to: TranscriptCleanup.prompt(for: raw),
                options: GenerationOptions(
                    // Deterministic. Cleanup has one right answer, and a
                    // sampled one would make the same sentence come out
                    // differently each time — which reads as the app being
                    // unreliable rather than creative.
                    sampling: .greedy,
                    // Output should never exceed input by much. This is a
                    // backstop against a runaway generation, not the real guard
                    // — `TranscriptCleanup.vetted` is.
                    maximumResponseTokens: max(64, raw.count / 2)))

            guard let vetted = TranscriptCleanup.vetted(raw: raw, cleaned: response.content) else {
                // Worth surfacing rather than swallowing: a model that keeps
                // failing vetting means the prompt needs work, and the user is
                // the one who can edit it.
                lastRejection = DictationHoldNotice.tidyingFailedSentence
                return raw
            }
            return vetted
        } catch {
            // Guardrail trips, context overruns, unsupported languages — all
            // end the same way, because the user's sentence is not negotiable.
            dictationLog("  cleanup failed: \(error.localizedDescription)")
            lastRejection = DictationHoldNotice.tidyingFailedSentence
            return raw
        }
    }

    /// Discard the used session and stand up its replacement now, so the build
    /// lands in the gap between dictations rather than in the pause between
    /// releasing the key and seeing your text.
    private func retire(instructions: String) {
        session = nil
        sessionInstructions = nil
        prepare(instructions: instructions)
    }

    /// Dropped when the instructions change so an edited prompt takes effect on
    /// the next dictation rather than after a restart.
    private func session(for instructions: String) -> LanguageModelSession {
        if let session, sessionInstructions == instructions { return session }
        let fresh = LanguageModelSession(instructions: instructions)
        session = fresh
        sessionInstructions = instructions
        return fresh
    }

    func reset() {
        session = nil
        sessionInstructions = nil
    }
}
