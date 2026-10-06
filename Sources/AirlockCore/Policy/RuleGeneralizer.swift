import Foundation

/// One rule you could write for a request, and what it would cover.
public struct RuleCandidate: Equatable, Sendable, Identifiable {
    /// Full rule text, e.g. `Bash(git log *)`.
    public let text: String
    /// Plain language, for a button label or a picker row.
    public let summary: String
    /// True for the literal, one-command-only rule.
    public let isExact: Bool

    public var id: String { text }

    public init(text: String, summary: String, isExact: Bool) {
        self.text = text
        self.summary = summary
        self.isExact = isExact
    }
}

/// Turns "allow this exact thing" into "allow this kind of thing".
///
/// `PolicyRule.exactRuleText` writes the command verbatim, which for anything
/// longer than `npm test` produces a rule that can never match again. Real
/// evidence, from this repo's own policy file:
///
///     - Bash(echo "=== ~/.codex/hooks.json (pre-existing, failing to parse) ===" && ls -la …)
///
/// One Always click, one permanently dead rule, and you get asked the same kind
/// of question forever. A policy file that only accumulates is a policy file
/// nobody trusts.
///
/// Pure, and the invariant under test is simple and absolute: **every candidate
/// must match the request it was derived from.** A "generalisation" that fails
/// to cover the very command you just approved is worse than the literal rule,
/// because it looks like it worked.
public enum RuleGeneralizer {
    /// Narrowest first. Element 0 is always the exact rule, so there is always
    /// something to write.
    public static func candidates(for request: PermissionRequest) -> [RuleCandidate] {
        let exact = RuleCandidate(text: PolicyRule.exactRuleText(for: request),
                                  summary: exactSummary(for: request),
                                  isExact: true)
        guard let subject = PolicyRule.subject(of: request), !subject.isEmpty else {
            return [exact] // tool-only rule; there is nothing to widen
        }

        let wider = request.toolName == "Bash"
            ? commandCandidates(tool: request.toolName, command: subject)
            : pathCandidates(tool: request.toolName, path: subject)
        return [exact] + wider
    }

    /// What one click should write.
    ///
    /// The first genuine generalisation when there is one, because that is the
    /// whole point — but the exact rule when nothing safe exists, rather than
    /// inventing something broad to feel useful. Callers are expected to *show*
    /// what they are about to write; quietly widening a rule the user did not
    /// read would trade one problem for a worse one.
    public static func recommended(for request: PermissionRequest) -> RuleCandidate {
        let all = candidates(for: request)
        return all.count > 1 ? all[1] : all[0]
    }

    // MARK: - Shell commands

    /// Anything that chains, pipes, redirects or substitutes.
    ///
    /// These get no generalisation at all, and the reason is safety rather than
    /// difficulty. The rule's subject is the *whole* line, so widening the first
    /// token of `echo hi && rm -rf /` to `echo *` would produce a rule that
    /// auto-approves every command anyone ever appends to an echo. The honest
    /// answer for a compound command is that only the literal rule is safe —
    /// which also means it will rarely match, and that is the correct trade.
    static let compoundMarkers = ["&&", "||", ";", "|", "$(", "`", ">", "<", "\n"]

    private static func commandCandidates(tool: String, command: String) -> [RuleCandidate] {
        guard !compoundMarkers.contains(where: command.contains) else { return [] }

        let tokens = command.split(separator: " ").map(String.init)
        guard tokens.count > 1 else { return [] } // `ls` is already as general as it gets

        // Prefixes stop at the first flag: `git log --oneline -5` widens through
        // `git log`, never through `--oneline`, which describes this invocation
        // rather than a family of them.
        var prefixes: [[String]] = []
        for (index, token) in tokens.enumerated() {
            if token.hasPrefix("-") { break }
            guard index < tokens.count - 1 else { break } // a full-length prefix is the exact rule
            prefixes.append(Array(tokens[0...index]))
        }

        // Widest last, so a picker reads narrow → broad.
        return prefixes.reversed().map { prefix in
            let joined = prefix.joined(separator: " ")
            return RuleCandidate(text: "\(tool)(\(joined) *)",
                                 summary: "Any `\(joined)` command",
                                 isExact: false)
        }
    }

    // MARK: - File paths

    private static func pathCandidates(tool: String, path: String) -> [RuleCandidate] {
        guard path.hasPrefix("/") else { return [] }
        let url = URL(fileURLWithPath: path)
        var result: [RuleCandidate] = []

        let directory = url.deletingLastPathComponent().path
        if directory != "/" && !directory.isEmpty {
            result.append(RuleCandidate(
                text: "\(tool)(\(directory)/*)",
                summary: "Any file in \(url.deletingLastPathComponent().lastPathComponent)/",
                isExact: false))
        }

        let ext = url.pathExtension
        if !ext.isEmpty {
            result.append(RuleCandidate(text: "\(tool)(*.\(ext))",
                                        summary: "Any .\(ext) file, anywhere",
                                        isExact: false))
        }
        return result
    }

    // MARK: - Wording

    /// What the Always button promises.
    ///
    /// The `else` used to be a bare "Only this file", which was true for as long
    /// as every non-`Bash` tool was a file tool. `Voice.*` ended that: a rule
    /// written from a spoken request covers a device or a source app, and each
    /// action says so in its own words — `Voice.Clipboard(Figma)` allows
    /// anything from Figma, not one clip. A button that describes the wrong
    /// scope is worse than one with no description, because it is read and
    /// believed.
    private static func exactSummary(for request: PermissionRequest) -> String {
        guard let subject = PolicyRule.subject(of: request), !subject.isEmpty else {
            // The rule is written with the raw name; the promise is read by a
            // person. An MCP tool's raw name is `mcp__<uuid>__trelloWriteCard`.
            return "Any use of \(ToolPhrase.name(request.toolName))"
        }
        if let spoken = VoiceActionCatalog.exactRuleSummary(toolName: request.toolName) {
            return spoken
        }
        return request.toolName == "Bash" ? "Only this exact command" : "Only this file"
    }
}
