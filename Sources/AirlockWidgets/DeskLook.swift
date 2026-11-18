import SwiftUI
import AirlockCore

/// The widget's colours. In full colour it is drawn on the same ground as
/// the notch (Settings › Appearance: Black, Dark glass or Light glass), which
/// the app passes along in the snapshot. Faded is the desktop's own look,
/// when a window is in front and every widget takes one tint: then a ticked
/// to-do is a filled circle and an open one a ring, so it reads with no
/// colour at all.
///
/// The values are the app's `Theme` (the widget cannot import the app): the
/// notch's obsidian, Theme's text greys for dark and light, and the brand
/// blue for Bloub, the ticks and the progress bar, as on the app icon. Keep
/// the two in step.
struct DeskLook: Equatable {
    var card: Color
    /// Glass under the card: the two glass grounds. The card colour then
    /// only tints it, and still carries the text if the desktop draws no
    /// glass.
    var glass: Bool
    var fg: Color
    var fg2: Color
    var fg3: Color
    var well: Color
    /// Ticks and the progress bar: the brand blue.
    var accent: Color
    /// The check drawn on a filled circle.
    var on: Color
    /// A button: its fill and its words. In full colour, words in `on` on
    /// the accent. In faded the desktop draws the widget as one tint, where
    /// dark words on a light pill are not drawn at all and the button reads
    /// as a blank white bar, so the pill is a soft tint and the words the
    /// tint itself.
    var buttonFill: Color? = nil
    var buttonText: Color? = nil
    var pill: Color { buttonFill ?? accent }
    var pillText: Color { buttonText ?? on }
    var bloub: Color
    var bloubEyes: Color
    /// The notch's warm "needs you" and green "finished" (Theme.needs,
    /// Theme.done). In faded they are the tint, like everything else.
    var needs: Color = Color(red: 0.941, green: 0.541, blue: 0.141)
    var done: Color = Color(red: 0.243, green: 0.812, blue: 0.557)

    /// Theme.pill, the notch's obsidian.
    private static let obsidian = Color(red: 0.020, green: 0.024, blue: 0.031)
    /// Theme.running, the brand blue (the app icon's Bloub).
    private static let blue = Color(red: 0.231, green: 0.576, blue: 0.941)

    /// `fadedDark` is the system's scheme, which picks the tint in faded.
    static func make(surface: DeskSurface, faded: Bool, fadedDark: Bool) -> DeskLook {
        if faded {
            let dark = fadedDark
            let tint = dark ? Color.white : Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
            let under = dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255) : Color.white
            return DeskLook(
                card: dark ? Color(red: 78 / 255, green: 80 / 255, blue: 92 / 255, opacity: 0.34)
                    : Color(white: 1, opacity: 0.36),
                glass: false,
                fg: tint, fg2: tint.opacity(0.7), fg3: tint.opacity(0.5), well: tint.opacity(0.1),
                accent: tint, on: under,
                buttonFill: tint.opacity(0.18), buttonText: tint,
                bloub: tint, bloubEyes: under, needs: tint, done: tint)
        }
        switch surface {
        case .black, .darkGlass:
            return DeskLook(
                card: surface == .black ? obsidian : obsidian.opacity(0.55),
                glass: surface.isGlass,
                fg: Color(red: 0.918, green: 0.929, blue: 0.953),
                fg2: Color(red: 0.57, green: 0.61, blue: 0.68),
                fg3: Color(red: 0.38, green: 0.42, blue: 0.48),
                well: Color.white.opacity(0.10),
                // Text on a filled accent stays dark in both schemes (Theme.pill).
                accent: blue, on: obsidian,
                bloub: blue, bloubEyes: obsidian)
        case .lightGlass:
            let fg = Color(red: 0.09, green: 0.10, blue: 0.12)
            return DeskLook(
                card: Color(white: 1, opacity: 0.6),
                glass: true,
                fg: fg,
                fg2: Color(red: 0.33, green: 0.36, blue: 0.42),
                fg3: Color(red: 0.52, green: 0.55, blue: 0.60),
                well: fg.opacity(0.08),
                accent: blue, on: obsidian,
                bloub: blue, bloubEyes: obsidian)
        }
    }
}

/// The ground under the widget: the card colour, over the system's own
/// Liquid Glass when the notch is set to glass.
struct DeskGround: View {
    var look: DeskLook
    var body: some View {
        if look.glass {
            ZStack {
                Color.clear.glassEffect(.regular, in: .rect)
                look.card
            }
        } else {
            look.card
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The design's type. Funnel Display and DM Mono are not in the app, so
/// the system's own faces stand in: SF for the titles, SF Mono for numbers
/// and times. Both are close in width, so the layout holds.
enum DeskType {
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func text(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight)
    }
}
