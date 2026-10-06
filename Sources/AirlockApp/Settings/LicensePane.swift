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

    /// `confirmingRemove` is the state gallery's: the question as it looks
    /// once Remove has been pressed.
    init(confirmingRemove: Bool = false) {
        _confirmingRemove = State(initialValue: confirmingRemove)
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
        Form {
            Section("Status") { status }

            // Only for somebody with no subscription. An overdue one is a
            // subscription with a payment problem, and offering it a second,
            // brand-new subscription is how people end up billed twice.
            if license.entitlement.license == nil {
                Section("Subscribe") {
                    LabeledContent("Yearly") {
                        Button(License.Period.yearly.price) { open(.yearly) }
                            .buttonStyle(.borderedProminent)
                    }
                    LabeledContent("Monthly") {
                        Button(License.Period.monthly.price) { open(.monthly) }
                    }
                    Text(Self.pitch)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Licence key") {
                // A licence is in: nothing to paste, so no field and no
                // Activate — a disabled button under an empty box asked "what
                // is this for?" on the one screen where everything is already
                // fine. Overdue counts: the key is in, it is the payment that
                // needs sorting. Remove stays, with the sentence that explains
                // why it exists.
                if license.entitlement.license != nil {
                    LabeledContent("This Mac") {
                        Button("Remove…") { confirmingRemove = true }
                            .disabled(confirmingRemove)
                    }
                    .settingsAnchor(.licenceKey)
                    if confirmingRemove { removeQuestion }
                    Text("Removes the licence from this Mac only — the subscription itself is untouched. One licence covers one Mac; to move it, write to hello@useairlock.app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // `labelsHidden` + `prompt`, not a title: a titled field in a
                    // Form is laid out as label-left, field-right, which halved
                    // the width and wrapped a 36-character key onto two lines.
                    // Minimum ONE line, not two — a key fits on one; a pasted
                    // token, which can be ~400 bytes, still grows to four.
                    TextField("Licence key", text: $draft,
                              prompt: Text("Paste the key from your purchase email"),
                              axis: .vertical)
                        .settingsAnchor(.licenceKey)
                        .labelsHidden()
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                    HStack {
                        Button(license.isActivating ? "Activating…" : "Activate") { activate() }
                            .buttonStyle(.borderedProminent)
                            .disabled(license.isActivating
                                      || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if license.isActivating {
                            WaitingIndicator(words: "Checking your key with the shop…")
                        } else if !license.token.isEmpty {
                            Button("Remove…") { confirmingRemove = true }
                                .disabled(confirmingRemove)
                        }
                    }
                    if confirmingRemove { removeQuestion }
                }
                // Two sources, one place to look: a key that does not verify
                // here, and a key the licence server would not take.
                if let problem = license.activationError ?? license.rejection.map(message(for:)) {
                    ProblemCard(sentence: problem)
                }
            }

            Section("Privacy") {
                Text(Self.privacy)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { license.refresh() }
    }

    @ViewBuilder
    private var status: some View {
        switch license.entitlement {
        case .free:
            // Not reached while Settings hides this page for a free app; here
            // so the page is never blank if it is opened anyway.
            Label("Airlock is free", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Color.green)

        case .licensed(let licence), .grace(let licence):
            // Grace deliberately reads the same as licensed. The renewal date
            // below is the only difference, and it tells the truth — somebody
            // who opens this page to check on their subscription deserves the
            // real date rather than reassurance.
            Label("Subscribed", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Color.green)
            LabeledContent("Issued to") { Text(licence.email).foregroundStyle(.secondary) }
            LabeledContent("Plan") { Text(licence.period.label).foregroundStyle(.secondary) }
            LabeledContent("Renews") {
                Text(licence.renewsAt.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.secondary)
            }

        case .trialing(let days):
            Label(days == 1 ? "1 day left in your trial" : "\(days) days left in your trial",
                  systemImage: "clock")
            // Says what happens AFTERWARDS, which is the question somebody
            // counting days is actually asking. It is also the reassuring
            // The honest answer now that the whole app is paid. The previous
            // version of this paragraph described a free tier that no longer
            // exists — it promised the clipboard, the shelf, media, sound and
            // the calendar would carry on.
            Text("Everything works during the trial — nothing is held back, so what you are trying is exactly what you would be subscribing to. Afterwards the panel still opens and tells you where you stand, but it stops doing the work until you subscribe. Nothing you have saved is deleted. No card up front, and nothing to cancel if you stop here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .trialExpired where license.hasSubscribedBefore:
            // A returning customer, not a stranger. Telling somebody who used to
            // pay that "your trial has ended" addresses them as a new user and
            // gets the fact wrong as well.
            Label("Welcome back", systemImage: "hand.wave")
            Text("Your subscription ended, and nothing was deleted while you were gone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Read from the stores rather than promised: none of this is
            // licence-gated, so these are facts about the disk and not
            // reassurance somebody has to take on trust.
            LabeledContent("Your rules") {
                Text("\(settings.policy.allow.count + settings.policy.deny.count) kept")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Shelf and clipboard") {
                Text("untouched").foregroundStyle(.secondary)
            }
            LabeledContent("Keys, widgets, panel width") {
                Text("as you left them").foregroundStyle(.secondary)
            }
            Text("No second trial, and no discount for having left — the price is the price either way.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .trialExpired:
            Label("Your trial has ended", systemImage: "clock.badge.xmark")
                .foregroundStyle(Color.orange)
            // This named what stopped and what did not, back when the paywall
            // took the agent surface and left the rest. It has not been true
            // since `allowsAgentActions` became `allowsUse` and the panel
            // started showing a paywall instead of widgets — the clipboard and
            // the shelf stop too. A promise the build does not keep is worse
            // than the blunt sentence, so say the blunt one.
            Text("Airlock needs a subscription to keep going. Your clipboard history, your shelf and your settings are all still here, and come straight back when you subscribe.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Subscribe below, or paste a key if you already have one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .overdue(let licence):
            Label("Your subscription needs renewing", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(Color.orange)
            LabeledContent("Issued to") { Text(licence.email).foregroundStyle(.secondary) }
            // No second Subscribe here (see the section above) and no invented
            // payment link: the way to fix a card is the shop's own email, and
            // a person who can't find it can write in.
            Text("Still running, and your key is still here. Airlock hasn't been able to confirm your last payment — once it's sorted, this clears itself the next time Airlock can reach the licence server. Not sure how to fix it? Write to hello@useairlock.app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The pitch, for somebody deciding. It sold agents alone, which is the
    /// part most people will never use — the guide and the notch are what
    /// everybody gets.
    static let pitch = "One subscription covers all of Airlock: the guide that helps with everyday tasks on screen, dictation, the notch's widgets, and approving your coding agents. Cancel whenever you like — it keeps working until the end of the period you paid for."

    /// What leaves this Mac for the licence, and when. It promised "no
    /// identifiers" while activation sends this Mac's hardware ID — the one
    /// licence, one Mac rule cannot work without it — so it now says so.
    static let privacy = "Your key is checked on this Mac. Airlock contacts the licence server when you activate a key and in the days around your renewal date — a few times a year on the yearly plan — and never otherwise. It sends your key and a code that identifies this Mac, so one licence stays on one Mac. Nothing about what you do with Airlock is sent, and in between everything works offline."

    /// Remove, asked about in place rather than in a pop-up.
    private var removeQuestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remove the licence from this Mac? Your subscription isn't affected, and you can paste the key again at any time.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Remove", role: .destructive) {
                    confirmingRemove = false
                    license.removeLicense()
                    draft = ""
                }
                Button("Keep it") { confirmingRemove = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
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
