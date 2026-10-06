import Foundation

/// Strict parser for the policy file — a deliberate YAML subset (top-level
/// scalars + block lists of strings, `#` comments, optional quotes).
///
/// Zero dependencies, and *loud* on anything outside the subset: a policy file
/// that gates command execution must never be silently misread. Every error
/// carries a line number.
public enum PolicyParser {
    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case tabIndentation(line: Int)
        case expectedKey(line: Int)
        case unknownKey(String, line: Int)
        case missingValue(key: String, line: Int)
        case invalidValue(key: String, line: Int)
        case inlineListValue(key: String, line: Int)
        case listItemOutsideList(line: Int)
        /// The rule's OWN error, carried rather than flattened. `try?` here
        /// discarded which of `PolicyRule.ParseError`'s four cases fired, so
        /// every malformed rule read "use `Tool` or `Tool(pattern)`" — true, and
        /// not the sentence somebody needs when they have left a bracket open.
        case badRule(String, line: Int, reason: PolicyRule.ParseError)

        public var description: String {
            switch self {
            case let .tabIndentation(line): return "line \(line): tabs are not allowed, indent with spaces"
            case let .expectedKey(line): return "line \(line): expected `key:` or `key: value`"
            case let .unknownKey(key, line): return "line \(line): unknown key `\(key)` (known: version, ask_timeout, allow, deny)"
            case let .missingValue(key, line): return "line \(line): `\(key)` needs a value"
            case let .invalidValue(key, line): return "line \(line): invalid value for `\(key)`"
            case let .inlineListValue(key, line): return "line \(line): `\(key)` takes a block list (`- rule` lines), not an inline value"
            case let .listItemOutsideList(line): return "line \(line): `- item` outside `allow:`/`deny:`"
            case let .badRule(rule, line, reason):
                return "line \(line): `\(rule)` — \(Self.explain(reason))"
            }
        }

        /// One clause each, phrased as the thing to go and fix.
        private static func explain(_ reason: PolicyRule.ParseError) -> String {
            switch reason {
            case .empty: return "the rule is empty"
            case .missingClosingParen: return "missing a closing bracket"
            case .emptyPattern: return "the brackets are empty — use `Tool` on its own, or `Tool(pattern)`"
            case .malformedTool: return "not a tool name — use `Tool` or `Tool(pattern)`"
            }
        }
    }

    public static func parse(_ text: String) throws -> Policy {
        var policy = Policy()
        var currentList: WritableKeyPath<Policy, [PolicyRule]>?

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = index + 1
            guard !rawLine.contains("\t") else { throw ParseError.tabIndentation(line: line) }

            let content = stripComment(rawLine)
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if content.hasPrefix(" ") {
                // Indented: must be a list item under the current list key.
                guard trimmed.hasPrefix("- "), let list = currentList else {
                    throw ParseError.listItemOutsideList(line: line)
                }
                let raw = unquote(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                do {
                    policy[keyPath: list].append(try PolicyRule(parsing: raw))
                } catch let reason as PolicyRule.ParseError {
                    throw ParseError.badRule(raw, line: line, reason: reason)
                }
            } else {
                guard !trimmed.hasPrefix("- ") else { throw ParseError.listItemOutsideList(line: line) }
                guard let colon = trimmed.firstIndex(of: ":") else { throw ParseError.expectedKey(line: line) }
                let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = unquote(String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces))

                switch key {
                case "version":
                    guard !value.isEmpty else { throw ParseError.missingValue(key: key, line: line) }
                    guard let version = Int(value) else { throw ParseError.invalidValue(key: key, line: line) }
                    policy.version = version
                    currentList = nil
                case "ask_timeout":
                    guard !value.isEmpty else { throw ParseError.missingValue(key: key, line: line) }
                    guard let seconds = Int(value), seconds >= 0 else { throw ParseError.invalidValue(key: key, line: line) }
                    policy.askTimeout = TimeInterval(seconds)
                    currentList = nil
                case "allow":
                    guard value.isEmpty else { throw ParseError.inlineListValue(key: key, line: line) }
                    currentList = \Policy.allow
                case "deny":
                    guard value.isEmpty else { throw ParseError.inlineListValue(key: key, line: line) }
                    currentList = \Policy.deny
                default:
                    throw ParseError.unknownKey(key, line: line)
                }
            }
        }
        return policy
    }

    /// Cut at the first `#` that starts the line or follows whitespace, outside
    /// quotes — so `Bash(*#*)` survives but `- Read  # safe` loses its comment.
    ///
    /// Internal rather than private so `PolicyDocument` can reuse it. The
    /// textual editor has to agree with the parser about what counts as a rule
    /// line down to the character; a second implementation of this is a drift
    /// bug waiting to delete the wrong line.
    static func stripComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character?
        for index in line.indices {
            let char = line[index]
            if let open = quote {
                if char == open { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "#", previous == nil || previous!.isWhitespace {
                return String(line[..<index])
            }
            previous = char
        }
        return line
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'",
              value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }
}
