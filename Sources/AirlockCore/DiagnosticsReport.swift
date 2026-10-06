import Foundation

/// The facts a support conversation actually starts with, in one paste.
///
/// **This is not a log export, deliberately.** `Log.swift` marks values
/// `.private`, which is right — an agent's command line, a repository name and a
/// clipboard entry have no business leaving this Mac — but it also means a log
/// someone exports and pastes is mostly `<private>`. It looks like evidence and
/// answers nothing. What a bug report actually needs is a dozen facts about the
/// install, and every one of them is known here without reading a single line of
/// log.
///
/// **Nothing in this type is secret, and that is a property of the type rather
/// than of the code that fills it in.** There is no field for a licence key, a
/// token, `License.ref`, an email address, a file path, a session or a
/// repository — so a future caller cannot put one here by accident. The two
/// values that arrive from richer types are narrowed on the way in
/// (`HookState.init(_:)` drops the conflict message, which names a config file;
/// `LicenseState.init(_:)` drops the licence entirely and keeps the state word),
/// and both narrowings are tested.
///
/// It sits beside `CalendarAccessDiagnosis` for the same reason that does: what
/// the app tells somebody about their own machine is a decision, decisions are
/// worth testing, and neither of these needs a running app to be checked.
public struct DiagnosticsReport: Equatable, Sendable {

    /// What macOS currently says about one permission.
    ///
    /// `asksOnFirstUse` is not a hedge — it is the truth for Automation and for
    /// audio capture, which macOS exposes no way to read without sending the
    /// very request that raises the prompt. Printing "not allowed" for those
    /// would be a guess, and a guess in a diagnostics report is worse than an
    /// admission.
    public enum PermissionState: Equatable, Sendable {
        case allowed
        case notAllowed
        /// Never asked for yet — nothing on file either way.
        case notAsked
        /// An administrator's decision (MDM, Screen Time), not the user's.
        case restricted
        /// Unreadable without asking. See above.
        case asksOnFirstUse
        /// Switched on in System Settings and still refused: macOS kept the
        /// approval an earlier, differently signed Airlock was given. Reading
        /// it as `allowed` is how a dead dictation key used to look healthy.
        case notWorking

        public var label: String {
            switch self {
            case .allowed: return "allowed"
            case .notAllowed: return "not allowed"
            case .notAsked: return "not asked"
            case .restricted: return "restricted"
            case .asksOnFirstUse: return "asks on first use"
            case .notWorking: return "on, but not working"
            }
        }
    }

    public struct Permission: Equatable, Sendable {
        public let name: String
        public let state: PermissionState

        public init(_ name: String, _ state: PermissionState) {
            self.name = name
            self.state = state
        }
    }

    /// A hook's install state with its detail taken off.
    ///
    /// `HookInstallStatus.conflict` carries a message naming the config file it
    /// found the unmanaged entries in — an absolute path with a home directory
    /// in it. That belongs in Settings, where the person reading it owns the
    /// path; it does not belong in a string headed for a public issue tracker.
    public enum HookState: Equatable, Sendable {
        case installed
        case notInstalled
        case conflict

        public init(_ status: HookInstallStatus) {
            switch status {
            case .installed: self = .installed
            case .notInstalled: self = .notInstalled
            case .conflict: self = .conflict
            }
        }

        public var label: String {
            switch self {
            case .installed: return "installed"
            case .notInstalled: return "not installed"
            case .conflict: return "conflict"
            }
        }
    }

    public struct Hook: Equatable, Sendable {
        public let agent: String
        public let state: HookState

        public init(_ agent: String, _ state: HookState) {
            self.agent = agent
            self.state = state
        }
    }

    /// Whether this copy could ever update itself.
    ///
    /// Three answers, not two: packaging leaves Sparkle's keys out when there is
    /// no appcast URL or signing key, and `swift run` has nothing to update at
    /// all. "Updates are broken" and "this build was never given an update feed"
    /// are the same symptom and different bugs.
    public enum UpdaterState: Equatable, Sendable {
        /// Not a bundle — running from `swift build`.
        case notBundled
        /// Bundled, but packaged without an appcast URL or signing key.
        case notConfigured
        case configured(automaticChecks: Bool)

        public var label: String {
            switch self {
            case .notBundled: return "not applicable (running from source)"
            case .notConfigured: return "not configured in this build"
            case .configured(let automatic):
                return "configured, automatic checks \(automatic ? "on" : "off")"
            }
        }
    }

    /// The entitlement, reduced to the word for it.
    ///
    /// Deliberately carries no `License`: not the key, not the token, not `ref`,
    /// not the email, and not even the vendor's licence id. The id is not a
    /// secret and the log does print it, but a log line is read by one person
    /// and a GitHub issue is read by everybody, and nothing in a bug report is
    /// answered better by knowing which customer this is.
    public enum LicenseState: Equatable, Sendable {
        case free
        case trial(daysRemaining: Int)
        case trialExpired
        case subscribed
        case grace
        case overdue

        public init(_ entitlement: Entitlement) {
            switch entitlement {
            case .free: self = .free
            case .trialing(let days): self = .trial(daysRemaining: days)
            case .trialExpired: self = .trialExpired
            case .licensed: self = .subscribed
            case .grace: self = .grace
            case .overdue: self = .overdue
            }
        }

        public var label: String {
            switch self {
            case .free: return "free"
            case .trial(let days):
                return "trial, \(days) day\(days == 1 ? "" : "s") left"
            case .trialExpired: return "trial expired"
            case .subscribed: return "subscribed"
            case .grace: return "subscribed (renewal not confirmed yet)"
            case .overdue: return "subscription needs attention"
            }
        }
    }

    /// Whether another app has secure event input switched on.
    ///
    /// It belongs in a diagnostics report because it silently removes a
    /// capability this app depends on: while it is enabled macOS withholds key
    /// events from every `CGEventTap`, so `HoldKeyMonitor` cannot see the second
    /// key of a chord and a bare-modifier hold runs on through ⌥⌫ as if the
    /// modifier were alone. Nothing logs, nothing errors, and the only visible
    /// symptom is dictation firing while somebody edits text.
    ///
    /// Found the hard way: across an entire log, key-press disqualification had
    /// fired exactly once, while the modifier-based path — which secure input
    /// does NOT suppress — had fired eight times. The asymmetry was the clue.
    public enum SecureInputState: Equatable, Sendable {
        case off
        /// `holder` is the app that turned it on, when it could be resolved.
        case on(holder: String?)

        public var label: String {
            switch self {
            case .off: return "off"
            case .on(let holder):
                let who = holder ?? "an app that could not be identified"
                return "ON, held by \(who) — key chords are invisible to the hold monitor"
            }
        }
    }

    public struct WidgetState: Equatable, Sendable {
        public let name: String
        public let isEnabled: Bool

        public init(_ name: String, isEnabled: Bool) {
            self.name = name
            self.isEnabled = isEnabled
        }
    }

    /// Already formatted by the caller — "v1.2.0 (34)", or "dev (swift run)".
    public let version: String
    /// "15.3.1 (24D70)". A string rather than three numbers because nothing here
    /// compares versions; it only prints them.
    public let macOS: String
    /// `hw.model`, e.g. "Mac16,7". Says nothing about who owns it.
    public let hardware: String
    /// Whether a display with a camera housing is currently attached and open.
    /// Half the panel's geometry depends on the answer.
    public let hasNotch: Bool
    public let displayCount: Int
    public let permissions: [Permission]
    public let hooks: [Hook]
    public let updater: UpdaterState
    public let license: LicenseState
    public let widgets: [WidgetState]
    public let secureInput: SecureInputState

    public init(version: String,
                macOS: String,
                hardware: String,
                hasNotch: Bool,
                displayCount: Int,
                permissions: [Permission],
                hooks: [Hook],
                updater: UpdaterState,
                license: LicenseState,
                widgets: [WidgetState],
                secureInput: SecureInputState) {
        self.version = version
        self.macOS = macOS
        self.hardware = hardware
        self.hasNotch = hasNotch
        self.displayCount = displayCount
        self.permissions = permissions
        self.hooks = hooks
        self.updater = updater
        self.license = license
        self.widgets = widgets
        self.secureInput = secureInput
    }
}

/// Turns the facts into the thing that goes on the pasteboard.
///
/// Pure, and the whole reason the report is a value type: what this prints can
/// be read in a test rather than by launching the app, granting four
/// permissions, and looking.
///
/// **Short on purpose.** Nine lines fit in an issue without a fold, and a report
/// nobody scrolls past is a report that gets read. Anything that would need a
/// tenth line has to earn it against that.
public enum DiagnosticsFormatter {
    public static let header = "Airlock diagnostics"

    /// Between the items of a one-line list. A middle dot rather than a comma,
    /// because several of the items contain commas themselves.
    private static let separator = " · "

    public static func text(_ report: DiagnosticsReport) -> String {
        let rows: [(String, String)] = [
            ("Version", report.version),
            ("macOS", report.macOS),
            ("Mac", machineLine(report)),
            ("Permissions", list(report.permissions.map { "\($0.name) \($0.state.label)" })),
            ("Hooks", list(report.hooks.map { "\($0.agent) \($0.state.label)" })),
            ("Updater", report.updater.label),
            ("Licence", report.license.label),
            ("Widgets", widgetLine(report.widgets)),
        ] + secureInputRow(report)
        // Padded to the longest label so the values line up in whatever
        // proportional font an issue tracker renders it in — one leading pad is
        // not enough for that, but a monospaced paste is where this lands most
        // often and there it is exact.
        let width = rows.map(\.0.count).max() ?? 0
        let body = rows.map { label, value in
            "  " + label.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + value
        }
        return ([header] + body).joined(separator: "\n")
    }

    /// The exception to the eight-line rule above, and it earns the ninth line
    /// by never using it: secure input is off almost always, and when it is on
    /// it explains a whole class of "dictation fired on its own" report that is
    /// otherwise unattributable from a paste.
    private static func secureInputRow(_ report: DiagnosticsReport) -> [(String, String)] {
        guard report.secureInput != .off else { return [] }
        return [("Secure input", report.secureInput.label)]
    }

    private static func machineLine(_ report: DiagnosticsReport) -> String {
        let notch = report.hasNotch ? "notch yes" : "notch no"
        let displays = report.displayCount == 1 ? "1 display" : "\(report.displayCount) displays"
        return [report.hardware, notch, displays].joined(separator: separator)
    }

    /// Enabled first and named; the rest gathered behind "off". A reader
    /// scanning for "is the thing they are complaining about even switched on"
    /// gets the answer either way, and switching everything off is a state worth
    /// seeing at a glance.
    private static func widgetLine(_ widgets: [DiagnosticsReport.WidgetState]) -> String {
        let on = widgets.filter(\.isEnabled).map(\.name)
        let off = widgets.filter { !$0.isEnabled }.map(\.name)
        if off.isEmpty { return on.isEmpty ? "none" : on.joined(separator: ", ") }
        let enabled = on.isEmpty ? "none on" : on.joined(separator: ", ")
        return enabled + separator + "off: " + off.joined(separator: ", ")
    }

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "none" : items.joined(separator: separator)
    }
}
