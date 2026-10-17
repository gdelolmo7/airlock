import AppKit
import SwiftUI
import AirlockCore

/// Owns the Airlock window: the calls at the top of its left column, the
/// Settings pages under them (`AirlockWindowView`). Showing it makes Airlock
/// an ordinary app for as long as it is open (`DockPresenceController`) and
/// activates it; closing it hands focus back to the app you were in.
///
/// One window rather than two. Settings and the call notes were separate
/// windows, each with a column down the left, until the owner asked for
/// one Airlock window in the Dock (2026-10-16): every way in now opens this
/// one at the right place, and the Dock icon brings it back where it was.
@MainActor
final class AirlockWindowController {
    /// Injected rather than owned: onboarding drives the same hook installs, and
    /// two `SettingsModel`s would mean the window still reading "Not
    /// installed" after the first-run setup just installed them.
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
    /// The Calls page: the call notes model's, handed over at launch. Every
    /// way into a call (the island's "Show", "Call Notes…", a notification)
    /// goes through it and lands here.
    var calls: CallsPage? {
        didSet {
            calls?.open = { [weak self] in self?.showCalls() }
            calls?.isShowing = { [weak self] in self?.isShowingCalls ?? false }
        }
    }
    private var focusObserver: (any NSObjectProtocol)?
    /// Takes the cursor out of the search field on a click anywhere else.
    private var clickMonitor: Any?

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
        // Where the window was left on the last run, so the Dock icon opens
        // it there. Before anything can show it.
        model.restorePlace()
    }

    /// Settings, on `pane`, or with nil on the page that was open last:
    /// "Settings…" and the notch's gear. `pane` is used by the permission
    /// notice, which is useless if it lands you on General. Never the calls,
    /// even when they were showing: this is the way into Settings.
    func show(pane: SettingsPane? = nil) {
        if let pane { model.pane = pane } else { model.showsCalls = false }
        present()
    }

    /// Opens Settings on the exact row, scrolled to and lit up — see
    /// `SettingsAnchor`.
    func show(anchor: SettingsAnchor) {
        model.reveal(anchor)
        present()
    }

    /// The calls, on whichever one `calls` has just chosen.
    func showCalls() {
        model.showsCalls = true
        present()
    }

    /// Wherever the window was left: the Dock icon, or Airlock opened again
    /// from Finder or Spotlight, with no window up.
    func showWhereLeft() {
        present()
    }

    /// The calls are on screen now, so notes finished meanwhile should
    /// appear in them without a click.
    var isShowingCalls: Bool {
        window?.isVisible == true && model.showsCalls && MeetingNotesModel.isOn
    }

    private func present() {
        if window == nil {
            var root = AnyView(AirlockWindowView())
            if let library = calls?.library { root = AnyView(root.environment(library)) }
            let hosting = NSHostingController(
                rootView: root.environment(model).environment(media)
                    .environment(sound).environment(appVolume).environment(calendar)
                    .environment(battery).environment(system).environment(tray)
                    .environment(clipboard).environment(dictation).environment(assistant)
                    .environment(appearance).environment(agents).environment(repository)
                    .environment(license).environment(updater).environment(usage)
                    .environment(controls).environment(usageAlerts)
                    .environment(\.islandPreview, islandPreview)
                    .environment(\.problemCardLook, .notch))
            // The window may be made smaller than the content's ideal size,
            // down to the smallest the calls fit in (`AirlockWindowView`).
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Airlock"
            // The notch's look reaches the window's edges: the title
            // bar is see-through over the black ground, with no title drawn,
            // so the traffic lights sit on black above the pages. Dark aqua so
            // menus and sheets are dark too. Resizable, for a long call.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(SettingsLook.ground)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            // Lay the SwiftUI content out BEFORE centring. `center()` works off
            // the current frame, and at construction that frame is whatever the
            // window started at rather than the size it is about to be given —
            // so it centred the wrong rectangle and the window then grew from
            // that origin, landing off to one side.
            //
            // `center()` centred it on whichever screen AppKit built it on,
            // which with an external display attached was the monitor rather
            // than the laptop the notch is on.
            window.setContentSize(AirlockWindowView.firstSize)
            hosting.view.layoutSubtreeIfNeeded()
            window.centerOnNotchScreen()
            // After centring, so a first run centres and later runs reopen
            // wherever you last dragged it to, at the size you left it. A new
            // name: the Settings window's frame was a fixed 760 by 600.
            window.setFrameAutosaveName("airlock.window")
            // Re-read on every return to the window.
            //
            // The Rules pane offers "Open in editor". Edit the file there, come
            // back, and the list was whatever it had been when the window
            // opened — with a live trash button beside rules that had already
            // moved. `refresh()` ran on `show()` only, and the window is kept
            // rather than rebuilt, so a second visit re-showed a stale list.
            // The calls the same: back from a text editor with the notes
            // changed, they are read again.
            focusObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak model, weak library = calls?.library] _ in
                MainActor.assumeIsolated {
                    model?.refresh()
                    if model?.showsCalls == true { library?.reload(selecting: nil) }
                }
            }
            // A Mac text field keeps the cursor until another field takes it,
            // and a page has few fields to take it. Without this the search
            // box stayed lit with a blinking cursor after a click on a page.
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
                guard let window, event.window === window,
                      window.firstResponder is NSText else { return event }
                let hit = window.contentView?.hitTest(event.locationInWindow)
                if !(hit is NSText || hit is NSTextField) { window.makeFirstResponder(nil) }
                return event
            }
            self.window = window
        }
        model.refresh()
        // In the Dock and in ⌘Tab while it is open, and a stage of its own
        // under Stage Manager, rather than a window stuck over another app.
        if let window { DockPresenceController.shared.willShow(window) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Opens with nothing focused. AppKit hands a newly shown window's
        // cursor to its first text field, which put it in search every time
        // Settings opened; ⌘F is how you get there on purpose. Again on the
        // next turn, because SwiftUI settles its focus after the window is up.
        window?.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak window] in window?.makeFirstResponder(nil) }
        let visible = window?.isVisible == true
        let place = model.showsCalls ? "calls" : model.pane.rawValue
        Log.app.debug("airlock window shown (visible=\(visible, privacy: .public), place=\(place, privacy: .public))")
    }
}
