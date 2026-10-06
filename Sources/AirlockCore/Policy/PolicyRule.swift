import Foundation
import Darwin

/// One policy rule: `Tool` (any use of the tool) or `Tool(pattern)` where the
/// pattern glob-matches the rule's subject — the shell command for Bash, the
/// file path for file tools.
public struct PolicyRule: Sendable, Equatable, Hashable {
    /// The rule as written in the policy file, kept for reporting
    /// ("Auto-approved by policy: Bash(git status)").
    public let text: String
    public let tool: String
    public let pattern: String?

    public enum ParseError: Error, Equatable, Sendable {
        case empty
        case missingClosingParen(String)
        case emptyPattern(String)
        case malformedTool(String)
    }

    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        guard let open = trimmed.firstIndex(of: "(") else {
            guard Self.isValidToolName(trimmed) else { throw ParseError.malformedTool(text) }
            self.text = trimmed
            self.tool = trimmed
            self.pattern = nil
            return
        }
        guard trimmed.hasSuffix(")") else { throw ParseError.missingClosingParen(text) }

        let tool = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
        guard Self.isValidToolName(tool) else { throw ParseError.malformedTool(text) }

        // First "(" to last ")": inner parentheses stay part of the pattern.
        let inner = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        let pattern = Self.normalize(inner)
        guard !pattern.isEmpty else { throw ParseError.emptyPattern(text) }

        self.text = trimmed
        self.tool = tool
        self.pattern = pattern
    }

    /// Identity for comparison, as opposed to `text`, which deliberately keeps
    /// the rule exactly as written so reports can quote it back. Two rules that
    /// differ only in whitespace inside the pattern behave identically at the
    /// gate, so anything deciding "is this the same rule" has to compare this.
    public var canonicalText: String {
        guard let pattern else { return tool }
        return "\(tool)(\(pattern))"
    }

    public func matches(_ request: PermissionRequest) -> Bool {
        guard tool == request.toolName else { return false }
        guard let pattern else { return true } // tool-only rule
        guard let subject = Self.subject(of: request) else { return false }
        return fnmatch(pattern, subject, 0) == 0
    }

    /// The string a pattern is matched against.
    public static func subject(of request: PermissionRequest) -> String? {
        (request.target ?? request.command).map(normalize)
    }

    /// The exact-match rule an "Always allow" click should persist, e.g.
    /// `Bash(git status)` or `Read`.
    public static func exactRuleText(for request: PermissionRequest) -> String {
        guard let subject = subject(of: request) else { return request.toolName }
        return "\(request.toolName)(\(subject))"
    }

    /// Collapse whitespace runs (including newlines) so patterns and subjects
    /// compare on content, not incidental spacing.
    static func normalize(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isValidToolName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains(where: \.isWhitespace)
    }
}
