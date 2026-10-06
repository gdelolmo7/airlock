import SwiftUI
import AirlockCore

/// The levels card: the output, then each app making sound, one line each — a
/// glyph that mutes, a name, a slider and a number.
///
/// **Rows, always, since 2026-09-28.** `AppMix.Form` has the three decisions
/// and why this one stands; the short version is that this card holds one or
/// two sources most of the time, and for that the console was ~200pt of mostly
/// empty card around a fader or two. Rows are as tall as what they hold, and
/// they are still the same shape every time the panel opens — which was the
/// console's real argument, and never needed faders to be true.
///
/// The console is still in here, and so is its name: `faderRow` draws vertical
/// faders on a shared baseline, reachable by moving `AppMix.formThreshold` and
/// nothing else. Its case was outweighed rather than wrong — "which of these is
/// loud" is answered at a glance by columns and by reading down a list in rows
/// — so it stays legible instead of being deleted.
///
/// In either form the output comes first, because it is the one that governs
/// the others.
struct FaderConsoleView: View {
    @Environment(AudioOutputModel.self) private var output
    @Environment(AppVolumeModel.self) private var mixer
    /// The form is LATCHED on this model, not derived here — see
    /// `SoundWidgetModel.form`. Deriving it in `body` is what would let the card
    /// rotate under a pointer already reaching for a control, the day the
    /// threshold splits the forms again.
    @Environment(SoundWidgetModel.self) private var sound

    /// Tall enough to be draggable and short enough to leave the calendar its
    /// half of the row.
    private static let trackHeight: CGFloat = 100

    /// **The track is narrower than the column it sits in, and that gap is the
    /// name.** At 44pt — the old column width, with the track filling it — a
    /// fader read as a battery indicator rather than an instrument: nearly as
    /// wide as it was tall, on a corner radius big enough to round the whole
    /// thing off. Slim and tall is what makes a row of them scan as one console.
    ///
    /// The leftover 12pt is what a proportional 10pt label needs to get from
    /// "Spo…" to "Spotify". Names matter more here than in any other card: the
    /// only other identifier is a 14pt app icon, and telling Music from Podcasts
    /// at 14pt is not a thing anyone should have to do to turn one of them down.
    private static let trackWidth: CGFloat = 34
    private static let columnWidth: CGFloat = 46
    /// Small enough that the track still reads as a straight-sided channel. At
    /// 8 the fill's own rounding swallowed low values whole.
    private static let trackRadius: CGFloat = 6

    var body: some View {
        // No header and no padding: `SoundSectionView` owns the card — its
        // title, the device, the background — and this is the levels inside it.
        VStack(alignment: .leading, spacing: 6) {
            if sound.form == .console {
                faderRow
                HiddenAppsNote(hidden: slots.hidden)
            } else if output.volume != nil || !slots.shown.isEmpty {
                // Gated rather than drawn empty, so the card is exactly as tall
                // as what it holds. The one card this skips is an output with no
                // software volume and nothing playing — `SoundSectionView` says
                // where the sound is going instead.
                rowStack
            }
            LevelsNotice(notice: AppVolumeModel.cardNotice(
                failures: slots.shown.compactMap { mixer.failures[$0.app.bundleID] }))
        }
    }

    private var slots: (shown: [AppMix.MixSlot], hidden: Int) { mixer.slots }

    // MARK: - Rows: one elastic slider per source, which is every card that draws

    /// Built from the models here and drawn from values by `LevelRows`, so the
    /// drawing can be rendered offscreen with sample data — see
    /// `LevelsRowsSnapshot`. The panel itself cannot be screenshotted from a
    /// test, and this card had gone a month unseen once already.
    private var rowStack: some View {
        LevelRows(output: outputLevel, apps: slots.shown.map(appLevel), hidden: slots.hidden)
    }

    /// The output's row, when it has a software volume. HDMI and DisplayPort
    /// outputs usually do not — the level belongs to the display — and then
    /// there is no row rather than a slider that moves nothing. The device still
    /// shows, in the card's header.
    private var outputLevel: LevelSource? {
        guard let volume = output.volume else { return nil }
        return LevelSource(
            id: "output",
            // The device is named once, in the card's header; the bar is just
            // how loud it is.
            name: "Volume",
            value: Double(volume),
            isMuted: output.isMuted,
            isIdle: false,
            icon: nil,
            symbol: OutputMute.isSilent(volume: volume, isMuted: output.isMuted)
                ? "speaker.slash.fill" : "speaker.wave.2.fill",
            mute: outputGlyphAction,
            failure: nil,
            set: { output.setVolume(Float($0)) })
    }

    private func appLevel(_ slot: AppMix.MixSlot) -> LevelSource {
        let bundleID = slot.app.bundleID
        let isMuted = mixer.isMuted(bundleID)
        return LevelSource(
            id: bundleID,
            name: slot.app.name,
            value: Double(mixer.gain(for: bundleID)),
            isMuted: isMuted,
            isIdle: slot.isIdle,
            icon: mixer.icon(for: bundleID),
            symbol: "app.dashed",
            // Inert while idle, like the slider beside it. The row is holding a
            // place for an app that has stopped, and a mute button would be the
            // one live control on it. The mute itself is remembered either way
            // (`AppVolumeModel.muted`), and the button is back the moment the
            // app is.
            mute: slot.isIdle ? nil : (name: isMuted ? "Unmute" : "Mute",
                                       run: { mixer.toggleMute(slot.app) }),
            failure: AppVolumeModel.rowFailure(mixer.failures[bundleID]),
            set: { mixer.setGain(Float($0), for: slot.app) })
    }

    /// `nil` — a reporting glyph rather than a button — when the current device
    /// has no settable mute. Shared by both forms.
    ///
    /// Several aggregates and USB interfaces answer the volume property and not
    /// the mute one, and a button that writes into nothing is worse than no
    /// button. `OutputSection` used to know this; it drew the output a second
    /// time on the same card, and when that duplicate went the knowledge had to
    /// come with it rather than go with it. It came to the console only, and the
    /// rows form went on offering an unguarded mute until 2026-09-28, when it
    /// became the form that ships.
    ///
    /// The name follows the state, because "Mute" on an already-muted device is
    /// the wrong label for what pressing it does.
    private var outputGlyphAction: (name: String, run: () -> Void)? {
        guard output.canMute else { return nil }
        return (name: output.isMuted ? "Unmute" : "Mute", run: { output.toggleMute() })
    }

    // MARK: - Console: faders side by side — the retained reversal

    /// **Nothing routes here while `AppMix.formThreshold` is `nil`.** Kept, not
    /// deleted, because it is the whole of what reversing that decision costs:
    /// one value in Core and this code is live again, latch and all.
    ///
    /// Its argument is still an honest one and worth keeping legible. Faders on
    /// one baseline answer "which of these is loud" at a glance, as bars; rows
    /// answer it by comparing thumbs down a column, which is slower once there
    /// are four or five of them. That was traded for a card that is short when
    /// it holds little, which is most of the time; see `AppMix.Form`.
    private var faderRow: some View {
        Group {
            HStack(alignment: .bottom, spacing: 6) {
                if let volume = output.volume {
                    // The glyph under the output fader IS the mute button.
                    //
                    // It had to become one: `output.toggleMute()` had exactly one
                    // call site in the whole tree, inside `OutputSection`, which
                    // `SoundSectionView` draws only when there is more than one
                    // output device. A MacBook with nothing but its own speakers
                    // therefore had no mute anywhere in the app, while Settings
                    // said it did. Putting it here fixes that without adding a
                    // second control: the icon was already sitting where a person
                    // would press to silence the thing above it.
                    fader(value: Double(volume),
                          symbol: OutputMute.isSilent(volume: volume, isMuted: output.isMuted)
                              ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          label: "Output",
                          isIdle: false,
                          glyphAction: outputGlyphAction) {
                        output.setVolume(Float($0))
                    }

                    // Audio's own divider — but only when there is something on
                    // the far side of it. Gated on `output.volume` alone it drew
                    // in the SHIPPED DEFAULT (`widget.sound.appLevels` is off),
                    // where it separated the output fader from an empty space.
                    if !slots.shown.isEmpty {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(width: 1, height: Self.trackHeight)
                            .padding(.horizontal, 3)
                    }
                }

                ForEach(slots.shown) { slot in
                    appFader(slot)
                }

                // LEFT-anchored, and the empty right is deliberate.
                //
                // Centring was tried first and is worse: `levels` sits left, the
                // output chips sit left, and a centred console made the faders
                // the one element in the card on their own axis — which reads as
                // a layout accident exactly when there is most empty space to
                // notice it. A ragged right edge under a left-aligned header is
                // a card with room to grow; a floating middle is a bug.
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - One fader

    private func appFader(_ slot: AppMix.MixSlot) -> some View {
        let gain = mixer.gain(for: slot.app.bundleID)
        return fader(value: Double(gain),
                     symbol: nil,
                     label: slot.app.name,
                     isIdle: slot.isIdle,
                     icon: mixer.icon(for: slot.app.bundleID)) {
            mixer.setGain(Float($0), for: slot.app)
        }
    }

    @ViewBuilder
    private func glyph(icon: NSImage?, symbol: String?, isIdle: Bool) -> some View {
        if let icon {
            Image(nsImage: icon).resizable().interpolation(.high)
                .saturation(isIdle ? 0 : 1)
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// A track, a fill, an icon and a number — the same four parts for every
    /// source, which is what makes them comparable.
    @ViewBuilder
    private func fader(value: Double, symbol: String?, label: String, isIdle: Bool,
                       icon: NSImage? = nil,
                       glyphAction: (name: String, run: () -> Void)? = nil,
                       set: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                let height = geometry.size.height
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: Self.trackRadius, style: .continuous)
                        .fill(isIdle ? Color.clear : Color.white.opacity(0.07))
                        // An idle app keeps its WELL — the slot stays so the
                        // console does not renumber under a pointer already
                        // reaching for a fader. See `AppMix.slots`.
                        .overlay {
                            if isIdle {
                                RoundedRectangle(cornerRadius: Self.trackRadius, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.22),
                                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            }
                        }

                    if !isIdle {
                        RoundedRectangle(cornerRadius: Self.trackRadius, style: .continuous)
                            .fill(Theme.running.opacity(0.32))
                            .frame(height: max(2, height * value))
                            .overlay(alignment: .top) {
                                Rectangle()
                                    .fill(Theme.running)
                                    .frame(height: 1.5)
                            }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard !isIdle else { return }
                            // Bottom-up: the fader's zero is its floor, which is
                            // the opposite of a view's y origin.
                            set(min(1, max(0, 1 - drag.location.y / height)))
                        }
                )
            }
            .frame(width: Self.trackWidth, height: Self.trackHeight)

            Group {
                if let glyphAction {
                    Button(action: glyphAction.run) {
                        glyph(icon: icon, symbol: symbol, isIdle: isIdle)
                    }
                    .buttonStyle(.plain)
                } else {
                    glyph(icon: icon, symbol: symbol, isIdle: isIdle)
                }
            }
            .frame(width: 14, height: 14)

            Text(isIdle ? "—" : "\(Int((value * 100).rounded()))")
                .font(Theme.label)
                .foregroundStyle(isIdle ? Theme.textTertiary : Theme.textPrimary)
                .monospacedDigit()

            // Proportional where the readout above is monospaced, which is the
            // whole hierarchy: the number is a value you compare down the row,
            // the name is a word you read once.
            Text(label)
                .font(Theme.chrome(10, .medium))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: Self.columnWidth)
        .opacity(isIdle ? 0.45 : 1)
        .help(isIdle ? "\(label) stopped playing — its place is held for a moment" : label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
        .accessibilityValue(isIdle ? "idle" : "\(Int((value * 100).rounded())) percent")
        // The track is a bare `DragGesture`, which VoiceOver and the keyboard
        // cannot drive — so every fader here announced a value nobody could
        // change. `children: .ignore` above also swallows the glyph button, so
        // its action has to be re-offered explicitly.
        .accessibilityAdjustableAction { direction in
            guard !isIdle else { return }
            switch direction {
            case .increment: set(min(1, value + 0.05))
            case .decrement: set(max(0, value - 0.05))
            @unknown default: break
            }
        }
        .accessibilityActions {
            if let glyphAction {
                Button(glyphAction.name, action: glyphAction.run)
            }
        }
    }
}

// MARK: - The rows form, drawn from values

/// What one row of the levels card shows. Plain values and two closures, so a
/// row can be drawn without the models behind it — which is what lets
/// `LevelsRowsSnapshot` put every state on one sheet.
struct LevelSource: Identifiable {
    let id: String
    let name: String
    /// 0…1, on the scale the output and every app share since `AppMix.maxGain`
    /// came down to unity.
    let value: Double
    let isMuted: Bool
    /// Went quiet within the linger window: drawn, and nothing on it is live.
    /// See `AppMix.slots`.
    let isIdle: Bool
    let icon: NSImage?
    /// Drawn when there is no icon — the output, or an app without one.
    let symbol: String
    /// The glyph's button, named for what pressing it does. `nil` draws the
    /// glyph as a report rather than a control: an idle app, or an output with
    /// no settable mute.
    let mute: (name: String, run: () -> Void)?
    /// What the row says when this app's level has stopped reaching its audio:
    /// one of `AppVolumeModel.failureSentences`.
    let failure: String?
    let set: (Double) -> Void
}

/// The output's bar, then one bar per app, then a word about any that did not
/// fit.
///
/// **Redrawn 2026-10-01, when the owner asked for the card to "make sense".**
/// Each row was a glyph, a name column, a system `Slider` and a number: four
/// parts in four styles, and at the Dashboard's width the mini slider was a
/// hairline you had to hunt for. Now every source is ONE bar — its name and
/// level written inside it, filled to the level — so the thing you read is the
/// thing you drag. The output's bar is taller because it governs the others,
/// which is what the hairline between them used to say.
struct LevelRows: View {
    let output: LevelSource?
    let apps: [LevelSource]
    /// Apps past `AppVolumeModel.visibleLimit`.
    var hidden = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let output {
                LevelRow(source: output, isPrimary: true)
                    // A little more air under the output than between the apps.
                    .padding(.bottom, apps.isEmpty ? 0 : 2)
            }
            ForEach(apps) { app in
                LevelRow(source: app)
            }
            HiddenAppsNote(hidden: hidden)
        }
    }
}

/// The card's one line about its rows — see `AppVolumeModel.cardNotice`.
/// Values in, so the gallery draws exactly this.
struct LevelsNotice: View {
    let notice: AppVolumeModel.CardNotice?

    var body: some View {
        switch notice {
        case .multiOutput:
            ProblemCard(sentence: AppVolumeTap.multiOutputRefusal)
        case .mayNeedPermission:
            ProblemCard(sentence: AppVolumeModel.permissionHint, button: PermissionPage.button,
                        action: { PermissionPage.permission(.screenRecording).open() })
        case nil:
            EmptyView()
        }
    }
}

/// `AppMix.slots` returns `hidden` alongside `shown` precisely so the card can
/// admit what it left out; a capped list must not look like a complete one.
struct HiddenAppsNote: View {
    let hidden: Int

    var body: some View {
        if hidden > 0 {
            Text("+\(hidden) more app\(hidden == 1 ? "" : "s") playing")
                .font(Theme.chrome(10, .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, LevelRow.failureIndent)
        }
    }
}

/// One source: the glyph that mutes it, and its bar.
///
/// **Every bar starts and ends at the same x**, for the output and for every
/// app, so levels compare down one column — the argument the old rows made with
/// a fixed name width, made now by the bar itself.
struct LevelRow: View {
    let source: LevelSource
    /// The output: a taller bar, because it governs the rest.
    var isPrimary = false

    /// The failure caption's type, indent and line limit, named so that
    /// `LevelFailureCaptionTests` lays the sentences out exactly as this row
    /// draws them. Indented to the bar, so the caption reads as belonging to
    /// this row and not to the one below.
    static let failureIndent: CGFloat = Theme.soundIconWidth + 7
    static var failureFont: Font { Theme.chrome(10) }
    /// Three, for the largest text size in the narrowest panel, where both
    /// sentences wrap onto a third line — measured. At the default size they
    /// take two and the test holds them to it: the third line is for the text
    /// size, not room for a longer sentence.
    static let failureLineLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                glyph
                LevelBar(source: source, height: ceil((isPrimary ? 26 : 22) * Theme.textScale))
            }

            // `AppVolumeModel.failures`: a level that has stopped reaching the
            // app's audio says so here, or the bar moves and nothing changes
            // with no word as to why. See `AppVolumeModel.levelNotApplied`.
            if let failure = source.failure {
                Text(failure)
                    .font(Self.failureFont)
                    .foregroundStyle(Theme.needs)
                    .lineLimit(Self.failureLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(failure)
                    .padding(.leading, Self.failureIndent)
            }
        }
        .opacity(source.isIdle ? 0.45 : 1)
        // One element: a name, a value, an adjustment and the mute as a named
        // action — the bar is a bare drag, which VoiceOver and the keyboard
        // cannot drive, so the adjustment has to be offered here.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source.id == "output" ? "Output volume" : "\(source.name) volume")
        .accessibilityValue(spokenValue)
        .accessibilityHint(source.failure ?? "")
        .accessibilityAdjustableAction { direction in
            guard !source.isIdle else { return }
            switch direction {
            case .increment: source.set(min(1, source.value + 0.05))
            case .decrement: source.set(max(0, source.value - 0.05))
            @unknown default: break
            }
        }
        .accessibilityActions {
            if let mute = source.mute {
                Button("\(mute.name) \(source.name)", action: mute.run)
            }
        }
    }

    /// The level with any mute first, by the output's rule for both — see
    /// `OutputMute.spokenLevel`.
    private var spokenValue: String {
        source.isIdle ? "idle" : OutputMute.spokenLevel(volume: Float(source.value),
                                                         isMuted: source.isMuted)
    }

    private var tooltip: String {
        source.isIdle ? "\(source.name) stopped playing — its place is held for a moment" : source.name
    }

    /// The mute button, or — with nothing to press — the same picture as a
    /// report: an idle app, or an output with no settable mute. No pointing
    /// hand on the report, so it does not promise a click.
    @ViewBuilder
    private var glyph: some View {
        if let mute = source.mute {
            Button(action: mute.run) { glyphImage }
                .buttonStyle(.plain)
                .clickable()
                .help("\(mute.name) \(source.name)")
        } else {
            glyphImage
                .help(tooltip)
        }
    }

    private var glyphImage: some View {
        Group {
            if let icon = source.icon {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .saturation(source.isIdle ? 0 : 1)
            } else {
                Image(systemName: source.symbol).resizable().scaledToFit()
                    .foregroundStyle(source.isMuted ? Theme.needs : Theme.textSecondary)
            }
        }
        .frame(width: Theme.soundIconWidth, height: Theme.soundIconWidth)
        .opacity(source.isMuted && source.icon != nil ? 0.35 : 1)
        .overlay(alignment: .bottomTrailing) {
            if source.isMuted && source.icon != nil {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.needs)
                    .padding(1)
                    .background(Circle().fill(Theme.rowFill))
            }
        }
        .contentShape(Rectangle())
    }
}

/// A level as a filled bar with its name and figure written inside it.
///
/// **Set to where you press, like any slider.** It was dragged relative to the
/// old level, so that a stray press on the name could not spike the volume —
/// and the owner found that a click did nothing, which is worse (2026-10-01).
/// The bar is the slider; the name and figure are written on it, not buttons.
///
/// Live while muted, deliberately: muted is where you set the level you want to
/// come back to. Grey, to say it is not being heard.
struct LevelBar: View {
    let source: LevelSource
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(source.isIdle ? 0.03 : 0.07))
                if !source.isIdle {
                    Rectangle()
                        .fill(source.isMuted ? Color.white.opacity(0.13) : Theme.running.opacity(0.55))
                        .frame(width: width * min(max(source.value, 0), 1))
                }
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(Theme.chrome(11, .medium))
                        .foregroundStyle(source.isMuted ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(source.isIdle ? "—" : (source.isMuted ? "Muted" : "\(percent)%"))
                        .font(Theme.chrome(10.5, .medium))
                        .foregroundStyle(source.isMuted ? Theme.needs : Theme.textSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
            }
            // Clipped rather than drawn as a capsule of its own, so a low level
            // is a thin sliver at the left and not a round blob the size of 10%.
            .clipShape(Capsule())
            .contentShape(Capsule())
            // The level goes where the pointer is: a click lands there, and a
            // drag follows the pointer from wherever it started.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard !source.isIdle else { return }
                        if let level = Self.level(at: drag.location.x, width: width) {
                            source.set(level)
                        }
                    }
            )
            .help(source.isIdle ? "\(source.name) stopped playing — its place is held for a moment"
                                : "Slide to change \(source.name == "Volume" ? "the volume" : source.name + "'s volume")")
        }
        .frame(height: height)
    }

    private var percent: Int { Int((source.value * 100).rounded()) }

    /// The level under a point on the bar, clamped to 0–1; nil for a bar with
    /// no width yet.
    static func level(at x: CGFloat, width: CGFloat) -> Double? {
        guard width > 0 else { return nil }
        return Double(min(1, max(0, x / width)))
    }
}
