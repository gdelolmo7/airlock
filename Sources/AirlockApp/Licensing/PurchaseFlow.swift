import Foundation
import Observation
import AirlockCore

/// The gap between "Continue to payment" and a working app.
///
/// **Nothing in the code covered it.** `LicenseModel.isActivating` exists for the
/// paste-a-key path, and the browser hand-off had no state at all — so a person
/// who clicked through to a checkout came back to a window that looked exactly
/// as it had before they left, with no sign anything was in progress.
///
/// The waiting has two meanings and they are a different screen each. The first
/// minute is patience: the page is open, it is being filled in, nothing is
/// wrong. The third minute is a fork — either they are still on the page, or
/// something went wrong out there — and both exits are named, because neither
/// of them is "start over".
///
/// **It survives the window closing.** Somebody who shuts the purchase window
/// mid-payment has not cancelled anything, and the app goes on listening until
/// it quits — which is why this lives on a model rather than in a view's state.
@MainActor
@Observable
final class PurchaseFlow {
    enum Stage: Equatable {
        /// Nothing started, or it finished.
        case idle
        /// The browser is open and we are waiting for the key to come back.
        case waiting(since: Date)
        /// Long enough that saying "waiting" alone stops being honest.
        case stalled
        /// The payment page never opened — no checkout address in this build,
        /// or macOS would not open the link. Nothing to wait for.
        case couldNotOpen
        /// A key arrived and verified. Carries nothing itself — the entitlement
        /// is the source of truth, and this only says the window may celebrate.
        case activated
    }

    private(set) var stage: Stage = .idle
    /// Which plan they left to buy, so the waiting screen can name the amount
    /// they are about to be charged rather than "a subscription".
    private(set) var plan: License.Period = .yearly

    /// When patience stops being the honest word.
    ///
    /// Three minutes rather than thirty seconds: a card form, a 3-D Secure
    /// challenge and a bank app is a normal three minutes, and a fork offered
    /// at thirty seconds would interrupt a purchase that was going fine.
    static let stallAfter: TimeInterval = 180

    @ObservationIgnored private var timer: Task<Void, Never>?

    /// They have left for the browser.
    func begin(plan: License.Period, now: Date = Date()) {
        self.plan = plan
        stage = .waiting(since: now)
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.stallAfter * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.setStalled()
        }
    }

    /// What the timer does when it fires, separated from the waiting itself so
    /// a test can reach the fork without three minutes of `Task.sleep` — which
    /// would be testing the sleep rather than the state machine.
    func setStalled() {
        guard case .waiting = stage else { return }
        stage = .stalled
    }

    /// The browser did not open. Stops the waiting: a three-minute "still
    /// waiting" for a page that was never shown is the screen this replaces.
    func failToOpen(plan: License.Period) {
        timer?.cancel()
        timer = nil
        self.plan = plan
        stage = .couldNotOpen
    }

    /// A key came back and verified.
    func succeed() {
        timer?.cancel()
        timer = nil
        stage = .activated
    }

    /// Explicitly abandoned — the "Not now" on the waiting screen, never the
    /// window merely closing.
    func cancel() {
        timer?.cancel()
        timer = nil
        stage = .idle
    }

    /// Whether the app is still listening for the browser. Closing the window
    /// must not change this; only finishing or cancelling does.
    var isWaiting: Bool {
        switch stage {
        case .waiting, .stalled: return true
        case .idle, .couldNotOpen, .activated: return false
        }
    }
}
