import SwiftUI

/// Every problem state's one look: an icon, one sentence, at most one button
/// named after what it does (`docs/how-airlock-talks.md`, card B1).
///
/// The shape is the licence banner's line, which was already the app's
/// calmest way to say "something needs you": the tint on a tenth-strength
/// fill, and the button as a capsule at the end. Problems drawn this way read
/// as siblings wherever they appear — the Shelf, the Agents tab, the guide,
/// Settings — instead of each widget inventing red text of its own.
///
/// With a button, the whole card is the button: a small target at the end of
/// a sentence is the hard one to hit, and there is only one thing to do.
struct ProblemCard: View {
    enum Tone {
        /// Something needs doing; nothing is lost. The usual one.
        case needs
        /// Something did not happen and will not until it is fixed.
        case stopped
        /// Nothing is wrong; something is worth knowing — where your words
        /// went, why a hold took longer. Blue rather than amber, so news about
        /// something that worked is not read as one more warning.
        case note

        var tint: Color {
            switch self {
            case .needs: return Theme.needs
            case .stopped: return Theme.danger
            case .note: return Theme.running
            }
        }
    }

    var icon: String = "exclamationmark.circle"
    let sentence: String
    var tone: Tone = .needs
    var button: String?
    var action: (() -> Void)?

    /// Which surface it is drawn on. Set once per window (Settings sets
    /// `.settings` at its root), never per call, so a problem written once
    /// looks right wherever it lands.
    @Environment(\.problemCardLook) private var look

    var body: some View {
        switch look {
        case .notch: notchCard
        case .settings: settingsLine
        }
    }

    /// Settings is a system form: system type and colours, the triangle the
    /// form's other warnings already used, and the button as a plain bordered
    /// one beside the sentence — a capsule there would be the only one.
    private var settingsLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(sentence, systemImage: settingsSymbol)
                .font(.callout)
                .foregroundStyle(settingsColour)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let button, let action {
                Button(button, action: action)
            }
        }
    }

    private var settingsSymbol: String {
        switch tone {
        case .needs: return "exclamationmark.triangle.fill"
        case .stopped: return "exclamationmark.octagon.fill"
        case .note: return "info.circle.fill"
        }
    }

    private var settingsColour: Color {
        switch tone {
        case .needs: return .orange
        case .stopped: return .red
        case .note: return .secondary
        }
    }

    @ViewBuilder private var notchCard: some View {
        let card = ProblemCardRow {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(sentence)
                .font(Theme.chrome(11, .medium))
            if let button, action != nil {
                Text(button)
                    .font(Theme.chrome(11, .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    // Not a Capsule: an outlined capsule drew a short bar
                    // outside each round end, which read as the button's sides
                    // being cut off. Corners just under half the button's
                    // height look the same and draw clean.
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tone.tint.opacity(0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(tone.tint.opacity(0.28), lineWidth: 1))
            }
        }
        .foregroundStyle(tone.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(tone.tint.opacity(0.10)))

        if let action, let button {
            card
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .clickable()
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(button)
                .accessibilityAction { action() }
        } else {
            card.accessibilityElement(children: .combine)
        }
    }
}

/// The notch card's icon, sentence and button. The button sits at the end of
/// the sentence while the sentence keeps a readable width, and moves under it
/// when it would not: in a half-width column a button beside the sentence
/// squeezed it into a four-line ribbon.
private struct ProblemCardRow: Layout {
    /// The narrowest the sentence may get with the button beside it — about
    /// four words of the notch's type.
    var sentenceMinWidth: CGFloat = 180
    var spacing: CGFloat = 7
    var stackedGap: CGFloat = 5

    private struct Plan {
        var size: CGSize
        var sentence: CGRect
        var icon: CGPoint
        var button: CGPoint?
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = plan(bounds.width, subviews)
        let origin = bounds.origin
        subviews[0].place(at: CGPoint(x: origin.x + plan.icon.x, y: origin.y + plan.icon.y), proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: origin.x + plan.sentence.minX, y: origin.y + plan.sentence.minY),
                          proposal: ProposedViewSize(width: plan.sentence.width, height: nil))
        if subviews.count > 2, let button = plan.button {
            subviews[2].place(at: CGPoint(x: origin.x + button.x, y: origin.y + button.y), proposal: .unspecified)
        }
    }

    private func plan(_ width: CGFloat?, _ subviews: Subviews) -> Plan {
        let icon = subviews[0].dimensions(in: .unspecified)
        let lead = icon.width + spacing
        let available = width ?? .infinity
        let button = subviews.count > 2 ? subviews[2].dimensions(in: .unspecified) : nil

        func sentence(_ width: CGFloat) -> ViewDimensions {
            subviews[1].dimensions(in: ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
        }
        // The icon sits on the sentence's first line, as the HStack's first
        // text baseline put it.
        func iconY(_ text: ViewDimensions) -> CGFloat {
            max(0, text[VerticalAlignment.firstTextBaseline] - icon[VerticalAlignment.firstTextBaseline])
        }

        guard let button else {
            let text = sentence(available - lead)
            let top = max(0, icon[VerticalAlignment.firstTextBaseline] - text[VerticalAlignment.firstTextBaseline])
            let height = max(top + text.height, iconY(text) + icon.height)
            return Plan(size: CGSize(width: width ?? lead + text.width, height: height),
                        sentence: CGRect(x: lead, y: top, width: text.width, height: text.height),
                        icon: CGPoint(x: 0, y: iconY(text)))
        }

        let besideWidth = available - lead - spacing - button.width
        if besideWidth >= sentenceMinWidth {
            let text = sentence(besideWidth)
            // Button, sentence and icon share the first line's baseline.
            let base = max(text[VerticalAlignment.firstTextBaseline], button[VerticalAlignment.firstTextBaseline])
            let textTop = base - text[VerticalAlignment.firstTextBaseline]
            let buttonTop = base - button[VerticalAlignment.firstTextBaseline]
            let height = max(textTop + text.height, buttonTop + button.height)
            let fullWidth = width ?? (lead + text.width + spacing + button.width)
            return Plan(size: CGSize(width: fullWidth, height: height),
                        sentence: CGRect(x: lead, y: textTop, width: besideWidth.isFinite ? besideWidth : text.width,
                                         height: text.height),
                        icon: CGPoint(x: 0, y: textTop + iconY(text)),
                        button: CGPoint(x: fullWidth - button.width, y: buttonTop))
        }

        // Stacked: the button starts under the sentence, not under the icon.
        let text = sentence(available - lead)
        let buttonTop = text.height + stackedGap
        return Plan(size: CGSize(width: width ?? lead + max(text.width, button.width),
                                 height: buttonTop + button.height),
                    sentence: CGRect(x: lead, y: 0, width: text.width, height: text.height),
                    icon: CGPoint(x: 0, y: iconY(text)),
                    button: CGPoint(x: lead, y: buttonTop))
    }
}

/// The two surfaces a problem is drawn on: the dark notch (the default) and
/// the Settings window's system form.
enum ProblemCardLook: Sendable { case notch, settings }

extension EnvironmentValues {
    @Entry var problemCardLook: ProblemCardLook = .notch
}
