import AppKit
import SwiftUI

/// Owns the everyday first-run window, "Welcome to Airlock" (designs 9a, 9d).
///
/// Shaped like `OnboardingWindowController` — one reused window, centred on the
/// notch screen every time it reappears, closing counts as finishing — with one
/// addition: it HIDES rather than closes while the practice runs, so the walk
/// can come back to the question without that counting as a close.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let model: WelcomeModel
    private var window: NSWindow?
    /// Set while the model itself closes the window, so `windowWillClose`
    /// can tell Done from the red button.
    private var closingOnPurpose = false

    init(model: WelcomeModel) {
        self.model = model
        super.init()
        model.onHide = { [weak self] in self?.window?.orderOut(nil) }
        model.onShow = { [weak self] in self?.show() }
        model.onClose = { [weak self] in
            self?.closingOnPurpose = true
            self?.window?.close()
            self?.closingOnPurpose = false
        }
    }

    func show() {
        let firstShow = window == nil
        if window == nil {
            let hosting = NSHostingController(rootView: WelcomeView().environment(model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to Airlock"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            hosting.view.layoutSubtreeIfNeeded()
            window.setContentSize(hosting.view.fittingSize)
            self.window = window
        }
        if firstShow || window?.isVisible == false {
            window?.centerOnNotchScreen()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard !closingOnPurpose else { return }
        model.closedByUser()
    }
}
