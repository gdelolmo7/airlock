import AirlockCore
import AppKit
import SwiftUI

/// Expanded-panel media card: artwork · title/artist · transport · timeline.
/// Ambient by contract — it renders when present, it never opens the island.
///
/// **Redrawn smaller and quieter on 2026-10-01**, when Home became just this
/// card and the controls under it. What went: the "now playing · spotify"
/// caption (the badge on the cover already names the player), the second
/// elapsed/total clock beside the transport (the timeline carries it once),
/// and the gradient banner (one ground for both Home cards). The drawing
/// itself is `NowPlayingCard`, which takes values rather than the model, so a
/// snapshot test can render exactly what ships.
struct MediaSectionView: View {
    @Environment(MediaWidgetModel.self) private var media

    var body: some View {
        // Now-playing, and nothing else. Output switching and per-app levels
        // hung off the bottom of this card until they earned their own — which
        // they did the moment a browser could be the only thing making sound,
        // because this card is gated on Spotify or Music being detected and a
        // browser is exactly when neither is. See `SoundSectionView`.
        if let state = media.state {
            NowPlayingCard(
                title: state.title,
                artist: state.artist,
                playerName: state.player.displayName,
                isPlaying: state.isPlaying,
                artwork: ArtworkView(url: state.artworkURL, size: MediaCardMetrics.artworkSize,
                                     source: state.player),
                artworkLabel: state.artworkURL == nil
                    ? "\(state.player.displayName) icon"
                    : "Album artwork, \(state.player.displayName)",
                timeline: timeline(state),
                onOpen: { media.activatePlayer() },
                onPrevious: { media.previous() },
                onTogglePlay: { media.togglePlay() },
                onNext: { media.next() })
        } else if let refused = media.refusedPlayer {
            MediaRefusedCard(player: refused.displayName)
        } else if let dormant = media.dormant {
            let isRunning = media.runningPlayers.contains(dormant.player)
            DormantTrackCard(
                title: dormant.title,
                artist: dormant.artist,
                caption: MediaWidgetModel.dormantCaption(
                    player: dormant.player.displayName,
                    ago: Self.elapsed.localizedString(for: dormant.since, relativeTo: Date()),
                    isRunning: isRunning),
                button: MediaWidgetModel.dormantButton(player: dormant.player.displayName, isRunning: isRunning),
                artwork: ArtworkView(url: dormant.artworkURL, size: MediaCardMetrics.artworkSize,
                                     source: dormant.player),
                onReopen: { media.reopenDormantPlayer() })
        }
    }

    private static let elapsed: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Elapsed, the bar, and the total on ONE line — the bar is a CONTROL, not
    /// a readout, whenever the player and the track both allow it.
    ///
    /// The whole row is one accessibility element. Three separate ones would
    /// announce "one twenty-three", "three forty-five" and an unlabelled
    /// progress indicator, and the adjustable action would have nothing
    /// sensible to hang off. The value is stated in TIME rather than as a
    /// percentage: the number a person wants when scrubbing is the clock.
    ///
    /// Read from the model at action time rather than from `context.date`: the
    /// timeline redraws once a second, so a captured position is up to a second
    /// stale by the time a key press lands on it, and fifteen of those compound.
    private func timeline(_ state: MediaPlayerState) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if state.duration > 0 {
                let position = media.displayPosition(at: context.date)
                MediaTimelineRow(
                    position: position,
                    duration: state.duration,
                    isSeekable: media.canSeek,
                    onBegin: { media.beginScrub(at: $0 * state.duration) },
                    onMove: { media.moveScrub(to: $0 * state.duration) },
                    onEnd: { media.endScrub(at: $0 * state.duration) })
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(Self.clock(position)) of \(Self.clock(state.duration))")
                    .modifier(SeekAdjustment(enabled: media.canSeek, media: media))
                    // A live drag is committed on release; the panel going away
                    // underneath one is the case SwiftUI never reports. Without
                    // this the scrub hold is never released and the panel stays
                    // expanded with nothing holding it open.
                    .onDisappear { media.cancelScrub() }
            } else {
                // Live radio, and podcast states that report no total. The row
                // still draws — an elapsed time is worth showing for a stream
                // that is plainly playing — with "Live" where the total goes.
                MediaTimelineRow(position: state.interpolatedPosition(at: context.date),
                                 duration: nil, isSeekable: false,
                                 onBegin: { _ in }, onMove: { _ in }, onEnd: { _ in })
            }
        }
    }

    /// Hours only when there are hours. `%d:%02d` alone turned an eight-hour
    /// stream — the ambient-radio and long-podcast case this row exists for —
    /// into "487:03", and a total of "1440:00" beside it. Under an hour the
    /// string is byte-for-byte what it always was: no leading "0:", so a
    /// three-minute track still reads "3:07".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        guard hours > 0 else {
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
    }
}

/// The ground both Home cards sit on, so the tab reads as one surface.
struct HomeCardBackground: ViewModifier {
    @Environment(\.fillsPairedRow) private var fillsRow

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxHeight: fillsRow ? .infinity : nil, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.rowFill)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.rowStroke, lineWidth: 1))
            )
    }
}

/// A Dashboard card's title line: a glyph, a name, and whatever the card keeps
/// on the right. Shared so Sound and This Mac read as two of a kind rather
/// than two cards that each invented a caption (owner, 2026-10-01).
struct CardHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.running)
                .frame(width: 14)
            Text(title)
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 6)
            trailing()
        }
        .frame(minHeight: 20)
    }
}

extension CardHeader where Trailing == EmptyView {
    init(symbol: String, title: String) {
        self.init(symbol: symbol, title: title) { EmptyView() }
    }
}

/// A track that is playing or paused: cover on the left, title and transport
/// on one line, the timeline under them.
struct NowPlayingCard<Artwork: View, Timeline: View>: View {
    let title: String
    let artist: String
    let playerName: String
    let isPlaying: Bool
    let artwork: Artwork
    let artworkLabel: String
    let timeline: Timeline
    var onOpen: () -> Void
    var onPrevious: () -> Void
    var onTogglePlay: () -> Void
    var onNext: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion



    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            artwork
                // Paused is otherwise only legible from the play glyph. Dimming
                // the biggest thing on the card says it at a glance.
                .opacity(isPlaying ? 1 : 0.45)
                .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: isPlaying)
                .onTapGesture(perform: onOpen)
                .clickable()
                .help("Open \(playerName)")
                // The player is named here and nowhere else on this element:
                // the badge on a cover is an unlabelled image.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(artworkLabel)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onOpen() }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Both truncate at one line and long titles are common.
                        // The tooltip is the whole affordance, deliberately: a
                        // marquee is a permanently animating surface.
                        Text(title)
                            .font(Theme.chrome(14, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(artist)
                            .font(Theme.chrome(12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    // A new track cross-fades in rather than the names snapping.
                    .contentTransition(.opacity)
                    .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpen)
                    .clickable()
                    .help("\(title) — \(artist)\nOpen \(playerName)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(title), \(artist)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens \(playerName)")
                    .accessibilityAction { onOpen() }

                    HStack(spacing: 6) {
                        transportButton("backward.fill", label: "Previous", size: 13, action: onPrevious)
                        // The one element that owns the playing state: the label
                        // says what pressing it does, the value where things stand.
                        Button(action: onTogglePlay) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                                .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: isPlaying)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Theme.textPrimary.opacity(0.12)))
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .clickable()
                        .accessibilityLabel(isPlaying ? "Pause" : "Play")
                        .accessibilityValue(isPlaying ? "Playing" : "Paused")
                        transportButton("forward.fill", label: "Next", size: 13, action: onNext)
                    }
                }

                timeline
            }
        }
        .modifier(HomeCardBackground())
    }

    /// The label is required, not defaulted: an unlabelled `Image(systemName:)`
    /// inside a plain button leaves VoiceOver reading the symbol name.
    private func transportButton(_ symbol: String, label: String, size: CGFloat,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .accessibilityLabel(label)
    }
}

/// Every player has quit, and the card stays — see `MediaWidgetModel.dormant`
/// — so the controls below do not jump up under a pointer already reaching for
/// them. Everything that would still be moving is gone; what is left is what
/// was true, when, and one button to make it true again.
struct DormantTrackCard<Artwork: View>: View {
    let title: String
    let artist: String
    let caption: String
    /// "Open Spotify", or "Show Spotify" while it is already open — see
    /// `MediaWidgetModel.dormantButton`.
    let button: String
    let artwork: Artwork
    var onReopen: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            artwork
                // Greyed: the same treatment a paused track gets, taken further,
                // and the whole signal that the card is a memory.
                .saturation(0)
                .opacity(0.4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.chrome(14, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .help(title)
                Text(artist)
                    .font(Theme.chrome(12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Text(caption)
                    .font(Theme.chrome(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onReopen) {
                Text(button)
                    .font(Theme.chrome(12, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(Theme.textPrimary.opacity(0.10)))
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .clickable()
        }
        .modifier(HomeCardBackground())
    }
}

/// Automation is off for the player, so nothing about the track can be read.
/// Said in the card's own place rather than leaving it empty, which looked
/// exactly like nothing playing. Values in, so the gallery draws this.
struct MediaRefusedCard: View {
    let player: String

    var body: some View {
        ProblemCard(icon: "music.note", sentence: MediaWidgetModel.refusedSentence(player: player),
                    button: PermissionPage.button, action: { PermissionPage.automation.open() })
    }
}

/// Settings' line under "Wave follows the audio": progress in grey, a problem
/// as a problem card, and the permission's page one press away when the
/// permission is the cause. Values in, so the gallery draws exactly this.
struct WaveTapStatusLine: View {
    let status: String
    let isProblem: Bool
    let needsPermission: Bool

    var body: some View {
        if isProblem {
            if needsPermission {
                ProblemCard(sentence: status, button: PermissionPage.button,
                            action: { PermissionPage.permission(.screenRecording).open() })
            } else {
                ProblemCard(sentence: status)
            }
        } else {
            Label(status, systemImage: "waveform")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Elapsed · bar · total, on one line. `duration == nil` is a live stream.
struct MediaTimelineRow: View {
    let position: TimeInterval
    let duration: TimeInterval?
    let isSeekable: Bool
    var onBegin: (Double) -> Void
    var onMove: (Double) -> Void
    var onEnd: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(MediaSectionView.clock(position))
                .frame(minWidth: 30, alignment: .leading)
            if let duration {
                SeekBarView(fraction: position / duration, isSeekable: isSeekable,
                            onBegin: onBegin, onMove: onMove, onEnd: onEnd)
            } else {
                // Where the bar would be, empty. A bar at zero is a claim — "at
                // the start of something" — and there is no something.
                Capsule().fill(Theme.rowStroke).frame(height: 4)
            }
            Text(duration.map(MediaSectionView.clock) ?? "Live")
                .frame(minWidth: 30, alignment: .trailing)
        }
        .font(Theme.chrome(10, .medium))
        .foregroundStyle(Theme.textTertiary)
        .monospacedDigit()
        .frame(height: 12)
    }
}

/// The timeline, as something you can drop the playhead into.
///
/// A drawn bar rather than a `ProgressView`, for the reason everything else on
/// this surface is drawn: `ProgressView` is a readout with no gesture and no
/// thumb, and a `Slider` brings AppKit chrome that belongs to a settings sheet
/// rather than a 640pt panel over the notch.
///
/// **`minimumDistance: 0`**, so a plain click on the bar is a seek — which is
/// what everyone expects of a progress bar and what a 4pt-tall drag target
/// otherwise makes nearly impossible. The gesture is masked to `.subviews`
/// rather than made conditional in a branch, so the un-seekable case is one
/// view with no gesture attached instead of two views that must be kept
/// looking identical.
///
/// The hit area is 12pt tall against a 4pt track: the drag must be catchable
/// without the eye having to aim at a hairline.
private struct SeekBarView: View {
    /// 0...1. Clamped here rather than trusted, because a live stream that
    /// briefly reports a duration shorter than its own elapsed time would
    /// otherwise draw a fill wider than the card.
    var fraction: Double
    var isSeekable: Bool
    var onBegin: (Double) -> Void
    var onMove: (Double) -> Void
    var onEnd: (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDragging = false
    /// What the bar draws. Follows `fraction`, gliding through each second of
    /// playback instead of stepping once a second (2026-10-04); a seek, a new
    /// track or a drag jumps, since a bar sweeping back to 0:00 would be a lie
    /// about where the music went.
    @State private var drawn: Double?

    private static let track: CGFloat = 4
    private static let hitHeight: CGFloat = 12
    private static let thumb: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let filled = width * Self.clamp(drawn ?? fraction)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.rowStroke)
                    .frame(height: Self.track)
                Capsule()
                    .fill(Theme.textSecondary)
                    .frame(width: filled, height: Self.track)
                if isSeekable {
                    // The affordance. Always on rather than revealed on hover:
                    // a bar that only looks draggable once you are already
                    // pointing at it is one nobody discovers, and this panel is
                    // open for a few seconds at a time.
                    Circle()
                        .fill(Theme.textPrimary)
                        .frame(width: Self.thumb, height: Self.thumb)
                        // The pointer answered: it grows when the drag starts
                        // and shrinks when it stops, and keeps doing so under
                        // Reduce Motion, since it follows a gesture.
                        .scaleEffect(isDragging ? 1.3 : 1)
                        .animation(MotionEffect.pointer, value: isDragging)
                        // Centred on the end of the fill, but never hanging off
                        // either end of the track: at 0:00 an uncorrected thumb
                        // sits half outside the bar and into the card's padding,
                        // which is where every track starts. Only the drawing is
                        // pinned — the pointer still maps straight across the
                        // full width, so where you click is where it goes.
                        .offset(x: min(max(filled, Self.thumb / 2),
                                       max(width - Self.thumb / 2, Self.thumb / 2))
                                   - Self.thumb / 2)
                }
            }
            .frame(width: width, height: Self.hitHeight)
            .contentShape(Rectangle())
            .gesture(drag(width: width), including: isSeekable ? .all : .subviews)
        }
        .frame(height: Self.hitHeight)
        .onChange(of: fraction) { old, new in
            // One second of playback is a small step forward; anything else
            // (a seek, a new track) is not playback and is drawn at once.
            let isPlayback = !isDragging && new > old && new - old < 0.1
            withAnimation(isPlayback && !reduceMotion ? MotionEffect.playhead : nil) {
                drawn = new
            }
        }
        // Only where it can be dragged. The pointing hand over a live stream's
        // inert rule would be a promise the row cannot keep.
        .modifier(SeekCursor(enabled: isSeekable))
    }

    /// Position within the bar, not distance travelled: a click and a drag then
    /// mean the same thing, and a drag that overshoots either end pins to it
    /// instead of running away.
    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let fraction = Self.clamp(value.location.x / max(width, 1))
                if isDragging {
                    onMove(fraction)
                } else {
                    isDragging = true
                    onBegin(fraction)
                }
            }
            .onEnded { value in
                isDragging = false
                onEnd(Self.clamp(value.location.x / max(width, 1)))
            }
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// `.clickable()` only when there is something to click, without writing the
/// bar out twice.
private struct SeekCursor: ViewModifier {
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled { content.clickable() } else { content }
    }
}

/// VoiceOver's scrub. Attached only when the timeline really is adjustable —
/// announcing an adjustable control that swallows both arrow keys is worse than
/// announcing a readout.
///
/// 15 seconds a press, the podcast-skip convention: fine enough to land on a
/// verse, coarse enough that crossing a three-minute track is eight presses
/// rather than thirty-six. The model clamps, so holding the key at either end
/// stops rather than wrapping.
private struct SeekAdjustment: ViewModifier {
    var enabled: Bool
    var media: MediaWidgetModel

    static let step: TimeInterval = 15

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAdjustableAction { direction in
                let now = media.displayPosition(at: Date())
                switch direction {
                case .increment: media.seek(to: now + Self.step)
                case .decrement: media.seek(to: now - Self.step)
                @unknown default: break
                }
            }
        } else {
            content
        }
    }
}

/// Now-playing, as a wave that travels rather than three sticks that bounce.
///
/// Its own view because the two say different things: `AgentLampView` means
/// *an agent is working*, and wearing the same shape for "music is playing" made
/// one indicator carry two unrelated meanings in the same island. They shared a
/// three-bar glyph once; the agent side has since moved to an orbit, so the
/// equalizer belongs to music alone.
///
/// **It does not follow the audio, and does not pretend to.** Reading the real
/// signal means a Core Audio process tap on Spotify or Music — a system-audio
/// capture prompt on top of the four permissions this app already asks for, and
/// an app that listens to what you listen to, for the sake of a 16pt
/// decoration. An equalizer glyph is read as "playing", the same way Music.app's
/// own is; it is a state, not a spectrum.
///
/// Driven by ONE implicit animation per bar, deliberately: the phase offsets
/// come from `delay`, so Core Animation owns the motion and SwiftUI never
/// re-evaluates the view. A `TimelineView(.animation)` would have been the
/// obvious way to write a sine wave and would redraw this at ProMotion's 120Hz
/// for as long as anything is playing.
struct MediaWaveView: View {
    var color: Color
    var animated: Bool = true
    /// Live band heights from the audio tap, or empty for the canned loop.
    /// Empty is the honest default: most of the time there is no tap, and a
    /// glyph pretending otherwise is the thing this whole feature was about.
    var levels: [Double] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lifted = false

    private var isLive: Bool { levels.count == Self.heights.count && !reduceMotion }

    /// A crest, so it still reads as a wave standing still — which is exactly
    /// what Reduce Motion leaves on screen.
    private static let heights: [CGFloat] = [6, 10, 14, 11, 7]
    /// Deeper than the agent glyph's 0.55: music should look livelier than a
    /// process thinking.
    private static let trough: CGFloat = 0.42

    /// Two separate view identities, not one view with a branch inside it.
    ///
    /// The first attempt drove one `scaleEffect` from both sources and swapped
    /// the animation modifier — and a `repeatForever` animation, once attached,
    /// keeps driving the property it was attached to. The canned loop went on
    /// oscillating underneath the live values and the bars barely responded to
    /// the audio at all: the tap was working perfectly and the glyph looked
    /// almost exactly as it had before. Giving each mode its own view means the
    /// old animation is torn down with the view that owned it.
    var body: some View {
        Group {
            if isLive {
                live
            } else {
                canned
            }
        }
        // Matched to `AgentLampView` so the compact slot doesn't change height
        // when a session ends and music is what's left.
        .frame(height: 15, alignment: .bottom)
        .accessibilityLabel("Playing")
    }

    /// Heights come straight from the audio. `WaveEnvelope` has already done the
    /// smoothing at 20fps, so all that is wanted here is a lerp between frames —
    /// anything longer would smooth twice and lag the music.
    private var live: some View {
        HStack(alignment: .bottom, spacing: 1.8) {
            ForEach(Array(Self.heights.enumerated()), id: \.offset) { index, height in
                bar(height)
                    .scaleEffect(y: levels[index], anchor: .bottom)
                    .animation(MotionEffect.meter, value: levels[index])
            }
        }
    }

    private var canned: some View {
        HStack(alignment: .bottom, spacing: 1.8) {
            ForEach(Array(Self.heights.enumerated()), id: \.offset) { index, height in
                bar(height)
                    .scaleEffect(y: lifted ? 1.0 : Self.trough, anchor: .bottom)
                    .animation(reduceMotion ? .default : MotionEffect.musicBars(bar: index), value: lifted)
            }
        }
        .onAppear {
            guard animated, !reduceMotion else { return }
            lifted = true
        }
    }

    private func bar(_ height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.25)
            .fill(color)
            .frame(width: 2.5, height: height)
    }
}

struct ArtworkView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let url: URL?
    let size: CGFloat
    /// The app the sound is coming from, when there is room to say so. Nil in
    /// the compact island, where a 15pt square has nothing to badge.
    var source: MediaPlayerKind? = nil

    private var sourceIcon: NSImage? {
        source.flatMap { PlayerIcon.image(for: $0) }
    }

    var body: some View {
        Group {
            if let url {
                // The cover fades in over the placeholder instead of popping.
                AsyncImage(url: url, transaction: Transaction(animation: Motion.swap.animation(reduceMotion: reduceMotion))) { phase in
                    if let image = phase.image {
                        cover(image)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
    }

    /// Badged here and not on the view as a whole: the placeholder below already
    /// IS the source icon, and the same image twice on one square says nothing
    /// the once did not. The badge sits OUTSIDE the clip so the corner radius
    /// does not bite a piece out of it.
    private func cover(_ image: Image) -> some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay(alignment: .bottomTrailing) { badge }
    }

    /// The source app, corner-badged. Nothing else on the card says where the
    /// audio is coming from: two players can be installed, only one is playing,
    /// and the title alone does not tell you which — least of all for a podcast
    /// that could equally be in either.
    @ViewBuilder
    private var badge: some View {
        if let icon = sourceIcon {
            let side = size * 0.26
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
                // Album art is arbitrary; a bare icon over a pale cover
                // disappears into it. A literal scrim rather than one of
                // `Theme`'s grounds because this sits on the artwork, not on
                // the panel — what it has to hold against is not the appearance.
                .background(
                    Circle()
                        .fill(.black.opacity(0.55))
                        .padding(-side * 0.14)
                )
                .padding(size * 0.05)
        }
    }

    /// With no cover to show, the source app's own icon says more than a music
    /// note does — and it is the same image the badge would have drawn, so the
    /// card never shows two different answers to "what is playing this".
    ///
    /// **Contrast raised after it was reported as the notch disappearing.** The
    /// compact island passes no `source`, so this is the music note — and at
    /// 15pt, in an 8%-white square, with `textTertiary` (0.38, 0.42, 0.48) on an
    /// island fused to a black camera housing, it was invisible. Playing a track
    /// with no cover art therefore looked exactly like the app quitting, and it
    /// is how "it hid it again" survived the resting-state fix: `.idle` was
    /// legible, and `.artwork` — the rung ABOVE it — was not.
    ///
    /// The expanded card draws this too, at 44pt, where the old values were
    /// merely quiet rather than absent. Legible there is legible here; the
    /// reverse was not true.
    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color.white.opacity(0.14))
            if let icon = sourceIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 0.52, height: size * 0.52)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.95))
            }
        }
    }
}

/// The playing app's icon, looked up once and kept.
///
/// The same lookup as `AppVolumeModel.icon(for:)`, and cached for the same
/// reason: `runningApplications(withBundleIdentifier:)` on every redraw is a lot
/// of work for an image that changes when the app is reinstalled and never
/// otherwise. It differs in one way — a MISS is not cached. The mixer only ever
/// asks about apps that are audible by definition, whereas a player can be
/// launched a moment after something first asked, and a nil remembered then
/// would leave the badge missing for the rest of the session.
@MainActor
private enum PlayerIcon {
    static func image(for kind: MediaPlayerKind) -> NSImage? {
        if let cached = cache[kind.bundleID] { return cached }
        guard let icon = NSRunningApplication
            .runningApplications(withBundleIdentifier: kind.bundleID)
            .first?.icon else { return nil }
        cache[kind.bundleID] = icon
        return icon
    }

    private static var cache: [String: NSImage] = [:]
}

/// Sizes the media cards share, outside the generic views so callers can name
/// them without spelling out type parameters.
enum MediaCardMetrics {
    static let artworkSize: CGFloat = 64
}
