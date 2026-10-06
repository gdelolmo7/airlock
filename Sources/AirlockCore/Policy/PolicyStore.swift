import Foundation

/// Loads and edits policy files.
///
/// Global: `~/.airlock/policy.yaml` (override the directory with
/// `AIRLOCK_POLICY_HOME` — used by tests and demos).
/// Project: `<project root>/.airlock/policy.yaml`.
///
/// "Always allow" appends rules **textually** (insert after the `allow:` line)
/// so user comments and formatting survive — a parse→serialize round-trip
/// would destroy them.
public struct PolicyStore: Sendable {
    public let globalFileURL: URL

    public init(globalFileURL: URL = PolicyStore.defaultGlobalFileURL()) {
        self.globalFileURL = globalFileURL
    }

    public static func defaultGlobalFileURL() -> URL {
        let home = ProcessInfo.processInfo.environment["AIRLOCK_POLICY_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".airlock")
        return URL(fileURLWithPath: home).appendingPathComponent("policy.yaml")
    }

    public func projectFileURL(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".airlock/policy.yaml")
    }

    // MARK: - Load

    public struct LoadResult: Sendable {
        public var policy: Policy
        /// Human-readable problems (unreadable / unparseable files). Surfaced,
        /// never swallowed — a broken policy file must not look like "no rules".
        public var problems: [String]
    }

    public func load(projectRoot: String?) -> LoadResult {
        var problems: [String] = []
        let global = read(globalFileURL, problems: &problems)
        guard let projectRoot else { return LoadResult(policy: global, problems: problems) }
        // An agent started in the policy directory itself — `cd ~ && claude`, or
        // `AIRLOCK_POLICY_HOME` pointing at the same folder — resolves to the
        // global file, which was then read TWICE and merged with itself: every
        // rule counted twice, every parse problem reported twice. A correctness
        // fix for the engine, not only for the pane.
        let projectFile = projectFileURL(projectRoot: projectRoot)
        guard projectFile != globalFileURL else {
            return LoadResult(policy: global, problems: problems)
        }
        let project = read(projectFile, problems: &problems)
        return LoadResult(policy: global.merging(project: project), problems: problems)
    }

    /// The rules in ONE file, unmerged.
    ///
    /// The pane edits a named file, and a merged view cannot answer "which file
    /// is this rule in" — which is the whole reason the scope switch exists.
    ///
    /// Deliberately NOT derived by subtracting the global list from the merged
    /// one. That would depend on `Policy.merging`'s concatenation order, which
    /// nothing declares as a contract, and it fails exactly where the pane
    /// matters most: a file that does not parse yields an empty `Policy`, so the
    /// subtraction is empty and the project segment would render "no rules"
    /// beside a warning instead of an explanation.
    public func load(fileAt url: URL) -> LoadResult {
        var problems: [String] = []
        let policy = read(url, problems: &problems)
        return LoadResult(policy: policy, problems: problems)
    }

    private func read(_ url: URL, problems: inout [String]) -> Policy {
        guard FileManager.default.fileExists(atPath: url.path) else { return Policy() }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return try PolicyParser.parse(text)
        } catch {
            problems.append("\(url.path): \(error)")
            return Policy()
        }
    }

    // MARK: - Write

    /// Append an allow rule ("Always" click). Creates the file if missing.
    /// Returns false if the rule was already present.
    @discardableResult
    public func appendAllowRule(_ ruleText: String, projectRoot: String?) throws -> Bool {
        try add(ruleText, kind: .allow, projectRoot: projectRoot)
    }

    /// Add a rule to either list. Creates the file from its template if missing,
    /// so the first rule you write from Settings lands in a documented file
    /// rather than a bare fragment.
    @discardableResult
    public func add(_ ruleText: String, kind: PolicyRuleKind, projectRoot: String? = nil) throws -> Bool {
        let url = projectRoot.map { projectFileURL(projectRoot: $0) } ?? globalFileURL
        try ensureFile(at: url, template: projectRoot == nil ? Self.globalTemplate : Self.projectTemplate)

        var document = PolicyDocument(try String(contentsOf: url, encoding: .utf8))
        guard document.insert(ruleText, into: kind) else { return false }
        try document.text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// Remove a rule. Returns false when the file or the rule is absent — a
    /// no-op, never an error, because the settings list can always be a moment
    /// behind a file someone edited by hand.
    @discardableResult
    public func remove(_ ruleText: String, kind: PolicyRuleKind, projectRoot: String? = nil) throws -> Bool {
        let url = projectRoot.map { projectFileURL(projectRoot: $0) } ?? globalFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        var document = PolicyDocument(try String(contentsOf: url, encoding: .utf8))
        guard document.remove(ruleText, from: kind) else { return false }
        try document.text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// Write the commented starter template to the global path if absent.
    /// Returns true if it was created.
    @discardableResult
    public func writeGlobalTemplateIfMissing() throws -> Bool {
        try writeTemplateIfMissing(projectRoot: nil)
    }

    /// The same, for whichever file a scope points at.
    ///
    /// The Settings pane's most prominent button used to be the global one
    /// unconditionally, so under a project scope it would write `~/.airlock` and
    /// then still report the project file as missing.
    @discardableResult
    public func writeTemplateIfMissing(projectRoot: String?) throws -> Bool {
        let url = projectRoot.map { projectFileURL(projectRoot: $0) } ?? globalFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try ensureFile(at: url, template: projectRoot == nil ? Self.globalTemplate : Self.projectTemplate)
        return true
    }

    private func ensureFile(at url: URL, template: String) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try template.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Templates

    public static let globalTemplate = """
    # agentic-notch policy
    #
    # The notch consults this file before interrupting you:
    #   deny rules   → auto-denied (the agent is told which rule)
    #   risk floor   → always asks, even if allowed (rm -rf, sudo, force push, …)
    #   allow rules  → auto-approved silently
    #   no match     → the notch asks you
    #
    # Rule syntax:  Tool            any use of the tool
    #               Tool(pattern)   glob on the command (Bash) or file path
    version: 1

    # Auto-defer to the agent's own prompt after this many seconds (0 = never).
    ask_timeout: 300

    allow:
      # Read-only tools.
      - Read
      - Glob
      - Grep
      # Git introspection.
      - Bash(git status)
      - Bash(git diff)
      - Bash(git diff *)
      - Bash(git log *)

    deny:
      # Hard bans — uncomment or add your own.
      # - Bash(*rm -rf /*)
      # - Bash(*production*)

    """

    public static let projectTemplate = """
    # agentic-notch project policy — merged over ~/.airlock/policy.yaml.
    # Project deny rules always beat global allow rules.
    version: 1

    allow:

    """
}
