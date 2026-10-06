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
    private let model: AppModel
    private let tally: UsageTallyStore
    /// Where "I already have a key" goes. Pasting a key is a settings job and
    /// already has a field there; duplicating it here would be two places to
    /// keep in step.
    private let openKeyField: () -> Void
    private var window: NSWindow?

    init(flow: PurchaseFlow, license: LicenseModel, model: AppModel,
         tally: UsageTallyStore, openKeyField: @escaping () -> Void) {
        self.flow = flow
        self.license = license
        self.model = model
        self.tally = tally
        self.openKeyField = openKeyField
    }

    func show() {
        // A page that didn't open last time is no reason to open on the
        // failure: coming back means choosing again.
        if flow.stage == .couldNotOpen { flow.cancel() }
        if window == nil {
            let hosting = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Airlock"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            hosting.view.layoutSubtreeIfNeeded()
            window.setContentSize(hosting.view.fittingSize)
            window.centerOnNotchScreen()
            self.window = window
        }
        // An accessory-policy agent has to ask for focus; a purchase window that
        // opened behind the browser would be the worst possible place to be
        // subtle about it.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private var content: some View {
        PurchaseView(
            flow: flow,
            tally: tally.tally,
            onBuy: { [weak self] plan in self?.buy(plan) },
            onPasteKey: { [weak self] in
                self?.window?.close()
                self?.openKeyField()
            },
            onDismiss: { [weak self] in self?.window?.close() },
            pendingGate: model.sessions.compactMap(\.pendingPermission?.command).first)
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
