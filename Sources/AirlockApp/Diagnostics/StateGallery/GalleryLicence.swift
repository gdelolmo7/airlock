import SwiftUI
import AirlockCore

/// The plan rows (L): the Plans page, the notch's plan cards and the
/// updater, drawn from fixed entitlements.
///
/// Every model here is a preview: `LicenseModel(previewing:)` reads and writes
/// nothing, ignores the page's `refresh()` and never asks the server, and
/// `SettingsModel(previewing:)` stands in for the window. `LicenseModel(defaults:)`
/// is never used — its first `refresh()` would read and heal the real trial
/// markers.
@MainActor
enum GalleryLicence {
    static let area = "Plans"

    static var states: [GalleryState] {
        [
            // A trial from before plans, running out on its own dates.
            GalleryState("L1", area, "Plans page: a trial from before plans", ground: .window, width: paneWidth) {
                plans(.trialing(daysRemaining: 10))
            },
            GalleryState("L2", area, "Trial ending (3 days or fewer)") {
                LicenseNoticeBanner(notice: .endingSoon(daysRemaining: 3))
                    .environment(LicenseModel(previewing: .trialing(daysRemaining: 3)))
            },
            // One day left is the last day: `resolve` never reports zero, it
            // reports `.free`.
            GalleryState("L3", area, "Last-day card") {
                LicenseNoticeBanner(notice: .endingSoon(daysRemaining: 1),
                                    tally: UsageTally(approvals: 41, answers: 9, dictations: 23))
                    .environment(LicenseModel(previewing: .trialing(daysRemaining: 1)))
            },
            // "You're on Free now", once, above the widgets. It took the place
            // of the screen that locked the panel when a trial ran out.
            GalleryState("L4", area, "You're on Free now: after the trial") {
                freeCard(PlanBefore(plan: PlanSnapshot(plan: .plus, isPaid: false), ending: .trial,
                                    endedOn: endedDay))
            },
            GalleryState("L4a", area, "You're on Free now: after Plus") {
                freeCard(PlanBefore(endedLicense: endedLicence(.plus)))
            },
            GalleryState("L4b", area, "You're on Free now: after Pro, no Apple Intelligence") {
                freeCard(PlanBefore(endedLicense: endedLicence(.pro)), macWritesNotes: false)
            },
            // A date still ahead: the key stopped checking out on this Mac
            // (moved to another, or refused) rather than running out.
            GalleryState("L4c", area, "You're on Free now: the key no longer works here") {
                freeCard(PlanBefore(plan: PlanSnapshot(plan: .plus, isPaid: true), ending: .subscription,
                                    endedOn: endedDay.addingTimeInterval(200 * 86_400)))
            },
            GalleryState("L5", area, "Payment overdue") {
                LicenseNoticeBanner(notice: .overdue)
                    .environment(LicenseModel(previewing: .overdue(licence)))
            },
            GalleryState("L6", area, "Plans page: grace period", ground: .window, width: paneWidth) {
                plans(.grace(licence))
            },
            GalleryState("L7", area, "Plans page: a key that isn't one", ground: .window, width: paneWidth) {
                plans(.free, rejection: .signature, enteringKey: true)
            },
            .notYet("L8", area, "Update available",
                    why: "Sparkle draws this window itself; the gallery never starts Sparkle."),
            .notYet("L9", area, "\"licence\" vs \"license\"",
                    why: "A spelling rule across the whole UI, not one screen."),
            GalleryOnboarding.permissionsAgain(area),
            GalleryState("L11", area, "Every \"See plans\" button in the island") {
                LicenseNoticeBanner(notice: .endingSoon(daysRemaining: 2))
                    .environment(LicenseModel(previewing: .trialing(daysRemaining: 2)))
            },
            GalleryState("L12", area, "Plans page: payment overdue", ground: .window, width: paneWidth) {
                plans(.overdue(licence))
            },
            // A subscription that ended keeps its key, so the page can offer
            // to check it again.
            GalleryState("L13", area, "Plans page: on Free after Plus ended", ground: .window, width: paneWidth) {
                plans(.free, subscribedBefore: true, stored: endedLicence(.plus))
            },
            GalleryState("L14", area, "Plans page: on Plus, more options and the privacy promise",
                         ground: .window, width: paneWidth) {
                plans(.licensed(licence), moreOptions: true)
            },
            GalleryState("L15", area, "Plans page: key for another Mac", ground: .window, width: paneWidth) {
                plans(.free, rejection: .otherMachine, enteringKey: true)
            },
            GalleryState("L16", area, "Plans page: build without keys", ground: .window, width: paneWidth) {
                plans(.free, activationError: LicenseModel.cannotCheckMessage, enteringKey: true)
            },
            GalleryState("L17", area, "Plans page: offline", ground: .window, width: paneWidth) {
                plans(.free, activationError: LicenseModel.unreachableMessage, enteringKey: true)
            },
            GalleryState("L18", area, "Plans page: Remove", ground: .window, width: paneWidth) {
                plans(.licensed(licence), confirmingRemove: true)
            },
            GalleryState("L19", area, "Plans page: on Free", ground: .window, width: paneWidth) {
                plans(.free)
            },
            // What the last-day card's monthly button opens.
            GalleryState("L19a", area, "Plans page: on Free, monthly prices", ground: .window, width: paneWidth) {
                plans(.free, period: .monthly)
            },
            GalleryState("L19b", area, "Plans page: on Pro", ground: .window, width: paneWidth) {
                plans(.licensed(proLicence))
            },
            GalleryState("L19c", area, "Plans page: a hand-issued key", ground: .window, width: paneWidth) {
                plans(.licensed(handIssued))
            },
            GalleryState("L19d", area, "Plans page: on Plus", ground: .window, width: paneWidth) {
                plans(.licensed(licence))
            },
            GalleryState("L19e", area, "Plans page: a hand-issued Pro key", ground: .window, width: paneWidth) {
                plans(.licensed(handIssuedPro))
            },
            GalleryState("L19f", area, "Plans page: a hand-issued key, Switch to Free pressed",
                         ground: .window, width: paneWidth) {
                plans(.licensed(handIssuedPro), goingFree: true)
            },
            GalleryState("L20", area, "Plans page: entering a key", ground: .window, width: paneWidth) {
                plans(.free, enteringKey: true)
            },
            GalleryState("L21", area, "Plans page: finish in your browser", ground: .window, width: paneWidth) {
                plans(.free) { $0.begin(.plus, .yearly) }
            },
            GalleryState("L21a", area, "Plans page: the payment page didn't open", ground: .window, width: paneWidth) {
                plans(.free) { $0.failToOpen(.pro, .monthly) }
            },
            GalleryState("L22", area, "Plans page: still waiting (3 min)", ground: .window, width: paneWidth) {
                plans(.free) { $0.begin(.plus, .yearly); $0.setStalled() }
            },
            // The key came back from the browser: the page is already on Plus.
            GalleryState("L23", area, "Plans page: you're on Plus", ground: .window, width: paneWidth) {
                plans(.licensed(licence)) { $0.begin(.plus, .yearly); $0.succeed() }
            },
            GalleryState("L23a", area, "Plans page: checked just now", ground: .window, width: paneWidth) {
                plans(.licensed(proLicence), lastCheck: .current(.pro))
            },
            GalleryState("L23b", area, "Plans page: the shop says it ended", ground: .window, width: paneWidth) {
                plans(.free, stored: endedLicence(.plus), lastCheck: .ended)
            },
            GalleryState("L23c", area, "Plans page: couldn't reach the server", ground: .window, width: paneWidth) {
                plans(.licensed(licence), lastCheck: .unreachable)
            },
            .notYet("L24", area, "Trial-ended dictation hold",
                    why: "Retired: nothing locks any more, so a hold is never turned away for the licence."),
            .notYet("L25", area, "Update dialogs",
                    why: "Sparkle draws these windows itself; the gallery never starts Sparkle."),
            // Settings › General › Updates, from the values the live updater
            // reports. Sparkle's own windows (L8, L25) stay Sparkle's.
            GalleryState("L26", area, "Updater didn't start", ground: .window, width: paneWidth) {
                updates(.didNotStart, canCheck: false)
            },
            GalleryState("L26a", area, "Update check didn't get through", ground: .window, width: paneWidth) {
                updates(.lastCheckFailed, canCheck: true)
            },
            GalleryState("L26b", area, "Update downloaded, installs on quit", ground: .window, width: paneWidth) {
                updates(.readyOnQuit(version: "1.5"), canCheck: true)
            },
            GalleryState("L26c", area, "Checking for updates", ground: .window, width: paneWidth) {
                updates(.quiet, canCheck: false)
            },
            // "Welcome to Plus", above the widgets, after a key for a bigger
            // plan goes in.
            GalleryState("L27", area, "Welcome to Plus") {
                welcome(.plus)
            },
            GalleryState("L27a", area, "Welcome to Pro") {
                welcome(.pro)
            },
            GalleryState("L27b", area, "Welcome to Plus: redo the last call's notes") {
                welcome(.plus, redo: .offered)
            },
            GalleryState("L27c", area, "Welcome to Pro: writing the notes again") {
                welcome(.pro, redo: .writing)
            },
            GalleryState("L27d", area, "Welcome to Plus: new notes written") {
                welcome(.plus, redo: .written)
            },
            GalleryState("L27e", area, "Welcome to Plus: offline, notes not redone") {
                welcome(.plus, redo: .said(CallNotesLibrary.said(.offline, plan: PlanSnapshot(plan: .plus,
                                                                                               isPaid: true)) ?? ""))
            },
            // Free's reminders: at most one a day, when the panel opens, in
            // the working blue with the stressed face. Never a sound.
            GalleryState("L28", area, "Free reminder: the clipboard let copies go (first time only)") {
                reminder(.clipboardFull)
            },
            GalleryState("L28a", area, "Free reminder: an agent asked in its terminal") {
                reminder(.agentInTerminal(asking: "website", answering: "storefront"))
            },
            GalleryState("L28b", area, "Free reminder: the month on Free") {
                reminder(.monthlyRecap(FreeMonth(month: endedDay, callsStopped: 3, copiesLetGo: 214,
                                                 agentsInTerminal: 6)))
            },
            GalleryState("L28c", area, "Free reminder: a month with one thing in it") {
                reminder(.monthlyRecap(FreeMonth(month: endedDay, callsStopped: 1)))
            },
            GalleryState("L28d", area, "Free reminder: a week in, using all three") {
                reminder(.firstWeek(uses: [.callNotes, .agents, .clipboard]))
            },
            GalleryState("L28e", area, "Free reminder: a week in, using only the clipboard") {
                reminder(.firstWeek(uses: [.clipboard]))
            },
        ]
    }

    // MARK: - Fixtures

    /// The settings window's detail column: 780 less the sidebar's 204.
    static let paneWidth: CGFloat = 576

    /// A yearly Plus bought in the shop (it has a shop key to check).
    private static let licence: License = {
        let renews = Date(timeIntervalSince1970: 1_822_000_000) // late Sep 2027
        return License(id: "lic_gallery", email: "someone@example.com", product: "airlock",
                       period: .yearly, issued: renews.addingTimeInterval(-365 * 86_400),
                       renewsAt: renews, checkBy: renews.addingTimeInterval(14 * 86_400), ref: "gallery")
    }()

    /// The same, issued by hand: nothing at the shop to check or manage.
    private static let handIssued: License = {
        let renews = Date(timeIntervalSince1970: 1_822_000_000)
        return License(id: "lic_gallery", email: "someone@example.com", product: "airlock",
                       period: .yearly, issued: renews.addingTimeInterval(-365 * 86_400),
                       renewsAt: renews, checkBy: renews.addingTimeInterval(14 * 86_400))
    }()

    private static let handIssuedPro: License = {
        let renews = Date(timeIntervalSince1970: 1_822_000_000)
        return License(id: "lic_gallery", email: "someone@example.com", product: "airlock",
                       period: .yearly, issued: renews.addingTimeInterval(-365 * 86_400),
                       renewsAt: renews, checkBy: renews.addingTimeInterval(14 * 86_400), plan: .pro)
    }()

    private static let proLicence: License = {
        let renews = Date(timeIntervalSince1970: 1_822_000_000)
        return License(id: "lic_gallery", email: "someone@example.com", product: "airlock",
                       period: .yearly, issued: renews.addingTimeInterval(-365 * 86_400),
                       renewsAt: renews, checkBy: renews.addingTimeInterval(14 * 86_400),
                       ref: "gallery", plan: .pro)
    }()

    /// The day a plan in the Free card ended: 15 November 2026, a morning.
    private static let endedDay = Date(timeIntervalSince1970: 1_794_733_200)

    private static func endedLicence(_ plan: License.Plan) -> License {
        License(id: "lic_gallery", email: "someone@example.com", product: "airlock", period: .monthly,
                issued: endedDay.addingTimeInterval(-30 * 86_400), renewsAt: endedDay,
                checkBy: endedDay.addingTimeInterval(14 * 86_400), plan: plan)
    }

    // MARK: - Drawing

    /// The Free card at the width of the panel's stack, a day after the plan
    /// ended.
    static func freeCard(_ before: PlanBefore, macWritesNotes: Bool = true) -> some View {
        let card = FreeCard.due(entitlement: .free, before: before, seen: false)!
        return MovedToFreeCard(card: card, macWritesNotes: macWritesNotes, onSeePlus: {}, onGotIt: {},
                               now: endedDay.addingTimeInterval(86_400))
    }

    /// Settings › Plans as the window shows it. `flow` puts the browser
    /// hand-off where a click would have left it.
    private static func plans(_ entitlement: Entitlement, period: License.Period = .yearly,
                              rejection: LicenseVerdict.Reason? = nil, activationError: String? = nil,
                              subscribedBefore: Bool = false, stored: License? = nil,
                              hasServer: Bool = true, lastCheck: PlanCheck? = nil,
                              confirmingRemove: Bool = false, enteringKey: Bool = false,
                              moreOptions: Bool = false, goingFree: Bool = false,
                              flow: (PurchaseFlow) -> Void = { _ in }) -> some View {
        let license = LicenseModel(previewing: entitlement, rejection: rejection,
                                   activationError: activationError,
                                   hasSubscribedBefore: subscribedBefore, stored: stored,
                                   hasServer: hasServer, lastCheck: lastCheck)
        license.plansPeriod = period
        flow(license.purchase)
        return PlansPane(confirmingRemove: confirmingRemove, enteringKey: enteringKey, moreOptions: moreOptions,
                         goingFree: goingFree)
            .environment(license)
            .environment(SettingsModel(previewing: [], policy: winBackPolicy))
            // The page scrolls, so it has no height of its own to fit.
            .frame(height: moreOptions ? 1180 : 1000)
    }

    /// Seven rules, so the win-back's "Your rules" has a number to read.
    private static var winBackPolicy: SettingsModel.PolicyInfo {
        let allow = ["Read", "Grep", "Bash(git status)", "Bash(swift build)", "Bash(npm test)"]
            .compactMap { try? PolicyRule(parsing: $0) }
        let deny = ["Bash(git push --force)", "Bash(rm -rf /)"].compactMap { try? PolicyRule(parsing: $0) }
        return SettingsModel.PolicyInfo(path: "~/.airlock/policy.yaml", exists: true, allow: allow, deny: deny,
                                        askTimeout: Policy.defaultAskTimeout, problems: [])
    }

    /// Settings › General › Updates. Also drawn by `GallerySettings` (X4).
    static func updates(_ status: UpdateStatus, canCheck: Bool) -> some View {
        LookColumn {
            UpdatesSection(checksAutomatically: .constant(true),
                           lastCheck: Date(timeIntervalSince1970: 1_790_000_000),
                           canCheck: canCheck,
                           statusLine: UpdateStatus.line(status, canCheck: canCheck))
        }
    }

    /// Settings › General's launch-at-login switch after macOS refused the
    /// change (X6), with the shipping sentence.
    static var launchAtLoginRefused: some View {
        LookColumn {
            LookToggleRow("Launch at login", isOn: .constant(false))
            LaunchAtLoginProblem(note: "Login Items couldn't be changed. Try it in System Settings › General › Login Items.")
        }
    }

    /// One of Free's reminder cards at the width of the panel's stack.
    private static func reminder(_ card: UpgradeReminder) -> some View {
        UpgradeReminderCard(reminder: card, onSeePlus: {}, onNotNow: {})
    }

    /// The welcome card at the width of the panel's stack. `redo` draws the
    /// row at that stage, for a call named the way the notch names one.
    private static func welcome(_ plan: AirlockPlan, redo: WelcomeCardView.Redo.Stage? = nil) -> some View {
        let card = WelcomeCard(plan)!
        let row = redo.map {
            WelcomeCardView.Redo(question: card.redoQuestion(title: "Budget review", when: "today", minutes: 42),
                                 stage: $0)
        }
        return WelcomeCardView(card: card, redo: row, onGotIt: {})
    }
}
