import AirlockCore
import AppKit
import SwiftUI

/// The small capitals that mark what a plan adds ("PLUS", "PRO"), beside
/// whatever it is on. Free sees every one of them: a paid thing is tagged,
/// never hidden.
struct PlanTag: View {
    let plan: AirlockPlan

    init(_ plan: AirlockPlan) {
        self.plan = plan
    }

    var body: some View {
        Text(plan.label.uppercased())
            .font(Theme.chrome(9.5, .bold))
            .tracking(0.6)
            .foregroundStyle(Self.text(plan))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Self.tint(plan).opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Self.tint(plan).opacity(0.45), lineWidth: 1))
            .accessibilityLabel("\(plan.label) plan")
    }

    /// Each plan's colour: Plus blue, Pro gold, Free the resting grey.
    static func tint(_ plan: AirlockPlan) -> Color {
        switch plan {
        case .free: Theme.textSecondary
        case .plus: plus
        case .pro: pro
        }
    }

    /// The words in that colour, a step lighter for a dark ground.
    static func text(_ plan: AirlockPlan) -> Color {
        switch plan {
        case .free: Theme.textSecondary
        case .plus: plusText
        case .pro: pro
        }
    }

    static let plus = Color(nsColor: NSColor(srgbRed: 0x6B / 255, green: 0x8C / 255, blue: 0xFF / 255, alpha: 1))
    static let plusText = Color(nsColor: NSColor(srgbRed: 0x9C / 255, green: 0xB2 / 255, blue: 0xFF / 255, alpha: 1))
    static let pro = Color(nsColor: NSColor(srgbRed: 0xED / 255, green: 0xBD / 255, blue: 0x5C / 255, alpha: 1))
}

/// A tag on something the plan leaves out, in Settings: the same small
/// capitals, and pressing it opens Plans on the plan cards. Nothing beside
/// it is greyed out; the tag is how the row says what it needs.
struct PlanTagButton: View {
    let plan: AirlockPlan
    var reveal: () -> Void

    init(_ plan: AirlockPlan, reveal: @escaping () -> Void) {
        self.plan = plan
        self.reveal = reveal
    }

    var body: some View {
        Button(action: reveal) { PlanTag(plan) }
            .buttonStyle(.plain)
            .clickable()
            .help("Comes with \(plan.label). Opens Plans.")
            .accessibilityLabel("\(plan.label) plan")
            .accessibilityHint("Opens Plans")
    }
}
