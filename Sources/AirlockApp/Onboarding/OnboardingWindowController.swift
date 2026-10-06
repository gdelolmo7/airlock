import AppKit
import SwiftUI

/// Owns the (single) first-run window.
///
/// Mirrors `SettingsWindowController` deliberately — same activation dance, same
/// reuse-one-window rule. It differs in two ways that matter: closing the window
/// counts as finishing (a wizard you dismissed is a wizard you are done with),
/// and there is no autosaved frame, because this should be centred every time
/// the small number of times it appears.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let model: OnboardingModel
    private var window: NSWindow?
    /// An async sequence rather than a block observer, matching
    /// `NotchDropCatcher`: `Task` is Sendable and cancellable from `deinit`, and
    /// mapping to the name keeps a non-Sendable `Notification` off the boundary.
    private var screenTask: Task<Void, Never>?

    deinit { screenTask?.cancel() }

    init(model: OnboardingModel) {
        self.model = model
        super.init()
    }

    func show() {
        // Claimed on every show, not once in `init`.
        //
        // The model is shared with the in-panel wizard, which points `onClose`
        // at `NotchController.endOnboarding` while it is running. Binding this
        // only at construction meant whichever surface ran *first* kept the
        // teardown forever — so after one in-panel first run, Done in this
        // window called the panel's teardown and left the window on screen.
        // Whoever presented last owns it.
        model.onClose = { [weak self] in self?.window?.close() }
        model.settings.refresh()
        let firstShow = window == nil
        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView().environment(model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Set up Airlock"
            // No miniaturise and no resize: it is a fixed-size sheet in spirit,
            // and a minimised first-run window is a first-run window nobody
            // finishes.
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            // Lay out before centring — centring works off the current frame,
            // which at construction is not yet the size the content asks for.
            hosting.view.layoutSubtreeIfNeeded()
            window.setContentSize(hosting.view.fittingSize)
            self.window = window
        }
        // Re-centred on every fresh appearance, not just at construction. Placing
        // it once is not enough: this window is built during
        // `applicationDidFinishLaunching`, and the display arrangement is not
        // reliably settled at that instant — measured once at x = -1069, off the
        // side of both displays, while the notch panel that reads the same
        // geometry a moment later landed correctly.
        if firstShow || window?.isVisible == false {
            window?.centerOnNotchScreen()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        watchScreenChanges()
    }

    /// The panel and the drop catcher both rebuild themselves on display
    /// changes; without this, a window created mid-reconfiguration is the one
    /// thing left stranded where it landed.
    private func watchScreenChanges() {
        guard screenTask == nil else { return }
        screenTask = Task { [weak self] in
            let changes = NotificationCenter.default
                .notifications(named: NSApplication.didChangeScreenParametersNotification)
                .map(\.name)
            for await _ in changes {
                guard let self, self.window?.isVisible == true else { continue }
                self.window?.centerOnNotchScreen()
            }
        }
    }

    /// Reopened from the menu bar. Rewinds to the first step so it is a guide
    /// rather than a stale end-screen.
    func showFromStart() {
        model.restart()
        show()
    }

    /// Closing by any route — the red button, ⌘W, Done — settles the flag. The
    /// alternative is an app that greets you with setup every single launch
    /// until you happen to press the right button.
    func windowWillClose(_ notification: Notification) {
        OnboardingModel.hasCompletedSetup = true
    }
}
