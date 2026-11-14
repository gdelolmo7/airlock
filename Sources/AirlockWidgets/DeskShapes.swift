import AirlockCore
import SwiftUI

/// The header's mark: a rounded square with a check, from the design.
struct TodoMark: View {
    var color: Color
    var size: CGFloat = 14

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 24
            let square = Path(roundedRect: CGRect(x: 3 * s, y: 3 * s, width: 18 * s, height: 18 * s),
                              cornerRadius: 5 * s)
            var check = Path()
            check.move(to: CGPoint(x: 8 * s, y: 12.5 * s))
            check.addLine(to: CGPoint(x: 11 * s, y: 15.5 * s))
            check.addLine(to: CGPoint(x: 16 * s, y: 9.5 * s))
            let stroke = StrokeStyle(lineWidth: 2.2 * s, lineCap: .round, lineJoin: .round)
            context.stroke(square, with: .color(color), style: stroke)
            context.stroke(check, with: .color(color), style: stroke)
        }
        .frame(width: size, height: size)
        .widgetAccentable()
    }
}

/// A to-do's circle: a ring while it is open, filled with a check once ticked.
struct TodoCircle: View {
    var done: Bool
    var look: DeskLook
    var size: CGFloat = 22
    var checkSize: CGFloat = 11

    var body: some View {
        ZStack {
            if done {
                Circle().fill(look.accent).widgetAccentable()
                CheckShape()
                    .stroke(look.on, style: StrokeStyle(lineWidth: 3.4 * checkSize / 24,
                                                         lineCap: .round, lineJoin: .round))
                    .frame(width: checkSize, height: checkSize)
            } else {
                Circle().strokeBorder(look.fg3, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}

/// The check inside a ticked circle, drawn in a 24-point box.
struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 5 * s, y: rect.minY + 12.5 * s))
        path.addLine(to: CGPoint(x: rect.minX + 10 * s, y: rect.minY + 17.5 * s))
        path.addLine(to: CGPoint(x: rect.minX + 19 * s, y: rect.minY + 7 * s))
        return path
    }
}

/// Bloub, Airlock's own character, happy: it shows up only when every to-do
/// of the day is ticked. The body and eyes are the app's, from Core's
/// `BloubArt`, so the widget can never drift from the notch.
struct Bloub: View {
    var look: DeskLook
    var width: CGFloat = 64

    var body: some View {
        Canvas { context, canvas in
            let rect = CGRect(origin: .zero, size: canvas)
            let body = Path(BloubArt.outline()).applying(BloubArt.fit(in: rect))
            context.fill(body, with: .color(look.bloub))
            context.fill(Path(BloubArt.eyes(.happy, in: rect)), with: .color(look.bloubEyes))
        }
        .frame(width: width, height: width * BloubArt.bounds.height / BloubArt.bounds.width)
        .accessibilityHidden(true)
    }
}
