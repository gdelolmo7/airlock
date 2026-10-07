import SwiftUI
import AirlockCore

/// The card a new version opens the panel with, once. See `WhatsNew`.
///
/// Drawn like the in-panel setup (`PanelOnboardingView`) on purpose: the same
/// monospaced label, the same rows, the same button, so it reads as the app
/// talking rather than as a dialog that wandered in. It takes the panel the
/// way setup does, held open by `IslandPresentation.Holds.notes` until "Got it"
/// or an explicit collapse — both of which count as read.
///
/// **The cloud brings the news** (owner, 2026-10-07, on the first picture:
/// "too bland now… make it a bit more visual, add some motion"). It arrives
/// excited and hops once, a few sparkles twinkle round it, and the rows come
/// up one after another. Then everything rests, apart from the cloud's slow
/// blink: a card that keeps moving is asking for attention it already has.
///
/// **Every value here RESTS at the finished picture** and is knocked back
/// only to be animated home, never a keyframe track that starts empty. That
/// is the rule build 628 learned when a fade whose clock never ran in this
/// panel left the notch black: here a stalled animation skips the flourish
/// and the card is still all there. It is also why the gallery's still is
/// the finished card. Under Reduce Motion nothing moves but opacity.
struct WhatsNewCard: View {
    let card: WhatsNew.Card
    var onDismiss: () -> Void = {}
    /// Play the arrival. Off for the state gallery, which photographs a view
    /// the moment it appears and would catch the rows before they rise.
    var arrives = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 1 when a row is in place. One per row, so they can arrive in turn.
    @State private var rowArrival: [Double]
    /// The sparkles round the cloud: 1 in place, 0 not yet arrived.
    @State private var sparkleArrival: Double = 1
    /// The sparkles mid-twinkle. Rests false.
    @State private var twinkling = false

    /// The news colour: the blue the cloud wears while working, which in this
    /// app means "something is happening for you".
    private static let accent = BloubTint.working.color

    init(card: WhatsNew.Card, onDismiss: @escaping () -> Void = {}, arrives: Bool = true) {
        self.card = card
        self.onDismiss = onDismiss
        self.arrives = arrives
        _rowArrival = State(initialValue: Array(repeating: 1, count: card.items.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            VStack(spacing: 4) {
                ForEach(Array(card.items.enumerated()), id: \.offset) { index, item in
                    row(item)
                        .opacity(rowArrival[safe: index] ?? 1)
                        .offset(y: (1 - (rowArrival[safe: index] ?? 1)) * 8)
                }
            }

            // Lines left off a card that folds several updates together. Said,
            // so the short card is not mistaken for everything.
            if card.moreCount > 0 {
                Text(card.moreCount == 1 ? "and 1 more change" : "and \(card.moreCount) more changes")
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 7)
            }

            HStack {
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Text("Got it")
                        .font(Theme.chrome(12, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                                )
                        )
                        // Inside the label: `.plain` hit-tests the label's
                        // content, and a background does not extend it.
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .clickable()
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .task { await arrive() }
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: 14) {
            cloud
            VStack(alignment: .leading, spacing: 3) {
                Text(card.label)
                    .font(Theme.label)
                    .foregroundStyle(Self.accent)
                Text(card.title)
                    .font(Theme.chrome(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.top, 2)
    }

    /// The cloud with its sparkles. The hop is `BloubHop`, the same one a
    /// finished guide or a practice that got there plays, and it rests at
    /// the ground.
    private var cloud: some View {
        BloubView(expression: .excited, motion: .breathing, tint: Self.accent)
            .frame(width: 40)
            .bloubHop(when: true, lift: 6, onAppear: arrives)
            .overlay(alignment: .topTrailing) {
                sparkle(size: 9, angle: 0).offset(x: 9, y: -7)
            }
            .overlay(alignment: .topLeading) {
                sparkle(size: 6, angle: 18).offset(x: -8, y: -2)
            }
            .overlay(alignment: .bottomTrailing) {
                sparkle(size: 5, angle: -12).offset(x: 10, y: 3)
            }
            .padding(.vertical, 4)
    }

    private func sparkle(size: CGFloat, angle: Double) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .opacity(sparkleArrival * (twinkling ? 1 : 0.7))
            .scaleEffect(sparkleArrival * (twinkling ? 1.35 : 1))
            .rotationEffect(.degrees(angle + (twinkling ? 25 : 0)))
            .accessibilityHidden(true)
    }

    private func row(_ item: WhatsNew.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.accent)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Self.accent.opacity(0.16))
                )
            Text(item.text)
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.rowFill))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.rowStroke, lineWidth: 1)
        )
    }

    // MARK: - Arrival

    /// Once, when the card appears: the rows rise in turn while the cloud
    /// hops, then the sparkles twinkle three times and rest. `.task` cancels
    /// on disappear, and every value is put back at rest on the way out.
    @MainActor private func arrive() async {
        guard arrives, !reduceMotion else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            rowArrival = rowArrival.map { _ in 0 }
            sparkleArrival = 0
        }
        defer {
            withTransaction(instant) {
                rowArrival = rowArrival.map { _ in 1 }
                sparkleArrival = 1
                twinkling = false
            }
        }

        // After the panel has opened under it (Motion.open's settle).
        try? await Task.sleep(for: .seconds(0.18))
        withAnimation(Motion.confirm.animation(reduceMotion: false)) { sparkleArrival = 1 }
        for index in rowArrival.indices {
            guard !Task.isCancelled else { return }
            withAnimation(Motion.swap.animation(reduceMotion: false)) { rowArrival[index] = 1 }
            try? await Task.sleep(for: .seconds(0.09))
        }

        try? await Task.sleep(for: .seconds(0.35))
        for _ in 0..<3 {
            guard !Task.isCancelled else { return }
            withAnimation(MotionEffect.twinkleUp) { twinkling = true }
            try? await Task.sleep(for: .seconds(MotionEffect.twinkleUpDuration))
            withAnimation(MotionEffect.twinkleDown) { twinkling = false }
            try? await Task.sleep(for: .seconds(0.5))
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
