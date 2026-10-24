import AirlockCore
import SwiftUI

/// "Welcome to Plus": once, above the widgets, after a key for a bigger plan
/// goes in (`WelcomeCard`). What just unlocked, in the plan card's own words,
/// and an offer to write the last call's notes again with the better model.
///
/// It waits in the notch rather than opening it: paying is not something the
/// island needs an answer to, so the card is there the next time the notch
/// opens, until "Got it".
struct WelcomeCardView: View {
    let card: WelcomeCard
    /// The offer to write the last call's notes again; nil for no row.
    var redo: Redo?
    var onRedo: () -> Void = {}
    /// "Not now" on the redo row: the row goes, the card stays.
    var onNotNow: () -> Void = {}
    /// "Open notes", once the new notes are written.
    var onOpenNotes: () -> Void = {}
    /// Marks the card read, so it never comes back for this plan.
    var onGotIt: () -> Void

    struct Redo: Equatable {
        let question: String
        /// Under the question while it is offered.
        var reason: String = WelcomeCard.redoReason
        var stage: Stage = .offered

        enum Stage: Equatable {
            case offered
            case writing
            case written
            /// It didn't happen, and why, in the notes window's words.
            case said(String)
        }
    }

    private var tint: Color { PlanTag.text(card.plan) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.label.lowercased())
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(tint)
                    Text(card.title)
                        .font(Theme.chrome(16, .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 8)
                BloubView(expression: .happy, motion: .breathing)
                    .frame(width: 34)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .offset(x: 8, y: -6)
                    }
                    .accessibilityHidden(true)
            }
            .padding(.bottom, 4)

            ForEach(card.rows, id: \.sentence) { row($0) }

            if let redo { redoRow(redo) }

            HStack {
                Spacer(minLength: 0)
                Button(action: onGotIt) {
                    Text("Got it")
                        .font(Theme.chrome(12, .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.92)))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .clickable()
                .fixedSize()
                .accessibilityHint("Closes this card. It won't come back.")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func row(_ row: WelcomeCard.Row) -> some View {
        HStack(spacing: 10) {
            icon(row.symbol, tint: PlanTag.tint(card.plan))
            Text(row.sentence)
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(box)
    }

    private func redoRow(_ redo: Redo) -> some View {
        HStack(spacing: 10) {
            icon(redo.stage == .written ? "checkmark" : "arrow.clockwise",
                 tint: redo.stage == .written ? Theme.done : Theme.assistant)
            VStack(alignment: .leading, spacing: 2) {
                Text(redo.stage == .written ? String(localized: "New notes are on the call's page.") : redo.question)
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    switch redo.stage {
                    case .offered: Text(redo.reason)
                    case .writing: WaitingIndicator(words: String(localized: "Writing them online…"), wordsFromStart: true)
                    case .written: EmptyView()
                    case .said(let why): Text(why)
                    }
                }
                .font(Theme.chrome(10.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            switch redo.stage {
            case .offered:
                quietButton(String(localized: "Redo"), filled: true, action: onRedo)
                quietButton(String(localized: "Not now"), filled: false, action: onNotNow)
            case .written:
                quietButton(String(localized: "Open notes"), filled: true, action: onOpenNotes)
            case .writing, .said:
                EmptyView()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(box)
    }

    private func icon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.14)))
            .accessibilityHidden(true)
    }

    private var box: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func quietButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.chrome(11.5, .semibold))
                .foregroundStyle(filled ? Color.black : Theme.textSecondary)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(filled ? Color.white.opacity(0.92) : Color.clear))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
        .fixedSize()
    }
}

/// The card where the notch shows it: finds the call to offer, and runs the
/// redo. Kept apart from the card so the state gallery can draw every stage
/// of the row without a call on disk.
struct WelcomeCardSlot: View {
    let card: WelcomeCard
    let meetings: MeetingNotesModel
    /// The plan now, for which calls can be redone and what a refusal says.
    let plan: PlanSnapshot
    var onGotIt: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var call: URL?
    @State private var redo: WelcomeCardView.Redo?

    var body: some View {
        WelcomeCardView(card: card, redo: redo, onRedo: start,
                        onNotNow: { withAnimation(Motion.close.animation(reduceMotion: reduceMotion)) { redo = nil } },
                        onOpenNotes: { if let call { meetings.showCall(folder: call.lastPathComponent) } },
                        onGotIt: onGotIt)
            .task(id: card) {
                // A Free call locked past 30 minutes opens on the new plan
                // first, so the redo offered is of the whole call.
                await CallUnlockService.shared.look()
                guard let found = await meetings.welcomeRedo(plan: plan) else { return }
                call = found.folder
                redo = WelcomeCardView.Redo(question: card.redoQuestion(for: found.record),
                                            reason: WelcomeCard.redoReason(for: found.record))
            }
    }

    private func start() {
        guard let call, redo?.stage == .offered else { return }
        redo?.stage = .writing
        Task { @MainActor in
            let result = await meetings.redoNotes(in: call)
            guard redo != nil else { return }
            if let said = CallNotesLibrary.said(result, plan: plan) {
                redo?.stage = .said(said)
            } else {
                redo?.stage = .written
            }
        }
    }
}
