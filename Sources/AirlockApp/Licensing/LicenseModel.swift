import AirlockCore
import Foundation
import Observation
import os

/// Holds the licence key, remembers when the trial started, and keeps the key
/// fresh.
///
/// Verification is `LicenseVerifier`, the rules are `Entitlement`, the trial is
/// `TrialClock` and the timing is `LicenseRefresh` — all pure and tested in
/// Core. What lives here is the part that cannot be pure: disk, and one HTTP
/// request a handful of times a year.
@MainActor
@Observable
final class LicenseModel {
    private(set) var entitlement: Entitlement = .trialing(daysRemaining: TrialClock.length)
    /// The stored key, so Settings can show it and let it be replaced.
    private(set) var token: String = ""
    /// Set when a pasted key was refused, so the field can say why rather than
    /// silently doing nothing.
    private(set) var rejection: LicenseVerdict.Reason?
    /// Set when the licence server refused or could not be reached — a
    /// different kind of failure from a key that does not verify, and one the
    /// customer can often fix themselves by reconnecting.
    private(set) var activationError: String?
    /// True while the exchange is in flight, so the button can say so. A paste
    /// that appears to do nothing for two seconds gets pasted again.
    private(set) var isActivating = false

    /// Whether this Mac has ever had a working licence on it.
    ///
    /// Survives `removeLicense`, deliberately: a returning customer told "your
    /// trial has ended" is being addressed as a stranger by an app they used to
    /// pay for. What they need to hear is that nothing was lost while they were
    /// gone, and that is a different screen — see the licence pane's win-back.
    var hasSubscribedBefore: Bool { previewSubscribedBefore ?? defaults.bool(forKey: Keys.hasSubscribed) }

    /// Raised when something in the panel asks to buy — the gate's "Subscribe
    /// and approve", the trial card's buttons. Wired by whoever owns the
    /// windows; the panel cannot open one itself and should not try.
    @ObservationIgnored var onShowPurchase: (() -> Void)?

    func showPurchase() { onShowPurchase?() }

    /// Opens Settings › Licence — from the overdue line, where the answer is
    /// the licence page and not a second subscription — and, with `keyField`,
    /// at the key field, for the last-day card's "I have a key".
    ///
    /// The notch's licence buttons used to call its own "open Settings", which
    /// reopened whichever page was last open while VoiceOver promised "Opens
    /// licence settings". Every "Subscribe" now goes to `showPurchase`.
    @ObservationIgnored var onShowLicence: ((_ keyField: Bool) -> Void)?

    func showLicence(keyField: Bool = false) { onShowLicence?(keyField) }

    /// Where to send somebody who has chosen a plan.
    ///
    /// On the model rather than in a view because two surfaces reach for it now
    /// — the licence pane's buttons and the purchase window — and a second copy
    /// of a store URL is a second thing to forget when the store moves.
    func checkoutURL(for period: License.Period) -> URL? { Self.checkoutURL(for: period) }

    /// `nonisolated static` so it can be tested without standing up a whole
    /// `LicenseModel` — it is a two-entry table, and building the model to read
    /// it would start timers and touch defaults for nothing.
    nonisolated static func checkoutURL(for period: License.Period) -> URL? {
        // The path segment is the VARIANT's uuid, not the product's and not the
        // numeric variant id — `/checkout/buy/2124315` is a 404, checked. These
        // came from the live store (`worker/scripts/ls-ids.sh` prints them).
        //
        // **Each lands on a PICKER showing both plans, with its own one already
        // selected** — it does not land on that plan alone, which this comment
        // claimed until somebody opened the two pages and looked (2026-09-15,
        // both verified live: `3ac38a46…` selects Monthly €3.99, `93a5fdb0…`
        // selects Annual €35.99). The difference matters twice over. A customer
        // can still switch plans on the page, so the url chooses the default and
        // not the outcome — and a reader who believed the old claim would rule
        // out the one bug that cannot be tested from here.
        //
        // Which is: **nothing local can tell you these two are the right way
        // round.** Swap them and every test below still passes — they are two
        // distinct, well-formed uuids on the right host either way — while
        // everyone choosing Annual is offered Monthly and the other way about.
        // The only check is opening both and reading which radio is filled.
        // Do that after any change here, and after any edit to the variants in
        // the Lemon Squeezy dashboard.
        //
        // This is the ONLY place they appear — the licence pane had a second
        // copy under its own "so they move in one place" comment, which is
        // exactly how a store URL gets missed when it changes.
        switch period {
        case .monthly:
            return URL(string: "https://useairlock.lemonsqueezy.com/checkout/buy/3ac38a46-f154-4a79-b872-0fbae892c873")
        case .yearly:
            return URL(string: "https://useairlock.lemonsqueezy.com/checkout/buy/93a5fdb0-4670-40cf-9057-827f8ffe454f")
        }
    }

    /// The public half of the signing key, compiled in at build time. Without
    /// it nothing can be verified, so every copy is on trial — which is the
    /// correct failure for a build packaged without a key, and vastly better
    /// than defaulting to "licensed".
    private let publicKey: Data?

    /// The licence server, if this build has one: `<base>/activate` swaps a
    /// Lemon Squeezy key for a signed token, `<base>/refresh` renews one.
    ///
    /// Absent in a build packaged without it, and then neither happens — a
    /// hand-issued token still works offline forever, and nothing else does.
    /// Same rule as Sparkle: a half-configured server that fails forever is
    /// worse than none.
    private let apiBase: URL?

    private static let log = Logger(subsystem: "com.airlock.app", category: "license")

    private enum Keys {
        static let token = "license.token"
        static let trialStarted = "license.trialStarted"
        static let lastRefresh = "license.lastRefreshAttempt"
        static let hasSubscribed = "license.hasSubscribedBefore"
        /// Set only by a 402 on refresh, cleared only by a minted token.
        ///
        /// Persisted rather than held in memory: a subscription that ended does
        /// not un-end on relaunch, and an in-memory flag would have made quitting
        /// the app the workaround for paying.
        static let subscriptionEnded = "license.subscriptionEnded"
    }

    /// A second copy of the trial start, beside the app's own preferences.
    ///
    /// Not an anti-piracy measure and not pretending to be one — anyone who
    /// wants to reset a local trial can. It is here because deleting
    /// preferences is something people do for entirely innocent reasons, and
    /// losing a trial to a defaults reset would be a support ticket from an
    /// honest customer. The EARLIEST of the two wins, so restoring either one
    /// cannot extend anything.
    private static var trialMarkerURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Airlock/.trial")
    }

    init(defaults: UserDefaults = .standard) {
        publicKey = Self.embeddedPublicKey()
        apiBase = Self.embeddedAPIBase()
        self.defaults = defaults
        token = defaults.string(forKey: Keys.token) ?? ""
        refresh()
    }

    /// A fixed entitlement that reads nothing and writes nothing — the state
    /// gallery's. `init(defaults:)` cannot stand in for it, not even on a
    /// throwaway suite: `refresh()` heals the trial markers on the way in, and
    /// on a Mac that never ran Airlock that STARTS a trial, in the real
    /// `~/Library/Application Support/Airlock/.trial`.
    ///
    /// The rest are the gallery's too: what the licence pane shows after a
    /// refused paste or a failed activation, and the returning-customer flag.
    /// `refresh()` is a no-op on this instance, because the licence pane calls
    /// it on appear and it would otherwise start a trial on the way in.
    init(previewing entitlement: Entitlement, token: String = "",
         rejection: LicenseVerdict.Reason? = nil, activationError: String? = nil,
         hasSubscribedBefore: Bool = false) {
        publicKey = nil
        apiBase = nil
        // A suite nothing writes to: `refresh()` does nothing on this
        // instance, and reading a suite creates no file.
        defaults = UserDefaults(suiteName: "com.airlock.state-gallery") ?? .standard
        isPreview = true
        previewSubscribedBefore = hasSubscribedBefore
        self.token = token
        self.entitlement = entitlement
        self.rejection = rejection
        self.activationError = activationError
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// True only for `init(previewing:)` — see there.
    @ObservationIgnored private var isPreview = false
    @ObservationIgnored private var previewSubscribedBefore: Bool?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Recompute periodically, and refresh when it is time to.
    ///
    /// The half-hour tick is almost entirely local: it is what moves the trial
    /// countdown over midnight and slides a licence from grace into overdue
    /// without needing a relaunch. `LicenseRefresh` is what decides whether any
    /// of those ticks becomes a request, and for most of the year none of them
    /// does.
    func start() {
        Self.log.info("entitlement at launch: \(self.diagnosticSummary, privacy: .public)")
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshFromServer()
                self?.refresh()
                try? await Task.sleep(for: .seconds(1_800))
            }
        }
    }

    deinit { ticker?.cancel() }

    /// Take whatever was pasted and try to turn it into a working licence.
    ///
    /// **Two things can arrive in that field**, and telling them apart locally
    /// is free: a signed token (issued by hand, verifies here, no network) or
    /// the licence key Lemon Squeezy emailed on purchase (means nothing to this
    /// app until the server exchanges it for a signed one). Trying the offline
    /// path first means a hand-issued key still works with the server down.
    @discardableResult
    func apply(_ candidate: String) async -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        rejection = nil
        activationError = nil

        // Seat-checked HERE, at the door: a licence for another Mac is refused
        // before it is ever stored, so the message can say which problem it is.
        let verdict = publicKey.map {
            LicenseVerifier.verify(trimmed, publicKey: $0, machine: MachineIdentity.current)
        }
        switch LicensePaste.step(verdict: verdict, hasServer: apiBase != nil) {
        case .store:
            // Stored even when it is out of date: it is genuinely theirs, and
            // keeping it means Settings can say "renew" with their address on
            // it rather than "no licence" — and that a refresh has something to
            // present when their card is fixed.
            store(trimmed)
            await refreshFromServer(force: true)
            return true
        case .refuse(let reason):
            rejection = reason
            return false
        case .cannotCheck:
            // The build's fault — no public key, or a shop key and no server to
            // exchange it. "That does not look like a licence key" here blamed
            // the customer for a packaging mistake.
            Self.log.error("licence paste refused: this build has no \(self.publicKey == nil ? "public key" : "licence server", privacy: .public)")
            activationError = Self.cannotCheckMessage
            return false
        case .askServer:
            return await exchangeAtServer(trimmed)
        }
    }

    /// Swap a Lemon Squeezy licence key for a signed token.
    private func exchangeAtServer(_ key: String) async -> Bool {
        guard let endpoint = endpoint("activate") else {
            // `LicensePaste` sends nothing here without a server; kept so a
            // later caller cannot reach a silent no-op.
            activationError = Self.cannotCheckMessage
            return false
        }
        isActivating = true
        defer { isActivating = false }

        // The Mac being activated, named. Without this the Worker cannot claim a
        // seat and cannot stamp the token, and the app's own seat check — which
        // has been complete and correct all along — stays unreachable, because
        // it only fires when BOTH sides name a machine.
        //
        // Omitted rather than faked when `IOPlatformUUID` is unreadable. A
        // licence that works everywhere is a smaller problem than one that
        // cannot be activated at all, and `machine` is nil-honoured by design.
        var body = ["key": key]
        if let machine = MachineIdentity.current { body["machine"] = machine }

        switch await post(endpoint, body: body) {
        case .token(let fresh):
            // A successful activation is proof of a live subscription, so it
            // clears any earlier refusal — otherwise resubscribing with the same
            // key would leave the app blocked with a working token on disk.
            defaults.set(false, forKey: Keys.subscriptionEnded)
            store(fresh)
            return true
        case .declined(let message):
            activationError = message
            return false
        case .unavailable(let message):
            activationError = message ?? Self.unreachableMessage(keepsWorking: entitlement.allowsUse)
            return false
        }
    }

    /// What the licence pane says when the server could not be reached. Named
    /// so the state gallery shows the shipping words rather than a copy.
    ///
    /// It used to end "your key is fine" — about a key nobody had checked.
    /// What is true is that it wasn't checked, and, unless the trial is
    /// already over, that nothing has stopped in the meantime.
    static func unreachableMessage(keepsWorking: Bool) -> String {
        "Airlock couldn't reach the internet, so your key hasn't been checked yet. "
            + (keepsWorking ? "Airlock keeps working — try again when you're back online."
                            : "Try again when you're back online.")
    }

    /// A copy of Airlock that can't check keys at all. Ours to fix, and it
    /// says so: the customer did nothing wrong by pasting.
    static let cannotCheckMessage =
        "This copy of Airlock can't check licence keys — that's on our side, not yours. Download Airlock again from useairlock.app, or write to hello@useairlock.app."

    func removeLicense() {
        token = ""
        defaults.removeObject(forKey: Keys.token)
        defaults.removeObject(forKey: Keys.lastRefresh)
        defaults.removeObject(forKey: Keys.subscriptionEnded)
        rejection = nil
        activationError = nil
        refresh()
    }

    /// **UserDefaults, not the Keychain — and the purchase copy used to say
    /// otherwise.** Two lines in `PurchaseView` promised the keychain, one of
    /// them on the post-purchase success screen, which is the worst possible
    /// place for a security claim that is not true. The copy now says "kept on
    /// this Mac", which is what this does.
    ///
    /// Moving it to the Keychain is a real improvement and a separate change:
    /// it needs a migration for tokens already written here, and a decision
    /// about what to do when the Keychain refuses. Not something to slip in
    /// beside a copy fix.
    private func store(_ fresh: String) {
        token = fresh
        defaults.set(fresh, forKey: Keys.token)
        // Set once and never cleared, including by `removeLicense`. It is the
        // only way to tell somebody who has come BACK from somebody who never
        // subscribed, and those two deserve different words — see
        // `hasSubscribedBefore`.
        defaults.set(true, forKey: Keys.hasSubscribed)
        rejection = nil
        activationError = nil
        refresh()
    }

    /// Recompute from what is already on disk. Cheap, synchronous, no network —
    /// safe to call whenever the answer is about to be shown.
    func refresh() {
        guard !isPreview else { return }
        // Free: no trial is started (no marker written) and nothing is read.
        if Pricing.isFree {
            entitlement = .free
            return
        }
        let wasUsable = entitlement.allowsUse
        entitlement = Entitlement.resolve(
            verdict: currentVerdict(),
            trialStarted: trialStart(),
            subscriptionEnded: defaults.bool(forKey: Keys.subscriptionEnded))
        if wasUsable, !entitlement.allowsUse { Moments.shared.announce(.licenceBlocked) }
    }

    // MARK: - Keeping the key fresh

    /// Ask for a newer token, if it is time to. Silent in every failure case:
    /// the token on disk carries its own grace window, and that window exists
    /// precisely so a failure here is not the customer's problem.
    func refreshFromServer(force: Bool = false) async {
        // Free: the licence server is never contacted, not even to renew a
        // key somebody still has on disk.
        guard !Pricing.isFree, let endpoint = endpoint("refresh"), !token.isEmpty else { return }
        guard force || LicenseRefresh.shouldAttempt(
            license: currentVerdict()?.license,
            lastAttempt: defaults.object(forKey: Keys.lastRefresh) as? Date) else { return }

        defaults.set(Date(), forKey: Keys.lastRefresh)

        switch await post(endpoint, body: ["token": token]) {
        case .token(let fresh):
            // Clears the flag as well as storing the token: a subscription that
            // was ended and then restarted must come all the way back, and the
            // proof it restarted is a token the server was willing to mint.
            defaults.set(false, forKey: Keys.subscriptionEnded)
            store(fresh)
            Self.log.info("licence refreshed")

        case .declined(let message):
            // **The path that used to not exist.** Its absence is what made one
            // month buy the app forever: no new token meant the one on disk aged
            // past `checkBy` into `.overdue`, which kept working and asked, and
            // asked, and kept working.
            //
            // The token is NOT deleted. It stays on disk and stays valid, so a
            // resubscription is picked up by the next refresh rather than
            // needing the key pasted again — and so a wrong refusal, if one ever
            // escapes the Worker, costs an entitlement rather than a licence.
            defaults.set(true, forKey: Keys.subscriptionEnded)
            Self.log.info("licence server declined the refresh: \(message, privacy: .public)")
            refresh()

        case .unavailable:
            // Silent, and that is the rule that has not changed: the token on
            // disk carries its own grace window, and that window exists
            // precisely so a failure here is not the customer's problem.
            break
        }
    }

    private enum ServerReply {
        case token(String)
        /// **402, and only 402.** The server was asked and the answer was no —
        /// the key is not ours, the subscription ended, it is paused. Every
        /// other outcome is "we do not know", and the distinction is the whole
        /// point: acting on "we do not know" is how one bad afternoon on a
        /// licence server revokes everybody.
        case declined(String)
        /// Transport failure, 5xx, or a reply that did not verify. Unknown.
        case unavailable(String?)
    }

    /// One request shape for both endpoints, and one place where a reply is
    /// only believed if it verifies.
    private func post(_ url: URL, body: [String: String]) async -> ServerReply {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let payload = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let fresh = payload["token"] else {
                let message = payload["error"]
                // 409 is "this token is not a subscription" — a hand-issued
                // licence, which is MEANT to run offline to its own `checkBy`
                // and must never be ended by asking about it.
                return status == 402
                    ? .declined(message ?? "That subscription is no longer active.")
                    : .unavailable(message)
            }
            // THE CHECK THAT MATTERS. A server that hands back rubbish — a bad
            // deploy, a hijacked DNS record, a captive portal returning a login
            // page — must never overwrite a working licence, or one mistake
            // revokes every customer at once.
            guard let publicKey else {
                return .unavailable("Your licence couldn't be checked just now. Nothing has changed — try again in a moment.")
            }
            switch LicenseVerifier.verify(fresh, publicKey: publicKey, machine: MachineIdentity.current) {
            case .valid:
                return .token(fresh)
            case .invalid(.otherMachine):
                // Still `.unavailable`, deliberately: `.declined` marks the
                // subscription ended, and it is not — the server simply named
                // a different Mac. Keep what we had, and say what happened
                // instead of the generic line, which once hid a wrong SIGNING
                // KEY on the server behind the same words for an afternoon.
                Self.log.error("licence server returned a token for another machine — kept the old one")
                return .unavailable("That licence belongs to a different Mac. Nothing has changed.")
            case .invalid:
                Self.log.error("licence server returned a token that does not verify — kept the old one")
                return .unavailable("Your licence couldn't be checked just now. Nothing has changed — try again in a moment.")
            }
        } catch {
            Self.log.info("licence request failed: \(error.localizedDescription, privacy: .public)")
            return .unavailable(nil)
        }
    }

    private func endpoint(_ path: String) -> URL? {
        apiBase?.appendingPathComponent(path)
    }

    /// One line for the log, and the answer to the first support question there
    /// is: what does this install actually think it is?
    ///
    /// Says the state and the dates and **never the email or the key** — a
    /// licence key in a log someone pastes into a bug report is a licence key
    /// in a bug tracker. `id` is deliberately included: it is the vendor's own
    /// reference, not a secret, and it is what makes a ticket answerable.
    private var diagnosticSummary: String {
        switch entitlement {
        case .free: return "free"
        case .trialing(let days): return "trialing, \(days)d left"
        case .trialExpired: return "trial expired"
        case .licensed(let l): return "licensed \(l.id), renews \(Self.stamp(l.renewsAt))"
        case .grace(let l): return "grace \(l.id), due \(Self.stamp(l.renewsAt)), checkBy \(Self.stamp(l.checkBy))"
        case .overdue(let l): return "overdue \(l.id), checkBy passed \(Self.stamp(l.checkBy))"
        }
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    private func currentVerdict() -> LicenseVerdict? {
        publicKey.flatMap { key in
            token.isEmpty ? nil : LicenseVerifier.verify(token, publicKey: key,
                                                          machine: MachineIdentity.current)
        }
    }

    // MARK: - Trial bookkeeping

    /// First run wins, and the earliest record of it wins.
    private func trialStart() -> Date {
        var candidates: [Date] = []
        if let stored = defaults.object(forKey: Keys.trialStarted) as? Date {
            candidates.append(stored)
        }
        if let marker = try? FileManager.default.attributesOfItem(
            atPath: Self.trialMarkerURL.path)[.creationDate] as? Date {
            candidates.append(marker)
        }

        if let earliest = candidates.min() {
            // Heal whichever copy is missing, so a later reset of one is caught
            // by the other.
            if defaults.object(forKey: Keys.trialStarted) == nil {
                defaults.set(earliest, forKey: Keys.trialStarted)
            }
            writeMarkerIfMissing()
            return earliest
        }

        let now = Date()
        defaults.set(now, forKey: Keys.trialStarted)
        writeMarkerIfMissing()
        return now
    }

    private func writeMarkerIfMissing() {
        let url = Self.trialMarkerURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    // MARK: - Injected at packaging

    /// Like Sparkle's key. A build without one verifies nothing — see `publicKey`.
    private static func embeddedPublicKey() -> Data? {
        guard let encoded = Bundle.main.object(forInfoDictionaryKey: "ALLicensePublicKey") as? String,
              !encoded.isEmpty else { return nil }
        return Data(base64Encoded: encoded)
    }

    /// https only. A licence key posted over plain http is one an airport
    /// network can read and replay — and the reply is what this app trusts.
    private static func embeddedAPIBase() -> URL? {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "ALLicenseAPIURL") as? String,
              let url = URL(string: string), url.scheme == "https" else { return nil }
        return url
    }
}
