import Foundation

/// What the model came back with: prose, or a named action.
///
/// The union is resolved here rather than at the model boundary so the rules
/// are testable without one. They are not obvious rules — a small model fills
/// in every field it is given, so "which of these did it mean" is a real
/// decision with a wrong answer.
public enum VoiceReply: Sendable, Equatable {
    case answer(String)
    case action(name: String, arguments: [String: String])

    /// Words a model writes into an action field when it means "no action".
    ///
    /// It is asked for an empty string and complies most of the time. The rest
    /// of the time it writes the most reasonable thing a person would write,
    /// and every one of these was more plausible to it than a blank.
    static let refusals: Set<String> = ["", "none", "no", "null", "nil", "na",
                                        "answer", "nothing", "unknown"]

    /// Classify one raw reply.
    ///
    /// **An action only wins if it names something in the catalogue.** The
    /// alternative — trusting the field — turns a hallucinated `Voice.SendEmail`
    /// into a dead end where the user gets neither an answer nor a card, which
    /// from the outside is the app ignoring them. Here it degrades to whatever
    /// prose came with it, which is usually a perfectly good answer.
    public static func resolve(
        action: String,
        arguments: [(name: String, value: String)],
        answer: String,
        offering actions: [any VoiceAction.Type] = VoiceActionCatalog.registered
    ) -> VoiceReply {
        let prose = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = VoiceActionCatalog.normalized(action)
        guard !refusals.contains(named),
              let resolved = VoiceActionCatalog.resolve(name: action, offering: actions) else {
            return .answer(prose)
        }
        return .action(name: resolved.toolName, arguments: dictionary(from: arguments))
    }

    /// Keys are lower-cased, values are not.
    ///
    /// `VoiceAction.parameters` are all lower-case, and a model that answers
    /// "Device" instead of "device" has understood the question perfectly — that
    /// should not be the thing that breaks it. Values keep their case because
    /// they are proper nouns: a device is called "AirPods Pro", and the folding
    /// that makes matching work belongs in `VoiceMatch`, where it is visible.
    ///
    /// Blank names and blank values are dropped, so a model that dutifully fills
    /// every field with "" produces an empty bag rather than a bag of nothings —
    /// which matters, because actions treat a present-but-blank argument as
    /// absent and a present-and-garbled one as a hard stop.
    static func dictionary(from pairs: [(name: String, value: String)]) -> [String: String] {
        var result: [String: String] = [:]
        for pair in pairs {
            let key = pair.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            // First wins: a model that repeats a key has changed its mind
            // mid-generation, and the first answer is the one it committed to
            // while the schema was still fresh.
            if result[key] == nil { result[key] = value }
        }
        return result
    }
}
