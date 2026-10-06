import Foundation

/// The gap between what was said and what the recogniser wrote down.
///
/// "Open Claude Code" arrives as "open cloud code", "clot code", "cloudy
/// code" — the recogniser has never heard of Claude and reaches for English
/// words that sound alike. The app the user named exists, the action exists,
/// and the match fails on spelling the user never produced. This is that
/// spelling gap, written down once, pure, and tested.
///
/// **Variants are tried only after the direct match found NOTHING.** An app
/// actually named "Cloud" beats every guess about "Claude", because the guess
/// never runs while a direct answer exists. And a variant resolves through the
/// same tiers and the same ambiguity rules as the real query — a guessed
/// spelling matching two apps is a bad guess, not a coin toss.
///
/// The proposal card is the second guardrail: a resolved mishearing still
/// renders "Open Claude" before anything happens, so a wrong canonicalisation
/// costs a read and a dismissal, never a launch.
///
/// Everything here is FOLDED text (`VoiceMatch.fold`) — lowercase, no
/// diacritics, single-spaced — which is also what makes the token table hold
/// across languages: a Spanish transcriber's "clod" and an English one's
/// "clawed" land in the same table the same way.
public enum VoiceMishearings {

    /// Names worth telling the recogniser about BEFORE it guesses.
    ///
    /// Fed to `AnalysisContext.contextualStrings`, which biases transcription
    /// toward these spellings in every locale — the fix at the source, of
    /// which the tables below are the safety net. Product names only, and
    /// multiword forms the installed-apps scan cannot produce ("Claude Code"
    /// is a thing people say; no bundle is named it).
    public static let recognitionVocabulary: [String] = [
        "Claude", "Claude Code", "Codex", "ChatGPT", "Cursor",
        "VS Code", "Visual Studio Code", "Xcode", "iTerm", "Airlock",
    ]

    /// Single tokens the recogniser substitutes for names it does not know,
    /// folded → folded. Applied per token, all tokens at once.
    ///
    /// Entries are earned by being a plausible transcription of the sound,
    /// not by being nearby spellings — "clock" is one letter from "clot" and
    /// is deliberately absent, because "open the clock" is a real sentence
    /// about a real app.
    static let tokens: [String: String] = [
        // Claude — /klɔːd/ through a recogniser that knows weather and injury.
        "cloud": "claude", "clod": "claude", "clot": "claude",
        "claud": "claude", "clawed": "claude", "clout": "claude",
        "cloudy": "claude", "clode": "claude", "klaud": "claude",
        "klod": "claude", "claudia": "claude", "claudio": "claude",
        // Codex — usually the plural of codec, occasionally a camera company.
        "codecs": "codex", "codec": "codex", "kodak": "codex",
        "kodaks": "codex", "kodex": "codex",
        // Cursor — misspelt agent, not the arrow.
        "curser": "cursor", "cursur": "cursor", "kurser": "cursor",
        // ChatGPT's first half, when it comes out as a name.
        "chad": "chat",
        // Number words, both languages, because apps spell themselves with
        // digits and mouths do not: "1Password" is SPOKEN "one password", and
        // the recogniser writes what was spoken. With the join lens below,
        // "one password" → "1 password" → "1password" — an exact match. The
        // live case that earned this block: "puedes abrir one password"
        // falling through the whole catalog to the Q&A model, which explained
        // it cannot open apps. It can; it just could not spell.
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10",
        "cero": "0", "uno": "1", "dos": "2", "tres": "3", "cuatro": "4",
        "cinco": "5", "seis": "6", "siete": "7", "ocho": "8", "nueve": "9",
        "diez": "10",
    ]

    /// Whole folded phrases → the folded name they mean. For nicknames and
    /// splits that token substitution cannot reach — "vs code" is not a
    /// mishearing of anything, it is what everyone calls the app whose bundle
    /// says "Visual Studio Code".
    static let phrases: [String: String] = [
        "vs code": "visual studio code",
        "vscode": "visual studio code",
        "v s code": "visual studio code",
        "claw code": "claude code",
        "chat gbt": "chatgpt",
        "ex code": "xcode",
        "i term": "iterm",
    ]

    /// Alternate queries worth trying when `spoken` matched nothing, most
    /// specific first, deduplicated, and never including the original — the
    /// caller has already tried it.
    ///
    /// Three lenses, composable because each returns folded text:
    /// - the phrase table, for nicknames;
    /// - the token table, for per-word substitutions ("cloud code" →
    ///   "claude code");
    /// - the words joined without spaces, for the split-compound class the
    ///   recogniser produces from names it parses as two words — "chat gpt"
    ///   → "chatgpt", "x code" → "xcode". Only for short queries: joining a
    ///   whole sentence makes a token nothing could ever match.
    public static func variants(of spoken: String) -> [String] {
        let folded = VoiceMatch.fold(spoken)
        guard !folded.isEmpty else { return [] }

        var seen: Set<String> = [folded]
        var out: [String] = []
        func add(_ candidate: String) {
            guard !candidate.isEmpty, !seen.contains(candidate) else { return }
            seen.insert(candidate)
            out.append(candidate)
        }

        if let named = phrases[folded] { add(named) }

        let tokensIn = folded.split(separator: " ").map(String.init)
        let substituted = tokensIn.map { tokens[$0] ?? $0 }.joined(separator: " ")
        add(substituted)
        if let named = phrases[substituted] { add(named) }

        if tokensIn.count > 1, tokensIn.count <= 3 {
            add(tokensIn.joined())
            let joinedSubstituted = substituted.split(separator: " ").joined()
            add(String(joinedSubstituted))
        }
        return out
    }
}
