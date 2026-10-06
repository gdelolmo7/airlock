import SwiftUI
import AirlockCore

/// The licence rows (L), drawn from fixed entitlements.
///
/// Every model here is a preview: `LicenseModel(previewing:)` reads and writes
/// nothing and ignores the pane's `refresh()`, and `SettingsModel(previewing:)`
/// stands in for the one figure the win-back reads. `LicenseModel(defaults:)`
/// is never used — its first `refresh()` would start a trial on disk.
@MainActor
enum GalleryLicence {
    static let area = "Licence"

    static var states: [GalleryState] {
        [
            GalleryState("L1", area, "Trial, 4–14 days left", ground: .window, width: paneWidth) {
                pane(.trialing(daysRemaining: 10))
            },
            GalleryState("L2", area, "Trial ending (3 days or fewer)") {
                LicenseNoticeBanner(notice: .endingSoon(daysRemaining: 3))
                    .environment(LicenseModel(previewing: .trialing(daysRemaining: 3)))
            },
            // One day left is the last day: `resolve` never reports zero, it
            // reports `.trialExpired`.
            GalleryState("L3", area, "Last-day card") {
                LicenseNoticeBanner(notice: .endingSoon(daysRemaining: 1),
                                    tally: UsageTally(approvals: 41, answers: 9, dictations: 23))
                    .environment(LicenseModel(previewing: .trialing(daysRemaining: 1)))
            },
            GalleryState("L4", area, "Trial ended") {
                LicenseBlockedView(onSubscribe: {}, surface: LicenseBlockedView.panel)
            },
            GalleryState("L4a", area, "Subscription ended (subscribed before)") {
                LicenseBlockedView(onSubscribe: {}, surface: LicenseBlockedView.panel, subscribedBefore: true)
            },
            GalleryState("L5", area, "Payment overdue") {
                LicenseNoticeBanner(notice: .overdue)
                    .environment(LicenseModel(previewing: .overdue(licence)))
            },
            GalleryState("L6", area, "Grace period", ground: .window, width: paneWidth) {
                pane(.grace(licence))
            },
            GalleryState("L7", area, "Bad key / other Mac / offline", ground: .window, width: paneWidth) {
                pane(.trialing(daysRemaining: 10), token: "", rejection: .signature)
            },
            .notYet("L8", area, "Update available",
                    why: "Sparkle draws this window itself; the gallery never starts Sparkle."),
            .notYet("L9", area, "\"licence\" vs \"license\"",
                    why: "A spelling rule across the whole UI, not one screen."),
            GalleryOnboarding.permissionsAgain(area),
            GalleryState("L11", area, "Every \"Subscribe\" button in the island") {
                LicenseNoticeBanner(notice: .endingSoon(daysRemaining: 2))
                    .environment(LicenseModel(previewing: .trialing(daysRemaining: 2)))
            },
            GalleryState("L12", area, "Payment overdue — what you're offered", ground: .window, width: paneWidth) {
                pane(.overdue(licence), token: "lic_gallery")
            },
            GalleryState("L13", area, "Ended after subscribing before", ground: .window, width: paneWidth) {
                pane(.trialExpired, subscribedBefore: true)
            },
            GalleryState("L14", area, "Licence page: privacy promise", ground: .window, width: paneWidth) {
                pane(.licensed(licence), token: "lic_gallery")
            },
            GalleryState("L15", area, "Licence page: key for another Mac", ground: .window, width: paneWidth) {
                pane(.trialing(daysRemaining: 10), rejection: .otherMachine)
            },
            GalleryState("L16", area, "Licence page: build without keys", ground: .window, width: paneWidth) {
                pane(.trialing(daysRemaining: 10), activationError: LicenseModel.cannotCheckMessage)
            },
            GalleryState("L17", area, "Licence page: offline", ground: .window, width: paneWidth) {
                pane(.trialing(daysRemaining: 10),
                     activationError: LicenseModel.unreachableMessage(keepsWorking: true))
            },
            GalleryState("L18", area, "Licence page: Remove", ground: .window, width: paneWidth) {
                pane(.licensed(licence), token: "lic_gallery", confirmingRemove: true)
            },
            GalleryState("L19", area, "Licence page: the pitch", ground: .window, width: paneWidth) {
                pane(.trialExpired)
            },
            GalleryState("L20", area, "Purchase window: choose a plan", ground: .window, width: purchaseWidth) {
                purchase(PurchaseFlow())
            },
            GalleryState("L21", area, "Purchase window: finish in your browser", ground: .window, width: purchaseWidth) {
                purchase(flow { $0.begin(plan: .yearly) })
            },
            GalleryState("L21a", area, "Purchase window: the payment page didn't open",
                         ground: .window, width: purchaseWidth) {
                purchase(flow { $0.failToOpen(plan: .yearly) })
            },
            GalleryState("L22", area, "Purchase window: still waiting (3 min)", ground: .window, width: purchaseWidth) {
                purchase(flow { $0.begin(plan: .yearly); $0.setStalled() })
            },
            GalleryState("L23", area, "Purchase window: you're subscribed", ground: .window, width: purchaseWidth) {
                purchase(flow { $0.begin(plan: .yearly); $0.succeed() }, pendingGate: "git push origin main")
            },
            GalleryState("L24", area, "Trial-ended dictation hold") {
                HoldNoticeCard(notice: .noSubscription)
            },
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
        ]
    }

    // MARK: - Fixtures

    /// The settings window's detail column: 780 less the sidebar's 204.
    static let paneWidth: CGFloat = 576
    /// `PurchaseView`'s own frame.
    private static let purchaseWidth: CGFloat = 460

    private static let licence: License = {
        let renews = Date(timeIntervalSince1970: 1_822_000_000) // late Sep 2027
        return License(id: "lic_gallery", email: "someone@example.com", product: "airlock",
                       period: .yearly, issued: renews.addingTimeInterval(-365 * 86_400),
                       renewsAt: renews, checkBy: renews.addingTimeInterval(14 * 86_400))
    }()

    // MARK: - Drawing

    private static func pane(_ entitlement: Entitlement, token: String = "",
                             rejection: LicenseVerdict.Reason? = nil, activationError: String? = nil,
                             subscribedBefore: Bool = false, confirmingRemove: Bool = false) -> some View {
        LicensePane(confirmingRemove: confirmingRemove)
            .environment(LicenseModel(previewing: entitlement, token: token, rejection: rejection,
                                      activationError: activationError,
                                      hasSubscribedBefore: subscribedBefore))
            .environment(SettingsModel(previewing: [], policy: winBackPolicy))
            // A grouped Form scrolls, so it has no height of its own to fit.
            .frame(height: entitlement.isPaid ? 500 : entitlement == .trialExpired ? 780 : 720)
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
        Form {
            UpdatesSection(checksAutomatically: .constant(true),
                           lastCheck: Date(timeIntervalSince1970: 1_790_000_000),
                           canCheck: canCheck,
                           statusLine: UpdateStatus.line(status, canCheck: canCheck))
        }
        .formStyle(.grouped)
        .frame(height: 375)
    }

    /// Settings › General's launch-at-login switch after macOS refused the
    /// change (X6), with the shipping sentence.
    static var launchAtLoginRefused: some View {
        Form {
            Section("When should Airlock start?") {
                Toggle("Launch at login", isOn: .constant(false))
                LaunchAtLoginProblem(note: "Login Items couldn't be changed. Try it in System Settings › General › Login Items.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 185)
    }

    private static func flow(_ steps: (PurchaseFlow) -> Void) -> PurchaseFlow {
        let flow = PurchaseFlow()
        steps(flow)
        return flow
    }

    private static func purchase(_ flow: PurchaseFlow, pendingGate: String? = nil) -> some View {
        PurchaseView(flow: flow, tally: UsageTally(approvals: 41, answers: 9, dictations: 23),
                     onBuy: { _ in }, onPasteKey: {}, onDismiss: {}, pendingGate: pendingGate)
    }
}
