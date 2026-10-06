import SwiftUI
import AirlockCore

/// Every wait's one look (card B2): nothing for a moment, then three breathing
/// dots, then words, then a way out. The stages and their seconds are
/// `WaitPace`'s; this only draws them.
///
/// **It times itself from when it appears**, because appearing is when the
/// wait began at every place that shows one. A caller whose wait outlives the
/// view (the guide's look, which the bubble redraws) keeps the view's identity
/// for the length of the wait, and a new wait gets a new identity with `.id`.
///
/// Never the Mac's spinner: on the notch it was the one stock control left,
/// and in a still picture it is a grey asterisk that says nothing about how
/// long it has been.
struct WaitingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What is happening, as a sentence ending in "…".
    let words: String
    /// Said from the first moment rather than from the explained stage — for
    /// a wait the person caused and is watching (the guide after a click),
    /// where silence would read as the click not landing. At the explained
    /// stage it becomes "Still …" so five seconds and fifty differ.
    var wordsFromStart = false
    /// What a from-the-start sentence becomes at the explained stage, when
    /// "Still" in front would not read right. Nil means `WaitPace.still`.
    var laterWords: String?
    /// What the stuck stage says above its buttons.
    var stuckWords = "This is taking longer than usual."
    var retryLabel = "Try again"
    var retry: (() -> Void)?
    var cancelLabel = "Cancel"
    var cancel: (() -> Void)?
    /// Dots only, for a slot with no room for a sentence (a tile, a header).
    /// The words still reach VoiceOver.
    var dotsOnly = false
    var pace: WaitPace = .standard

    @Environment(\.problemCardLook) private var look
    /// A retry starts a new wait, so it starts a new clock: without this the
    /// buttons would stay up after being pressed.
    @State private var attempt = 0

    var body: some View {
        WaitClock(pace: pace) { stage in
            content(stage)
                .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: stage)
        }
        .id(attempt)
        // A TimelineView takes all the room it is offered, which put the dots
        // at the top of a Shelf tile instead of its middle. Sentences keep
        // their width so they can still wrap.
        .fixedSize(horizontal: dotsOnly, vertical: true)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func content(_ stage: WaitPace.Stage) -> some View {
        if dotsOnly {
            WaitingDots(tint: tint)
                .opacity(stage == .quiet ? 0 : 1)
                .accessibilityLabel(String(words.trimmingCharacters(in: CharacterSet(charactersIn: "…"))))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    WaitingDots(tint: tint)
                        .opacity(stage == .quiet ? 0 : 1)
                        .accessibilityHidden(true)
                    if let line = sentence(stage) {
                        Text(line)
                            .font(font)
                            .foregroundStyle(tint)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                if stage == .stuck, retry != nil || cancel != nil {
                    buttons.transition(.opacity)
                }
            }
        }
    }

    private func sentence(_ stage: WaitPace.Stage) -> String? {
        switch stage {
        case .quiet, .alive: wordsFromStart ? words : nil
        case .explained: wordsFromStart ? (laterWords ?? WaitPace.still(words)) : words
        case .stuck: stuckWords
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            if let retry { button(retryLabel, primary: true) { attempt += 1; retry() } }
            if let cancel { button(cancelLabel, primary: false, action: cancel) }
        }
    }

    @ViewBuilder private func button(_ label: String, primary: Bool, action: @escaping () -> Void) -> some View {
        switch look {
        case .settings:
            Button(label, action: action)
        case .notch:
            Button(action: action) {
                Text(label)
                    .font(Theme.chrome(11, .semibold))
                    .foregroundStyle(primary ? Theme.running : Theme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill((primary ? Theme.running : Theme.textPrimary).opacity(0.12)))
            }
            .buttonStyle(.plain)
            .clickable()
        }
    }

    private var tint: Color { look == .settings ? .secondary : Theme.running }
    private var font: Font { look == .settings ? .callout : Theme.chrome(11.5, .medium) }
}

/// The stage a wait has reached, for a view that says it in its own way (the
/// guide's first-look panel ages its headline rather than adding a line).
/// Times itself from when it appears, and redraws only at the boundaries.
struct WaitClock<Content: View>: View {
    var pace: WaitPace = .standard
    @ViewBuilder var content: (WaitPace.Stage) -> Content

    /// Set by the state gallery to draw one stage still.
    @Environment(\.waitElapsedOverride) private var frozenAt
    @State private var start = Date()

    var body: some View {
        TimelineView(.explicit(pace.boundaries.map { start.addingTimeInterval($0) })) { context in
            content(pace.stage(after: frozenAt ?? context.date.timeIntervalSince(start)))
        }
    }
}

/// Three dots breathing in turn. Still, at a middle strength, under Reduce
/// Motion — still dots read as "waiting", which is true.
struct WaitingDots: View {
    var tint: Color = Theme.running
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint)
                    .frame(width: 4.5, height: 4.5)
                    // Scoped to the opacity alone. A forever-repeating
                    // animation on the whole dot also caught the dot's first
                    // placement, so it bobbed from the top of its slot for
                    // good instead of sitting in the middle.
                    .animation(reduceMotion ? nil : MotionEffect.waiting(dot: index)) {
                        $0.opacity(reduceMotion ? 0.6 : (breathing ? 1 : 0.25))
                    }
            }
        }
        .frame(height: 12)
        .onAppear { breathing = true }
    }
}

extension EnvironmentValues {
    /// Seconds into every wait below, fixed — the state gallery's way to draw
    /// one stage. Nil everywhere in the shipping app.
    @Entry var waitElapsedOverride: TimeInterval?
}
