import Foundation

/// Which list a rule belongs to.
public enum PolicyRuleKind: String, Sendable, CaseIterable, Identifiable, Codable {
    case allow
    case deny

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .allow: return "Allow"
        case .deny: return "Deny"
        }
    }
}

/// A policy file as *text*, edited a line at a time.
///
/// The whole point is that it never parses-and-reserialises. A policy file is
/// something people write by hand, comment, and reason about; a round-trip
/// through `Policy` would silently discard every comment, every blank line and
/// every deliberate ordering the moment you clicked a button in Settings. So
/// adding a rule inserts one line and removing a rule deletes one line, and
/// everything else in the file is returned exactly as it was found.
///
/// Pure and value-typed, so the surgery is testable without a filesystem —
/// which matters more here than usual, because "delete this rule" quietly
/// removing the *wrong* line would loosen the thing that gates command
/// execution.
public struct PolicyDocument: Equatable, Sendable {
    public private(set) var text: String

    public init(_ text: String) {
        self.text = text
    }

    // MARK: - Reading

    /// Whether the section already declares this rule, compared canonically —
    /// `Bash(git  status)` and `Bash(git status)` are the same rule, because
    /// that is how `PolicyRule` normalises them and therefore how the engine
    /// will treat them.
    public func contains(_ ruleText: String, in kind: PolicyRuleKind) -> Bool {
        guard let wanted = Self.canonical(ruleText) else { return false }
        let lines = Self.split(text)
        guard let body = Self.bodyRange(lines, kind) else { return false }
        return body.contains { Self.rule(on: lines[$0]) == wanted }
    }

    // MARK: - Writing

    /// Inserts directly under the section header, so a new rule is visible at
    /// the top of its list rather than buried under a template's comments.
    /// Returns false when the rule is unparseable or already present.
    @discardableResult
    public mutating func insert(_ ruleText: String, into kind: PolicyRuleKind) -> Bool {
        guard let rule = Self.canonical(ruleText), !contains(rule, in: kind) else { return false }

        var lines = Self.split(text)
        if let header = Self.headerIndex(lines, kind) {
            lines.insert("  - \(rule)", at: header + 1)
        } else {
            // No such section yet — append one rather than refusing.
            if lines.last == "" { lines.removeLast() }
            lines.append(contentsOf: ["", "\(kind.rawValue):", "  - \(rule)", ""])
        }
        text = lines.joined(separator: "\n")
        return true
    }

    /// Removes the first line in that section declaring this rule. Scoped to the
    /// section on purpose: the same rule may legitimately appear under both
    /// `allow` and `deny`, and deleting from the list you were not looking at
    /// would be the worst possible outcome.
    @discardableResult
    public mutating func remove(_ ruleText: String, from kind: PolicyRuleKind) -> Bool {
        guard let wanted = Self.canonical(ruleText) else { return false }
        var lines = Self.split(text)
        guard let body = Self.bodyRange(lines, kind),
              let index = body.first(where: { Self.rule(on: lines[$0]) == wanted })
        else { return false }
        lines.remove(at: index)
        text = lines.joined(separator: "\n")
        return true
    }

    // MARK: - Line analysis

    private static func split(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// Normalised through `PolicyRule`, so comparisons match the engine's own
    /// idea of rule identity. Nil for anything that is not a valid rule.
    private static func canonical(_ ruleText: String) -> String? {
        (try? PolicyRule(parsing: ruleText))?.canonicalText
    }

    /// The rule a line declares, canonically, or nil for blanks, comments and
    /// commented-out rules. `# - Bash(rm -rf /)` is documentation, not a rule,
    /// and must never be matched or removed.
    private static func rule(on line: String) -> String? {
        let content = PolicyParser.stripComment(line)
        guard content.hasPrefix(" ") else { return nil } // list items are indented
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") else { return nil }
        let raw = PolicyParser.unquote(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        return canonical(raw)
    }

    private static func headerIndex(_ lines: [String], _ kind: PolicyRuleKind) -> Int? {
        lines.firstIndex { line in
            guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { return false }
            return PolicyParser.stripComment(line)
                .trimmingCharacters(in: .whitespaces) == "\(kind.rawValue):"
        }
    }

    /// The lines belonging to a section's body: everything after its header up
    /// to the next top-level key. Blank and comment lines stay inside, so a
    /// section separated from the next by a blank line still ends in the right
    /// place.
    private static func bodyRange(_ lines: [String], _ kind: PolicyRuleKind) -> Range<Int>? {
        guard let header = headerIndex(lines, kind) else { return nil }
        var end = header + 1
        while end < lines.count {
            let content = PolicyParser.stripComment(lines[end])
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !content.hasPrefix(" ") { break } // next top-level key
            end += 1
        }
        return (header + 1)..<end
    }
}
