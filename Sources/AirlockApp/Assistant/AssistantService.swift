import FoundationModels
import AirlockCore
import AirlockGenerable

/// Answers a spoken question with Apple's on-device model.
///
/// The sibling of `CleanupService`, and deliberately its mirror image. Cleanup
/// exists to stop the model answering a dictated question — `TranscriptCleanup.vetted`
/// rejects anything built from words the speaker did not say. Here, answering is
/// the entire point, so there is no vetting at all and the raw transcript goes
/// straight in as the prompt. Running cleanup first would reject every correct
/// result and spend a model round-trip to do it.
///
/// Streamed rather than awaited whole: the panel shows an answer arriving, which
/// is both faster to first word and honest about a model that is thinking.
@MainActor
final class AssistantService {
    private var session: LanguageModelSession?
    private var sessionInstructions: String?

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

    /// Warm the model so the first question is not the slow one.
    func prepare(instructions: String) {
        guard availability.isReady else { return }
        session(for: instructions).prewarm()
    }

    /// Stream an answer. Each element is the answer *so far*, not a delta.
    ///
    /// Throwing is a first-class outcome, not an edge case: guardrails refuse
    /// things, and a refusal is exactly when the caller should be offering to
    /// hand the question to Claude Code instead.
    func answer(_ question: String, instructions: String) -> AsyncThrowingStream<String, Error> {
        let session = session(for: instructions)
        // One question per session, for the reason measured in CleanupService:
        // a held session accumulates every previous exchange until it crosses
        // the 4096-token window and then fails permanently. Answers are longer
        // than cleanups, so it would arrive sooner here.
        retire(instructions: instructions)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = session.streamResponse(
                        to: question,
                        options: GenerationOptions(
                            // Deterministic, for the same reason `CleanupService`
                            // is: the same question should not answer well once
                            // and badly the next time. Sampling is also what made
                            // the original echo bug intermittent and what made two
                            // prompt comparisons here unreadable until it was
                            // fixed — a difference between runs was
                            // indistinguishable from a difference between prompts.
                            sampling: .greedy,
                            maximumResponseTokens: AssistantPrompt.maximumResponseTokens))
                    for try await partial in stream {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Ask the model which action a phrase names, if any.
    ///
    /// **A SEPARATE pass, never folded into answering**, and the reason is
    /// measured: `VoicePrompt` records that teaching one prompt to answer and
    /// act took answering from 13/14 to 8/14, turned "how do I reverse a string
    /// in Swift" into `dlrow olleh`, and answered "what does this do" by
    /// describing its own output schema. The answering path this feeds is
    /// untouched — no action, and today's code runs with today's prompt.
    ///
    /// **A fresh session every time**, matching `ActionScoring.ask`: a reused
    /// one lets each reply condition the next, and the probe scores cold. If
    /// the two differed the probe would be measuring something else.
    ///
    /// Returns `.answer("")` on any failure — a guardrail refusal, an
    /// unavailable model, a timeout. Nothing proposed, and the caller answers
    /// the phrase as it always would.
    func classify(_ spoken: String,
                  offering actions: [any VoiceAction.Type]) async -> VoiceReply {
        guard case .available = SystemLanguageModel.default.availability else {
            return .answer("")
        }
        let session = LanguageModelSession(
            instructions: VoicePrompt.classifierInstructions(actions))
        do {
            let response = try await session.respond(
                to: spoken,
                generating: SpokenReply.self,
                options: GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: VoicePrompt.maximumClassifierTokens))
            return response.content.reply
        } catch {
            dictationLog("  classifier failed: \(error.localizedDescription)")
            return .answer("")
        }
    }

    private func retire(instructions: String) {
        session = nil
        sessionInstructions = nil
        prepare(instructions: instructions)
    }

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
