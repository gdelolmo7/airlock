import AirlockCore
import SwiftUI

/// A person's face (`Blobatar.face`): its shape and eyes from their name, its
/// body in their call colour so the face and the name beside it read as one.
/// No plate behind it: the body sits straight on the window's dark.
struct BlobatarFace: View {
    let name: String
    /// 0xRRGGBB, the person's colour (`CallsLook.value(for:)`).
    let colour: UInt32

    var body: some View {
        let figure = Blobatar.face(for: name)
        let bodyColour = Self.color(colour)
        let eyeColour = Self.color(Self.value(Blobatar.eyeColour(on: colour)))
        Canvas { context, size in
            // The figure is drawn in a 100-point square.
            let side = min(size.width, size.height)
            context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            context.scaleBy(x: side / 100, y: side / 100)
            // Each mark on its own, as the original draws them: a petal and
            // the body overlap, and one path holding both would leave a hole.
            for mark in figure.body { context.fill(Self.path(mark), with: .color(bodyColour)) }
            for mark in figure.eyes { context.fill(Self.path(mark), with: .color(eyeColour)) }
        }
    }

    static func path(_ mark: Blobatar.Mark) -> Path {
        switch mark {
        case .circle(let cx, let cy, let r):
            return Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        case .path(let segments):
            var path = Path()
            var at = CGPoint.zero
            for segment in segments {
                switch segment {
                case .move(let x, let y):
                    at = CGPoint(x: x, y: y)
                    path.move(to: at)
                case .line(let x, let y):
                    at = CGPoint(x: x, y: y)
                    path.addLine(to: at)
                case .horizontal(let x):
                    at = CGPoint(x: x, y: at.y)
                    path.addLine(to: at)
                case .vertical(let y):
                    at = CGPoint(x: at.x, y: y)
                    path.addLine(to: at)
                case .quad(let x1, let y1, let x, let y):
                    at = CGPoint(x: x, y: y)
                    path.addQuadCurve(to: at, control: CGPoint(x: x1, y: y1))
                case .cubic(let x1, let y1, let x2, let y2, let x, let y):
                    at = CGPoint(x: x, y: y)
                    path.addCurve(to: at, control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
                case .close:
                    path.closeSubpath()
                }
            }
            return path
        }
    }

    private static func value(_ hex: String) -> UInt32 {
        UInt32(hex.dropFirst(), radix: 16) ?? 0
    }

    private static func color(_ value: UInt32) -> Color {
        Color(.sRGB,
              red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}
