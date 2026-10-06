import AirlockCore
import SwiftUI

/// What you see while holding the dictation key.
///
/// Dictation is the one feature with no visible surface of its own — you hold a
/// key somewhere else entirely and hope. Without this, "is it listening?" and
/// "did it hear me?" are unanswerable until the text either appears or doesn't,
/// which is far too late to do anything about.
///
/// The live text here is genuinely live: partial results stream in as you speak.
/// It is deliberately NOT typed into your document as it arrives. Volatile
/// results get replaced wholesale by the final — different casing, different
/// punctuation — so streaming into a text field would mean backspacing over text
/// this app does not own to correct itself. One drift in the count and it eats
/// your words instead of its own.
struct DictationOverlayView: View {
    /// How tall the transcript may grow. Passed in because the panel already
    /// computes the screen-derived budget and there is no reason for two
    /// answers to that question.
    var maxTranscriptHeight: CGFloat = 260
    /// The panel is closing behind what was just dismissed: keep drawing the
    /// last notice or card rather than what the model now says (nothing,
    /// which would be the bare listening strip). See
    /// `NotchUIState.holdDictationThroughCollapse`.
    var frozen = false

    @Environment(DictationModel.self) private var dictation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The three things that decide which card is up.
    private struct Shown: Equatable {
        var silent: DictationModel.SilentHold?
        var heard: DictationModel.HeardDictation?
        var notice: DictationHoldNotice?
    }

    /// Recorded while live, so a frozen overlay has something to keep.
    @State private var lastShown = Shown()

    private var live: Shown {
        Shown(silent: dictation.heardNothing, heard: dictation.heardDictation, notice: dictation.holdNotice)
    }

    private var shown: Shown { frozen ? lastShown : live }

    var body: some View {
        content
            .onChange(of: live, initial: true) { _, now in
                // Not while frozen: the change that froze it is the one
                // clearing the card this keeps on screen.
                if !frozen { lastShown = now }
            }
    }

    @ViewBuilder private var content: some View {
        if let silent = shown.silent {
            HeardNothingCard(silent: silent,
                             chooseInput: { dictation.chooseInput() },
                             dismiss: { dictation.dismissHeardNothing() })
        } else if let card = shown.heard {
            HeardDictationCard(card: card,
                               keyHint: dictation.askKeyHint,
                               canAsk: dictation.canAskHeardDictation,
                               type: { dictation.typeHeardDictation() },
                               ask: { dictation.askHeardDictation() },
                               guide: { dictation.guideHeardDictation() },
                               dismiss: { dictation.dismissHeardDictation() })
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let notice = shown.notice {
                    HoldNoticeCard(notice: notice, fix: { dictation.fixHoldNotice() })
                        .transition(.opacity)
                }
                // Not under a notice for a hold that is over: the strip would
                // say "Tidying up…" over nothing.
                if shown.notice == nil || dictation.isActive {
                    listening
                }
            }
            .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: shown.notice)
        }
    }

    private var listening: some View {
        ListeningStrip(isListening: dictation.isListening,
                       isSorting: dictation.isSorting,
                       isAsking: dictation.isAsking,
                       askRoute: dictation.askRoute,
                       route: dictation.route,
                       destinationName: dictation.destinationName,
                       liveText: dictation.liveText,
                       inputLevels: dictation.inputLevels,
                       maxTranscriptHeight: maxTranscriptHeight)
    }
}

/// A `DictationHoldNotice` as the notch draws it: the shared problem card,
/// so a dictation that could not record looks like every other problem in
/// the app (rule 6 of `docs/how-airlock-talks.md`).
///
/// Plain values in, like the two cards below, so the state gallery draws the
/// same card the notch does.
struct HoldNoticeCard: View {
    let notice: DictationHoldNotice
    var fix: () -> Void = {}

    var body: some View {
        ProblemCard(icon: notice.icon,
                    sentence: notice.sentence,
                    tone: notice.tone == .problem ? .needs : .note,
                    button: notice.fix?.button,
                    action: notice.fix == nil ? nil : fix)
    }
}

/// An ask-key hold the sort read as dictation: words for a document or a
/// coding agent, spoken on the asking key. Nothing has happened yet — no
/// answer, no guide, no typing — and this is where the person says which.
///
/// "Type it" is the prominent one because a slip onto the ask key is the
/// common case; the other two are one click for when the sort was wrong.
/// Nothing is typed without that click: the key stated "ask", and only
/// the person can restate it (see `DictationModel.askKey`).
///
/// Plain values in, so the state gallery can draw it without a dictation
/// model — which owns the audio engine.
struct HeardDictationCard: View {
    let card: DictationModel.HeardDictation
    /// `DictationModel.askKeyHint`.
    let keyHint: String
    /// The assistant can be off, and then there is nothing to ask.
    let canAsk: Bool
    let type: () -> Void
    let ask: () -> Void
    let guide: () -> Void
    let dismiss: () -> Void

    var body: some View {
        let tint = Theme.running
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "keyboard")
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: .circle)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(card.certain ? "Sounded like dictation" : "Type it, ask it, or be guided?")
                        .font(Theme.chrome(11, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(keyHint)
                        .font(Theme.chrome(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                Text("“\(card.text)”")
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    OverlayCardButton(title: card.app.map { "Type it into \($0)" } ?? "Type it",
                                      prominent: true, tint: tint, perform: type)
                    if canAsk {
                        OverlayCardButton(title: "Ask", prominent: false, tint: tint, perform: ask)
                    }
                    OverlayCardButton(title: "Guide me", prominent: false, tint: tint, perform: guide)
                    OverlayCardButton(title: "Esc", prominent: false, tint: tint, perform: dismiss)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.rowFill, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        }
    }
}

/// The hold that produced no audio at all — and which of the two that was.
///
/// It used to be one card saying the microphone was at fault, because the
/// only thing it looked at was the peak level. On a sub-second hold that is
/// the wrong half of the story: the app closed the window before the input
/// had started, and the card sent people to Settings to check hardware that
/// was working. `SilentCapture` decides which of these it was; this only
/// draws it. Plain values in, like `HeardDictationCard`.
struct HeardNothingCard: View {
    let silent: DictationModel.SilentHold
    let chooseInput: () -> Void
    let dismiss: () -> Void

    var body: some View {
        let isInputFault = silent.cause == .inputProducedNothing
        // Amber is for the one that needs something changed. A hold that was
        // simply too short is guidance, and colouring it as a fault is how a
        // notice trains people to dismiss notices.
        let tint = isInputFault ? Theme.needs : Theme.running
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: isInputFault ? "mic.slash" : "timer")
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: .circle)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(isInputFault ? "Heard nothing" : "Too short")
                        .font(Theme.chrome(11, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(isInputFault ? "the level never moved — \(silent.device)"
                                      : "the input had not started yet")
                        .font(Theme.chrome(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                Text(isInputFault
                     ? "The hold registered and the transcriber ran, so this is the microphone rather than the app. Check the input in Settings › Dictation, or hold again closer."
                     : "The key came back up before any audio arrived. A Bluetooth input takes about a second to switch from playing to recording — hold it a little longer and speak once the panel is up.")
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    // Prominent only when changing the input is actually the
                    // fix. On a short hold it is a detour, so it stays offered
                    // and stops being the answer.
                    OverlayCardButton(title: "Choose input…", prominent: isInputFault,
                                      tint: tint, perform: chooseInput)
                    OverlayCardButton(title: "Esc", prominent: false,
                                      tint: tint, perform: dismiss)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.rowFill, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        }
    }
}

/// The two cards' buttons.
private struct OverlayCardButton: View {
    let title: String
    let prominent: Bool
    var tint: Color = Theme.needs
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            Text(title)
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(prominent ? tint : Theme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(prominent ? tint.opacity(0.16) : Color.white.opacity(0.06),
                            in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}


struct ListeningStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isListening: Bool
    let isSorting: Bool
    let isAsking: Bool
    let askRoute: GuideRouting.Route?
    let route: DictationRoute
    let destinationName: String?
    let liveText: String
    /// Scaled readings, newest last (`MicLevel`).
    let inputLevels: [Double]
    var maxTranscriptHeight: CGFloat = 260

    /// The hold itself, redrawn on 2026-10-01 after the owner asked for "better
    /// notch views" for listening and transcribing.
    ///
    /// **No card, and nothing under it.** It was a bordered card above an
    /// emptied, full-height widget region, so a two-second hold opened the
    /// biggest dark panel the app draws. Now the panel is exactly this: the
    /// cloud moving with your voice, the words as they arrive, and one quiet line saying where
    /// they will go. The panel grows a line at a time as you speak, which reads
    /// as the words arriving rather than as the layout jumping.
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            indicator
                .frame(width: 44, height: 44, alignment: .bottom)
            VStack(alignment: .leading, spacing: 5) {
                transcript
                caption
            }
            // Centred on the cloud while short, so a lone "Tidying up…" sits
            // beside it rather than above it; longer words grow downward.
            .frame(minHeight: 44, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    /// The cloud alone, big enough to be the thing you look at, moving with
    /// your voice while the microphone is live and glancing about once it is
    /// off and the words are being sorted or tidied. See `ListeningBloub`.
    ///
    /// **No wave under it** (owner's gallery walk, 2026-10-05: "remove the
    /// wave form, make the cloud bigger and react to sound"). The wave was
    /// the meter and the cloud the character; now the cloud is both — it
    /// rises gently as you speak, so a cloud that stays still while you
    /// plainly speak still says "it cannot hear you".
    ///
    /// Bottom-aligned in a taller frame so the stretch has room above it and
    /// the words beside it never move.
    private var indicator: some View {
        ListeningBloub(isThinking: !isListening, level: levelScale, tint: tint)
            .frame(width: 40, height: 34)
    }

    /// Blue for words going into a document, violet for a question to the
    /// notch — the two keys, told apart before a word is said.
    private var tint: Color { isAsking ? Theme.assistant : Theme.running }

    /// Where the words are going, as one line: "Release to type into Notes",
    /// "Release to ask", "Tidying up…".
    ///
    /// Asking is stated by the key you held, so that half is never a guess. The
    /// type-or-copy half still comes from a focus probe — but its worst case is
    /// a transcript on the clipboard rather than a sentence executed as
    /// keyboard shortcuts, which is why it is allowed to be a heuristic at all.
    private var caption: some View {
        HStack(spacing: 5) {
            if isListening {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint)
            } else {
                // Moving, because this pause is the one where a still "…"
                // read as the key having been missed (card B2).
                WaitingDots(tint: tint)
                    .scaleEffect(0.8)
                    .accessibilityHidden(true)
            }
            Text(captionText)
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: captionText)
    }

    /// Split out of the view body: nesting a ternary inside an interpolation
    /// inside a ternary defeated the type-checker outright.
    private var captionText: String {
        guard isListening else {
            // The pause between letting go and anything happening is the model
            // working. Named, so it is not read as the app missing the key.
            return isSorting ? "Working out what you meant…" : "Tidying up…"
        }
        if isAsking {
            // With the guide on, the line says which way the words are leaning
            // as they are spoken, so "how do I…" visibly becomes a guide.
            switch askRoute {
            case .guide: return "Release to be guided"
            case .chat: return "Release to chat"
            case .unsure, nil: return "Release to ask"
            }
        }
        if route == .copy { return "Release to copy it" }
        return "Release to type into \(destinationName ?? "the front app")"
    }

    private var symbol: String {
        if isAsking { return askRoute == .guide ? "safari" : "sparkles" }
        return route == .copy ? "doc.on.clipboard" : "arrow.turn.down.right"
    }

    @ViewBuilder
    private var transcript: some View {
        if liveText.isEmpty {
            // Distinguishes "we are up and waiting" from "we heard nothing",
            // which look identical if the area is simply blank. Only while
            // listening: after release the caption's moving dots already say
            // it is working, and a grey "…" above them was a second, still set
            // of dots (owner, 2026-10-05: "remove that").
            if isListening {
                Text("Listening…")
                    .font(Theme.chrome(14, .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        } else {
            // Grows with what you say up to the panel's budget, then keeps the
            // NEWEST words and lets the oldest fall off the top.
            //
            // No ScrollView: one is greedy vertically, so it claimed the full
            // budget whatever you had said and the panel ballooned on the first
            // word. `alignment: .bottom` does the whole job instead — the text
            // keeps its natural height, sits against the bottom of the frame,
            // and anything past the cap overflows upward where `clipped`
            // removes it.
            Text(liveText)
                .font(Theme.chrome(14, .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: maxTranscriptHeight, alignment: .bottom)
                .clipped()
        }
    }

    /// The cloud moves with the last few readings averaged, so it follows the
    /// voice rather than every syllable.
    private var levelScale: CGFloat {
        let recent = inputLevels.suffix(3)
        guard !recent.isEmpty else { return 0 }
        return CGFloat(recent.reduce(0, +) / Double(recent.count))
    }
}
