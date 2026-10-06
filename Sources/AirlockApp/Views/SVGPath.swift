import SwiftUI

/// An SVG path, as a `Shape`.
///
/// **Vector in code rather than a raster in a bundle**, which is the same call
/// `scripts/make-icon.swift` makes about the app icon: the shape is code, so a
/// change is a diff, it is sharp at every size and text scale, and it needs no
/// resource plumbing through SwiftPM and the packaging script.
///
/// It exists because the two agent marks are the vendors' own artwork, and
/// approximating them by hand — as the four rotated capsules standing in for
/// Claude's spark did — gets the silhouette wrong in a way people who know the
/// mark notice immediately.
///
/// Deliberately supports **only the commands the artwork uses**: move, line,
/// horizontal, vertical, cubic, arc and close, in both cases. Quadratics and
/// smooth continuations are absent because nothing here has them, and a parser
/// that pretends to handle a command it has never been given is a parser that
/// fails silently the first time it is.
struct SVGPath: Shape {
    let commands: String
    /// The artwork's own coordinate space. Both marks are `0 0 24 24`.
    var viewBox: CGFloat = 24
    /// Fit the **ink** to the frame rather than the canvas.
    ///
    /// A logo drawn to sit on its own tile carries the margin that tile needed.
    /// Scaled by its viewBox that margin survives as dead space, and the mark
    /// reads small beside one whose artwork happens to be tight — which is
    /// exactly what happened when Codex lost its white square and ended up
    /// visibly smaller than Claude next to it.
    ///
    /// Two logos look the same size when their INK does, not their canvases.
    var fitsInk: Bool = true

    func path(in rect: CGRect) -> Path {
        // Built in the artwork's own coordinates first, then transformed once —
        // which is also what makes fitting the ink possible, since the ink's
        // bounds are not known until the path exists.
        let raw = rawPath()
        let source = fitsInk && !raw.isEmpty
            ? raw.boundingRect
            : CGRect(x: 0, y: 0, width: viewBox, height: viewBox)
        guard source.width > 0, source.height > 0 else { return raw }

        // Uniform, and centred: a non-uniform fit would distort a logo, which is
        // the one kind of image nobody is allowed to distort.
        let scale = min(rect.width / source.width, rect.height / source.height)
        let dx = rect.midX - source.midX * scale
        let dy = rect.midY - source.midY * scale
        return raw.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: dx, y: dy)))
    }

    private func rawPath() -> Path {
        var path = Path()
        var scanner = Scanner(commands)
        func map(_ point: CGPoint) -> CGPoint { point }

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var command: Character = "M"

        while let next = scanner.nextCommand(previous: command) {
            command = next
            let isRelative = command.isLowercase
            func absolute(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                isRelative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch Character(command.lowercased()) {
            case "m":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = absolute(x, y)
                subpathStart = current
                path.move(to: map(current))
            case "l":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = absolute(x, y)
                path.addLine(to: map(current))
            case "h":
                guard let x = scanner.number() else { return path }
                current = isRelative ? CGPoint(x: current.x + x, y: current.y)
                                     : CGPoint(x: x, y: current.y)
                path.addLine(to: map(current))
            case "v":
                guard let y = scanner.number() else { return path }
                current = isRelative ? CGPoint(x: current.x, y: current.y + y)
                                     : CGPoint(x: current.x, y: y)
                path.addLine(to: map(current))
            case "c":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let control1 = absolute(x1, y1)
                let control2 = absolute(x2, y2)
                current = absolute(x, y)
                path.addCurve(to: map(current), control1: map(control1), control2: map(control2))
            case "a":
                guard let rx = scanner.number(), let ry = scanner.number(),
                      let rotation = scanner.number(), let largeArc = scanner.flag(),
                      let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let end = absolute(x, y)
                appendArc(&path, from: current, to: end, rx: rx, ry: ry,
                          rotation: rotation, largeArc: largeArc, sweep: sweep, map: map)
                current = end
            case "z":
                path.closeSubpath()
                current = subpathStart
            default:
                return path
            }
        }
        return path
    }

    /// Endpoint arc → centre parameterisation → cubic segments.
    ///
    /// SwiftUI's `addArc` takes a centre, a radius and two angles; SVG gives two
    /// endpoints and two flags. The conversion is the standard one from the SVG
    /// implementation notes, and the ellipse is approximated in ≤90° cubic
    /// pieces — exact enough that a 14pt glyph cannot show the difference.
    private func appendArc(_ path: inout Path, from start: CGPoint, to end: CGPoint,
                           rx: CGFloat, ry: CGFloat, rotation: CGFloat,
                           largeArc: Bool, sweep: Bool,
                           map: (CGPoint) -> CGPoint) {
        // Degenerate radii mean a straight line — the spec says so, and it does
        // happen in hand-authored artwork.
        guard rx != 0, ry != 0 else {
            path.addLine(to: map(end))
            return
        }
        var rx = abs(rx), ry = abs(ry)
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx2 = (start.x - end.x) / 2, dy2 = (start.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        // Radii too small to span the chord are scaled up, again per the spec.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }

        let sign: CGFloat = largeArc == sweep ? -1 : 1
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coefficient = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx

        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard len != 0 else { return 0 }
            let value = min(1, max(-1, dot / len))
            return (ux * vy - uy * vx < 0 ? -1 : 1) * acos(value)
        }

        let start1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var sweepAngle = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                               (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep, sweepAngle < 0 { sweepAngle += 2 * .pi }

        let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let delta = sweepAngle / CGFloat(segments)
        let alpha = 4.0 / 3.0 * tan(delta / 4)

        var theta = start1
        var from = start
        for _ in 0..<segments {
            let theta2 = theta + delta
            func point(_ angle: CGFloat) -> CGPoint {
                let x = rx * cos(angle), y = ry * sin(angle)
                return CGPoint(x: cosPhi * x - sinPhi * y + cx,
                               y: sinPhi * x + cosPhi * y + cy)
            }
            func derivative(_ angle: CGFloat) -> CGPoint {
                let x = -rx * sin(angle), y = ry * cos(angle)
                return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
            }
            let to = point(theta2)
            let d1 = derivative(theta), d2 = derivative(theta2)
            let control1 = CGPoint(x: from.x + alpha * d1.x, y: from.y + alpha * d1.y)
            let control2 = CGPoint(x: to.x - alpha * d2.x, y: to.y - alpha * d2.y)
            path.addCurve(to: map(to), control1: map(control1), control2: map(control2))
            theta = theta2
            from = to
        }
    }

    /// Hand-rolled because SVG path data is not whitespace-delimited: numbers
    /// run together (`.08-.23`), a sign starts one, and a command may be
    /// implicit — `l` followed by six numbers is three line-tos.
    private struct Scanner {
        private let characters: [Character]
        private var index = 0

        init(_ text: String) { characters = Array(text) }

        mutating func nextCommand(previous: Character) -> Character? {
            skipSeparators()
            guard index < characters.count else { return nil }
            let character = characters[index]
            if character.isLetter {
                index += 1
                return character
            }
            // A number where a command was expected: the previous command
            // repeats, except that a repeated move-to is a line-to.
            switch previous {
            case "M": return "L"
            case "m": return "l"
            default: return previous
            }
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var digits = ""
            if index < characters.count, characters[index] == "-" || characters[index] == "+" {
                digits.append(characters[index])
                index += 1
            }
            var seenDot = false
            while index < characters.count {
                let character = characters[index]
                if character.isNumber {
                    digits.append(character)
                } else if character == ".", !seenDot {
                    seenDot = true
                    digits.append(character)
                } else if character == "e" || character == "E" {
                    digits.append(character)
                    index += 1
                    if index < characters.count, characters[index] == "-" || characters[index] == "+" {
                        digits.append(characters[index])
                        index += 1
                    }
                    continue
                } else {
                    break
                }
                index += 1
            }
            return Double(digits).map { CGFloat($0) }
        }

        /// Arc flags are single digits and may be packed against what follows
        /// them — `0 01-.104` is largeArc 0, sweep 1, then −0.104.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < characters.count, let value = characters[index].wholeNumberValue,
                  value == 0 || value == 1 else { return nil }
            index += 1
            return value == 1
        }

        private mutating func skipSeparators() {
            while index < characters.count,
                  characters[index] == " " || characters[index] == ","
                    || characters[index] == "\n" || characters[index] == "\t" {
                index += 1
            }
        }
    }
}
