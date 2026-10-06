import AppKit
import SwiftUI
import AirlockCore

/// The notch design language: obsidian glass, SF Pro chrome, one semantic accent
/// trio (warm needs-you / cool running / green done). Mono is quarantined to
/// genuine code. This is the "material, not flat black" direction from the brief.
enum Theme {
    /// Resolved against the effective appearance, so the panel's own
    /// `.colorScheme` flips the whole palette. Needed because the surface is no
    /// longer always black: on light glass, a palette that is light-on-dark by
    /// construction would be white text on a pale background.
    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// One value in both schemes, and a deliberate choice rather than a missing
    /// pair. The brand accents ARE the brand in either appearance: an orange
    /// that shifts when the surface does is two oranges, and a product whose
    /// mark changes colour with a system setting does not have a mark. Only the
    /// two ends of the value scale — the body and the eyes — flip, because those
    /// have to invert against the ground or they disappear into it.
    private static func fixed(_ color: NSColor) -> Color { Color(nsColor: color) }

    // Grounds
    /// Text drawn ON a filled accent (the today circle). Stays dark in both
    /// schemes because the fill it sits on is saturated either way.
    static let pill = Color(red: 0.020, green: 0.024, blue: 0.031)
    static let panelStroke = adaptive(dark: .white.withAlphaComponent(0.11),
                                      light: .black.withAlphaComponent(0.12))
    static let rowFill = adaptive(dark: .white.withAlphaComponent(0.035),
                                  light: .black.withAlphaComponent(0.05))
    static let rowStroke = adaptive(dark: .white.withAlphaComponent(0.05),
                                    light: .black.withAlphaComponent(0.09))

    // Text (cool off-white, chosen not defaulted)
    static let textPrimary = adaptive(dark: rgb(0.918, 0.929, 0.953), light: rgb(0.09, 0.10, 0.12))
    static let textSecondary = adaptive(dark: rgb(0.57, 0.61, 0.68), light: rgb(0.33, 0.36, 0.42))
    static let textTertiary = adaptive(dark: rgb(0.38, 0.42, 0.48), light: rgb(0.52, 0.55, 0.60))
    static let codeText = adaptive(dark: rgb(0.953, 0.851, 0.659), light: rgb(0.42, 0.30, 0.06))

    // Agent brand identities (leading glyphs)
    static let claudeCoral = adaptive(dark: rgb(0.851, 0.467, 0.341), light: rgb(0.72, 0.33, 0.19))
    static let codexTint = adaptive(dark: rgb(0.75, 0.78, 0.82), light: rgb(0.40, 0.43, 0.47))

    // Semantic accents — darkened on light so they hold contrast rather than
    // glowing off a pale backdrop.
    // The brand palette, one value each in both appearances.
    //
    // **Measured cost, accepted knowingly.** These are tuned for the panel,
    // whose ground is `pill` (#050608), and there they run 5.2:1 (red) to
    // 10.2:1 (green) — every one clears AA. On a WHITE ground they do not:
    // green is 2.0:1, orange and grey 2.5:1, blue 3.2:1. That is fine for the
    // dots, fills and glyphs these mostly are, and thin for anything that ends
    // up as small text on light glass or in Settings. If one reads badly there,
    // the fix is that call site taking a darker token — not this table
    // splitting in two, which is the thing being deliberately avoided.
    static let needs = fixed(rgb(0.941, 0.541, 0.141))
    static let running = fixed(rgb(0.231, 0.576, 0.941))
    static let done = fixed(rgb(0.243, 0.812, 0.557))
    static let danger = fixed(rgb(0.910, 0.282, 0.247))
    /// Airlock itself working — dictation listening, the assistant thinking.
    ///
    /// Deliberately NOT `running`: that one means somebody else's agent is
    /// busy, and this app has a large second audience who will never start one.
    /// Voice, the command bar and the clipboard are theirs, and this is the
    /// colour that says the product is doing something for them.
    static let assistant = fixed(rgb(0.545, 0.361, 0.965))
    /// At rest, and for states that are true but not urgent — offline, idle.
    /// A grey, never an accent: the resting island must not read as an alarm.
    static let resting = fixed(rgb(0.639, 0.639, 0.639))

    // The bloub. Two ends, named for their role and not their brightness,
    // because which one is dark flips with the appearance.
    //
    // The source artwork is a near-black body with near-white eyes knocked out
    // of it. Held literally that is invisible on obsidian, so in dark the pair
    // swaps: a light body with eyes the colour of the panel behind it — which is
    // the knockout the SVG mask actually meant, arrived at through `adaptive`
    // rather than a second asset.
    // The body and the eyes are the two that DO flip, and the only two. They are
    // the ends of the value scale rather than accents: a near-white body on a
    // light surface is invisible, so it inverts with the ground while every
    // brand colour above stays put.
    static let bloubBody = adaptive(dark: rgb(0.945, 0.937, 0.914),
                                    light: rgb(0.039, 0.039, 0.047))
    static let bloubEyes = adaptive(dark: rgb(0.020, 0.024, 0.031),
                                    light: rgb(0.976, 0.976, 0.976))

    static func accent(for status: SessionStatus) -> Color {
        switch status {
        case .needsAttention, .waitingQuestion: return needs
        case .running, .starting: return running
        case .done, .idle: return done
        case .error: return danger
        }
    }

    // MARK: - Type

    /// The user's text size, 1.0–1.4. Written by `NotchAppearanceModel` and by
    /// nothing else.
    ///
    /// A static, and that deserves justification because this codebase prefers
    /// the compiler to convention. The alternatives do not work here:
    /// `@Environment` cannot reach a static func, and converting ~80 call sites
    /// to view modifiers still would not serve `PermissionCardView`, which
    /// builds a `Font` VALUE inside a `Text + Text` concatenation; passing the
    /// appearance down is dead on arrival because `DynamicNotch` stores the
    /// view value once, at construction.
    ///
    /// The cost is that SwiftUI cannot observe it, so a change alone re-renders
    /// nothing. `NotchRootView` pairs this with `.id(appearance.textScale)` on
    /// the expanded content, and THE PAIR IS LOAD-BEARING: delete the `.id` and
    /// the slider silently moves nothing — worse, a parent re-render would scale
    /// section headers and not rows, which reads as "mostly working". Both ends
    /// say so.
    @MainActor private(set) static var textScale: CGFloat = 1

    /// The ceiling, and 1.4 rather than Apple's 200% deliberately.
    ///
    /// At 2.0 the panel does not merely look large, it looks BROKEN: the media
    /// title clips out of its container, the calendar week strip collapses to
    /// ellipses, and device names truncate — because this scales fonts and not
    /// the containers around them, several of which are hard-coded (104pt
    /// artwork, 30pt calendar cell). A control whose top setting looks broken is
    /// worse than a narrower one that always looks right.
    ///
    /// Reaching a genuine 200% means scaling those frames too, and probably a
    /// different layout at large sizes — real work, verifiable only by eye. Until
    /// then this is an honest text-size nudge and Settings says so rather than
    /// claiming a conformance it does not have.
    static let maxTextScale: CGFloat = 1.4

    /// The Sound card's glyph column, shared by the output row and every app
    /// row so every bar starts at the same x: the whole point of that card is
    /// that an app's level and the system output read on the same scale. One
    /// of the hard-coded frames `maxTextScale` is capped for.
    static let soundIconWidth: CGFloat = 16

    /// Only `NotchAppearanceModel` should call this. Clamped HERE as well as at
    /// the slider, so a stale or hand-edited preference cannot exceed the range
    /// the layout was checked against.
    @MainActor static func setTextScale(_ scale: CGFloat) {
        textScale = min(max(scale, 1), maxTextScale)
    }

    /// Panel body type — SF Pro, and the only tier that follows the setting.
    ///
    /// The 10pt macOS floor still applies at scale 1: raising the literals was
    /// a separate change precisely so no clamp had to be smuggled in here,
    /// where it would silently alter every default size while looking like
    /// scale plumbing.
    @MainActor
    static func chrome(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * textScale, weight: weight, design: .default)
    }

    /// Type that must NOT follow the setting: the compact island, which the kit
    /// hard-clips to the physical notch height. Growing text there does not
    /// overflow gracefully — it is cut off by the window, and the window is the
    /// size of a camera housing.
    static func fixed(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// The band flanking the housing. Scales, but capped: its width budget is
    /// measured in `NotchAppearanceModel.trailingGutterDemand`, and unbounded
    /// growth there pushes the usage figures behind the camera.
    @MainActor
    static func gutter(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * min(textScale, 1.25), weight: weight, design: .default)
    }

    /// Funcs rather than constants now, because a stored `let` is evaluated once
    /// and could never follow the setting.
    @MainActor static var code: Font { .system(size: 12 * textScale, weight: .medium, design: .monospaced) }
    @MainActor static var label: Font { .system(size: 10 * textScale, weight: .semibold, design: .monospaced) }

    // Motion. One place that decides what Reduce Motion means here, because the
    // answer is not "no animation" and being wrong in either direction costs
    // something real. Apple asks for two DIFFERENT things (HIG, Accessibility →
    // "Be cautious with fast-moving and blinking animations"): reduce
    // "automatic and repetitive animations, including zooming, scaling, and
    // peripheral motion", and separately "tighten animation springs to reduce
    // bounce effects". Switching every animation off satisfies neither — it
    // removes the pointer feedback, the drop affordance and the paste
    // confirmation, and the guidance elsewhere lists tracking a gesture as
    // something to DO.

    /// A perpetual, automatic effect — a pulse, a blink, a breath. These are
    /// the ones the guidance names first, and Reduce Motion switches them off.
    ///
    /// Returns nil rather than `.default` so the caller has nothing to attach.
    /// That distinction matters: a `repeatForever` animation, once attached,
    /// keeps driving the property it was attached to (see `MediaWaveView`), so
    /// the caller must ALSO make the change a change of view identity — a
    /// degraded animation swapped in underneath a running one changes nothing.
    static func perpetual(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    // One-shot movements are the five named motions and their calm versions
    // (`Motion`, Notch/NotchMotion.swift), and every other timing is a named
    // effect there (`MotionEffect`). This file keeps only the rule above.
}

/// Pointing hand over anything you can click.
///
/// The notch is a custom surface: its rows and option cards are drawn views with
/// tap gestures, not AppKit controls, so nothing gives the pointer a reason to
/// change. macOS reserves the hand for links rather than buttons, but that
/// convention assumes standard chrome you can recognise on sight — here a
/// question option and a paragraph of text look equally inert until the cursor
/// says otherwise.
///
/// Driven by `NSCursor` rather than SwiftUI's `.pointerStyle`, which did nothing
/// at all in this window. The panel is a non-activating `NSPanel` that is
/// usually not key, and pointer styles resolve through the responder chain that
/// such a window sits outside of. `.onHover` fires regardless — it is already
/// what highlights rows — so the cursor is set by hand.
///
/// None of it shows while another app is frontmost — which, for a
/// non-activating panel, is always — unless `BackgroundCursor` is on.
///
/// Push/pop rather than `set()`, because the system restores the window's own
/// cursor on the next mouse-moved event and a plain `set` is undone before you
/// finish crossing the row.
private struct Clickable: ViewModifier {
    /// Mirrors whether THIS view pushed. Without it a stray extra hover-in
    /// would push twice and the single pop on exit would leave the hand behind.
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            // A tap target with transparent padding is only hoverable where it
            // is painted, so without this the cursor flickers as you cross the
            // gaps between glyphs.
            .contentShape(.rect)
            .onHover { inside in
                if inside, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                    HoverTrace.note("cursor hand pushed")
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            // The panel can collapse out from under the pointer — on a hotkey,
            // on a decision, on hover-out grace. Without this the hand stays
            // pushed with no view left to pop it, and the whole system is stuck
            // with a pointing-hand cursor.
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

extension View {
    func clickable() -> some View { modifier(Clickable()) }
}
