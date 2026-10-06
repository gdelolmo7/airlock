import AppKit
import CoreWLAN
import IOKit.ps
import IOKit.pwr_mgt
import Network
import Observation
import AirlockCore

/// The rail of system toggles on the home tab.
///
/// **Only controls with a public API are here, and that is a deliberate ceiling
/// rather than a first pass.** The drawn rail also carries Bluetooth, Night
/// Shift, Focus and a lock button; none of the first three can be written
/// without private symbols, and Focus cannot be written at all — Apple exposes
/// setting it to Shortcuts and to nothing else.
///
/// **Lock was here and shipped broken, which is how this ceiling gets tested.**
/// It shelled out to `CGSession` inside `Menu Extras/User.menu`, described here
/// as "the same call the Apple menu's Lock Screen makes" — true when written and
/// false by macOS 26, where `User.menu` is gone and nine legacy menus are all
/// that remain in that folder. It threw on every press, on every current Mac,
/// and the rail said so in orange.
///
/// Nothing public replaces it. `SACLockScreenImmediate` lives in the private
/// `login.framework`, and firing `ScreenSaverEngine` locks only if a Lock Screen
/// setting is on that an app cannot read — a button that sometimes just starts a
/// screensaver is exactly the half-toggle this rail refuses. So lock leaves,
/// rather than staying as the one control that lies. The same answer the other
/// three got, applied to one that had already been written. An updater-shipping, notarized app whose pitch is that
/// it keeps working is the wrong place to bet on `CoreBrightness` still
/// answering after the next point release, so the rail states what it has
/// rather than half-toggling what it hasn't.
///
/// Every control here is read on demand and written through a documented API:
/// CoreWLAN for the radio, an `IOPMAssertion` for the wake lock, System Events
/// for the appearance, and the system screenshot tool for capture.
@MainActor
@Observable
final class SystemControlsModel {
    /// Said when macOS turns the Wi-Fi switch down. Static so the state
    /// gallery draws the same sentence.
    static let wifiRefused = "macOS didn't let Airlock change Wi-Fi. Use the Wi-Fi menu in the menu bar instead."
    static let noWiFi = "This Mac has no Wi-Fi."
    /// Automation refused for System Events. Names the permission, never the
    /// app being controlled: "System Events" is a name only scripts use.
    static let appearanceRefused = "Dark mode needs the Automation permission."
    static let appearanceFailed = "macOS didn't change the appearance."
    /// Said beside a press, not instead of it: the tool still runs, so the
    /// first press is still the one macOS asks on.
    static let screenshotNeedsPermission = "Screenshots need the Screen Recording permission."
    static let recordingNeedsPermission = "Recording needs the Screen Recording permission."
    static let screenshotDidNotStart = "The screenshot tool didn't start."
    static let recorderDidNotStart = "The screen recorder didn't start."
    static let displaySleepDidNotStart = "The display didn't go to sleep."
    /// Under the rail while an agent holds the Mac awake and the switch is
    /// off, so the cup in the notch and the unlit button stop disagreeing.
    static let heldForAgentsNote = "Staying awake while an agent works."

    /// Why the last press did nothing, and the page that fixes it when there
    /// is one — a refusal with nowhere to go was half an answer.
    struct Problem: Equatable {
        let sentence: String
        var pane: PermissionPage?
    }

    // MARK: - Arrangement

    /// The user's rail order, and which buttons they switched off.
    ///
    /// **Observable properties, not `UserDefaults` reads.** SwiftUI cannot see a
    /// defaults read, so a rail wired to one would draw the old order after
    /// arrange mode wrote the new one — the same trap `SoundWidgetModel` was
    /// created to record, and the same fix.
    ///
    /// Stored as raw values beside the `widget.*` family because they are the
    /// same kind of fact: what the panel shows and in what order.
    private(set) var order: [String] = UserDefaults.standard.stringArray(forKey: "systemControls.order") ?? []
    private(set) var off: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "systemControls.off") ?? [])

    /// Declaration order, rearranged by whatever the user stored.
    ///
    /// Reuses `WidgetArrangement.arranged` rather than repeating it: the two
    /// rules that matter are the same ones — a stored id that no longer exists
    /// is dropped, and an id the stored list never heard of KEEPS ITS
    /// DECLARATION SLOT rather than being appended. That second rule is why
    /// adding a control needs no migration and why removing `lock` did not
    /// scramble anybody's rail.
    private var arranged: [Control] {
        WidgetArrangement.arranged(Control.allCases.map(\.rawValue), stored: order)
            .compactMap(Control.init(rawValue:))
    }

    /// What the rail draws.
    var shown: [Control] { arranged.filter { !off.contains($0.rawValue) } }
    /// What arrange mode offers to put back.
    var hidden: [Control] { arranged.filter { off.contains($0.rawValue) } }

    func setShown(_ control: Control, _ isShown: Bool) {
        if isShown { off.remove(control.rawValue) } else { off.insert(control.rawValue) }
        UserDefaults.standard.set(Array(off), forKey: "systemControls.off")
    }

    /// Move `control` into `other`'s slot. Dropping ON a chip means "go where
    /// this one is", which is the whole gesture in one move — the same rule the
    /// block rows use.
    func move(_ control: Control, before other: Control) {
        guard control != other else { return }
        var ids = arranged.map(\.rawValue)
        guard let from = ids.firstIndex(of: control.rawValue) else { return }
        ids.remove(at: from)
        guard let to = ids.firstIndex(of: other.rawValue) else { return }
        ids.insert(control.rawValue, at: to)
        order = ids
        UserDefaults.standard.set(ids, forKey: "systemControls.order")
    }

    /// One rail button. Ordered as drawn.
    enum Control: String, CaseIterable, Identifiable {
        case wifi, awake, dark, capture, record, sleepDisplay

        var id: String { rawValue }

        /// The label under the button — lowercase, as drawn.
        var label: String {
            switch self {
            case .wifi: return "wifi"
            case .awake: return "awake"
            case .dark: return "dark"
            case .capture: return "capture"
            case .record: return "record"
            case .sleepDisplay: return "sleep"
            }
        }

        /// The Home rail's caption, in sentence case. `label` stays the
        /// lowercase monospaced chip arrange mode draws.
        var title: String {
            switch self {
            case .wifi: return "Wi-Fi"
            case .awake: return "Awake"
            case .dark: return "Dark"
            case .capture: return "Screenshot"
            case .record: return "Record"
            case .sleepDisplay: return "Sleep"
            }
        }

        var symbol: String {
            switch self {
            case .wifi: return "wifi"
            case .awake: return "cup.and.saucer.fill"
            case .dark: return "circle.lefthalf.filled"
            case .capture: return "camera.viewfinder"
            case .record: return "record.circle"
            case .sleepDisplay: return "moon.zzz.fill"
            }
        }

        /// Whether the button holds a state, or just does something.
        ///
        /// Four of the seven fire and leave nothing to be "on" afterwards, so
        /// they never light and never open a strip. Drawing one lit would
        /// promise a mode it does not have.
        var isMomentary: Bool {
            switch self {
            case .capture, .record, .sleepDisplay: return true
            case .wifi, .awake, .dark: return false
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .wifi: return "Wi-Fi"
            case .awake: return "Keep this Mac awake"
            case .dark: return "Dark appearance"
            case .capture: return "Take a screenshot"
            case .record: return "Record the screen"
            case .sleepDisplay: return "Put the display to sleep"
            }
        }
    }

    private(set) var isWiFiOn = false
    /// Where the route actually goes — see `NetworkStatus`.
    ///
    /// Separate from `isWiFiOn` on purpose: the radio's power state and whether
    /// anything is reachable through it are different facts, and conflating them
    /// is what let the strip say "Wi-Fi is on" while nothing worked.
    private(set) var network = NetworkStatus.unknown
    /// Whether the monitor has delivered a path yet. The first one lands a beat
    /// after launch, and reporting an outage for that beat every time is worse
    /// than saying "checking".
    private(set) var hasResolvedNetwork = false
    private(set) var isAwake = false
    /// Held awake because an agent is working, apart from the switch. The
    /// island's cup shows for either; the rail's button stays the switch's.
    private(set) var isHeldForAgents = false
    private(set) var isDark = false

    /// Why the last press did nothing, or nil.
    ///
    /// **A toggle that fails silently is the worst control on the panel** — it
    /// looks broken and gives you nothing to act on. Wi-Fi refuses when the Mac
    /// has no interface or the user is denied control of the radio, and the
    /// appearance script refuses until Automation has been allowed. Both were
    /// swallowed by a `try?`.
    private(set) var failure: Problem?

    /// Which control has its strip open, or nil.
    ///
    /// One at a time and inside the same card — the disclosure contract: the row
    /// above never moves, it costs no window, and the panel can still collapse
    /// on its own timer. An `NSMenu` here would take the run loop and strand a
    /// half-open panel.
    var openStrip: Control?

    // MARK: Keep-awake options (Settings, beside the switch)

    /// On battery, keep-awake lets go below this percentage. Zero never stops,
    /// which is what keep-awake did before there was a choice.
    var keepAwakeCutoff: Int = Defaults.int("keepAwake.batteryCutoff", default: 0) {
        didSet {
            guard keepAwakeCutoff != oldValue else { return }
            Defaults.set(keepAwakeCutoff, "keepAwake.batteryCutoff")
            watchBattery()
            reconcileAgentHold()
        }
    }

    /// Keep the Mac awake while a Claude Code or Codex session is working
    /// (card Awake 1). On by default, plugged in only — see `agentsWorking`.
    var awakeWhileAgentsWork: Bool = Defaults.bool("keepAwake.whileAgentsWork", default: true) {
        didSet {
            guard awakeWhileAgentsWork != oldValue else { return }
            Defaults.set(awakeWhileAgentsWork, "keepAwake.whileAgentsWork")
            reconcileAgentHold()
        }
    }

    /// The same on battery. Off by default: a hold nobody pressed for should
    /// not cost battery unless somebody asked it to.
    var awakeWhileAgentsWorkOnBattery: Bool = Defaults.bool("keepAwake.whileAgentsWork.onBattery",
                                                            default: false) {
        didSet {
            guard awakeWhileAgentsWorkOnBattery != oldValue else { return }
            Defaults.set(awakeWhileAgentsWorkOnBattery, "keepAwake.whileAgentsWork.onBattery")
            reconcileAgentHold()
        }
    }

    /// Hold the Mac awake but let the display turn off on its own timer —
    /// downloads, renders and agents keep going in the dark.
    var letsScreenSleep: Bool = Defaults.bool("keepAwake.letScreenSleep", default: false) {
        didSet {
            guard letsScreenSleep != oldValue else { return }
            Defaults.set(letsScreenSleep, "keepAwake.letScreenSleep")
            // Takes effect now rather than at the next press: the switch says
            // what is held, so a held assertion of the other kind is swapped.
            if wakeAssertion != nil {
                releaseAwake()
                holdAwake()
                refresh()
                // The new hold can be refused; then nothing is held and the
                // battery has nothing to watch for.
                watchBattery()
            }
        }
    }

    var hotkeyEnabled: Bool = Defaults.bool("keepAwake.hotkeyEnabled", default: false) {
        didSet {
            guard hotkeyEnabled != oldValue else { return }
            Defaults.set(hotkeyEnabled, "keepAwake.hotkeyEnabled")
            applyHotkey()
        }
    }

    var hotkey: GlobalHotkey.Binding = Defaults.binding("keepAwake.hotkey",
                                                        default: .controlOptionCommandW) {
        didSet {
            guard hotkey != oldValue else { return }
            Defaults.setBinding(hotkey, "keepAwake.hotkey")
            applyHotkey()
        }
    }

    /// Why the shortcut is not registered, for Settings — see `GlobalHotkey.lastError`.
    private(set) var hotkeyError: String?

    /// When the cutoff last ended keep-awake, for the island's notice. Cleared
    /// by the next press, so a hand on the switch is never reported as the
    /// battery's doing.
    private(set) var stoppedByCutoffAt: Date?
    /// The cutoff that did it, which may have been changed since.
    private(set) var stoppedCutoff = 0
    /// When the panel first showed the cutoff's line — see
    /// `KeepAwakePolicy.keepsStoppedNotice`.
    @ObservationIgnored private var stoppedNoticeSeenAt: Date?

    /// Raised when the cutoff lets go, so the controller can bring the island
    /// up to say so — a stop is not something the island's own events would
    /// notice in time.
    @ObservationIgnored var onAwakeStoppedByCutoff: (() -> Void)?

    /// Held while `isAwake`. Releasing it is the only way to end the assertion,
    /// so it is the state as well as the effect.
    @ObservationIgnored private var wakeAssertion: IOPMAssertionID?
    @ObservationIgnored private var batteryWatch: Task<Void, Never>?
    /// The agents' own assertion, never the switch's: pressing the switch off
    /// must not drop a hold an agent still needs, and an agent finishing must
    /// not turn off a switch somebody pressed.
    @ObservationIgnored private var agentAssertion: IOPMAssertionID?
    @ObservationIgnored private var agentsAreWorking = false
    @ObservationIgnored private var agentsLastWorkedAt: Date?
    @ObservationIgnored private var agentWatch: Task<Void, Never>?
    @ObservationIgnored private let hotkeyRegistration = GlobalHotkey()
    /// Push, not poll. `NWPathMonitor` calls back on a route change, so there is
    /// no timer here and nothing to keep alive while the panel is shut.
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    deinit { pathMonitor?.cancel() }

    func start() {
        refresh()
        startWatchingPath()
        applyHotkey()
    }

    /// One monitor for the app's lifetime.
    ///
    /// Its queue is NOT the main one — `NWPathMonitor` documents a queue of its
    /// own — so the hop back is explicit. `NetworkStatus` is a value type, which
    /// is what makes that hop a single assignment rather than a lock.
    private func startWatchingPath() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let link = Self.link(of: path)
            let satisfied = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                guard let self else { return }
                self.hasResolvedNetwork = true
                self.network = NetworkStatus(link: link,
                                             isSatisfied: satisfied,
                                             isExpensive: expensive,
                                             isConstrained: constrained,
                                             signal: link == .wifi ? Self.signal() : nil)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.airlock.network-path"))
        pathMonitor = monitor
    }

    /// The interface carrying the route, narrowed to what the strip can say.
    ///
    /// Order matters: a Mac on Ethernet with the radio still on reports BOTH
    /// available, and the wired one is the one carrying traffic.
    /// RSSI, and deliberately NOT the SSID.
    ///
    /// Checked on a real machine: with Location undetermined, `ssid()` returns
    /// nil while `rssiValue()` answers — so signal quality is free and the
    /// network's name would cost a Location prompt for a string. Not a trade
    /// worth making for a strip.
    private static func signal() -> NetworkStatus.Signal? {
        guard let rssi = CWWiFiClient.shared().interface()?.rssiValue(), rssi != 0 else {
            return nil
        }
        return NetworkStatus.Signal(rssi: rssi)
    }

    /// `nonisolated` because it runs on the monitor's queue, before the hop to
    /// the main actor. It touches nothing but its argument, which is what makes
    /// that safe rather than merely quiet.
    private nonisolated static func link(of path: NWPath) -> NetworkStatus.Link {
        guard path.status == .satisfied else { return .none }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        return .other
    }

    func refresh() {
        isWiFiOn = CWWiFiClient.shared().interface()?.powerOn() ?? false
        isAwake = wakeAssertion != nil
        isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The panel is showing the rail. The battery cutoff's line is the one
    /// failure nobody's press caused, so it is the one that has to know when
    /// it has been read rather than wait for a press that may never come.
    func railShown(now: Date = Date()) {
        guard stoppedByCutoffAt != nil,
              failure?.sentence == KeepAwakePolicy.stoppedMessage(cutoff: stoppedCutoff) else { return }
        if KeepAwakePolicy.keepsStoppedNotice(firstSeenAt: stoppedNoticeSeenAt, now: now) {
            if stoppedNoticeSeenAt == nil { stoppedNoticeSeenAt = now }
        } else {
            failure = nil
        }
    }

    func isOn(_ control: Control) -> Bool {
        switch control {
        case .wifi: return isWiFiOn
        case .awake: return isAwake
        case .dark: return isDark
        case .capture, .record, .sleepDisplay: return false
        }
    }

    /// A button press. Momentary controls act; the rest toggle.
    ///
    /// The press is written down before anything is attempted, so a control
    /// that returns without acting still leaves a record that it was pressed —
    /// see `ControlDiagnostics`.
    func activate(_ control: Control) {
        ControlDiagnostics.log(
            control, control.isMomentary ? "pressed" : "pressed · reads \(isOn(control) ? "on" : "off")")
        switch control {
        case .wifi: toggleWiFi()
        case .awake: toggleAwake()
        case .dark: toggleAppearance()
        case .capture: capture()
        case .record: record()
        case .sleepDisplay: sleepDisplay()
        }
    }

    // MARK: - Wi-Fi

    /// `setPower` throws when the Mac has no Wi-Fi interface or the user has
    /// been denied control of it. Reported by re-reading rather than by an
    /// alert: the button's own state going back is the honest answer, and an
    /// alert over a radio toggle is more interruption than the action was.
    private func toggleWiFi() {
        failure = nil
        guard let interface = CWWiFiClient.shared().interface() else {
            failure = Problem(sentence: Self.noWiFi)
            ControlDiagnostics.log(.wifi, "no Wi-Fi interface — nothing attempted")
            return
        }
        let wanted = !interface.powerOn()
        let name = interface.interfaceName ?? "an unnamed interface"
        var outcome = "ok"
        do {
            try interface.setPower(wanted)
        } catch {
            let refusal = error as NSError
            failure = Problem(sentence: Self.wifiRefused)
            outcome = "refused: \(error.localizedDescription) (\(refusal.domain) \(refusal.code))"
        }
        refresh()
        // The read-back is the interesting half: `setPower` can return without
        // throwing and without the radio moving, which is a press that did
        // nothing with nothing to show for it.
        ControlDiagnostics.log(
            .wifi, "setPower(\(wanted)) on \(name) → \(outcome); radio reads \(isWiFiOn ? "on" : "off")")
    }

    // MARK: - Stay awake

    /// `IOPMAssertionCreateWithName`, held for as long as the button is lit.
    ///
    /// `PreventUserIdleDisplaySleep` by default: the point is usually a screen
    /// that stays readable, and that assertion keeps the Mac up as well.
    /// `letsScreenSleep` swaps it for `PreventUserIdleSystemSleep`, which
    /// keeps the Mac working while the display goes dark on its own timer —
    /// the island's cup still says it is held when the screen comes back.
    private func toggleAwake() {
        failure = nil
        stoppedByCutoffAt = nil
        if wakeAssertion != nil {
            releaseAwake()
            Moments.shared.announce(.keepAwakeStopped, "turned off")
        } else {
            let battery = Self.batteryReading()
            if let refusal = KeepAwakePolicy.refusal(cutoff: keepAwakeCutoff,
                                                     percentage: battery.percentage,
                                                     onBattery: battery.onBattery) {
                failure = Problem(sentence: refusal)
                ControlDiagnostics.log(.awake, "not held: battery \(battery.percentage ?? -1)% "
                    + "on battery, below the \(keepAwakeCutoff)% cutoff")
            } else {
                holdAwake()
                if wakeAssertion != nil { Moments.shared.announce(.keepAwakeOn) }
            }
        }
        refresh()
        watchBattery()
    }

    private func holdAwake() {
        let type = letsScreenSleep ? kIOPMAssertionTypePreventUserIdleSystemSleep
                                   : kIOPMAssertionTypePreventUserIdleDisplaySleep
        let name = letsScreenSleep ? "PreventUserIdleSystemSleep" : "PreventUserIdleDisplaySleep"
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Airlock — keep awake" as CFString,
            &assertion)
        wakeAssertion = result == kIOReturnSuccess ? assertion : nil
        // A refusal here is the quietest failure on the rail: nothing is
        // held, no message is set, and the button simply does not light.
        ControlDiagnostics.log(
            .awake, "IOPMAssertionCreateWithName(\(name)) → "
            + "\(ControlDiagnostics.describe(ioReturn: result))"
            + (result == kIOReturnSuccess ? ", holding \(assertion)" : ", nothing held"))
    }

    private func releaseAwake() {
        guard let assertion = wakeAssertion else { return }
        let result = IOPMAssertionRelease(assertion)
        wakeAssertion = nil
        ControlDiagnostics.log(
            .awake, "IOPMAssertionRelease(\(assertion)) → \(ControlDiagnostics.describe(ioReturn: result))")
    }

    /// Reads the battery every thirty seconds while keep-awake is held with a
    /// cutoff set, and only then. A percentage moves about a point every few
    /// minutes on battery, so a half-minute read cannot miss the line by more
    /// than a point, and nothing runs at all with the cutoff off.
    private func watchBattery() {
        batteryWatch?.cancel()
        batteryWatch = nil
        guard wakeAssertion != nil, keepAwakeCutoff > 0 else { return }
        batteryWatch = Task { [weak self] in
            while !Task.isCancelled {
                // Ends with the hold, however it ended: `checkCutoff` alone
                // answered false forever once nothing was held.
                guard let self, self.wakeAssertion != nil else { return }
                if self.checkCutoff() { return }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Lets go if the battery is below the cutoff. True when it did.
    private func checkCutoff() -> Bool {
        let battery = Self.batteryReading()
        guard wakeAssertion != nil,
              KeepAwakePolicy.shouldStop(cutoff: keepAwakeCutoff,
                                         percentage: battery.percentage,
                                         onBattery: battery.onBattery) else { return false }
        ControlDiagnostics.log(.awake, "battery \(battery.percentage ?? -1)% on battery, "
            + "below the \(keepAwakeCutoff)% cutoff — letting go")
        releaseAwake()
        refresh()
        failure = Problem(sentence: KeepAwakePolicy.stoppedMessage(cutoff: keepAwakeCutoff))
        stoppedCutoff = keepAwakeCutoff
        stoppedByCutoffAt = Date()
        stoppedNoticeSeenAt = nil
        Moments.shared.announce(.keepAwakeStopped, "battery cutoff")
        onAwakeStoppedByCutoff?()
        return true
    }

    // MARK: - While an agent works (card Awake 1)

    /// Whether any agent session is running now. Called on every island pass,
    /// so it does nothing unless the answer changed.
    func agentsWorking(_ working: Bool) {
        guard working != agentsAreWorking else { return }
        agentsAreWorking = working
        if !working { agentsLastWorkedAt = Date() }
        reconcileAgentHold()
    }

    /// Holds or lets go to match `KeepAwakePolicy.holdsForAgents`, and keeps a
    /// half-minute check running for as long as there is anything left to
    /// decide later: the linger running out, or the power cable coming out.
    private func reconcileAgentHold() {
        let busy = KeepAwakePolicy.agentsBusy(working: agentsAreWorking,
                                              lastWorkedAt: agentsLastWorkedAt, now: Date())
        var wanted = false
        if awakeWhileAgentsWork, busy {
            let battery = Self.batteryReading()
            wanted = KeepAwakePolicy.holdsForAgents(
                enabled: true, onBatteryToo: awakeWhileAgentsWorkOnBattery, busy: true,
                cutoff: keepAwakeCutoff, percentage: battery.percentage, onBattery: battery.onBattery)
        }
        if wanted, agentAssertion == nil { holdForAgents() }
        if !wanted, agentAssertion != nil { releaseForAgents() }
        isHeldForAgents = agentAssertion != nil

        if awakeWhileAgentsWork, busy {
            guard agentWatch == nil else { return }
            // One sleep, then a fresh pass that arms the next one if it is
            // still needed — so the check can never outlive its reason.
            agentWatch = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                self.agentWatch = nil
                self.reconcileAgentHold()
            }
        } else {
            agentWatch?.cancel()
            agentWatch = nil
        }
    }

    /// Always the kind that lets the screen sleep: agents need the Mac, not
    /// the display. Closing the lid still sleeps it — an idle assertion
    /// never holds a shut laptop up.
    private func holdForAgents() {
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Airlock — an agent is working" as CFString,
            &assertion)
        agentAssertion = result == kIOReturnSuccess ? assertion : nil
        ControlDiagnostics.log(
            .awake, "agent working: IOPMAssertionCreateWithName(PreventUserIdleSystemSleep) → "
            + "\(ControlDiagnostics.describe(ioReturn: result))"
            + (result == kIOReturnSuccess ? ", holding \(assertion)" : ", nothing held"))
    }

    private func releaseForAgents() {
        guard let assertion = agentAssertion else { return }
        let result = IOPMAssertionRelease(assertion)
        agentAssertion = nil
        ControlDiagnostics.log(
            .awake, "agents done: IOPMAssertionRelease(\(assertion)) → "
            + "\(ControlDiagnostics.describe(ioReturn: result))")
    }

    /// The internal battery, as the cutoff needs it: a percentage, and whether
    /// the Mac is running from it. Nil percentage on a Mac with no battery.
    private static func batteryReading() -> (percentage: Int?, onBattery: Bool) {
        guard
            let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
            let first = sources.first,
            let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any]
        else { return (nil, false) }
        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let percentage = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
        let onBattery = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
        return (percentage, onBattery)
    }

    /// The shortcut presses the rail's button, so the log, the refusal and
    /// the island all behave exactly as a click would.
    private func applyHotkey() {
        hotkeyRegistration.unregister()
        hotkeyError = nil
        guard hotkeyEnabled else { return }
        hotkeyRegistration.register(hotkey) { [weak self] in self?.activate(.awake) }
        hotkeyError = hotkeyRegistration.lastError
    }

    // MARK: - Appearance

    /// System Events, which needs Automation permission — the same grant the
    /// media controls already ask for, and the first refusal is explained in
    /// Settings rather than swallowed here.
    ///
    /// **The script says whether it ran; the appearance does not, not yet.**
    /// This used to confirm the press by re-reading `NSApp.effectiveAppearance`
    /// on the grounds that a refused prompt leaves the appearance untouched —
    /// true, but so does a granted one for a run loop or two after the system
    /// setting flips. The read-back therefore saw the OLD value on a press that
    /// had just worked and blamed Automation for it; the NEXT press came back
    /// clean, because by then AppKit had caught up. Warning first, working
    /// second, every other press — which is exactly how it was reported.
    ///
    /// `perform` reports the refusal itself, so there is nothing to infer.
    private func toggleAppearance() {
        failure = nil
        let wanted = !isDark
        Task { [weak self] in
            let outcome = await AppleScriptClient.perform(
                "tell application \"System Events\" to tell appearance preferences "
                + "to set dark mode to \(wanted)")
            // Before the model is consulted: an answer that arrives as the app
            // is going away is still an answer worth having written down.
            ControlDiagnostics.log(
                .dark, "System Events: set dark mode to \(wanted) → "
                + ControlDiagnostics.describe(appleScript: outcome))
            guard let self else { return }
            switch outcome {
            case .ok:
                // The event was delivered and System Events acted on it, so the
                // appearance IS `wanted` — whatever AppKit still thinks.
                isDark = wanted
            case .failed:
                failure = outcome.isNotPermitted
                    ? Problem(sentence: Self.appearanceRefused, pane: .automation)
                    : Problem(sentence: Self.appearanceFailed)
            }
        }
    }

    // MARK: - Capture, record, and the two that end the session

    /// The system screenshot tool, with its own UI — never a silent grab.
    ///
    /// An app that captures the screen without showing you it is doing so is
    /// the exact shape of the thing people fear from a background app, and
    /// Airlock promises to look at the screen only when asked.
    ///
    /// **This shipped broken twice over.** The binary is in `/usr/sbin`, not
    /// `/usr/bin`, so the process never launched — and `screencapture` requires
    /// a destination file, so it would have done nothing even if it had. A
    /// `try?` hid both, which is why the button looked dead rather than wrong.
    ///
    /// **No `-U`, deliberately.** That flag shows the interactive toolbar — the
    /// ⇧⌘5 panel — which already contains both recording options, so this button
    /// was opening a menu that contained the next button along. Two rail buttons
    /// where one is a menu containing the other is one button too many and a
    /// question mark over both. Crosshair region straight to a file instead,
    /// which is ⇧⌘4 and is one press.
    private func capture() {
        run(.capture, Self.screencapture, ["-i", desktopFile(name: "Screenshot", ext: "png")],
            failure: Self.screenshotDidNotStart,
            needsScreenRecording: Self.screenshotNeedsPermission)
    }

    /// A screen recording, to the Desktop.
    ///
    /// The whole screen, starting now — the counterpart to `capture`'s one press
    /// rather than a second route into the same toolbar. Between them the rail
    /// offers the two things people actually want from a notch: grab that, and
    /// record this. Choosing a region for a recording is what ⇧⌘5 is for, and
    /// this does not try to be ⇧⌘5.
    ///
    /// `screencapture -v` records until it is stopped, and the thing that stops
    /// it is the system's own control in the menu bar — which is right: a
    /// recording the notch could start but only the notch could stop is a
    /// recording you lose when the panel collapses.
    ///
    /// Needs Screen Recording permission, and macOS asks the first time. That
    /// prompt is this app's own rule working as intended — nothing is requested
    /// on launch, and this one arrives the first time you press the button that
    /// needs it.
    private func record() {
        run(.record, Self.screencapture, ["-v", desktopFile(name: "Recording", ext: "mov")],
            failure: Self.recorderDidNotStart,
            needsScreenRecording: Self.recordingNeedsPermission)
    }

    /// `~/Desktop/Screenshot 2026-08-18 at 16.42.10.png` — near enough to what
    /// ⇧⌘4 produces that the two land in the same place under the same name.
    private func desktopFile(name: String, ext: String) -> String {
        let stamp = Self.fileStamp.string(from: Date())
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return desktop.appendingPathComponent("\(name) \(stamp).\(ext)").path
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    /// `/usr/sbin`, and it matters — see `capture`.
    private static let screencapture = "/usr/sbin/screencapture"

    /// Launch a system tool, and write down which one, with what, and how it
    /// ended.
    ///
    /// **The exit status is the half nobody had.** A launch that succeeds is
    /// all this used to check, so a tool that started and then refused — no
    /// Screen Recording permission, a capture cancelled, `pmset` turned away —
    /// looked exactly like one that worked. The `failure` message is unchanged:
    /// it still only speaks for a tool that would not start, because by the
    /// time an exit status arrives the press is over and a line appearing under
    /// the rail a second later belongs to nothing the user can see.
    ///
    /// The arguments are recorded, except the destination file, which is the
    /// user's own — its kind and folder go in instead. See `ControlDiagnostics`.
    ///
    /// `needsScreenRecording` is what to say when the permission is missing.
    /// The old message blamed the permission for a tool that would not LAUNCH,
    /// which is never the permission's doing, and said nothing at all when the
    /// permission was the real cause. The tool still runs either way: the first
    /// press is the one macOS asks on, and stopping it would take that away.
    /// Screen Recording applies only after Airlock reopens, so this preflight
    /// is not stale in the way a freshly granted switch might suggest — until
    /// then the capture really is without it.
    private func run(_ control: Control, _ executable: String, _ arguments: [String], failure message: String,
                     needsScreenRecording: String? = nil) {
        self.failure = nil
        let tool = (executable as NSString).lastPathComponent
        let spoken = arguments
            .map { $0.hasPrefix("/") ? ControlDiagnostics.destination($0) : $0 }
            .joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.terminationHandler = { finished in
            // Read here, on the thread that was handed the process: it is not
            // Sendable and has no business crossing to the main actor.
            let status = finished.terminationStatus
            let signalled = finished.terminationReason == .uncaughtSignal
            Task { @MainActor in
                ControlDiagnostics.log(
                    control, "\(tool) \(ControlDiagnostics.describe(exitStatus: status, wasSignalled: signalled))")
            }
        }
        do {
            try process.run()
            ControlDiagnostics.log(control, "launched \(executable) \(spoken) → pid \(process.processIdentifier)")
            if let needsScreenRecording, !CGPreflightScreenCaptureAccess() {
                self.failure = Problem(sentence: needsScreenRecording, pane: .permission(.screenRecording))
                ControlDiagnostics.log(control, "Screen Recording not allowed — said so under the rail")
            }
        } catch {
            self.failure = Problem(sentence: message)
            ControlDiagnostics.log(control, "could not launch \(executable) — \(error.localizedDescription)")
        }
    }

    /// Display off, machine awake — the opposite end of the question the
    /// "awake" toggle answers, which is why the two sit on one rail.
    private func sleepDisplay() {
        run(.sleepDisplay, "/usr/bin/pmset", ["displaysleepnow"],
            failure: Self.displaySleepDidNotStart)
    }
}

