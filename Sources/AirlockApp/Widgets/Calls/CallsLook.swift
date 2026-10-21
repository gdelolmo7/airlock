import AirlockCore
import AppKit
import SwiftUI

/// What the Calls tab and the call notes window add to `Theme`: each app's
/// own colour for its tile, one colour per person on a call, and the lighter
/// tints that text in an accent takes on a dark ground.
///
/// The accents stay `Theme`'s (`running` for Take notes, `needs` for to-dos,
/// `assistant` for anything Airlock wrote); only their text is lifted, since
/// the panel's accents read dim as 11pt words on black.
enum CallsLook {
    // MARK: - Text in an accent

    /// "Take notes", on its blue.
    static let takeText = adaptive(dark: rgb(0x7DB8F7), light: rgb(0x1F6FC5))
    /// "3 to-dos" and the notes window's badges, on their orange.
    static let todoText = adaptive(dark: rgb(0xF5A55A), light: rgb(0xB35A0B))
    /// When a line was said ("0:23"), and the transcript's marks: Airlock's
    /// purple, a step lighter.
    static let saidText = rgb(0xA88BFA)
    /// The summary's label.
    static let summaryText = rgb(0xB79CFB)
    /// The person's own notes: a warm paper yellow, apart from every colour
    /// Airlock writes in.
    static let yours = rgb(0xF3D9A8)
    static let decisions = Theme.done
    static let keyPoints = rgb(0x4A9BFF)
    static let questions = rgb(0x4FC3D9)
    /// The topics of notes written online: where the key points were.
    static let topics = keyPoints
    /// "Check these words": an amber that asks for a look, not an alarm.
    static let words = rgb(0xF2C14E)
    /// A recording added afterwards and its reading: its tile, the bar, the
    /// words that count it.
    static let recording = rgb(0x4FC3D9)

    // MARK: - The notes window, always dark

    /// The list down the side, a step off the window's black.
    static let sidebar = rgb(0x0C0D11)
    /// What Airlock wrote, in a card: a little under white.
    static let noteText = rgb(0xD5D9E1)
    static let summaryBody = rgb(0xE2E5EC)
    /// What was said, in the transcript.
    static let spokenText = rgb(0xDDE1E8)
    /// Words on the window's buttons, and a to-do's owner.
    static let quietText = rgb(0xC9CED8)
    /// A to-do's empty circle.
    static let openBox = rgb(0x5A6372)

    // MARK: - People

    /// You, in the blue of your own side of the call.
    static let you = rgb(0x4A9BFF)
    /// Everyone else, in the order they sit on the call (`CallPeople.Seat`).
    static let others: [Color] = otherValues.map(rgb)
    private static let otherValues: [UInt32] = [0xF5A55A, 0x3ECF8E, 0xF472B6, 0xA78BFA, 0x4FC3D9, 0xF3D9A8]

    static func colour(for seat: CallPeople.Seat) -> Color {
        switch seat {
        case .you: you
        case .other(let index): others[index % others.count]
        case .unknown: Theme.textSecondary
        }
    }

    /// The same colour as 0xRRGGBB, for working out what reads on it: a
    /// face's eyes.
    static func value(for seat: CallPeople.Seat) -> UInt32 {
        switch seat {
        case .you: 0x4A9BFF
        case .other(let index): otherValues[index % otherValues.count]
        case .unknown: 0x919CAD  // Theme.textSecondary on the window's dark
        }
    }

    // MARK: - Apps

    /// The app's own colour, as its logo is known by: Meet's green,
    /// WhatsApp's, Slack's pink. The camera for Zoom is blue, the room's
    /// people are purple, a phone call green, a recording teal.
    static func tint(for kind: CallGlyph.Kind) -> Color {
        switch kind {
        case .logo(let name): brands[name].map(rgb) ?? Theme.textSecondary
        case .symbol("video.fill"): rgb(0x4A9BFF)
        case .symbol("person.2.fill"): rgb(0xA78BFA)
        case .symbol("waveform"): recording
        case .symbol: rgb(0x3DD06A)
        }
    }

    private static let brands: [String: UInt32] = [
        "googlemeet": 0x34A853, "whatsapp": 0x25D366, "slack": 0xE9497A, "discord": 0x7983F5,
        "telegram": 0x2AABEE, "signal": 0x3A76F0, "chrome": 0x4C8DF6, "safari": 0x3A9BFF,
        "firefox": 0xFF7139, "arc": 0xF56A6A, "brave": 0xFB542B, "opera": 0xFF4D5A, "vivaldi": 0xF05A5A,
    ]

    // MARK: -

    private static func rgb(_ hex: UInt32) -> Color {
        Color(nsColor: nsColor(hex))
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// The panel can be light glass; the notes window never is.
    private static func adaptive(dark: Color, light: Color) -> Color {
        let dark = NSColor(dark), light = NSColor(light)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// The app a call was in, on a small tile of its own colour: the logo in that
/// colour over a faint wash of it, so a list of calls reads by app at a
/// glance. 30pt on the Calls tab, 26 in the notes window's list, 40 over a
/// call's notes.
struct CallAppTile: View {
    let kind: CallGlyph.Kind
    var size: CGFloat = 30

    var body: some View {
        let tint = CallsLook.tint(for: kind)
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        shape
            .fill(tint.opacity(0.13))
            .overlay(shape.strokeBorder(tint.opacity(0.2), lineWidth: 1))
            .frame(width: size, height: size)
            .overlay { glyph.foregroundStyle(tint) }
            // The name beside it says which call this is; the app is detail
            // a screen reader can do without.
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .logo(let name):
            if let logo = CallGlyph.image(name) {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 0.5, height: size * 0.5)
            } else {
                symbol("phone.fill")
            }
        case .symbol(let name):
            symbol(name)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.42, weight: .semibold))
    }
}

/// A person on a call as a round letter in their colour: "Y" for you, "A"
/// for Ana, "2" for Person 2; a plain figure for "Them".
struct CallPersonAvatar: View {
    let name: String
    let seat: CallPeople.Seat
    var size: CGFloat = 24
    /// A plate in the ground's colour, so avatars laid over each other part.
    var ring: Color?

    var body: some View {
        Group {
            // "Them" and "Someone" are nobody in particular: Airlock's own
            // cloud, so they never get a face that reads as Tom's or Sara's.
            // A plain person glyph read as a missing picture.
            if name == MeetingSpeaker.them.label || name == MeetingRecord.someone {
                BloubView(expression: .neutral)
                    .padding(size * 0.04)
            } else {
                BlobatarFace(name: name, colour: CallsLook.value(for: seat))
            }
        }
        .background { if let ring { Circle().fill(ring).padding(1) } }
        .frame(width: size, height: size)
        .overlay {
            if let ring { Circle().strokeBorder(ring, lineWidth: 2).padding(-2) }
        }
        .accessibilityHidden(true)
    }
}

/// How far along a recording's reading is, as a bar: teal running into
/// Take notes' blue. The notes window's card and the Calls tab's row.
struct RecordingProgressBar: View {
    let fraction: Double
    var height: CGFloat = 5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [CallsLook.recording, Theme.running],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .animation(MotionEffect.reading(reduceMotion: reduceMotion), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((fraction * 100).rounded(.down))) percent")
    }
}

/// The same, as a ring: where a row's to-do count would be while its
/// recording is read.
struct RecordingProgressRing: View {
    let fraction: Double
    var size: CGFloat = 17

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, fraction)))
                .stroke(CallsLook.recording, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(MotionEffect.reading(reduceMotion: reduceMotion), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Reading the recording")
        .accessibilityValue("\(Int((fraction * 100).rounded(.down))) percent")
    }
}

/// "Stop" on a recording being read, in the notes window and the Calls
/// tab: its meeting goes, the file stays.
struct RecordingStopButton: View {
    let stopping: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("Stop")
                    .font(Theme.chrome(12, .semibold))
            }
            .foregroundStyle(CallsLook.quietText)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(shape.fill(Color.white.opacity(hovered && !stopping ? 0.1 : 0.06)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(shape)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(stopping)
        .opacity(stopping ? 0.45 : 1)
        .onHover { inside in
            withAnimation(MotionEffect.pointer) { hovered = inside }
        }
        .clickable()
        .help("Stop and remove this meeting. The recording itself stays where it is.")
    }
}
