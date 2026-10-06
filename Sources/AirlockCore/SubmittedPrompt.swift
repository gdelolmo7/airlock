import Foundation

/// What arrived as a prompt, sorted by who wrote it.
///
/// `UserPromptSubmit` does not only carry the person at the keyboard. The Claude
/// desktop app reports a finished background task through the same hook, as if
/// it had been typed —
///
///     <task-notification>
///     <task-id>bqjx76m5c</task-id>
///     <tool-use-id>toolu_01XQ4ibg1CH1zoHBVxnMG4t5</tool-use-id>
///     <output-file>/private/tmp/claude-…/tasks/bqjx76m5c.output</output-file>
///     <status>completed</status>
///     <summary>Background command "…" completed (exit code 0)</summary>
///     </task-notification>
///
/// — and the session card printed it after "You:", ids and all, and named the
/// conversation after it when it came first. Claude Code wraps slash commands,
/// shell escapes and IDE context in tags of its own the same way.
///
/// The tags are the agent's; the rule is ours: the "You:" line holds what the
/// person typed and nothing else. Pure, so the reducer can apply it, and the
/// reducer does — a session is only ever changed there.
public enum SubmittedPrompt: Equatable, Sendable {
    /// What the person typed, with anything the host wrapped around it taken
    /// off. A slash command or a shell escape comes back the way it was typed —
    /// "/review", "! ls" — rather than as the tags that carry it.
    case typed(String)
    /// A background task reported back. Nobody typed it, but the agent answers
    /// it, so the session is working.
    case taskNotification(TaskOutcome)
    /// Something the host attached, with nothing typed alongside it.
    case injected

    public enum TaskOutcome: Equatable, Sendable {
        case finished
        case failed
        case stopped

        /// The session row's activity line.
        public var activity: String {
            switch self {
            case .finished: return "Background task finished"
            case .failed: return "Background task failed"
            case .stopped: return "Background task stopped"
            }
        }
    }

    /// Tags a host writes and a person does not. Matched by exact name, and
    /// only as a whole block at the start or end of the text: `<div> doesn't
    /// render` is a prompt like any other, and so is one that mentions a tag.
    static let hostTags: Set<String> = [
        "task-notification", "system-reminder",
        "local-command-stdout", "local-command-stderr", "local-command-caveat",
        "command-name", "command-message", "command-args",
        "bash-input", "bash-stdout", "bash-stderr",
        "user-prompt-submit-hook", "ide_selection", "ide_opened_file",
    ]

    public static func classify(_ raw: String) -> SubmittedPrompt {
        var rest = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        var blocks: [(tag: String, body: Substring)] = []
        while let block = leadingBlock(of: rest) {
            blocks.append((block.tag, block.body))
            rest = block.rest.drop(while: \.isWhitespace)
        }

        // The whole message is the host's, including whatever it appends.
        if let note = blocks.first(where: { $0.tag == "task-notification" }) {
            return .taskNotification(outcome(of: note.body))
        }
        // A command the person ran. The tags carry its name and arguments;
        // anything after them is the command's own expansion, not typing.
        if let name = body(of: "command-name", in: blocks) {
            let command = name.hasPrefix("/") ? name : "/" + name
            return .typed(body(of: "command-args", in: blocks).map { "\(command) \($0)" } ?? command)
        }
        if let input = body(of: "bash-input", in: blocks) {
            return .typed("! \(input)")
        }
        // Context the host put before the prompt — an open file, a reminder —
        // and whatever follows it is what was typed.
        let typed = withoutPasteTags(withoutTrailingBlocks(rest))
        return typed.isEmpty ? .injected : .typed(typed)
    }

    /// Whether stored text still carries something `classify` takes off — a
    /// host block at the start, or a paste's wrapper anywhere. The test for
    /// text saved before either rule existed.
    public static func needsCleaning(_ text: String) -> Bool {
        startsWithHostTag(text) || text.contains("<\(pasteTag)")
    }

    /// The Claude desktop app wraps what was pasted into the prompt box in
    /// `<pasted_content id="f93b">…</pasted_content>`, in the MIDDLE of what
    /// was typed — "Previous message <pasted_content id=…> Nothing is…" — so
    /// the start-and-end rule above never sees it. The paste IS what the person
    /// sent, so its text stays; only the wrapper goes, wherever it sits.
    static let pasteTag = "pasted_content"

    private static func withoutPasteTags(_ text: String) -> String {
        guard text.contains(pasteTag) else { return text }
        return text
            .replacingOccurrences(of: "</?\(pasteTag)(\\s[^>]*)?>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the text opens with a host's block — the test for text stored
    /// before this type existed, which is the only place that needs asking.
    public static func startsWithHostTag(_ text: String) -> Bool {
        leadingBlock(of: Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))) != nil
    }

    /// `<tag>…</tag>` at the very start, for a tag in `hostTags`.
    ///
    /// Unterminated counts, running to the end: a stored prompt was cut at 200
    /// characters, a title at 60, and either can end mid-block.
    private static func leadingBlock(of text: Substring)
        -> (tag: String, body: Substring, rest: Substring)? {
        guard text.hasPrefix("<"), let close = text.firstIndex(of: ">") else { return nil }
        let tag = String(text[text.index(after: text.startIndex)..<close])
        guard hostTags.contains(tag) else { return nil }
        let inside = text[text.index(after: close)...]
        guard let end = inside.range(of: "</\(tag)>") else {
            return (tag, inside, inside[inside.endIndex...])
        }
        return (tag, inside[..<end.lowerBound], inside[end.upperBound...])
    }

    /// The text with complete host blocks taken off its end — context appended
    /// after what was typed rather than before it.
    private static func withoutTrailingBlocks(_ text: Substring) -> String {
        var rest = text
        while true {
            let trimmed = rest.reversed().drop(while: \.isWhitespace).count
            rest = rest.prefix(trimmed)
            guard rest.hasSuffix(">"),
                  let tag = hostTags.first(where: { rest.hasSuffix("</\($0)>") }),
                  let open = rest.range(of: "<\(tag)>", options: .backwards) else { break }
            rest = rest[..<open.lowerBound]
        }
        return String(rest)
    }

    private static func body(of tag: String, in blocks: [(tag: String, body: Substring)]) -> String? {
        guard let body = blocks.first(where: { $0.tag == tag })?.body else { return nil }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// From the notification's `<status>`, and from its summary's exit code —
    /// a command that ran to the end and exited 1 did not succeed.
    private static func outcome(of notification: Substring) -> TaskOutcome {
        func inner(_ tag: String) -> Substring? {
            guard let open = notification.range(of: "<\(tag)>"),
                  let close = notification.range(of: "</\(tag)>", range: open.upperBound..<notification.endIndex)
            else { return nil }
            return notification[open.upperBound..<close.lowerBound]
        }
        let status = inner("status").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        switch status ?? "" {
        case "failed", "error", "errored":
            return .failed
        case "killed", "stopped", "cancelled", "canceled", "aborted":
            return .stopped
        default:
            break
        }
        if let summary = inner("summary"),
           let marker = summary.range(of: "exit code "),
           let code = Int(summary[marker.upperBound...].prefix(while: \.isNumber)),
           code != 0 {
            return .failed
        }
        return .finished
    }
}
