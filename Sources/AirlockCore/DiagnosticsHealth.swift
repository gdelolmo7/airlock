import Foundation

/// The same facts as the diagnostics paste, read instead of copied.
///
/// **The distinction the whole thing turns on is three states, not two.** A
/// health page that prints "not allowed" for Automation — which macOS gives no
/// way to read without raising the prompt — sends somebody to System Settings to
/// fix nothing, and `PermissionState.asksOnFirstUse` and `UpdaterState.notBundled`
/// both exist precisely to preserve that. Neither is broken. Colouring them like
/// a fault trains people to ignore the page, which is the one failure a health
/// page cannot survive.
///
/// The other half of that: most of the time nothing is wrong, and a pane that
/// looks eventful when everything is fine is a pane nobody reads on the day it
/// matters. `faults` being empty is the common case and is meant to be dull.
public struct DiagnosticsHealth: Equatable, Sendable {
    /// What a row's dot means.
    public enum Severity: Equatable, Sendable {
        /// Known, and fine.
        case fact
        /// Known, and wrong. The only rows worth acting on, and the only ones
        /// the design makes tappable.
        case fault
        /// Honestly unknown, and not a problem. Hollow rather than tinted.
        case unknown
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let title: String
        public let detail: String
        public let severity: Severity
        /// Where the fix is. Only ever set on a fault — a row with nothing wrong
        /// has nowhere to send anybody.
        public let remedy: Remedy?

        public var id: String { title }

        public init(title: String, detail: String, severity: Severity, remedy: Remedy? = nil) {
            self.title = title
            self.detail = detail
            self.severity = severity
            self.remedy = remedy
        }
    }

    /// Where an amber row leads.
    public enum Remedy: Equatable, Sendable {
        case agentsSettings
        case permissionsSettings
        case updateSettings
    }

    public let rows: [Row]

    public init(rows: [Row]) { self.rows = rows }

    public var faults: [Row] { rows.filter { $0.severity == .fault } }
    /// The boring case, and the one the pane exists to make legible.
    public var isHealthy: Bool { faults.isEmpty }

    public static func from(_ report: DiagnosticsReport) -> DiagnosticsHealth {
        var rows: [Row] = []

        for hook in report.hooks {
            let severity: Severity
            switch hook.state {
            case .installed: severity = .fact
            // Not connected is a choice, not a fault: most people use one agent
            // or none, and a Codex nobody wants is not something to fix.
            case .notInstalled: severity = .unknown
            // The one to fix — the agent's config names us outside our managed
            // block, so uninstalling cannot find it and installing would
            // duplicate it.
            case .conflict: severity = .fault
            }
            // The report keeps the technical words for support; this row is
            // on screen, so it says it the way Settings does.
            let plain: String
            switch hook.state {
            case .installed: plain = "connected"
            case .notInstalled: plain = "not connected"
            case .conflict: plain = "needs a hand"
            }
            rows.append(Row(title: hook.agent,
                            detail: plain,
                            severity: severity,
                            remedy: severity == .fault ? .agentsSettings : nil))
        }

        for permission in report.permissions {
            let severity: Severity
            switch permission.state {
            case .allowed:
                severity = .fact
            case .notAllowed, .restricted, .notWorking:
                severity = .fault
            case .asksOnFirstUse, .notAsked:
                // Nothing is wrong and nothing has been refused — macOS simply
                // has not been asked yet, and asking is what using the feature
                // does. Printing this as a fault is the mistake this case exists
                // to prevent.
                severity = .unknown
            }
            rows.append(Row(title: permission.name,
                            detail: permission.state.label,
                            severity: severity,
                            remedy: severity == .fault ? .permissionsSettings : nil))
        }

        switch report.updater {
        case .configured(let automatic):
            rows.append(Row(title: "Updates",
                            detail: automatic ? "checks automatically" : "checks when you ask",
                            severity: .fact))
        case .notConfigured:
            rows.append(Row(title: "Updates",
                            detail: "not configured in this build",
                            severity: .unknown))
        case .notBundled:
            // Running from source. There is nothing to update and nothing to
            // fix, which is why this is not amber.
            rows.append(Row(title: "Updates",
                            detail: "running from source",
                            severity: .unknown))
        }

        // Deliberately `.unknown` rather than `.fault`, and the choice is the
        // same one the permission rows make. Nothing in Airlock is broken —
        // another app has taken a capability away, the remedy is not in any of
        // our settings panes, and the app holding it is often one the user
        // wants running. Amber every time their editor is open is precisely the
        // wolf-crying these tests exist to prevent; a hollow row that names the
        // holder is what turns "dictation fired on its own" from a mystery into
        // a sentence.
        //
        // No row at all when it is off. There is nothing to say.
        if case .on(let holder) = report.secureInput {
            let who = holder ?? "another app"
            rows.append(Row(title: "Secure input",
                            detail: "on — \(who) is hiding key presses, so a chord "
                                  + "cannot cancel a hold",
                            severity: .unknown))
        }

        return DiagnosticsHealth(rows: rows)
    }

    /// The sentence under "Nothing to report": the hollow rows, named, and
    /// the reassurance counted to match — "neither" is only right for two.
    ///
    /// Built from the rows rather than written by hand, so it cannot claim
    /// something the rows disagree with.
    public var healthySummary: String {
        let unknowns = rows.filter { $0.severity == .unknown }
        guard !unknowns.isEmpty else { return "Everything checked out." }
        let named = unknowns.map { "\($0.title): \($0.detail)" }.joined(separator: "; ")
        switch unknowns.count {
        case 1: return named + ". That is not a problem."
        case 2: return named + ". Neither is a problem."
        default: return named + ". None of these is a problem."
        }
    }
}
