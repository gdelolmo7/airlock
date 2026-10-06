import Foundation

/// What VoiceOver says when a blocking gate arrives.
///
/// Pure and here rather than in the view, for the same reason `RiskAssessor` and
/// `AgentsPresence` are: the phrasing is the part that can be wrong, and getting
/// it wrong is invisible to anyone who does not run VoiceOver. Tests can read
/// this; nobody re-reads a string literal buried in a controller.
///
/// The panel does not take the keyboard when a gate arrives — see
/// `NotchController.focusPendingGate` — so a listener who hears this has no way
/// to act on it unless we say which key makes it answerable. That is why the
/// hotkey is part of the sentence rather than something to discover in Settings.
public enum GateAnnouncement {
    /// Long commands are the norm, and VoiceOver reads every character of them.
    /// A sentence that takes twenty seconds to speak is worse than one that
    /// names the tool and lets the listener open the card for the detail.
    static let detailLimit = 100

    /// - Parameters:
    ///   - agent: the agent's display name, e.g. "Claude Code".
    ///   - request: the gate being announced.
    ///   - risk: the risk floor's verdict, if any. Spoken because the card
    ///     signals it with a coloured dot and nothing else — a listener would
    ///     otherwise approve a recursive delete and a file read in the same
    ///     tone of voice.
    ///   - hotkey: spoken form of the key that makes the card answerable, or
    ///     nil when the gate hotkey is switched off — in which case promising a
    ///     shortcut would be a lie.
    public static func text(
        agent: String,
        request: PermissionRequest,
        risk: RiskAssessor.Risk?,
        hotkey: String?
    ) -> String {
        var sentence: String

        if let question = request.question {
            // The card steps through them, and a listener cannot see "1 of 3".
            let count = request.questions.count
            sentence = count > 1
                ? "\(agent) asks \(count) questions, starting with: \(clamp(question.question))"
                : "\(agent) asks: \(clamp(question.question))"
        } else {
            // `summary` is already a one-line human phrase ("Run shell
            // command", "Edit src/app.ts"), which is exactly what should be
            // spoken. The raw command is not — it is unbounded and full of
            // punctuation VoiceOver reads aloud.
            sentence = "\(agent) needs permission: \(clamp(request.summary))"
        }

        sentence = terminated(sentence)

        if let risk {
            sentence += " Risky — \(risk.reason)."
        }

        if let hotkey {
            sentence += " Press \(hotkey) to answer."
        }

        return sentence
    }

    /// Trailing punctuation matters to a speech synthesiser: without it the
    /// next clause runs on as though it were part of the command.
    private static func terminated(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".?!".contains(last) ? trimmed : trimmed + "."
    }

    /// Collapses whitespace — a diff or a wrapped command is full of newlines,
    /// and they become pauses — then truncates on a word boundary so the
    /// sentence does not end mid-token.
    private static func clamp(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > detailLimit else { return flat }
        let cut = flat.prefix(detailLimit)
        // Back up to the last space so we truncate between words, unless the
        // whole prefix is one long token (a URL, a path) and there is none.
        let stem = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return stem.trimmingCharacters(in: .whitespaces) + "…"
    }
}
