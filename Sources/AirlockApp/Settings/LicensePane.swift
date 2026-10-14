import AirlockCore
import SwiftUI

/// Trial status, licence entry, and where to subscribe.
///
/// Deliberately never scolds. A finished trial is a request, not an accusation,
/// and someone whose payment did not go through is a customer rather than a
/// suspect — so the worst thing on this page is an amber label.
struct LicensePane: View {
    @Environment(LicenseModel.self) private var license
    /// Only for the win-back's rule count — the one figure on that screen that
    /// is read rather than asserted.
    @Environment(SettingsModel.self) private var settings
    @State private var draft = ""
    /// Remove asks first. It used to act on the first click, and the key it
    /// throws away is in an email somebody may not be able to find.
    @State private var confirmingRemove: Bool
    @State private var moreOptions: Bool

    /// `confirmingRemove` is the state gallery's: the question as it looks
    /// once Remove has been pressed.
    init(confirmingRemove: Bool = false, moreOptions: Bool = false) {
        _confirmingRemove = State(initialValue: confirmingRemove)
        _moreOptions = State(initialValue: moreOptions)
    }

    /// Through the model, never a local copy.
    ///
    /// This pane used to hold its own pair of store URLs, under a comment
    /// saying they lived here "so the buy links move in one place" — while
    /// `LicenseModel.checkoutURL(for:)` carried the same two under a comment
    /// saying the same thing. Two single sources of truth is none, and the day
    /// they diverge is the day the store moves.
    private func open(_ period: License.Period) {
        guard let url = license.checkoutURL(for: period) else { return }
        NSWorkspace.shared.open(url)
    }

    var body: some View {
        LookPage("Licence", subtitle: "Your trial or subscription, and your key.", moreOptions: $moreOptions) {
            LookGroupLabel("Status")
            status

            // Only for somebody with no subscription. An overdue one is a
            // subscription with a payment problem, and offering it a second,
            // brand-new subscription is how people end up billed twice.
            if license.entitlement.license == nil {
                LookGroupLabel("Subscribe")
                LookRow("Yearly") {
                    LookButton(License.Period.yearly.price, prominent: true) { open(.yearly) }
                }
                LookRow("Monthly") {
                    LookButton(License.Period.monthly.price) { open(.monthly) }
                }
            }

            LookGroupLabel("Licence key")
            keyRows
            // Two sources, one place to look: a key that does not verify
            // here, and a key the licence server would not take.
            if let problem = license.activationError ?? license.rejection.map(message(for:)) {
                ProblemCard(sentence: problem)
            }
        } more: {
            if license.entitlement.license == nil {
                LookGroupLabel("Subscribe")
                LookNote(Self.pitch(guide: GuideSwitch.isOn))
            }
            statusNotes
            if license.entitlement.license != nil {
                LookGroupLabel("Licence key")
                LookNote("Remove takes the licence off this Mac only — the subscription itself is untouched. "
                         + "One licence covers one Mac; to move it, write to hello@useairlock.app.")
            }
            LookGroupLabel("Privacy")
            LookNote(Self.privacy)
        }
        .onAppear { license.refresh() }
    }

    @ViewBuilder
    private var keyRows: some View {
        // A licence is in: nothing to paste, so no field and no Activate — a
        // disabled button under an empty box asked "what is this for?" on the
        // one screen where everything is already fine. Overdue counts: the key
        // is in, it is the payment that needs sorting.
        if license.entitlement.license != nil {
            LookRow("This Mac", subtitle: "Your subscription isn't affected by removing it") {
                LookButton("Remove…") { confirmingRemove = true }
                    .disabled(confirmingRemove)
            }
            .settingsAnchor(.licenceKey)
            if confirmingRemove { removeQuestion }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // `labelsHidden` + `prompt`, not a title. Minimum ONE line,
                // not two — a key fits on one; a pasted token, which can be
                // ~400 bytes, still grows to four.
                TextField("Licence key", text: $draft,
                          prompt: Text("Paste the key from your purchase email"),
                          axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.chrome(12).monospaced())
                HStack(spacing: 8) {
                    LookButton(license.isActivating ? "Activating…" : "Activate", prominent: true) { activate() }
                        .disabled(license.isActivating
                                  || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if license.isActivating {
                        WaitingIndicator(words: "Checking your key with the shop…")
                    } else if !license.token.isEmpty {
                        LookButton("Remove…") { confirmingRemove = true }
                            .disabled(confirmingRemove)
                    }
                    Spacer(minLength: 0)
                }
            }
            .lookRowBox()
            .settingsAnchor(.licenceKey)
            if confirmingRemove { removeQuestion }
        }
    }

    /// The state in one row, with the facts that go with it.
    @ViewBuilder
    private var status: some View {
        switch license.entitlement {
        case .free:
            // Not reached while Settings hides this page for a free app; here
            // so the page is never blank if it is opened anyway.
            statusRow("Airlock is free", symbol: "checkmark.seal.fill", tint: Theme.done)

        case .licensed(let licence), .grace(let licence):
            // Grace deliberately reads the same as licensed. The renewal date
            // is the only difference, and it tells the truth — somebody who
            // opens this page to check on their subscription deserves the real
            // date rather than reassurance.
            statusRow("Subscribed", symbol: "checkmark.seal.fill", tint: Theme.done)
            LookRow("Issued to") { LookValue(licence.email) }
            LookRow("Plan") { LookValue(licence.period.label) }
            LookRow("Renews") { LookValue(licence.renewsAt.formatted(date: .abbreviated, time: .omitted)) }

        case .trialing(let days):
            statusRow(days == 1 ? "1 day left in your trial" : "\(days) days left in your trial",
                      subtitle: "Everything works, and no card is needed",
                      symbol: "clock", tint: Theme.textSecondary)

        case .trialExpired where license.hasSubscribedBefore:
            // A returning customer, not a stranger. Telling somebody who used to
            // pay that "your trial has ended" addresses them as a new user and
            // gets the fact wrong as well.
            statusRow("Welcome back", subtitle: "Your subscription ended, and nothing was deleted while you were gone",
                      symbol: "hand.wave", tint: Theme.textSecondary)
            // Read from the stores rather than promised: none of this is
            // licence-gated, so these are facts about the disk and not
            // reassurance somebody has to take on trust.
            LookRow("Your rules") { LookValue("\(settings.policy.allow.count + settings.policy.deny.count) kept") }
            LookRow("Shelf and clipboard") { LookValue("untouched") }
            LookRow("Keys, widgets, panel width") { LookValue("as you left them") }

        case .trialExpired:
            // This once named what stopped and what did not, back when the
            // paywall took only the agent surface. The clipboard and the shelf
            // stop too now, and a promise the build does not keep is worse than
            // the blunt sentence, so say the blunt one.
            statusRow("Your trial has ended", subtitle: "Subscribe below, or paste a key if you already have one",
                      symbol: "clock.badge.xmark", tint: Theme.needs)
            LookNote("Airlock needs a subscription to keep going. Your clipboard history, your shelf and your "
                     + "settings are all still here, and come straight back when you subscribe.")

        case .overdue(let licence):
            statusRow("Your subscription needs renewing", subtitle: "Still running, and your key is still here",
                      symbol: "clock.badge.exclamationmark", tint: Theme.needs)
            LookRow("Issued to") { LookValue(licence.email) }
            // No second Subscribe here (see above) and no invented payment
            // link: the way to fix a card is the shop's own email, and a person
            // who can't find it can write in.
            LookNote("Airlock hasn't been able to confirm your last payment — once it's sorted, this clears "
                     + "itself the next time Airlock can reach the licence server. Not sure how to fix it? "
                     + "Write to hello@useairlock.app.")
        }
    }

    /// The long sentences behind the status, for More options.
    @ViewBuilder
    private var statusNotes: some View {
        switch license.entitlement {
        case .trialing:
            // Says what happens AFTERWARDS, which is the question somebody
            // counting days is actually asking. The previous version described
            // a free tier that no longer exists.
            LookGroupLabel("Status")
            LookNote("Everything works during the trial — nothing is held back, so what you are trying is exactly "
                     + "what you would be subscribing to. Afterwards the panel still opens and tells you where you "
                     + "stand, but it stops doing the work until you subscribe. Nothing you have saved is deleted. "
                     + "No card up front, and nothing to cancel if you stop here.")
        case .trialExpired where license.hasSubscribedBefore:
            LookGroupLabel("Status")
            LookNote("No second trial, and no discount for having left — the price is the price either way.")
        default:
            EmptyView()
        }
    }

    private func statusRow(_ title: String, subtitle: String? = nil, symbol: String, tint: Color) -> some View {
        LookRow(title, subtitle: subtitle) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
        }
    }

    /// The pitch, for somebody deciding. It sold agents alone, which is the
    /// part most people will never use — the notch is what everybody gets.
    /// The guide is named only in a copy that has it.
    static func pitch(guide: Bool) -> String {
        let covers = guide
            ? "the guide that helps with everyday tasks on screen, dictation, the notch's widgets, and approving your coding agents"
            : "dictation, the notch's widgets, and approving your coding agents"
        return "One subscription covers all of Airlock: \(covers). Cancel whenever you like — it keeps working until the end of the period you paid for."
    }

    /// What leaves this Mac for the licence, and when. It promised "no
    /// identifiers" while activation sends this Mac's hardware ID — the one
    /// licence, one Mac rule cannot work without it — so it now says so.
    static let privacy = "Your key is checked on this Mac. Airlock contacts the licence server when you activate a key and in the days around your renewal date — a few times a year on the yearly plan — and never otherwise. It sends your key and a code that identifies this Mac, so one licence stays on one Mac. Nothing about what you do with Airlock is sent, and in between everything works offline."

    /// Remove, asked about in place rather than in a pop-up.
    private var removeQuestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remove the licence from this Mac? Your subscription isn't affected, and you can paste the key again at any time.")
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                LookButton("Remove") {
                    confirmingRemove = false
                    license.removeLicense()
                    draft = ""
                }
                LookButton("Keep it", prominent: true) { confirmingRemove = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lookRowBox()
    }

    private func activate() {
        Task { if await license.apply(draft) { draft = "" } }
    }

    /// Say what is actually wrong. "Invalid licence" for a key that is simply
    /// for another product sends somebody to support for no reason.
    private func message(for reason: LicenseVerdict.Reason) -> String {
        switch reason {
        case .otherMachine:
            // 2b's third sentence, and the one that must not read as an
            // accusation. One licence covers one Mac; that is the deal, not a
            // fault, and the way out is stated rather than left to support.
            //
            // It said "move it across in Settings there", which Remove on the
            // other Mac does not do: the seat stays claimed with the shop, and
            // the line under Remove already says to write in.
            return "This licence is already set up on another Mac. One licence covers one Mac — to move it here, write to hello@useairlock.app, or subscribe again for this Mac."
        case .malformed:
            return "That doesn't look like a licence key. Copy the whole line from your purchase email."
        case .signature:
            return "That licence wasn't recognised. Copy it again from your purchase email, or write to hello@useairlock.app."
        case .wrongProduct:
            return "That licence is for a different product."
        }
    }
}
