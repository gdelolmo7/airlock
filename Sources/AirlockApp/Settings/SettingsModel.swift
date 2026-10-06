import AppKit
import Observation
import ServiceManagement
import AirlockCore
import os

/// State for the settings window. Registry-driven: a new agent integration
/// shows up here (and in the UI) with zero settings-specific code.
@MainActor
@Observable
final class SettingsModel {
    private nonisolated static let log = Logger(subsystem: "com.airlock.app", category: "settings")

    struct AgentRow: Identifiable {
        let kind: AgentKind
        let name: String
        let configPath: String
        var status: HookInstallStatus
        var actionError: String?
        var id: String { kind.rawValue }
    }

    struct PolicyInfo {
        var path: String
        var exists: Bool
        /// The rules themselves, not just how many. Counting them was enough
        /// when the pane could only point at a file; editing needs the list.
        var allow: [PolicyRule]
        var deny: [PolicyRule]
        var askTimeout: TimeInterval
        /// Parse problems, surfaced loud — a broken policy file must never
        /// silently read as "no rules".
        var problems: [String]

        /// The file at this path did not parse, so NOTHING in it is in effect.
        /// Kept apart from "no rules" because that is the promise
        /// `LoadResult.problems` exists to keep, and this pane is the only place
        /// it gets kept.
        var parseFailed: Bool { !problems.isEmpty }

        var state: RulesListState {
            RulesListState.of(exists: exists, parseFailed: parseFailed,
                              isEmpty: allow.isEmpty && deny.isEmpty)
        }

        func rules(_ kind: PolicyRuleKind) -> [PolicyRule] {
            kind == .allow ? allow : deny
        }
    }

    private(set) var agents: [AgentRow] = []

    /// Which file the Rules pane is editing.
    ///
    /// PERSISTED, and that is not a convenience. Sessions are pruned within
    /// minutes while the settings window is built once and kept, so a scope tied
    /// to the live session list would snap back to Everywhere mid-edit and the
    /// next rule added would land in the global file — the exact "where did this
    /// rule go" failure the switch exists to answer.
    var policyScope: PolicyScope = .everywhere {
        didSet {
            guard policyScope != oldValue else { return }
            UserDefaults.standard.set(policyScope.projectRoot, forKey: Self.scopeKey)
            policyNote = nil
            refresh()
        }
    }

    @ObservationIgnored static let scopeKey = "policy.scopeRoot"

    /// Where the project list comes from: the working directories of the
    /// sessions the app knows about.
    ///
    /// A closure rather than a model reference, and deliberately NOT
    /// `RepositoryWidgetModel` — that one resolves the git top level, which is
    /// the wrong path (the gate reads the agent's `cwd`, not its repository
    /// root), and it clears itself when its widget is switched off. The Rules
    /// pane must work with the whole agent surface turned off.
    @ObservationIgnored private let projectRoots: @MainActor () -> [String]

    init(projectRoots: @escaping @MainActor () -> [String] = { [] }) {
        self.projectRoots = projectRoots
        if let remembered = UserDefaults.standard.string(forKey: Self.scopeKey),
           let scope = PolicyScope.project(remembered, globalFile: store.globalFileURL) {
            // Validated on the way in: a remembered directory that has since
            // been deleted or unmounted degrades to Everywhere rather than being
            // recreated by the first write.
            policyScope = scope
        }
    }

    /// Fixed rows for the state gallery. `refresh()` is a no-op on this
    /// instance — every settings page calls it on appear, and it reads hook
    /// installs, the gate log and the policy files from disk.
    convenience init(previewing agents: [AgentRow], policy: PolicyInfo? = nil) {
        self.init()
        isPreview = true
        self.agents = agents
        if let policy {
            self.policy = policy
            scopedPolicy = policy
        }
    }

    /// True only for `init(previewing:)`.
    @ObservationIgnored private var isPreview = false

    /// Every project the switch may offer. The selected one is always in it.
    var policyScopeCandidates: [PolicyScope] {
        PolicyScope.candidates(selected: policyScope,
                               remembered: UserDefaults.standard.string(forKey: Self.scopeKey),
                               sessions: projectRoots(),
                               globalFile: store.globalFileURL)
    }

    /// The file the switch points at, read ON ITS OWN.
    ///
    /// A second field rather than a repointing of `policy`, because two other
    /// panes read that one as a fact about the global file: the ask-timeout row,
    /// and the licence pane's rule count. Repointing it would make both quietly
    /// wrong under a project scope.
    private(set) var scopedPolicy = PolicyInfo(path: "", exists: false, allow: [], deny: [],
                                               askTimeout: Policy.defaultAskTimeout, problems: [])
    private(set) var policy = PolicyInfo(path: "", exists: false, allow: [], deny: [],
                                         askTimeout: Policy.defaultAskTimeout, problems: [])
    /// Result of the last add/remove, shown inline. A rule that silently failed
    /// to save is the kind of thing you only discover when a command you thought
    /// you had allowed interrupts you again.
    var policyNote: String?
    private(set) var launchAtLogin = false
    var launchAtLoginNote: String?

    /// Mirrored rather than read through: `@Observable` can't see UserDefaults,
    /// so the toggle needs stored state to redraw from.
    var followsMainDisplay = NotchDisplayPolicy.followsMainDisplay {
        didSet {
            guard followsMainDisplay != oldValue else { return }
            NotchDisplayPolicy.followsMainDisplay = followsMainDisplay
        }
    }
    var showsOnExternalWhenClosed = NotchDisplayPolicy.showsOnExternalWhenClosed {
        didSet {
            guard showsOnExternalWhenClosed != oldValue else { return }
            NotchDisplayPolicy.showsOnExternalWhenClosed = showsOnExternalWhenClosed
        }
    }

    /// Which pane is showing. On the model rather than in the view's `@State`
    /// because the window is built once and reused — so opening it *onto* a
    /// particular pane has to survive the view already existing.
    /// Normalised on write, so a deep link to a folded pane selects the row it
    /// actually lands on. Without this the sidebar would highlight nothing while
    /// the detail showed Widgets — see `SettingsPane.resolved`.
    var pane: SettingsPane = .general {
        didSet {
            let resolved = pane.resolved
            if resolved != pane { pane = resolved }
        }
    }

    /// A row somebody asked to land on — from search, a notice or another
    /// page — until the page has scrolled to it (`SettingsAnchor`). A new value
    /// every time, so asking for the same row twice still lands twice.
    private(set) var revealRequest: RevealRequest?
    /// The row lit up right now, for a moment after landing.
    var highlighted: SettingsAnchor?

    struct RevealRequest: Equatable {
        let anchor: SettingsAnchor
        let serial = UUID()
    }

    /// Opens the row's page and has it scroll to the row and light it up.
    func reveal(_ anchor: SettingsAnchor) {
        pane = anchor.pane
        revealRequest = RevealRequest(anchor: anchor)
    }

    private(set) var suggestions: [PolicySuggestion] = []
    /// Match counts and authorship per rule text — see `RuleProvenance`.
    private(set) var provenance: [String: RuleProvenance] = [:]
    private(set) var recentGates: [GateRecord] = []

    /// Fired whenever hook install status is re-read, which every mutation here
    /// funnels through. `AgentsWidgetModel` derives its default from exactly
    /// that, so installing hooks turns the agent surfaces on without a relaunch.
    @ObservationIgnored var onHookStatusChange: (() -> Void)?

    @ObservationIgnored private let registry = AgentRegistry.shared
    @ObservationIgnored private let store = PolicyStore()
    @ObservationIgnored private let gateLogStore = GateLogStore()

    /// Launch-at-login (SMAppService) only works from a real .app bundle —
    /// `swift run` executables have nothing for launchd to register.
    var isBundled: Bool { AppBundle.isBundled }

    var versionLabel: String {
        guard isBundled,
              let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return "dev (swift run)"
        }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "v\(short) (\($0))" } ?? "v\(short)"
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard isBundled else { return }
        launchAtLoginNote = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Self.log.error("login item change failed: \(error.localizedDescription, privacy: .private)")
            launchAtLoginNote = "Login Items couldn't be changed. Try it in System Settings › General › Login Items."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refresh() {
        guard !isPreview else { return }
        if isBundled {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        agents = registry.all
            .sorted { $0.kind.displayName < $1.kind.displayName }
            .map { integration in
                let installer = integration.installer
                return AgentRow(
                    kind: integration.kind,
                    name: integration.kind.displayName,
                    configPath: installer.configPath,
                    status: installer.status()
                )
            }
        onHookStatusChange?()

        // Read from disk rather than from AppModel: the settings window is not
        // on the gate path, and going through the same file both writers use
        // means it cannot show a stale list.
        let log = gateLogStore.load()
        recentGates = log.records
        let result = store.load(projectRoot: nil)
        suggestions = PolicySuggestions.from(log, policy: result.policy)
        // What each rule has actually decided, and who put it there. Indexed in
        // one pass here rather than per row: the pane stays open while somebody
        // reads it, and forty rules against a 500-record log is 20,000
        // comparisons per redraw otherwise.
        provenance = RuleProvenance.index(log)
        policy = PolicyInfo(
            path: store.globalFileURL.path,
            exists: FileManager.default.fileExists(atPath: store.globalFileURL.path),
            allow: result.policy.allow,
            deny: result.policy.deny,
            askTimeout: result.policy.askTimeout ?? Policy.defaultAskTimeout,
            problems: result.problems
        )

        let file = policyScope.projectRoot.map(store.projectFileURL(projectRoot:))
            ?? store.globalFileURL
        let scoped = store.load(fileAt: file)
        scopedPolicy = PolicyInfo(
            path: file.path,
            exists: FileManager.default.fileExists(atPath: file.path),
            allow: scoped.policy.allow,
            deny: scoped.policy.deny,
            askTimeout: scoped.policy.askTimeout ?? Policy.defaultAskTimeout,
            problems: scoped.problems
        )
    }

    // MARK: - Agent actions

    func toggle(_ row: AgentRow) {
        clearError(row.kind)
        do {
            let installer = integration(for: row.kind).installer
            switch row.status {
            case .installed:
                try installer.uninstall()
            case .notInstalled:
                guard let source = HookBinaryStager.locateSourceHook(near: Bundle.main.executableURL) else {
                    throw SettingsError.hookBinaryMissing
                }
                let staged = try HookBinaryStager.stage(from: source)
                try installer.install(hookBinaryPath: staged.path)
            case .conflict:
                return // the person edits the file; the page offers no toggle for it
            }
        } catch SettingsError.hookBinaryMissing {
            Self.log.error("connect: the hook binary is missing from the bundle")
            setError("Part of Airlock is missing. Reinstall it, then try again.", for: row.kind)
        } catch {
            Self.log.error("connect/disconnect failed: \(error.localizedDescription, privacy: .private)")
            let what = row.status == .installed ? "disconnected" : "connected"
            setError("\(row.kind.displayName) couldn't be \(what). \(PlainProblem.file(error))", for: row.kind)
        }
        refresh()
    }

    func revealConfig(_ row: AgentRow) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.configPath)])
    }

    // MARK: - Policy actions

    func createStarterPolicy() {
        do {
            // The SCOPED file. Global unconditionally meant that under a project
            // scope the pane's most prominent button wrote `~/.airlock` and then
            // still reported the project file as missing.
            try store.writeTemplateIfMissing(projectRoot: policyScope.projectRoot)
        } catch {
            Self.log.error("starter rules failed: \(error.localizedDescription, privacy: .private)")
            policy.problems.append("Your rules file couldn't be made. \(PlainProblem.file(error))")
        }
        refresh()
    }

    /// Adds a rule, reporting the outcome rather than failing silently. The
    /// "already there" case is a real answer, not an error.
    func addPolicyRule(_ text: String, kind: PolicyRuleKind) {
        policyNote = nil
        do {
            if try store.add(text, kind: kind, projectRoot: policyScope.projectRoot) {
                policyNote = "Added \(kind.label.lowercased()) rule \(text)."
            } else {
                policyNote = "\(text) is already in the \(kind.label.lowercased()) list."
            }
        } catch {
            Self.log.error("rule write failed: \(error.localizedDescription, privacy: .private)")
            policyNote = "Your rules couldn't be saved. \(PlainProblem.file(error))"
        }
        refresh()
    }

    /// Accept a suggestion: write the rule it offered, verbatim. Same text the
    /// notch's Always button would have written, so the two paths cannot promise
    /// different things.
    func accept(_ suggestion: PolicySuggestion) {
        addPolicyRule(suggestion.ruleText, kind: suggestion.kind)
    }

    /// Forget the gates behind a suggestion so it stops being offered, without
    /// writing a rule. The record is the only evidence for it, so dropping the
    /// evidence is the honest way to dismiss.
    func dismiss(_ suggestion: PolicySuggestion) {
        var log = gateLogStore.load()
        log = GateLog(records: log.records.filter { $0.ruleText != suggestion.ruleText })
        try? gateLogStore.save(log)
        refresh()
    }

    func clearGateHistory() {
        gateLogStore.delete()
        policyNote = "Cleared the request history."
        refresh()
    }

    func removePolicyRule(_ rule: PolicyRule, kind: PolicyRuleKind) {
        policyNote = nil
        do {
            if try store.remove(rule.canonicalText, kind: kind, projectRoot: policyScope.projectRoot) {
                policyNote = "Removed \(rule.text)."
            } else {
                // The list is read from the merged policy, which includes
                // project files this pane does not edit.
                // Once the pane edits ONE named file, a failed remove is not
                // "it came from somewhere else" — it means the file changed
                // under you.
                policyNote = "\(rule.text) is no longer in \((scopedPolicy.path as NSString).lastPathComponent) — it may have been edited outside Airlock."
            }
        } catch {
            Self.log.error("rule write failed: \(error.localizedDescription, privacy: .private)")
            policyNote = "Your rules couldn't be saved. \(PlainProblem.file(error))"
        }
        refresh()
    }

    /// Runs a hypothetical request through the real engine. The same pure
    /// function the bridge calls, so the answer here is the answer you will get.
    func testPolicy(tool: String, subject: String) -> PolicyVerdict {
        let request = PermissionRequest(
            id: "settings-probe",
            toolName: tool.trimmingCharacters(in: .whitespaces),
            summary: "policy test",
            command: subject,
            target: subject,
            createdAt: Date()
        )
        // MERGED, deliberately, unlike the lists above. "Try it" promises the
        // answer the engine would give, and the engine merges.
        return PolicyEngine.evaluate(
            request, policy: store.load(projectRoot: policyScope.projectRoot).policy)
    }

    func openPolicyInEditor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: scopedPolicy.path))
    }

    func revealPolicy() {
        NSWorkspace.shared.activateFileViewerSelecting([store.globalFileURL])
    }

    // MARK: - Helpers

    private func integration(for kind: AgentKind) -> any AgentIntegration {
        registry.integration(kind: kind)! // rows only exist for registered kinds
    }

    private func setError(_ message: String, for kind: AgentKind) {
        if let index = agents.firstIndex(where: { $0.kind == kind }) {
            agents[index].actionError = message
        }
    }

    private func clearError(_ kind: AgentKind) {
        if let index = agents.firstIndex(where: { $0.kind == kind }) {
            agents[index].actionError = nil
        }
    }

    enum SettingsError: LocalizedError {
        case hookBinaryMissing
        var errorDescription: String? {
            "airlock-hook not found next to the app — run `swift build` first"
        }
    }
}
