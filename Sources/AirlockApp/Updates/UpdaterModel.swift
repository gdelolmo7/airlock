import Observation
import Sparkle
import AirlockCore

/// Auto-updates, via Sparkle.
///
/// The one external dependency in the package, for the reason set out in
/// Package.swift: an updater downloads code and runs it, which makes it the
/// most security-sensitive thing an app outside the App Store contains. Every
/// update is verified against an **EdDSA public key compiled into the bundle**
/// (`SUPublicEDKey`), so a compromised web host can serve whatever it likes and
/// the app will refuse it. The signature — not the download — is the trust.
///
/// **It is not the app's only outbound request**, which this comment and the
/// General page both used to say: the licence server is contacted to activate
/// a key and around renewal, and the guide asks an online service. What stays
/// true is the plist's "No telemetry.": Sparkle asks for one XML file and sends
/// no identifiers with it. Automatic checking is a setting, and somebody who
/// turns it off is never contacted by the updater again.
@MainActor
@Observable
final class UpdaterModel {
    /// Sparkle's own controller. `startingUpdater: false` because the app is
    /// `LSUIElement` and constructs its models before the UI exists — starting
    /// on our own terms means a first-run check cannot race the onboarding
    /// window for the screen.
    @ObservationIgnored private let controller: SPUStandardUpdaterController

    /// Mirrored rather than read through: `@Observable` cannot see Sparkle's
    /// own properties, so a settings toggle bound straight to them would not
    /// redraw.
    var checksAutomatically: Bool {
        didSet {
            guard checksAutomatically != oldValue else { return }
            controller.updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    /// When Sparkle last asked. Mirrored for the same reason as the toggle, and
    /// **kept up to date by KVO rather than by whoever happens to look**.
    ///
    /// A computed pass-through was worse than it looked: `@Observable` sees no
    /// dependency, so the About pane redrew only when something else invalidated
    /// it — and its only such signal was the app becoming active again. Sparkle's
    /// check and its "You're up to date" sheet are both in-process, so the app
    /// never resigns active: press Check Now, dismiss the sheet, and "Last
    /// checked" still read **Never**.
    private(set) var lastCheck: Date?

    /// Whether Check Now can be pressed. Same mirror, same reason — without it
    /// the button never showed as disabled for the duration of a check.
    private(set) var canCheck: Bool

    /// Whether an update could actually arrive.
    ///
    /// **This used to ask only whether we were in a bundle, which is not the
    /// same question and shipped as the wrong one.** Packaging omits the
    /// updater — silently, deliberately — when there is no appcast URL or no
    /// signing key, but it still produces a `.app`; so a release built without
    /// Sparkle keys drew the whole Updates section, with a Check Now that could
    /// only fail, above a paragraph promising signature verification that was
    /// not configured. The Settings comment already claimed this checked for
    /// the keys. Now it does.
    ///
    /// Both keys are read from the bundle because they are what Sparkle itself
    /// reads: no feed is nowhere to ask, and no key means nothing that came
    /// back could be trusted anyway.
    let isAvailable: Bool

    /// Pure so it can be tested — `Bundle.main` in a test process is the test
    /// runner, so the real one can never be exercised from `swift test`.
    nonisolated static func updaterIsUsable(isBundled: Bool,
                                            feedURL: Any?,
                                            publicKey: Any?) -> Bool {
        isBundled && feedURL != nil && publicKey != nil
    }

    /// What the General page says beside the button — see `UpdateStatus`.
    /// Fed by Sparkle's delegate callbacks, which are the only place a failed
    /// check or a download waiting for quit is ever reported.
    private(set) var status: UpdateStatus = .quiet

    /// The sentence for the page, or nil. Says why Check Now is greyed out
    /// whenever it is.
    var statusLine: String? { UpdateStatus.line(status, canCheck: canCheck) }

    /// Held because KVO stops at deallocation, not at scope exit.
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Held strongly: Sparkle keeps its delegate weakly, so an unowned one
    /// would be gone before the first check finished.
    @ObservationIgnored private let events = UpdaterEvents()

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: events,
                                                  userDriverDelegate: nil)
        isAvailable = Self.updaterIsUsable(
            isBundled: AppBundle.isBundled,
            feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL"),
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey"))
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
        canCheck = isAvailable && controller.updater.canCheckForUpdates

        // Both keys notify: `canCheckForUpdates` is documented KVO-compliant,
        // and `lastUpdateCheckDate` posts its own will/did around the write.
        // Sparkle stamps the date BEFORE it re-enables checking at the end of a
        // cycle, so re-reading the pair on either notification never catches a
        // finished check that still says Never.
        let sparkle = controller.updater
        observations = [
            sparkle.observe(\.canCheckForUpdates) { [weak self] _, _ in
                Task { @MainActor in self?.readSparkleState() }
            },
            sparkle.observe(\.lastUpdateCheckDate) { [weak self] _, _ in
                Task { @MainActor in self?.readSparkleState() }
            }
        ]
        events.report = { [weak self] event in self?.apply(event) }
    }

    private func apply(_ event: UpdaterEvents.Event) {
        switch event {
        case .finished(let code):
            status = UpdateStatus.after(errorCode: code, previous: status)
        case .readyOnQuit(let version):
            status = .readyOnQuit(version: version)
        }
    }

    private func readSparkleState() {
        lastCheck = controller.updater.lastUpdateCheckDate
        canCheck = isAvailable && controller.updater.canCheckForUpdates
    }

    func start() {
        guard isAvailable else { return }
        do {
            try controller.updater.start()
        } catch {
            // Never fatal. A broken updater must not stop the app launching —
            // the worst outcome is that updates have to be downloaded by hand,
            // which is where this app was yesterday.
            Log.app.error("updater did not start — \(error.localizedDescription, privacy: .public)")
            status = .didNotStart
        }
    }

    /// The menu item. Shows Sparkle's own UI, including "you're up to date",
    /// because a check that silently does nothing reads as a broken button.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

/// Sparkle's delegate, reduced to the two outcomes the General page reports.
///
/// Not main-actor-isolated: Sparkle's protocol is not annotated, so these are
/// called as plain Objective-C. Each callback copies out plain values and hops
/// to the main actor with them, rather than assuming it is already there.
final class UpdaterEvents: NSObject, SPUUpdaterDelegate {
    enum Event: Sendable {
        /// An update cycle ended; Sparkle's error code, nil when it ended well.
        case finished(errorCode: Int?)
        /// Downloaded, and Sparkle will install it when the app quits.
        case readyOnQuit(version: String)
    }

    /// Set once, by `UpdaterModel`, before Sparkle starts.
    var report: (@MainActor @Sendable (Event) -> Void)?

    private func send(_ event: Event) {
        guard let report else { return }
        Task { @MainActor in report(event) }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        send(.finished(errorCode: error.map { ($0 as NSError).code }))
    }

    /// `false` keeps Sparkle's own behaviour — it installs on quit either way.
    /// This only notes that it will.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        send(.readyOnQuit(version: item.displayVersionString))
        return false
    }
}
