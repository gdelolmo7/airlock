import AppKit
import Observation
import Foundation
import AirlockCore
import os

/// Owns whether the agent surfaces are shown, and why.
///
/// The decision itself is `AgentsPresence` in Core, pure and tested. What lives
/// here is the part that cannot be: reading the user's choice out of
/// UserDefaults as a tri-state, and asking every registered integration whether
/// its hook is actually installed.
///
/// Registry-driven like everything else about agents — `AgentRegistry.all`,
/// never a list of agent names — so a new integration counts towards the
/// default the moment it is registered.
@MainActor
@Observable
final class AgentsWidgetModel {
    /// Whether to draw the Agents tab, the compact session glyphs and the usage
    /// KPI. Read-only from outside on purpose: a plain setter could not tell a
    /// deliberate choice from a re-derivation, and only the first should stick.
    /// See `choose(_:)`.
    private(set) var isEnabled: Bool
    /// Why `isEnabled` is what it is, so the settings pane can say so rather
    /// than presenting a switch that mysteriously set itself.
    private(set) var basis: AgentsPresence.Basis

    /// The controller re-derives island presentation on flips — with agents off
    /// a running session is no longer a reason for the island to be visible.
    @ObservationIgnored var onChange: (() -> Void)?

    /// Hooks written by the card below. Claude's usage figures need one more
    /// thing than hooks — its status line — and the app connects that when it
    /// hears this. `onChange` cannot carry it: it fires when the switch moves,
    /// and on a Mac where agents were already on, nothing moves.
    @ObservationIgnored var onHooksInstalled: (() -> Void)?

    /// Raised when the gate hotkey fires, so the controller can hand the panel
    /// the keyboard. Set by whoever owns both, like `ClipboardWidgetModel`.
    @ObservationIgnored var onGateHotkey: (() -> Void)?

    /// Whether the gate can be answered from the keyboard at all.
    ///
    /// On by default. A blocking gate that only a pointer can answer is the one
    /// state this app cannot afford to make unreachable, and unlike the
    /// clipboard hotkey — a convenience — this is the only route to the buttons
    /// for anyone driving the Mac without a mouse.
    var hotkeyEnabled: Bool = Defaults.bool("agents.gateHotkeyEnabled", default: true) {
        didSet {
            guard hotkeyEnabled != oldValue else { return }
            Defaults.set(hotkeyEnabled, "agents.gateHotkeyEnabled")
            applyHotkey()
        }
    }

    var hotkey: GlobalHotkey.Binding = Defaults.binding("agents.gateHotkey",
                                                        default: .commandShiftA) {
        didSet {
            guard hotkey != oldValue else { return }
            Defaults.setBinding(hotkey, "agents.gateHotkey")
            applyHotkey()
        }
    }

    /// Which sound says a request is waiting (card D2): Airlock's own Needs
    /// you, or one of the Mac's. A picker rather than one fixed choice,
    /// because a sound you cannot change is one you switch off rather than
    /// retune. Whether it plays at all is Settings › General › Sounds
    /// (`Sounds.level`); somebody who picked a Mac sound before Airlock had
    /// its own keeps it, since only a stored choice is read back.
    var gateSoundName: String = Defaults.string("agents.gateSoundName", default: Sounds.airlockChoice) {
        didSet {
            guard gateSoundName != oldValue else { return }
            Defaults.set(gateSoundName, "agents.gateSoundName")
        }
    }

    /// Airlock's own first, then names from `/System/Library/Sounds`,
    /// filtered to the ones that read as "come back to this" rather than as
    /// an error or a success — `Basso` and `Funk` are macOS's error sounds and
    /// would say the wrong thing about a gate, which is a question, not a
    /// failure.
    static let gateSoundChoices = [Sounds.airlockChoice, "Submarine", "Ping", "Purr", "Tink", "Glass", "Morse"]

    /// Play it, whatever the Sounds setting. Settings' preview — a sound
    /// picker you cannot hear is a list of words.
    func playGateSound() {
        Sounds.play(Sounds.name(for: .needsYou, needsYouChoice: gateSoundName))
    }

    /// Non-nil when registration failed — surfaced in Settings for the same
    /// reason the clipboard's is: the symptom is a key that does nothing, and
    /// the usual cause (another app owns the chord) is invisible from here.
    private(set) var hotkeyError: String?

    @ObservationIgnored private let registry = AgentRegistry.shared
    private nonisolated static let log = Logger(subsystem: "com.airlock.app", category: "agents")
    @ObservationIgnored private let hotkeyRegistration = GlobalHotkey()

    private enum Keys {
        /// Matches the `widget.<id>.enabled` shape every other widget uses,
        /// though it is read as a tri-state rather than through `WidgetToggle`.
        static let choice = "widget.agents.enabled"
    }

    /// Agents that are set up on this Mac but not wired to us — their own config
    /// file exists and our hooks are not in it.
    ///
    /// The day-one card says "Claude Code is installed on this Mac but its hooks
    /// aren't", and that sentence is only true when somebody has actually run
    /// the thing. Without this the card would assert it at a user who has never
    /// installed an agent at all. Computed beside `hookStatuses` because it
    /// touches the filesystem for the same reason and must never run from a
    /// SwiftUI read.
    private(set) var unwiredAgentNames: [String] = []

    /// Which agents actually reach the notch, for the Agents tab's empty
    /// state. `basis` cannot answer that — a conflict counts as connected for
    /// it, and Developer mode switched on counts whatever is installed — so the
    /// tab used to say "No agents running" over three different situations.
    /// See `AgentsConnection`. Read with the hook statuses, for the same reason.
    private(set) var connection = AgentsConnection(connected: [])

    /// Claude usage's link, and whether the figures are switched on — set by
    /// the app delegate, which owns both. Nil here means nothing to check.
    @ObservationIgnored var usage: UsageConnectionModel?
    @ObservationIgnored var wantsUsage: @MainActor () -> Bool = { false }

    /// Whether the Agents tab says the usage figures have stopped. Launch puts
    /// Airlock's link back, so this is another tool taking it while the app
    /// runs — after which the figures froze and nothing on the notch said so.
    private(set) var usageStopped = false

    /// The gallery's: the picture is the values it was given, so the tab
    /// appearing must not read this Mac's agents over them.
    @ObservationIgnored private var isPreview = false

    init() {
        let basis = AgentsPresence.basis(choice: Self.storedChoice(),
                                         hookStatuses: Self.hookStatuses(registry: .shared))
        self.basis = basis
        self.isEnabled = basis.showsAgents
        self.unwiredAgentNames = Self.unwiredAgents(registry: .shared)
        self.connection = Self.readConnection(registry: .shared)
    }

    /// A fixed basis that reads no agent config and writes nothing — the state
    /// gallery's. `init()` asks every installer for its hook status, so a
    /// picture of "not set up" would depend on the Mac it was drawn on. Nothing
    /// here registers the hotkey: that is `start()`, never called on this one.
    ///
    /// `connection` defaults to what the basis implies — Claude Code connected
    /// for `.hooksInstalled`, nothing otherwise — so a picture of a broken
    /// setup has to say so.
    init(previewing basis: AgentsPresence.Basis, unwiredAgentNames: [String] = [],
         installError: String? = nil, connection: AgentsConnection? = nil,
         usageStopped: Bool = false) {
        self.isPreview = true
        self.basis = basis
        self.usageStopped = usageStopped
        self.isEnabled = basis.showsAgents
        self.unwiredAgentNames = unwiredAgentNames
        self.installError = installError
        self.connection = connection
            ?? AgentsConnection(connected: basis == .hooksInstalled ? [AgentKind.claudeCode.displayName] : [])
    }

    /// The settings toggle.
    ///
    /// Deliberately a method rather than a settable property: writing here is
    /// the user *choosing*, and a choice outranks every later hook install or
    /// uninstall. `reload()` must be able to move the flag without that being
    /// mistaken for somebody having asked.
    func choose(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.choice)
        reload()
    }

    /// Why the last "Connect" failed, or nil. Shown on the card that offered
    /// it — a button that silently does nothing is worse than no button.
    private(set) var installError: String?

    /// Write our hooks into every agent that hasn't got them.
    ///
    /// The day-one card promises "one click writes them", so it writes them
    /// rather than routing to Settings — a card that explains the problem and
    /// then hands you somewhere else to solve it is two steps pretending to be
    /// one. Settings keeps the per-agent rows for everything this cannot do.
    ///
    /// `.conflict` is skipped deliberately: the config already names us outside
    /// our managed block, and overwriting somebody's own entries is exactly what
    /// `HookInstaller` promises never to do. Those need the Settings pane, which
    /// can show which file and why.
    func installHooks() {
        installError = nil
        guard let source = HookBinaryStager.locateSourceHook(near: Bundle.main.executableURL) else {
            Self.log.error("connect: the hook binary is missing from the bundle")
            installError = "Part of Airlock is missing. Reinstall it, then try again."
            reload()
            return
        }
        do {
            let staged = try HookBinaryStager.stage(from: source)
            for integration in registry.all where integration.installer.status() == .notInstalled {
                try integration.installer.install(hookBinaryPath: staged.path)
            }
        } catch {
            Self.log.error("connect failed: \(error.localizedDescription, privacy: .private)")
            installError = Self.connectFailure(error)
        }
        // Re-derives `basis`: with hooks now present the switch turns itself on,
        // which is the whole point of the derived default.
        reload()
        if installError == nil { onHooksInstalled?() }
    }

    /// What the card says when connecting failed. Static so the state gallery
    /// draws the same sentence.
    static func connectFailure(_ error: any Error) -> String {
        "Your coding agent couldn't be connected. \(PlainProblem.file(error))"
    }

    /// Re-read after hooks are installed or removed.
    ///
    /// Only moves anything while the value is still derived — which is what
    /// makes "install the Claude hooks" turn the tab on by itself for someone
    /// who found the app as a notch companion first, without ever second-
    /// guessing a user who has stated a preference.
    func refreshFromHooks() { reload() }

    func start() { applyHotkey() }

    // MARK: - Gate hotkey

    /// Registered whatever `isEnabled` says, deliberately.
    ///
    /// Switching the agent surface off is a statement about clutter, not consent
    /// to hang — `demandsAttention` already keeps a blocking gate on screen
    /// through the switch. A hotkey that went away with the toggle would leave
    /// that gate visible and unanswerable for anyone without a pointer, which is
    /// the exact failure the switch was never meant to cause.
    private func applyHotkey() {
        hotkeyRegistration.unregister()
        hotkeyError = nil
        guard hotkeyEnabled else { return }
        hotkeyRegistration.register(hotkey) { [weak self] in self?.onGateHotkey?() }
        hotkeyError = hotkeyRegistration.lastError
    }

    private func reload() {
        let previous = isEnabled
        basis = AgentsPresence.basis(choice: Self.storedChoice(),
                                     hookStatuses: Self.hookStatuses(registry: registry))
        isEnabled = basis.showsAgents
        unwiredAgentNames = Self.unwiredAgents(registry: registry)
        connection = Self.readConnection(registry: registry)
        if isEnabled != previous { onChange?() }
    }

    /// Re-read on the tab's own appearance too: a conflict is fixed by hand,
    /// in a file, while the app runs, and nothing else would notice.
    func refreshConnection() {
        guard !isPreview else { return }
        connection = Self.readConnection(registry: registry)
        guard let usage else { return }
        usage.refresh()
        usageStopped = UsageReadout.showsStopped(wanted: wantsUsage(), connection: usage.state)
    }

    /// The stopped card's button: Airlock's own entry back, with the other
    /// tool's command chained behind it as at launch — never removed.
    func restoreUsage() {
        usage?.connect()
        refreshConnection()
    }

    private static func readConnection(registry: AgentRegistry) -> AgentsConnection {
        AgentsConnection(registry.all.map {
            AgentsConnection.Link(name: $0.kind.displayName, status: $0.installer.status(),
                                  settingsPath: $0.installer.configPath)
        })
    }

    /// Agents with a config file of their own and no hook of ours in it.
    ///
    /// A conflict counts as wired up here for the same reason `AgentsPresence`
    /// treats it that way — the config already names us, so "not wired up" is
    /// the wrong thing to tell somebody whose problem is the opposite.
    private static func unwiredAgents(registry: AgentRegistry) -> [String] {
        registry.all.compactMap { integration in
            guard integration.installer.status() == .notInstalled,
                  FileManager.default.fileExists(atPath: integration.installer.configPath)
            else { return nil }
            return integration.kind.displayName
        }
    }

    /// nil until the switch is touched — see `AgentsPresence.basis`.
    private static func storedChoice() -> Bool? {
        UserDefaults.standard.object(forKey: Keys.choice) as? Bool
    }

    /// Touches the filesystem (each installer reads its agent's config), so it
    /// runs at launch and on an explicit refresh — never from a SwiftUI read.
    private static func hookStatuses(registry: AgentRegistry) -> [HookInstallStatus] {
        registry.all.map { $0.installer.status() }
    }

    /// One line for the settings pane, naming the reason rather than leaving the
    /// user to infer it from a switch that is already in a position.
    var explanation: String {
        switch basis {
        case .chosen(true):
            return "On because you turned it on. Connecting or disconnecting an agent won't change that."
        case .chosen(false):
            return "Off because you turned it off, so the Agents tab, the agent icons beside the notch and Claude usage are hidden. Connecting an agent won't change that."
        case .hooksInstalled:
            return "On because a coding agent is connected. A request waiting for your answer always shows, whatever this says, so an agent is never left waiting on nobody."
        case .noHooksInstalled where GuideSwitch.isOn:
            // With the guide on nothing is shown until someone says yes
            // (card 3.02), so the switch reads off and this says so.
            return "Off: no coding agent is connected on this Mac. Switch it on to connect Claude Code or Codex. Connecting one turns this on by itself."
        case .noHooksInstalled:
            // Reads "on" while nobody has chosen, because the Agents tab IS on
            // screen asking to be set up. Saying "off" here would describe a
            // switch the user can see in the other position.
            return "On, but nothing is connected yet: the Agents tab is showing so you can connect from it. Once you do, the agent icons and Claude usage turn on too. Don't use coding agents? Switch this off and it stays off."
        }
    }
}
