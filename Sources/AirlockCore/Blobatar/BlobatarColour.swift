import Foundation

/// Blobatar's colours: the seed picks a hue and one of six authored tones,
/// and the eyes are pushed until they read against the body. Worked in OKLCh,
/// written out as sRGB hex. Part of the port in `Blobatar.swift`.
extension Blobatar {
    struct Oklch { var l, c, h: Double }

    public struct Palette: Equatable, Sendable {
        public let head: String
        public let eye: String
    }

    /// The colours the original gives a name of its own.
    public static func palette(for name: String) -> Palette {
        let t = Traits(seed: name)
        return palette(hue: t.num("hue", 0, 360), tone: t("tone"))
    }

    /// Eyes that read on a body of `rgb` (0xRRGGBB): dark on a light body,
    /// light on a dark one, then pushed to 4.5:1, as the original does for
    /// its own bodies.
    public static func eyeColour(on rgb: UInt32) -> String {
        let head = fromHex(rgb)
        let eye = head.l >= 0.5 ? Oklch(l: 0.17, c: 0.02, h: head.h) : Oklch(l: 0.97, c: 0.012, h: head.h)
        return toHex(ensureContrast(eye, head, 4.5))
    }

    // MARK: - The tone set

    /// Pale and mid tones dominate; the near-black body stays a rare find.
    private static let tones: [(Double, l: Double, c: Double)] = [
        (0.2, 0.86, 0.085),   // pastel
        (0.36, 0.9, 0.028),   // pale neutral
        (0.62, 0.73, 0.135),  // mid
        (0.8, 0.62, 0.165),   // deep
        (0.93, 0.87, 0.16),   // bright
        (1.0, 0.34, 0.035),   // ink
    ]

    /// The darkest page a body is expected to sit on, and how far it must
    /// stand off it.
    private static let darkSurface = Oklch(l: 0.145, c: 0, h: 0)
    private static let surfaceFloor = 1.5

    static func palette(hue h: Double, tone: Double) -> Palette {
        let swatch = tones.first { tone < $0.0 } ?? tones[0]
        let bg = Oklch(l: 0.965, c: 0.01, h: h)
        var head = ensureContrast(Oklch(l: swatch.l, c: swatch.c, h: h), darkSurface, surfaceFloor)
        var eye = head.l >= 0.5 ? Oklch(l: 0.17, c: 0.02, h: h) : Oklch(l: 0.97, c: 0.012, h: h)
        head = ensureContrast(head, bg, 1.25)
        eye = ensureContrast(eye, head, 4.5)
        return Palette(head: toHex(head), eye: toHex(eye))
    }

    // MARK: - OKLCh

    /// To linear-light sRGB; components may fall outside 0–1.
    private static func toLinear(_ colour: Oklch) -> [Double] {
        let r = (colour.h * Double.pi) / 180
        let a = colour.c * cos(r)
        let b = colour.c * sin(r)
        let l = colour.l

        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.291485548 * b

        let L = l_ * l_ * l_
        let M = m_ * m_ * m_
        let S = s_ * s_ * s_

        return [
            4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
            -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
            -0.0041960863 * L - 0.7034186147 * M + 1.707614701 * S,
        ]
    }

    private static func inGamut(_ rgb: [Double]) -> Bool {
        rgb.allSatisfy { $0 >= -1e-4 && $0 <= 1 + 1e-4 }
    }

    /// In gamut by giving up chroma, never by clipping, which shifts hue.
    private static func resolve(_ colour: Oklch) -> [Double] {
        var rgb = toLinear(colour)
        if !inGamut(rgb) {
            var lo = 0.0
            var hi = colour.c
            for _ in 0..<12 {
                let mid = (lo + hi) / 2
                if inGamut(toLinear(Oklch(l: colour.l, c: mid, h: colour.h))) { lo = mid } else { hi = mid }
            }
            rgb = toLinear(Oklch(l: colour.l, c: lo, h: colour.h))
        }
        return rgb.map { min(1, max(0, $0)) }
    }

    private static func luminance(_ colour: Oklch) -> Double {
        let rgb = resolve(colour)
        return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
    }

    static func contrast(_ a: Oklch, _ b: Oklch) -> Double {
        let x = luminance(a)
        let y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Walks `fg`'s lightness away from `bg` until the pair clears `floor`,
    /// the way it already leans first.
    static func ensureContrast(_ fg: Oklch, _ bg: Oklch, _ floor: Double) -> Oklch {
        if contrast(fg, bg) >= floor { return fg }
        let lean: Double = fg.l >= bg.l ? 1 : -1
        for dir in [lean, -lean] {
            var probe = fg
            for _ in 0..<60 {
                probe.l = min(1, max(0, probe.l + dir * 0.02))
                if contrast(probe, bg) >= floor { return probe }
                if probe.l == 0 || probe.l == 1 { break }
            }
        }
        let black = Oklch(l: 0, c: 0, h: fg.h)
        let white = Oklch(l: 1, c: 0, h: fg.h)
        return contrast(black, bg) >= contrast(white, bg) ? black : white
    }

    static func toHex(_ colour: Oklch) -> String {
        "#" + resolve(colour).map { v in
            let s = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
            return String(format: "%02x", Int(jsRound(s * 255)))
        }.joined()
    }

    static func fromHex(_ rgb: UInt32) -> Oklch {
        let channels = [(rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255].map { v -> Double in
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = (channels[0], channels[1], channels[2])
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let A = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
        return Oklch(l: 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
                     c: hypot(A, B),
                     h: (atan2(B, A) * 180) / Double.pi)
    }
}
