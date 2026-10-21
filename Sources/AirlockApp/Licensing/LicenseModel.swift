import AirlockCore
import Foundation
import Observation
import os

/// Holds the licence key, keeps it fresh, and says which plan this Mac is on.
///
/// Verification is `LicenseVerifier`, the rules are `Entitlement`, an old
/// trial's days are `TrialClock` and the timing is `LicenseRefresh` — all pure
/// and tested in Core. What lives here is the part that cannot be pure: disk,
/// and one HTTP request a handful of times a year.
///
/// **No trial starts any more** (the owner, 2026-10-15): a new install is on
/// Free. A trial already running at the update keeps its days, so the trial
/// markers are still read, and healed when one copy is missing, but never
/// written on a Mac that has neither.
@MainActor
@Observable
final class LicenseModel {
    private(set) var entitlement: Entitlement = .free
    /// "You're on Free now", while it is due: once, after a trial or a paid
    /// plan ends (`FreeCard.due`). Nil the rest of the time.
    private(set) var freeCard: FreeCard?
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
    /// Survives `removeLicense`, deliberately: a returning customer told
    /// "Airlock is free" is being addressed as a stranger by an app they used
    /// to pay for. What they need to hear is that nothing was lost while they were
    /// gone, and that is a different screen — see the licence pane's win-back.
    var hasSubscribedBefore: Bool { previewSubscribedBefore ?? defaults.bool(forKey: Keys.hasSubscribed) }

    /// "Welcome to Plus", while it is due: after a key for a bigger plan
    /// goes in, however it arrived (`WelcomeCard.due`). Kept until "Got it",
    /// across launches, so a card raised while the notch was shut, or just
    /// before a quit, is still there to read.
    private(set) var welcomeCard: WelcomeCard?

    /// The key on this Mac when it still checks out, whatever the
    /// entitlement says: a subscription that ended is on Free and still has a
    /// key worth asking about. Set by `refresh()`, so a view reading it does
    /// not verify a signature on every draw.
    private(set) var storedLicense: License?

    /// The Plans page's Monthly | Yearly switch. Here rather than in the
    /// page, so a button that names a period ("€3.99 a month") can open the
    /// page showing it, and the choice survives the window closing.
    var plansPeriod: License.Period = .yearly

    /// The browser hand-off after "Get Plus": waiting, a fork after three
    /// minutes, done. Here so it outlives the Settings window, which can
    /// close mid-payment without cancelling anything, and so every key that
    /// goes in ends it, whichever way it arrived.
    let purchase = PurchaseFlow()

    /// Free's reminders in the notch (`UpgradeReminderModel`): here so the
    /// panel, which has this model already, can draw the card.
    let reminders: UpgradeReminderModel

    /// True while "Check my plan now" is asking, so the button can say so.
    private(set) var isCheckingPlan = false
    /// What the last "Check my plan now" found, until the page closes.
    private(set) var lastCheck: PlanCheck?

    /// Opens Settings › Plans: from the notch's cards, the call notes'
    /// "See plans" and the overdue line. Wired by whoever owns the windows;
    /// the panel cannot open one itself and should not try. `keyField` lands
    /// on the key field, for "I have a key".
    @ObservationIgnored var onShowPlans: ((_ keyField: Bool) -> Void)?

    /// `period`, when the button that got here named one, so the page shows
    /// the price that was pressed. `from` names that button for usage counts:
    /// a code word, never anything the person wrote.
    func showPlans(period: License.Period? = nil, keyField: Bool = false, from: String = "other") {
        if let period { plansPeriod = period }
        if !isPreview { UsageCounts.shared.record(.plansOpened(from: from)) }
        onShowPlans?(keyField)
    }

    /// What notes written online need from the licence: where to send them
    /// and the token that says who is asking. Nil without a licence server
    /// in this build or without a token; never a model's key, which only
    /// the server holds.
    var notesAccess: (endpoint: URL, token: String)? {
        guard let endpoint = endpoint("notes"), !token.isEmpty else { return nil }
        return (endpoint, token)
    }

    /// Whether this build has a licence server at all.
    var hasServer: Bool { isPreview ? previewHasServer : apiBase != nil }

    /// The public half of the signing key, compiled in at build time. Without
    /// it nothing can be verified, so every copy is on Free — which is the
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
        /// The last plan that was not Free, as `PlanBefore` JSON: what the
        /// "You're on Free now" card compares Free with. Written on every
        /// refresh that is not Free, because once it is Free nothing else
        /// says what it was.
        static let planBefore = "license.planBefore"
        /// The card has been seen for the plan in `planBefore`. Cleared by any
        /// refresh that is not Free, so a later ending gets its own card.
        static let freeCardSeen = "license.freeCardSeen"
        /// The plan a "Welcome to …" card is waiting to be read for, as
        /// `AirlockPlan`'s raw value. Removed by "Got it".
        static let welcomeCard = "license.welcomeCard"
    }

    /// A second copy of the trial start, beside the app's own preferences.
    ///
    /// Not an anti-piracy measure and not pretending to be one — anyone who
    /// wants to reset a local trial can. It is here because deleting
    /// preferences is something people do for entirely innocent reasons, and
    /// losing a trial to a defaults reset would be a support ticket from an
    /// honest customer. The EARLIEST of the two wins, so restoring either one
    /// cannot extend anything.
    ///
    /// Only read now, and healed from the other copy: a Mac with neither never
    /// started a trial and never will.
    nonisolated static var defaultTrialMarkerURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Airlock/.trial")
    }

    /// `trialMarker` is for tests, which must never read or heal the real one.
    init(defaults: UserDefaults = .standard, trialMarker: URL = LicenseModel.defaultTrialMarkerURL,
         publicKey: Data? = LicenseModel.embeddedPublicKey()) {
        self.publicKey = publicKey
        apiBase = Self.embeddedAPIBase()
        self.defaults = defaults
        trialMarkerURL = trialMarker
        token = defaults.string(forKey: Keys.token) ?? ""
        welcomeCard = defaults.string(forKey: Keys.welcomeCard)
            .flatMap(AirlockPlan.init(rawValue:)).flatMap(WelcomeCard.init)
        reminders = UpgradeReminderModel(defaults: defaults)
        refresh()
        reminders.onFree = { [weak self] in self?.entitlement.plan == .free }
        reminders.otherCardUp = { [weak self] in self?.freeCard != nil || self?.welcomeCard != nil }
        reminders.onSeePlus = { [weak self] in self?.showPlans(from: "reminder") }
    }

    /// A fixed entitlement that reads nothing and writes nothing — the state
    /// gallery's. `init(defaults:)` cannot stand in for it, not even on a
    /// throwaway suite: `refresh()` heals the trial markers on the way in, in
    /// the real `~/Library/Application Support/Airlock/.trial` unless told
    /// otherwise.
    ///
    /// The rest are the gallery's too: what the Plans page shows after a
    /// refused paste or a failed activation, the returning-customer flag, a
    /// key kept from a subscription that ended (`stored`), whether there is a
    /// licence server to ask, and the welcome card. `refresh()` is a no-op on
    /// this instance, because the Plans page calls it on appear and it would
    /// otherwise replace the state being shown.
    ///
    /// `checkingWith` and `keepingIn` are for tests: with them a pasted token
    /// signed by that key is taken for real and kept in that suite, so what a
    /// working paste sets off can be checked without the real trial marker
    /// or a licence server.
    init(previewing entitlement: Entitlement, token: String = "",
         rejection: LicenseVerdict.Reason? = nil, activationError: String? = nil,
         hasSubscribedBefore: Bool = false, freeCard: FreeCard? = nil,
         stored: License? = nil, hasServer: Bool = false, welcomeCard: WelcomeCard? = nil,
         lastCheck: PlanCheck? = nil, reminder: UpgradeReminder? = nil,
         checkingWith publicKey: Data? = nil, keepingIn defaults: UserDefaults? = nil) {
        self.publicKey = publicKey
        apiBase = nil
        trialMarkerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("airlock-preview-has-no-trial")
        // A suite nothing writes to: `refresh()` does nothing on this
        // instance, and reading a suite creates no file.
        self.defaults = defaults ?? UserDefaults(suiteName: "com.airlock.state-gallery") ?? .standard
        isPreview = true
        previewSubscribedBefore = hasSubscribedBefore
        self.token = token
        self.entitlement = entitlement
        self.freeCard = freeCard
        self.rejection = rejection
        self.activationError = activationError
        storedLicense = stored ?? entitlement.license
        previewHasServer = hasServer
        self.welcomeCard = welcomeCard
        self.lastCheck = lastCheck
        reminders = UpgradeReminderModel(previewing: reminder)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let trialMarkerURL: URL
    /// True only for `init(previewing:)` — see there.
    @ObservationIgnored private var isPreview = false
    @ObservationIgnored private var previewSubscribedBefore: Bool?
    @ObservationIgnored private var previewHasServer = false
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Recompute periodically, and refresh when it is time to.
    ///
    /// The half-hour tick is almost entirely local: it is what moves an old
    /// trial's countdown over midnight and slides a licence from grace into
    /// overdue without needing a relaunch. `LicenseRefresh` is what decides whether any
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
        // Ends the browser hand-off here, once, rather than in each caller:
        // two callers each deciding whether to say so is how a key pasted in
        // Settings once left the purchase window saying "Finish up in your
        // browser" over a working licence.
        let accepted = await take(candidate)
        if accepted { purchase.succeed() }
        return accepted
    }

    private func take(_ candidate: String) async -> Bool {
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
            activationError = message ?? Self.unreachableMessage
            return false
        }
    }

    /// What the licence pane says when the server could not be reached. Named
    /// so the state gallery shows the shipping words rather than a copy.
    ///
    /// It used to end "your key is fine" — about a key nobody had checked.
    /// What is true is that it wasn't checked, and that nothing has stopped in
    /// the meantime: nothing ever does.
    static let unreachableMessage =
        "Airlock couldn't reach the internet, so your key hasn't been checked yet. "
            + "Airlock keeps working — try again when you're back online."

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
    /// otherwise.** Two lines in the old purchase window promised the
    /// keychain, one of them on the post-purchase success screen, which is the
    /// worst possible place for a security claim that is not true. The copy
    /// now says "kept on this Mac", which is what this does.
    ///
    /// Moving it to the Keychain is a real improvement and a separate change:
    /// it needs a migration for tokens already written here, and a decision
    /// about what to do when the Keychain refuses. Not something to slip in
    /// beside a copy fix.
    private func store(_ fresh: String) {
        let before = entitlement
        defer {
            if let card = WelcomeCard.due(before: before, after: entitlement) { raise(card) }
        }
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
        let verdict = currentVerdict()
        let started = trialStart()
        storedLicense = verdict?.license
        entitlement = Entitlement.resolve(
            verdict: verdict,
            trialStarted: started,
            subscriptionEnded: defaults.bool(forKey: Keys.subscriptionEnded))
        rememberPlan(verdict: verdict, trialStarted: started)
        freeCard = FreeCard.due(entitlement: entitlement, before: storedPlanBefore,
                                seen: defaults.bool(forKey: Keys.freeCardSeen))
        // A welcome to a plan this Mac is no longer on would thank somebody
        // for something they no longer have.
        if let welcomeCard, welcomeCard.plan != entitlement.plan { dismissWelcome() }
    }

    /// "Got it" on the card. It does not come back for this ending.
    func dismissFreeCard() {
        freeCard = nil
        guard !isPreview else { return }
        defaults.set(true, forKey: Keys.freeCardSeen)
    }

    private func raise(_ card: WelcomeCard) {
        welcomeCard = card
        // A welcome replaces any "You're on Free now" still waiting: it is
        // the newer news, and both at once would contradict each other.
        if freeCard != nil { dismissFreeCard() }
        guard !isPreview else { return }
        defaults.set(card.plan.rawValue, forKey: Keys.welcomeCard)
    }

    /// "Got it" on the welcome card.
    func dismissWelcome() {
        welcomeCard = nil
        guard !isPreview else { return }
        defaults.removeObject(forKey: Keys.welcomeCard)
    }

    // MARK: - The plan before Free

    /// Remembers what is not Free, and on Free, works out what it was when
    /// nothing was remembered: the first launch of this version, on a Mac
    /// whose trial or subscription ended under the old one.
    private func rememberPlan(verdict: LicenseVerdict?, trialStarted: Date?) {
        if let before = PlanBefore(entitlement, trialStarted: trialStarted) {
            store(planBefore: before)
            defaults.removeObject(forKey: Keys.freeCardSeen)
            return
        }
        // A key that still verifies, on Free: its subscription ended, on the
        // date the key itself was paid up to. The key is the better witness
        // than whatever was remembered before it ran out.
        if case .valid(let license) = verdict {
            store(planBefore: PlanBefore(endedLicense: license))
            return
        }
        guard storedPlanBefore == nil, let trialStarted else { return }
        store(planBefore: PlanBefore(plan: PlanSnapshot(plan: .plus, isPaid: false), ending: .trial,
                                     endedOn: PlanBefore.trialEnds(started: trialStarted)))
    }

    private var storedPlanBefore: PlanBefore? {
        defaults.data(forKey: Keys.planBefore).flatMap { try? JSONDecoder().decode(PlanBefore.self, from: $0) }
    }

    private func store(planBefore: PlanBefore) {
        guard planBefore != storedPlanBefore,
              let data = try? JSONEncoder().encode(planBefore) else { return }
        defaults.set(data, forKey: Keys.planBefore)
    }

    // MARK: - Keeping the key fresh

    /// Ask for a newer token, if it is time to. Silent in every failure case:
    /// the token on disk carries its own grace window, and that window exists
    /// precisely so a failure here is not the customer's problem.
    ///
    /// Returns what was found, for "Check my plan now" to say, or nil when
    /// nothing was asked.
    @discardableResult
    func refreshFromServer(force: Bool = false) async -> PlanCheck? {
        guard let endpoint = endpoint("refresh"), !token.isEmpty else { return nil }
        guard force || LicenseRefresh.shouldAttempt(
            license: currentVerdict()?.license,
            lastAttempt: defaults.object(forKey: Keys.lastRefresh) as? Date) else { return nil }

        defaults.set(Date(), forKey: Keys.lastRefresh)

        switch await post(endpoint, body: ["token": token]) {
        case .token(let fresh):
            // Clears the flag as well as storing the token: a subscription that
            // was ended and then restarted must come all the way back, and the
            // proof it restarted is a token the server was willing to mint.
            defaults.set(false, forKey: Keys.subscriptionEnded)
            store(fresh)
            Self.log.info("licence refreshed")
            return .current(entitlement.plan)

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
            return .ended

        case .unavailable:
            // Silent, and that is the rule that has not changed: the token on
            // disk carries its own grace window, and that window exists
            // precisely so a failure here is not the customer's problem.
            return .unreachable
        }
    }

    // MARK: - The Plans page

    /// "Check my plan now": the same check a renewal makes, on demand, for
    /// somebody who just paid, paid on another Mac or changed plan in the
    /// shop. Never on a timer: a Mac that nobody asks stays quiet.
    func checkPlanNow() async {
        guard !isCheckingPlan else { return }
        isCheckingPlan = true
        defer { isCheckingPlan = false }
        lastCheck = await refreshFromServer(force: true) ?? .unreachable
    }

    /// The Plans page opened: recompute, and ask the server once more if the
    /// last time was over ten minutes ago, so a plan changed in the shop is
    /// there to see. Silent; only "Check my plan now" says what it found.
    /// Only for a key the shop sold, as there is nothing else to ask about.
    func plansPageOpened(now: Date = Date()) {
        guard !isPreview else { return }
        refresh()
        lastCheck = nil
        guard hasServer, storedLicense?.ref != nil else { return }
        if let last = defaults.object(forKey: Keys.lastRefresh) as? Date,
           now.timeIntervalSince(last) < Self.pageCheckEvery { return }
        Task { await refreshFromServer(force: true) }
    }

    /// How often opening the Plans page may ask the server.
    static let pageCheckEvery: TimeInterval = 10 * 60

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
            let (data, response) = try await PretendOutage.shared.data(for: request)
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
        case .licensed(let l): return "licensed \(l.id) \(l.plan.rawValue), renews \(Self.stamp(l.renewsAt))"
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

    /// When an old trial started: the earliest of the two records. Nil on a
    /// Mac with neither, which never had a trial, and nothing is written then.
    func trialStart() -> Date? {
        guard !isPreview else { return nil }
        var candidates: [Date] = []
        if let stored = defaults.object(forKey: Keys.trialStarted) as? Date {
            candidates.append(stored)
        }
        if let marker = try? FileManager.default.attributesOfItem(
            atPath: trialMarkerURL.path)[.creationDate] as? Date {
            candidates.append(marker)
        }

        guard let earliest = candidates.min() else { return nil }
        // Heal whichever copy is missing, so a later reset of one is caught by
        // the other.
        if defaults.object(forKey: Keys.trialStarted) == nil {
            defaults.set(earliest, forKey: Keys.trialStarted)
        }
        writeMarkerIfMissing()
        return earliest
    }

    private func writeMarkerIfMissing() {
        let url = trialMarkerURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    // MARK: - Injected at packaging

    /// Like Sparkle's key. A build without one verifies nothing — see `publicKey`.
    nonisolated static func embeddedPublicKey() -> Data? {
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
