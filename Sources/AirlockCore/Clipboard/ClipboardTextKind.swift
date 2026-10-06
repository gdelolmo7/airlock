import Foundation

/// What a clipboard entry looks like, so the list can stop setting everything
/// in mono.
///
/// **The codebase's own rule is that mono is quarantined to code**, and the
/// clipboard broke it for every row: a paragraph, a filename and a `git push`
/// were all rendered as monospaced amber, which made prose look like a command
/// and cost the one signal that would have told them apart at a glance.
///
/// Deliberately three coarse buckets and no more. This decides a font, not a
/// syntax highlighter, and a wrong guess costs a slightly odd-looking row —
/// so the tests that matter are the ones proving prose is never mistaken for a
/// command, which is the direction that actually misleads.
public enum ClipboardTextKind: Equatable, Sendable {
    /// A URL. Gets the running accent, because a link is the one entry whose
    /// type tells you what activating it will do.
    case link
    /// Shell, code, a path. Mono, with the amber code tint.
    case code
    /// Everything else — prose, names, numbers. The normal UI face.
    case prose

    public static func of(_ text: String) -> ClipboardTextKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .prose }
        if isLink(trimmed) { return .link }
        return isCode(trimmed) ? .code : .prose
    }

    /// A scheme we would actually open, not "contains a dot".
    ///
    /// `URL(string:)` alone is far too generous — it accepts "hello world" on
    /// some inputs and every bare filename on all of them — so the scheme is
    /// checked explicitly and a link has to be the WHOLE entry. A sentence
    /// mentioning a URL is prose about a link, not a link.
    private static func isLink(_ text: String) -> Bool {
        guard !text.contains(" "), !text.contains("\n") else { return false }
        let lowered = text.lowercased()
        return ["https://", "http://", "ftp://", "mailto:", "file://"]
            .contains { lowered.hasPrefix($0) }
    }

    /// Shell and code, judged on shape rather than vocabulary.
    ///
    /// A leading `$`, a path, a flag, an obvious command head, or punctuation
    /// density no sentence reaches. Multi-line is NOT enough on its own — a
    /// two-paragraph note is multi-line and is not code, and treating it as
    /// such was most of the old behaviour.
    private static func isCode(_ text: String) -> Bool {
        let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? text
        if text.hasPrefix("$ ") || text.hasPrefix("/") || text.hasPrefix("~/")
            || text.hasPrefix("./") { return true }
        if commandHeads.contains(first.lowercased()) { return true }
        // A FLAG, not a dash. `contains(" -")` was the intent and it caught
        // ordinary English instead: "Lunch - 13:00", "Toby Romeo - Lose U",
        // "The plan - as we discussed - is to ship on Friday", and any email
        // containing one spaced hyphen anywhere in it. A dash between words is
        // punctuation; a flag is a token that STARTS with the hyphen and has a
        // letter after it.
        if text.count < 200, hasFlag(text) { return true }
        // Punctuation density, and both halves of that were wrong.
        //
        // `[`, `]`, `<`, `>` and `&` are prose characters: "R&D and Q&A at AT&T"
        // and "see the notes [1], [2] and [3]" are three and six hits of pure
        // English. Braces, semicolons, pipes and equals are the ones that do not
        // turn up in a sentence.
        //
        // And it was a COUNT, not a density — independent of length, so a longer
        // entry was MORE likely to be called code, which is backwards. An essay
        // with three semicolons in two thousand characters is an essay.
        let dense = text.filter { "{};|=".contains($0) }.count
        return dense >= 3 && dense * 40 >= text.count
    }

    /// A token that starts with one or two hyphens and continues with a letter:
    /// `-la`, `--cask`. Not a lone dash, and not a negative number.
    private static func hasFlag(_ text: String) -> Bool {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).contains { token in
            guard token.hasPrefix("-") else { return false }
            let body = token.drop(while: { $0 == "-" })
            return body.first?.isLetter == true
        }
    }

    /// Command heads common enough to be worth naming, and specific enough not
    /// to appear at the start of a sentence.
    ///
    /// "make" and "test" are deliberately absent: both open ordinary English
    /// sentences, and a note beginning "make sure the build passes" set in mono
    /// is exactly the failure this list exists to avoid.
    private static let commandHeads: Set<String> = [
        "git", "npm", "npx", "yarn", "pnpm", "brew", "swift", "cargo", "docker",
        "kubectl", "curl", "wget", "ssh", "scp", "sudo", "rm", "cp", "mv", "ls",
        "cd", "cat", "grep", "sed", "awk", "python", "python3", "pip", "node",
        "go", "ruby", "gem", "bundle", "rails", "xcodebuild", "pod", "gh",
    ]
}
