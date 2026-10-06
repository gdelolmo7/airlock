import SwiftUI
import AirlockCore

/// "Welcome to Airlock": the everyday first run's window (designs 9a and 9d).
///
/// Native chrome and the system's own colours, following the Mac's appearance,
/// because it is a window like any other. The only dark thing in it is the
/// picture of the notch, which is dark on every Mac.
struct WelcomeView: View {
    @Environment(WelcomeModel.self) private var model

    static let width: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            switch model.plan.step {
            case .welcome, .practice: welcome
            case .developer: developer
            }
            footer
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 9a

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            WelcomeHero()
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.bottom, 22)
            Text("Stuck on a screen? Ask.")
                .font(.system(size: 24, weight: .semibold))
                .padding(.bottom, 10)
            howToAsk
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.bottom, 10)
            Text(askFootnote)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The key the person actually set, and only while it would ask — it
    /// used to say "Hold ⌥ Option" whatever was set, including nothing.
    /// Each a single literal so `**` is read as Markdown; joining pieces
    /// with `+` makes a plain String and prints the asterisks.
    private var howToAsk: Text {
        switch model.askWay {
        case .hold(let key):
            Text("Hold **\(key)** and say what you're trying to do. Airlock looks at your screen, tells you the next step and points at where to click. You do the clicking.")
        case .type(let key):
            Text("Press **\(key)** and type what you're trying to do. Airlock looks at your screen, tells you the next step and points at where to click. You do the clicking.")
        case .notOn:
            Text("Ask Airlock what you're trying to do. It looks at your screen, tells you the next step and points at where to click. You do the clicking.")
        }
    }

    private var askFootnote: String {
        switch model.askWay {
        case .hold, .type: "It only looks when you ask."
        case .notOn: "It only looks when you ask. Asking is off for now: Settings › \(SettingsPane.voice.title) turns it on."
        }
    }

    // MARK: - 9d

    private var developer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.plan.practice == .reached {
                didIt
                    .padding(.bottom, 20)
            }
            Text("Do you use AI coding tools like Claude Code?")
                .font(.system(size: 22, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            Text("If you do, Airlock can show what they're working on and let you approve their "
                 + "actions from the notch. If you don't, you won't see any of it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)
            HStack(spacing: 12) {
                choice("No, I don't", "Keep Airlock simple") { model.answer(.no) }
                choice("Yes, I do", "Turn on Developer mode and connect them") { model.answer(.yes) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 16)
            Text("You can change this any time in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The practice got there. Said, with the cloud hopping once, because
    /// a first success that passes in silence is a missed one.
    private var didIt: some View {
        HStack(spacing: 12) {
            BloubView(expression: .proud, motion: .breathing, tint: BloubTint.working.color)
                .frame(width: 34)
                .bloubHop(when: model.celebrating, lift: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nice, you did it.")
                    .font(.system(size: 14, weight: .semibold))
                Text("That's all there is to it: ask, then follow the ring.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }

    /// A plain button drawn as a card. No default: neither is the answer most
    /// people give, so neither is pre-chosen or answers Return.
    private func choice(_ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .clickable()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<WelcomePlan.dots, id: \.self) { dot in
                    Circle()
                        .fill(dot == model.plan.dot ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Page \(model.plan.dot + 1) of \(WelcomePlan.dots)")
            if model.plan.practice == .notReached, model.plan.step != .practice {
                // Said wherever the walk lands after a practice that did not
                // get there — including back here with nothing left to ask,
                // where the window used to just close.
                Text(model.plan.step == .developer ? "The practice didn't finish. Back to try again."
                                                   : "The practice didn't finish.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch model.plan.step {
            case .welcome:
                // A way past the practice: it is a practice, not a gate.
                Button(skipTitle) { model.skip() }
                Button(model.plan.practice == .notTried ? "Try it" : "Try again") { model.tryIt() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .practice:
                Text(model.isOpeningSettings ? "Opening System Settings…" : "Follow the blue ring")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case .developer:
                Button("Back") { model.back() }
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .top) { Divider() }
    }

    /// "Skip the practice" before a go; after one, the way on — to the
    /// question, or Done when there is nothing left to ask.
    private var skipTitle: String {
        if model.plan.practice == .notTried { return "Skip the practice" }
        return model.plan.asksDeveloper ? "Continue" : "Done"
    }
}

extension EnvironmentValues {
    @Entry var welcomeHeroStill = false
}

/// 9a's picture: bloub drops out of the notch and rings a button, on a loop.
/// A still of the ringed button under Reduce Motion.
struct WelcomeHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The still frame regardless, for a snapshot.
    @Environment(\.welcomeHeroStill) private var still

    enum Beat: CaseIterable {
        case rest, drop, ring, hold

        var bloubY: CGFloat { self == .rest ? -62 : 0 }
        var bloubShown: Bool { self != .rest }
        var ringShown: Bool { self == .ring || self == .hold }
    }

    var body: some View {
        Group {
            if reduceMotion || still {
                scene(.hold)
            } else {
                PhaseAnimator(Beat.allCases) { beat in
                    scene(beat)
                } animation: { beat in
                    // The guide's own motions, so the picture moves the way
                    // the real thing will: bloub leaves the notch as the
                    // island opens, the ring draws on, and bloub tucks back.
                    switch beat {
                    case .rest: Motion.close.animation(reduceMotion: false)
                    case .drop: Motion.open.animation(reduceMotion: false).delay(0.9)
                    case .ring: MotionEffect.ringDrawOn.delay(0.5)
                    // Nothing moves on this beat; the delay is the hold
                    // before the loop starts again.
                    case .hold: Motion.swap.animation(reduceMotion: false).delay(3.2)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Bloub drops from the notch and puts a ring around a button")
    }

    private func scene(_ beat: Beat) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)],
                           startPoint: .top, endPoint: .bottom)
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                .fill(Color.black)
                .frame(width: 128, height: 20)
            window(beat)
                .padding(.top, 44)
        }
    }

    private func window(_ beat: Beat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach([46.0, 38.0, 52.0, 30.0], id: \.self) { width in
                    Capsule().fill(Color.white.opacity(0.14)).frame(width: width, height: 6)
                }
            }
            .padding(12)
            .frame(width: 84, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.white.opacity(0.04))
            VStack(alignment: .leading, spacing: 9) {
                Capsule().fill(Color.white.opacity(0.22)).frame(width: 96, height: 8)
                Capsule().fill(Color.white.opacity(0.1)).frame(width: 150, height: 6)
                Capsule().fill(Color.white.opacity(0.1)).frame(width: 128, height: 6)
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 8) {
                    Spacer(minLength: 0)
                    BloubView(expression: .attentive, tint: BloubTint.working.color)
                        .frame(width: 22)
                        .offset(y: beat.bloubY)
                        .opacity(beat.bloubShown ? 1 : 0)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 72, height: 24)
                        .overlay {
                            ZStack {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Theme.running.opacity(0.22), lineWidth: 8)
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Theme.running, lineWidth: 2.5)
                            }
                            .padding(-5)
                            .scaleEffect(beat.ringShown ? 1 : 1.35)
                            .opacity(beat.ringShown ? 1 : 0)
                        }
                }
            }
            .padding(14)
        }
        .frame(width: 300, height: 136)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.2)))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.1)))
    }
}
