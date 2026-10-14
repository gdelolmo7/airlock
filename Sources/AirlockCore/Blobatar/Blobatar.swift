import Foundation

/// A face drawn from a name: a soft body and two eyes, the same every time
/// for the same name, and unrelated for a name one letter away.
///
/// A port of Blobatar 2's generator (MIT, © 2026 Alain, notice in
/// THIRD-PARTY-LICENSES.txt): its seed hash, its trait reader, its ten
/// silhouettes and the way it fits the eyes into each. The arithmetic is kept
/// in the original's order on purpose, so a name draws the face the original
/// draws for it; `BlobatarTests` holds this to the upstream golden fixture.
///
/// Geometry is in the original's 100 × 100 frame. Nothing here draws: the app
/// turns the marks into paths, and `svg` exists to compare against upstream.
public enum Blobatar {
    public enum Shape: String, CaseIterable, Sendable {
        case round, organic, boxy, capsule, nub, cloud, droplet, hexagon, sun, triangle
    }

    /// One step of an outline, as the SVG path command it would be written as.
    public enum Segment: Equatable, Sendable {
        case move(Double, Double)
        case line(Double, Double)
        case horizontal(Double)
        case vertical(Double)
        case quad(Double, Double, Double, Double)
        case cubic(Double, Double, Double, Double, Double, Double)
        case close
    }

    public enum Mark: Equatable, Sendable {
        case path([Segment])
        case circle(cx: Double, cy: Double, r: Double)
    }

    /// What a name draws: the body's marks (all one colour) and the eyes'.
    public struct Figure: Equatable, Sendable {
        public let shape: Shape
        public let body: [Mark]
        public let eyes: [Mark]
    }

    /// The face for `name`. `traits` pins individual values the way the
    /// original's overrides do (a 0–1 position, `["shape": 0.95]`); tests use
    /// it to reach every silhouette.
    public static func figure(for name: String, traits overrides: [String: Double] = [:]) -> Figure {
        let t = Traits(seed: name, overrides: overrides)
        return layout(t)
    }

    // MARK: - The seed

    /// Mixes bytes into a 32-bit state (murmur3's body step).
    static func feed<S: Sequence>(_ state: UInt32, _ bytes: S) -> UInt32 where S.Element == UInt8 {
        var h = state
        for byte in bytes {
            h = (h ^ UInt32(byte)) &* 3_432_918_353
            h = (h << 13) | (h >> 19)
        }
        return h
    }

    /// murmur3's fmix32: full avalanche, so "alain" and "alaim" look unrelated.
    static func finalize(_ state: UInt32) -> UInt32 {
        var h = (state ^ (state >> 16)) &* 2_246_822_507
        h = (h ^ (h >> 13)) &* 3_266_489_909
        return h ^ (h >> 16)
    }

    /// NFC, trimmed, lowercased: "Mariana " and "mariana" are one person.
    static func normalized(_ seed: String) -> String {
        seed.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: trimmed)
            .lowercased()
    }

    /// What JavaScript's `trim` strips, which the seeds were made with.
    private static let trimmed = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}"))
        .subtracting(CharacterSet(charactersIn: "\u{85}"))

    static func seedState(_ seed: String) -> UInt32 {
        let s = normalized(seed)
        // The length is counted in UTF-16 units, as the original counts it.
        return feed(1_779_033_703 ^ UInt32(truncatingIfNeeded: s.utf16.count), s.utf8)
    }

    /// One value in [0, 1) for `key`, independent of every other key.
    static func stream(_ state: UInt32, _ key: String) -> Double {
        Double(finalize(feed(feed(state, [0xFF]), key.utf8))) / 4_294_967_296
    }

    /// Every value is read by name rather than drawn in order, so each one
    /// depends on the seed and its key alone.
    struct Traits {
        let state: UInt32
        let overrides: [String: Double]

        init(seed: String, overrides: [String: Double] = [:]) {
            state = Blobatar.seedState(seed)
            self.overrides = overrides
        }

        func callAsFunction(_ key: String) -> Double {
            if let o = overrides[key] { return o > 0 ? (o < 1 ? o : 0.999999) : 0 }
            return Blobatar.stream(state, key)
        }

        func num(_ key: String, _ min: Double, _ max: Double) -> Double { min + self(key) * (max - min) }

        func int(_ key: String, _ min: Int, _ max: Int) -> Int {
            min + Int((self(key) * Double(max - min + 1)).rounded(.down))
        }

        func jitter(_ key: String, _ amount: Double) -> Double { (self(key) * 2 - 1) * amount }
    }

    // MARK: - Layout

    struct Body {
        var cx, cy, rx, ry, n, rot: Double
        var radii: [Double]
        var sides = 0
        var round = 0.0
    }

    struct Ellipse { var cx, cy, rx, ry: Double }

    struct Eye { var cx, cy, rx, ry, n, rot: Double }

    /// Weighted rather than even: round and organic are the everyday shapes,
    /// the louder silhouettes stay finds. Upper edge of each band, in order.
    static let bands: [(Shape, Double)] = [
        (.round, 0.22), (.organic, 0.48), (.boxy, 0.6), (.capsule, 0.7), (.nub, 0.79),
        (.cloud, 0.86), (.droplet, 0.915), (.hexagon, 0.95), (.sun, 0.98), (.triangle, 1),
    ]

    static func layout(_ t: Traits) -> Figure {
        let v = t("shape")
        let shape = bands.first { v < $0.1 }?.0 ?? .triangle
        let r = t.num("body.r", 31, 38) * core(shape)
        var body = Body(
            cx: 50 + t.jitter("body.x", 1.5),
            cy: 50 + t.jitter("body.y", 1.5),
            rx: r,
            ry: r * t.num("body.ratio", 0.92, 1.08),
            n: t.num("body.n", 1.9, 2.5),
            rot: 0,
            radii: (0..<t.int("body.pts", 6, 8)).map { 1 + t.jitter("body.r\($0)", 0.16) }
        )
        patch(shape, t, &body)
        let face = self.face(shape, body)
        var petals: [Mark] = []
        var extra: [Mark] = []
        decorate(shape, t, body, &petals, &extra)

        let outline: [Segment] = switch shape {
        case .organic, .cloud: spline(body)
        case .capsule: box(body.cx, body.cy, body.rx - body.ry, body.ry)
        case .hexagon, .triangle: polygon(body)
        default: superellipse(body.cx, body.cy, body.rx, body.ry, n: body.n, rot: body.rot)
        }
        let eyes = fitEyes(t, body, face).map { eye in
            Mark.path(superellipse(eye.cx, eye.cy, eye.rx, eye.ry, n: eye.n, rot: eye.rot))
        }
        return Figure(shape: shape, body: petals + extra + [.path(outline)], eyes: eyes)
    }

    /// How much of the frame the core body takes.
    private static func core(_ shape: Shape) -> Double {
        switch shape {
        case .round: 1
        case .organic: 0.98
        case .boxy: 0.86
        case .capsule: 1.02
        case .nub: 0.88
        case .cloud, .droplet: 0.78
        case .hexagon: 1.05
        case .sun: 0.7
        case .triangle: 1.15
        }
    }

    private static func patch(_ shape: Shape, _ t: Traits, _ b: inout Body) {
        switch shape {
        case .boxy:
            b.n = t.num("body.n", 3.4, 6)
            b.rot = t.num("body.rot", -20, 20)
        case .capsule:
            b.ry *= t.num("capsule.squat", 0.55, 0.68)
        case .droplet:
            // Lowered by what the point adds above, so head and point sit
            // centred together; a true ellipse, which the point is tangent to.
            b.cy += 0.22 * b.ry
            b.n = 2
        case .hexagon:
            b.sides = 6
            b.rot = t.num("body.rot", -12, 12)
            b.round = t.num("poly.round", 0.24, 0.5)
        case .triangle:
            b.sides = 3
            b.rot = t.num("body.rot", -5, 5)
            b.round = t.num("poly.round", 0.24, 0.5)
        default:
            break
        }
    }

    /// The region the eyes must fit inside.
    private static func face(_ shape: Shape, _ b: Body) -> Ellipse {
        let shrunk = { (k: Double) in Ellipse(cx: b.cx, cy: b.cy, rx: b.rx * k, ry: b.ry * k) }
        switch shape {
        case .organic, .cloud: return shrunk(b.radii.min()! * 0.95)
        case .capsule: return shrunk(0.94)
        case .droplet: return Ellipse(cx: b.cx, cy: b.cy + b.ry * 0.05, rx: b.rx * 0.88, ry: b.ry * 0.88)
        case .hexagon: return shrunk(0.84)
        case .triangle: return Ellipse(cx: b.cx, cy: b.cy + b.ry * 0.1, rx: b.rx * 0.54, ry: b.ry * 0.36)
        default: return Ellipse(cx: b.cx, cy: b.cy, rx: b.rx, ry: b.ry)
        }
    }

    private static func decorate(_ shape: Shape, _ t: Traits, _ b: Body,
                                 _ petals: inout [Mark], _ extra: inout [Mark]) {
        switch shape {
        case .capsule:
            for s in [-1.0, 1.0] {
                petals.append(.circle(cx: b.cx + s * (b.rx - b.ry), cy: b.cy, r: b.ry))
            }
        case .nub:
            for i in 0..<t.int("nub.n", 1, 2) {
                let a = t.num("nub.a\(i)", 0, 2 * Double.pi)
                petals.append(.circle(cx: b.cx + cos(a) * b.rx * 0.88,
                                      cy: b.cy + sin(a) * b.rx * 0.88,
                                      r: b.rx * t.num("nub.r\(i)", 0.24, 0.4)))
            }
        case .cloud:
            let count = t.int("cloud.n", 4, 6)
            for i in 0..<count {
                let a = Double.pi + (Double.pi * (Double(i) + 0.5)) / Double(count)
                petals.append(.circle(cx: b.cx + cos(a) * b.rx * 0.8,
                                      cy: b.cy + sin(a) * b.rx * 0.5,
                                      r: b.rx * t.num("cloud.r\(i)", 0.44, 0.62)))
            }
        case .droplet:
            extra.append(.path(taper(b.cx, b.cy, b.rx, b.ry, tip: t.num("droplet.tip", 1.4, 1.65))))
        case .sun:
            let count = t.int("sun.n", 6, 9)
            let dist = b.rx * t.num("sun.dist", 1.0, 1.08)
            let pr = b.rx * t.num("sun.r", 0.2, 0.26)
            let off = t.num("sun.rot", 0, 2 * Double.pi)
            for i in 0..<count {
                let a = off + (2 * Double.pi * Double(i)) / Double(count)
                petals.append(.circle(cx: b.cx + cos(a) * dist, cy: b.cy + sin(a) * dist, r: pr))
            }
        default:
            break
        }
    }

    /// Two capsule eyes, sized and spaced from the seed, then scaled down
    /// together until the pair fits the face region on both axes.
    private static func fitEyes(_ t: Traits, _ b: Body, _ face: Ellipse) -> [Eye] {
        let rx = b.rx
        let er0 = t.num("eye.rx", 0.075, 0.105) * rx
        let ratio = t.num("eye.ratio", 1.9, 3.2)
        let scale = t.num("eye.scale", 0.78, 1.24)
        let stretch = t.num("eye.stretch", 0.85, 1.18)
        let clearance = t.num("eye.gap", 0.1, 0.24) * rx
        let wide = er0 * max(1, scale)
        let tall = er0 * ratio * max(1, scale * stretch)
        let gap0 = wide + rx * 0.03 + clearance

        let gx = t.jitter("gaze.x", 0.09) * face.rx
        let gy = t.num("gaze.y", -0.2, 0.08) * face.ry
        let dy = t.jitter("eye.dy", 0.04) * face.ry
        let reach = hypot(wide, tall)
        let need = hypot((abs(gx) + gap0 + reach) / face.rx, (abs(gy) + abs(dy) + reach) / face.ry)
        let fit = need > 0.9 ? 0.9 / need : 1

        let er = er0 * fit
        let eyeRy = er * ratio
        let gap = gap0 * fit
        let room = max(0, min(1, clearance / tall))
        let bound = min(12, (asin(room) * 180) / Double.pi)
        let lean = t.num("eye.lean", -1, 1) * bound
        let lean2 = max(-12, min(12, lean + t.jitter("eye.lean2", 3.5)))

        let cx = face.cx + gx * fit
        let cy = face.cy + gy * fit
        return [
            Eye(cx: cx - gap, cy: cy, rx: er, ry: eyeRy, n: t.num("eye.n", 3.5, 6), rot: lean),
            Eye(cx: cx + gap, cy: cy + dy * fit, rx: er * scale, ry: eyeRy * scale * stretch,
                n: t.num("eye.n", 3.5, 6), rot: lean2),
        ]
    }

    // MARK: - Outlines

    /// |x/a|^n + |y/b|^n = 1, one cubic per quadrant, through the exact 45°
    /// point. `rot` in degrees, clockwise.
    static func superellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double,
                             n: Double, rot: Double) -> [Segment] {
        // Past n ≈ 5.55 the control offset would pass the radius and bulge.
        let k = min(1, (8 * pow(2, -1 / n) - 4) / 3)
        let a = rx
        let b = ry
        let ak = a * k
        let bk = b * k
        let pts: [(Double, Double)] = [
            (a, 0),
            (a, bk), (ak, b), (0, b),
            (-ak, b), (-a, bk), (-a, 0),
            (-a, -bk), (-ak, -b), (0, -b),
            (ak, -b), (a, -bk), (a, 0),
        ]
        let t = (rot * Double.pi) / 180
        let c = cos(t)
        let s = sin(t)
        let at = { (i: Int) -> (Double, Double) in
            let (x, y) = pts[i]
            return (cx + x * c - y * s, cy + x * s + y * c)
        }
        var out: [Segment] = [.move(at(0).0, at(0).1)]
        for i in stride(from: 1, to: 13, by: 3) {
            let (x1, y1) = at(i), (x2, y2) = at(i + 1), (x3, y3) = at(i + 2)
            out.append(.cubic(x1, y1, x2, y2, x3, y3))
        }
        out.append(.close)
        return out
    }

    /// A pebble: radii around a circle, joined by a closed Catmull-Rom spline.
    static func spline(_ b: Body) -> [Segment] {
        let n = b.radii.count
        let t0 = (b.rot * Double.pi) / 180
        let p: [(Double, Double)] = b.radii.enumerated().map { i, m in
            let a = t0 + (2 * Double.pi * Double(i)) / Double(n)
            return (b.cx + b.rx * m * cos(a), b.cy + b.ry * m * sin(a))
        }
        let at = { (i: Int) in p[((i % n) + n) % n] }
        var out: [Segment] = [.move(at(0).0, at(0).1)]
        for i in 0..<n {
            let (x0, y0) = at(i - 1), (x1, y1) = at(i), (x2, y2) = at(i + 1), (x3, y3) = at(i + 2)
            out.append(.cubic(x1 + (x2 - x0) / 6, y1 + (y2 - y0) / 6,
                              x2 - (x3 - x1) / 6, y2 - (y3 - y1) / 6,
                              x2, y2))
        }
        out.append(.close)
        return out
    }

    /// A regular polygon, vertex up, each corner cut back by `round` along
    /// both edges and joined through the vertex with a quadratic.
    static func polygon(_ b: Body) -> [Segment] {
        let sides = b.sides
        let k = b.round > 0 ? (b.round < 1 ? b.round / 2 : 0.5) : 0
        let t0 = (b.rot * Double.pi) / 180 - Double.pi / 2
        let v: [(Double, Double)] = (0..<sides).map { i in
            let a = t0 + (2 * Double.pi * Double(i)) / Double(sides)
            return (b.cx + b.rx * cos(a), b.cy + b.ry * sin(a))
        }
        let at = { (i: Int) in v[((i % sides) + sides) % sides] }
        let cut = { (i: Int, j: Int) -> (Double, Double) in
            let (x0, y0) = at(i), (x1, y1) = at(j)
            return (x0 + (x1 - x0) * k, y0 + (y1 - y0) * k)
        }
        let start = cut(0, -1)
        var out: [Segment] = [.move(start.0, start.1)]
        for i in 0..<sides {
            let (x, y) = at(i)
            let end = cut(i, i + 1)
            out.append(.quad(x, y, end.0, end.1))
            // Omitted when the cuts meet, so a fully round one has no empty runs.
            if k < 0.5 {
                let next = cut(i + 1, i)
                out.append(.line(next.0, next.1))
            }
        }
        out.append(.close)
        return out
    }

    /// A capsule's straight run; its two end circles are petals.
    static func box(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> [Segment] {
        [.move(cx - rx, cy - ry), .horizontal(cx + rx), .vertical(cy + ry), .horizontal(cx - rx), .close]
    }

    /// A droplet's point: the two tangents from an apex to the body ellipse,
    /// eased through the apex so it never ends in a needle.
    static func taper(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, tip: Double) -> [Segment] {
        let t = max(1.05, tip)
        let tx = rx * sqrt(1 - 1 / (t * t))
        let ty = cy - ry / t
        let apex = cy - t * ry
        let px = tx * 0.14
        let py = ty + 0.86 * (apex - ty)
        return [.move(cx - tx, ty), .line(cx - px, py), .quad(cx, apex, cx + px, py), .line(cx + tx, ty), .close]
    }
}

// MARK: - SVG, to compare with the original

extension Blobatar {
    /// The markup the original writes for `name` with its default options
    /// (no backdrop, its own colours).
    static func svg(for name: String, traits overrides: [String: Double] = [:]) -> String {
        let t = Traits(seed: name, overrides: overrides)
        let figure = layout(t)
        let colours = palette(hue: t.num("hue", 0, 360), tone: t("tone"))
        let body = figure.body.map(markup).joined()
        let eyes = figure.eyes.map(markup).joined()
        return #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">"#
            + #"<g fill="\#(colours.head)">\#(body)</g><g fill="\#(colours.eye)">\#(eyes)</g></svg>"#
    }

    private static func markup(_ mark: Mark) -> String {
        switch mark {
        case .circle(let cx, let cy, let r):
            return #"<circle cx="\#(r2(cx))" cy="\#(r2(cy))" r="\#(r2(r))"/>"#
        case .path(let segments):
            return #"<path d="\#(pathData(segments))"/>"#
        }
    }

    static func pathData(_ segments: [Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .move(let x, let y): "M\(r2(x)) \(r2(y))"
            case .line(let x, let y): "L\(r2(x)) \(r2(y))"
            case .horizontal(let x): "H\(r2(x))"
            case .vertical(let y): "V\(r2(y))"
            case .quad(let x1, let y1, let x, let y): "Q\(r2(x1)) \(r2(y1)) \(r2(x)) \(r2(y))"
            case .cubic(let x1, let y1, let x2, let y2, let x, let y):
                "C\(r2(x1)) \(r2(y1)) \(r2(x2)) \(r2(y2)) \(r2(x)) \(r2(y))"
            case .close: "Z"
            }
        }.joined()
    }

    /// A number as the original writes it: two decimals, the shortest form,
    /// no "-0".
    static func r2(_ v: Double) -> String {
        let s = jsRound(v * 100) / 100
        if s == 0 { return "0" }
        if s == s.rounded(.towardZero), abs(s) < 1e15 { return String(Int(s)) }
        return String(s)
    }

    /// JavaScript's `Math.round`: halves go up, toward +∞.
    static func jsRound(_ v: Double) -> Double {
        let f = v.rounded(.down)
        return v - f >= 0.5 ? f + 1 : f
    }
}
