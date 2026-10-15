import AppKit
import SwiftUI
import AirlockCore

/// Owns the (single) purchase window.
///
/// **Its own window rather than a pane in Settings.** Buying is a task with a
/// beginning and an end, reached from a gate in the notch, and burying it in a
/// sidebar puts a settings tree between somebody and the thing they decided to
/// do. It is also the one screen that has to stay open while attention is
/// somewhere else entirely — in a browser — which is a window's job.
///
/// **Closing it cancels nothing.** The window is a view onto `PurchaseFlow`, not
/// the flow itself: shut it mid-payment and the app goes on listening for
/// `airlock://activate`, exactly as the waiting screen promises. That promise is
/// only keepable because the state lives on the model and this controller is
/// disposable.
@MainActor
final class PurchaseWindowController {
    private let flow: PurchaseFlow
    private let license: LicenseModel
    /// Read each time the window opens, never kept. Its content was built once,
    /// on the first open, so a later open quoted that day's counts and handed
    /// back a request that had been answered hours before.
    private let tally: () -> UsageTally
    private let pendingGate: () -> String?
    /// Where "I already have a key" goes. Pasting a key is a settings job and
    /// already has a field there; duplicating it here would be two places to
    /// keep in step.
    private let openKeyField: () -> Void
    private(set) var window: NSWindow?
    /// What the window is showing. A new one on every open, so the plan picked
    /// is the one the caller asked for rather than whatever was clicked last
    /// time — `@State` lives exactly as long as its hosting controller.
    private(set) var hosting: NSHostingController<PurchaseView>?

    init(flow: PurchaseFlow, license: LicenseModel, tally: @escaping () -> UsageTally,
         pendingGate: @escaping () -> String?, openKeyField: @escaping () -> Void) {
        self.flow = flow
        self.license = license
        self.tally = tally
        self.pendingGate = pendingGate
        self.openKeyField = openKeyField
    }

    func show(plan: License.Period = .yearly) {
        prepare(plan: plan)
        // Asks for focus outright: a purchase window that opened behind the
        // browser would be the worst possible place to be subtle about it.
        // In the Dock while it is open, so it can be found again from there
        // while the browser has the payment page.
        if let window { DockPresenceController.shared.willShow(window) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Everything `show` does short of bringing the window forward.
    func prepare(plan: License.Period) {
        let onScreen = window?.isVisible == true
        // A page that didn't open last time is no reason to open on the
        // failure: coming back means choosing again.
        if flow.stage == .couldNotOpen { flow.cancel() }
        // Nor is a purchase that finished some other time. Somebody whose
        // subscription later ended would otherwise be told "You're subscribed"
        // by the window they opened to subscribe again. On screen, it stays:
        // that is the confirmation they are reading.
        if flow.stage == .activated, !onScreen { flow.cancel() }

        let hosting = NSHostingController(rootView: makeView(plan: plan))
        self.hosting = hosting
        if let window {
            // Same window, same place, new content.
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            window.contentViewController = hosting
            fit(window, to: hosting)
            window.setFrameTopLeftPoint(topLeft)
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "Airlock"
            // Settings' chrome: the title bar see-through over the notch's
            // near-black, with no title drawn, so the close button sits on
            // the same black as the page. Dark aqua so the menus a text
            // selection opens are dark too.
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(SettingsLook.ground)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            fit(window, to: hosting)
            window.centerOnNotchScreen()
            self.window = window
        }
    }

    /// A licence went in, however it arrived. The window says so rather than
    /// going on waiting for the browser, and the request it hands back is the
    /// one waiting now.
    func licenceApplied() {
        flow.succeed()
        hosting?.rootView = makeView(plan: flow.plan)
    }

    func makeView(plan: License.Period) -> PurchaseView {
        PurchaseView(
            flow: flow,
            tally: tally(),
            onBuy: { [weak self] plan in self?.buy(plan) },
            onPasteKey: { [weak self] in
                self?.window?.close()
                self?.openKeyField()
            },
            onDismiss: { [weak self] in self?.window?.close() },
            pendingGate: pendingGate(),
            openingPlan: plan)
    }

    /// The page plus the title bar it runs up under: the hosting view counts
    /// the bar as safe area in its fitting size, and a full-size content view
    /// counts it in the content size, so the two agree. A screen reached while
    /// the window is up is sized by the hosting view's constraints instead.
    private func fit(_ window: NSWindow, to hosting: NSHostingController<PurchaseView>) {
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)
    }

    /// Off to the browser, and the flow starts waiting.
    ///
    /// The order matters: the state moves BEFORE the browser opens, so the
    /// window is already showing "finish up in your browser" by the time focus
    /// leaves — rather than still offering two plans behind a checkout page.
    ///
    /// Waiting only starts when there is a page to wait for: with no checkout
    /// address, or a link macOS would not open, the window says so instead of
    /// "the payment page is open".
    private func buy(_ plan: License.Period) {
        guard let url = license.checkoutURL(for: plan) else { return flow.failToOpen(plan: plan) }
        flow.begin(plan: plan)
        if !NSWorkspace.shared.open(url) { flow.failToOpen(plan: plan) }
    }
}
