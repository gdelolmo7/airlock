import Foundation

/// Takes the person out of a crash report before it leaves the Mac.
///
/// A crash report is addresses, function names and a few facts about the
/// machine, and those are what it is for. What can ride along with them is
/// the person: their account name and the Mac's name, typed into every file
/// path under the home folder (`/Users/<name>/…`, which is where the app
/// itself lives for anyone who keeps it in `~/Applications`), and sometimes
/// into an error message. So every string in the report goes through
/// `scrub(_:)` on the way out, and the facts about the machine are kept by
/// name rather than by default (`keptContextFields`): a field Sentry adds in
/// a later version is left out until somebody decides it belongs.
///
/// What stays is what a fix needs: Airlock's version and build, the macOS
/// version, the Mac's model, and the stack trace.
///
/// Pure, so it is tested without Sentry, and safe on any thread: the crash
/// library calls it from whichever thread is sending. The expressions are
/// built once, here, and never changed; `NSRegularExpression` is immutable
/// and Sendable, so the compiler checks the rest.
public final class CrashReportScrubber: Sendable {
    /// What a person's account name becomes.
    public static let userMark = "<user>"
    /// What the Mac's name becomes.
    public static let computerMark = "<computer>"

    /// Keys whose whole value is about who or where, dropped wherever they
    /// turn up in a nested value. `device_app_hash` is derived from the Mac's
    /// network address: a number that names the machine.
    public static let droppedKeys: Set<String> = [
        "hostname", "host_name", "computer_name", "device_name",
        "user_name", "username", "email", "ip_address", "device_app_hash",
    ]

    /// The facts about the machine that are kept, by context and field.
    /// Everything else is dropped: the `culture` context (language, region,
    /// time zone), the device's boot time and locale, the "user info" an
    /// exception can carry, and anything a newer Sentry adds.
    public static let keptContextFields: [String: Set<String>] = [
        "app": ["app_identifier", "app_name", "app_version", "app_build", "build_type",
                "app_id", "in_foreground", "is_active", "app_memory"],
        "device": ["family", "model", "model_id", "arch", "simulator", "processor_count",
                   "cpu_description", "memory_size", "free_memory", "usable_memory",
                   "thermal_state"],
        "os": ["name", "version", "build", "kernel_version", "rooted"],
    ]

    /// A home folder in a path, other than the shared one. The name stops at
    /// the next slash, space, quote or colon. `<` is left out of the name so
    /// that a path already scrubbed is not matched again.
    private static let homeFolder = try! NSRegularExpression(
        pattern: #"/Users/(?!Shared(?:/|$|[\s"']))[^/\s"'<>:]+"#,
        options: [.caseInsensitive])

    private let names: [(pattern: NSRegularExpression, mark: String)]

    /// - Parameters:
    ///   - computerNames: the Mac's name as the person set it, its local host
    ///     name, and whatever `gethostname` says.
    ///   - userNames: the account's short name and its full name.
    ///
    /// Names shorter than three characters are left alone: replacing "al"
    /// everywhere would take apart the function names the report is for.
    public init(computerNames: [String], userNames: [String]) {
        var seen = Set<String>()
        let marked = computerNames.map { ($0, Self.computerMark) } + userNames.map { ($0, Self.userMark) }
        names = marked
            .map { ($0.0.trimmingCharacters(in: .whitespacesAndNewlines), $0.1) }
            .filter { $0.0.count >= 3 && seen.insert($0.0.lowercased()).inserted }
            // Longest first, so "Ana's MacBook Pro" goes before "Ana" can
            // leave "<user>'s MacBook Pro" behind.
            .sorted { $0.0.count > $1.0.count }
            .compactMap { name, mark in
                // Whole words only, so a short account name inside a longer
                // word (a function name, say) is not cut out of it.
                let escaped = NSRegularExpression.escapedPattern(for: name)
                guard let pattern = try? NSRegularExpression(
                    pattern: #"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#,
                    options: [.caseInsensitive]) else { return nil }
                return (pattern, mark)
            }
    }

    /// The text with every home folder and every known name replaced.
    public func scrub(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = Self.replace(Self.homeFolder, in: text, with: "/Users/\(Self.userMark)")
        for name in names {
            result = Self.replace(name.pattern, in: result, with: name.mark)
        }
        return result
    }

    /// Any value from a report: strings scrubbed, dictionaries and arrays
    /// walked all the way down, `droppedKeys` removed. Numbers and the rest
    /// come back as they were.
    public func scrub(value: Any) -> Any {
        if let text = value as? String {
            return scrub(text)
        }
        if let dictionary = value as? [String: Any] {
            return scrub(dictionary: dictionary)
        }
        if let array = value as? [Any] {
            return array.map { scrub(value: $0) }
        }
        return value
    }

    public func scrub(dictionary: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dictionary where !Self.droppedKeys.contains(key.lowercased()) {
            result[key] = scrub(value: value)
        }
        return result
    }

    /// The report's contexts cut down to `keptContextFields`, the values
    /// scrubbed as well. Nil when nothing is left.
    public func scrub(contexts: [String: [String: Any]]?) -> [String: [String: Any]]? {
        guard let contexts else { return nil }
        var kept: [String: [String: Any]] = [:]
        for (name, fields) in contexts {
            guard let allowed = Self.keptContextFields[name] else { continue }
            var out: [String: Any] = [:]
            for (key, value) in fields where allowed.contains(key) {
                out[key] = scrub(value: value)
            }
            if !out.isEmpty { kept[name] = out }
        }
        return kept.isEmpty ? nil : kept
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, with mark: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: mark))
    }
}
