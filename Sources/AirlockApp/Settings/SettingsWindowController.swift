import AppKit
import SwiftUI
import AirlockCore

/// Owns the (single) settings window. The app is an accessory-policy agent, so
/// showing settings explicitly activates us; closing hands focus back.
@MainActor
final class SettingsWindowController {
    /// Injected rather than owned: onboarding drives the same hook installs, and
    /// two `SettingsModel`s would mean the settings window still reading "Not
    /// installed" after the first-run window just installed them.
    private let model: SettingsModel
    private let media: MediaWidgetModel
    private let sound: SoundWidgetModel
    private let appVolume: AppVolumeModel
    private let calendar: CalendarWidgetModel
    private let battery: BatteryWidgetModel
    private let system: SystemStatsWidgetModel
    private let tray: TrayModel
    private let clipboard: ClipboardWidgetModel
    private let dictation: DictationModel
    private let appearance: NotchAppearanceModel
    private let assistant: AssistantModel
    private let agents: AgentsWidgetModel
    private let repository: RepositoryWidgetModel
    private let license: LicenseModel
    private let updater: UpdaterModel
    private let usage: UsageConnectionModel
    private let controls: SystemControlsModel
    private let usageAlerts: UsageAlertModel
    private var window: NSWindow?
    /// The notch's live picture for The notch page; set once the notch exists.
    var islandPreview: (@MainActor () -> AnyView)?
    private var focusObserver: (any NSObjectProtocol)?

    init(model: SettingsModel, media: MediaWidgetModel,
         sound: SoundWidgetModel, appVolume: AppVolumeModel,
         calendar: CalendarWidgetModel, assistant: AssistantModel,
         battery: BatteryWidgetModel, system: SystemStatsWidgetModel, tray: TrayModel,
         clipboard: ClipboardWidgetModel, dictation: DictationModel,
         appearance: NotchAppearanceModel, agents: AgentsWidgetModel,
         repository: RepositoryWidgetModel, license: LicenseModel,
         updater: UpdaterModel, usage: UsageConnectionModel,
         controls: SystemControlsModel, usageAlerts: UsageAlertModel) {
        self.model = model
        self.media = media
        self.sound = sound
        self.appVolume = appVolume
        self.calendar = calendar
        self.assistant = assistant
        self.battery = battery
        self.system = system
        self.tray = tray
        self.clipboard = clipboard
        self.dictation = dictation
        self.appearance = appearance
        self.agents = agents
        self.repository = repository
        self.license = license
        self.updater = updater
        self.usage = usage
        self.controls = controls
        self.usageAlerts = usageAlerts
    }

    /// `pane` opens the window onto a specific page — used by the permission
    /// notice, which is useless if it lands you on General.
    func show(pane: SettingsPane? = nil) {
        if let pane { model.pane = pane }
        present()
    }

    /// Opens Settings on the exact row, scrolled to and lit up — see
    /// `SettingsAnchor`.
    func show(anchor: SettingsAnchor) {
        model.reveal(anchor)
        present()
    }

    private func present() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView().environment(model).environment(media)
                    .environment(sound).environment(appVolume).environment(calendar)
                    .environment(battery).environment(system).environment(tray)
                    .environment(clipboard).environment(dictation).environment(assistant)
                    .environment(appearance).environment(agents).environment(repository)
                    .environment(license).environment(updater).environment(usage)
                    .environment(controls).environment(usageAlerts)
                    .environment(\.islandPreview, islandPreview)
                    .environment(\.problemCardLook, .settings))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Airlock"
            // Plain title bar on purpose. Finder's full-height sidebar needs
            // `.fullSizeContentView` with a transparent title bar, but SwiftUI's
            // NavigationSplitView then renders the sidebar as an inset floating
            // panel rather than filling the column — worse than the standard
            // chrome it was meant to improve on.
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            // Lay the SwiftUI content out BEFORE centring. `center()` works off
            // the current frame, and at construction that frame is whatever the
            // window started at rather than the 780×540 the content asks for —
            // so it centred the wrong rectangle and the window then grew from
            // that origin, landing off to one side.
            //
            // `center()` centred it on whichever screen AppKit built it on,
            // which with an external display attached was the monitor rather
            // than the laptop the notch is on.
            hosting.view.layoutSubtreeIfNeeded()
            window.setContentSize(hosting.view.fittingSize)
            window.centerOnNotchScreen()
            // After centring, so a first run centres and later runs reopen
            // wherever you last dragged it to.
            window.setFrameAutosaveName("agentic-notch.settings")
            // Re-read on every return to the window.
            //
            // The Rules pane offers "Open in Editor". Edit the file there, come
            // back, and the list was whatever it had been when the window
            // opened — with a live trash button beside rules that had already
            // moved. `refresh()` ran on `show()` only, and the window is kept
            // rather than rebuilt, so a second visit re-showed a stale list.
            focusObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak model] _ in
                MainActor.assumeIsolated { model?.refresh() }
            }
            self.window = window
        }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        let visible = window?.isVisible == true
        Log.app.debug("settings window shown (visible=\(visible, privacy: .public))")
    }
}
