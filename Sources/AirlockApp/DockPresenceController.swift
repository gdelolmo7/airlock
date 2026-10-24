import AppKit
import AirlockCore

/// The AppKit half of `DockPresence`: Airlock is an ordinary app — Dock icon,
/// ⌘Tab, its menus in the menu bar, its own stage — while one of its full
/// windows is open or minimised, and only the notch once the last one closes.
///
/// The decisions are `DockPresence`'s; this only keeps the facts. A full
/// window is reported by its owner as it is shown (`willShow`), and from then
/// on its close, minimise and return are read off AppKit's notifications for
/// that one window. Kept from events rather than read off `isVisible`, because
/// the Dock's Hide takes every window off screen without closing any of them,
/// and the Dock icon has to stay for the click that brings them back.
///
/// Panels that float over other apps (the notch, the window beside a live
/// call, the drop catcher) are never reported, so they
/// never count; they set `canHide = false` instead, so hiding the app from its
/// Dock icon leaves them where they are.
@MainActor
final class DockPresenceController {
    static let shared = DockPresenceController()

    private struct Entry {
        weak var window: NSWindow?
        var state: DockPresence.WindowState
        var lastUsed: Int
        var observers: [any NSObjectProtocol]
    }

    /// Only windows that are on screen or minimised. A closed one is
    /// forgotten, observers and all: some owners make a new window for every
    /// showing, and a new window can land at a freed one's address.
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var uses = 0
    /// What was last applied. Starts where `App.swift` puts the app.
    private var policy: DockPresence.Policy = .accessory
    /// The app the person was last in, for when the last window closes.
    private var previousApp: NSRunningApplication?
    private var activationObserver: (any NSObjectProtocol)?
    private var unhideObserver: (any NSObjectProtocol)?
    private var settlePending = false

    private init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.noteActivated(app) }
        }
        // Back from the Dock's Hide, by a Dock click or ⌘Tab. The notch panel
        // stayed on screen through it and is the frontmost of Airlock's
        // windows, so without this it takes the keyboard (measured) and the
        // window the person came back for does not.
        unhideObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didUnhideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.bringForward() }
        }
    }

    /// Called by a full window's owner just before it activates the app and
    /// orders the window front, so the switch to an ordinary app happens
    /// first: activating an accessory app and switching it afterwards leaves
    /// the menu bar showing the previous app's menus.
    func willShow(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        if entries[key] == nil {
            entries[key] = Entry(window: window, state: .onScreen, lastUsed: 0, observers: observe(window))
        }
        entries[key]?.state = .onScreen
        touch(key)
        if policy == .accessory, let front = NSWorkspace.shared.frontmostApplication,
           !front.isAirlock, front.activationPolicy == .regular {
            previousApp = front
        }
        let old = policy
        let wasActive = NSApp.isActive
        let new = apply()
        guard new == .regular else { return }
        if DockPresence.redrawsMenuBar(from: old, to: new, wasActive: wasActive) {
            // Already active, so activating again would leave the previous
            // app's menus up. Asking the Dock to take over and taking it
            // straight back makes the window server hand the menu bar over
            // (measured; deactivating first does not). The Dock has no
            // window, so nothing on screen moves.
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?
                .activate(options: [])
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A full window taken off screen without being closed. `orderOut` posts
    /// no notification, so its owner says so.
    func didHide(_ window: NSWindow) {
        forget(ObjectIdentifier(window))
        settleSoon()
    }

    /// The Dock icon was clicked, or Airlock was opened again from Finder.
    /// Puts the window `DockPresence.reopenTarget` picks in front with the
    /// keyboard, unminimising it; false when there was none, so the click
    /// does what it always did.
    func reopen() -> Bool {
        bringForward()
    }

    @discardableResult
    private func bringForward() -> Bool {
        let tracked = entries.compactMap { key, entry in
            entry.window == nil ? nil
                : DockPresence.Tracked(id: key, state: entry.state, lastUsed: entry.lastUsed)
        }
        guard let key = DockPresence.reopenTarget(tracked), let window = entries[key]?.window else { return false }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
            Log.app.info("dock: brought back a minimised window")
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    // MARK: -

    private func observe(_ window: NSWindow) -> [any NSObjectProtocol] {
        let center = NotificationCenter.default
        let key = ObjectIdentifier(window)
        let closing = center.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forget(key)
                // On the next turn: during `willClose` the window is still on
                // screen, and the owner may be opening another one in the same
                // breath (Purchase's "I already have a key" opens Settings).
                self?.settleSoon()
            }
        }
        let minimised = center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window,
                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(key, .minimised) }
        }
        let restored = center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window,
                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(key, .onScreen) }
        }
        let used = center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.touch(key) }
        }
        return [closing, minimised, restored, used]
    }

    private func set(_ key: ObjectIdentifier, _ state: DockPresence.WindowState) {
        guard entries[key] != nil else { return }
        entries[key]?.state = state
        if state == .onScreen { touch(key) }
        apply()
    }

    private func touch(_ key: ObjectIdentifier) {
        guard entries[key] != nil else { return }
        uses += 1
        entries[key]?.lastUsed = uses
    }

    private func forget(_ key: ObjectIdentifier) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func settleSoon() {
        guard !settlePending else { return }
        settlePending = true
        DispatchQueue.main.async { [weak self] in
            self?.settlePending = false
            self?.apply()
        }
    }

    @discardableResult
    private func apply() -> DockPresence.Policy {
        // A window freed without closing would otherwise hold the Dock icon
        // up for good.
        for (key, entry) in entries where entry.window == nil { forget(key) }
        let next = DockPresence.policy(entries.values.map(\.state))
        guard next != policy else { return next }
        let old = policy
        let wasActive = NSApp.isActive
        policy = next
        let ok = NSApp.setActivationPolicy(next == .regular ? .regular : .accessory)
        Log.app.info("dock: \(next == .regular ? "in the Dock" : "notch only", privacy: .public)\(ok ? "" : " (refused)", privacy: .public)")
        if DockPresence.handsFocusBack(from: old, to: next, isActive: wasActive) {
            handFocusBack()
        }
        return next
    }

    /// Back to the app the person was in, so its window takes the keyboard
    /// and, under Stage Manager, its stage comes back to the middle. Asked
    /// for rather than left to the system: an app that stops being ordinary
    /// stays the active app, with nothing on screen to type into.
    private func handFocusBack() {
        guard let app = previousApp, !app.isTerminated else { return }
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }

    /// Only ordinary apps: the Dock is activated for a moment whenever the
    /// menu bar has to be handed over (`willShow`), and closing the last
    /// window must not send the person to the Dock (measured, it did).
    private func noteActivated(_ app: NSRunningApplication?) {
        guard let app, !app.isAirlock, app.activationPolicy == .regular else { return }
        previousApp = app
    }
}
