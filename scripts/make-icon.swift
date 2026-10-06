// Draws the app icon and writes Resources/AppIcon.icns.
//
//     swift scripts/make-icon.swift
//
// A generator rather than a checked-in blob so the icon is reviewable: the shape
// is code, the palette is the product's own, and a change to either is a diff
// instead of a binary swap. The .icns is committed too, so packaging never
// depends on running this.
//
// **STATUS LIGHT** — a sealed recess with one bar of light at its lip. Chosen
// from four Airlock concepts (door ajar, chamber, status light, threshold); the
// others are kept in `scripts/icon-concepts.swift`.
//
// The name is the brief: an airlock is a chamber you do not enter until it says
// you may, and the only thing you read off it is the lamp. That is also what the
// product is — a gate that holds an agent until you decide — so the icon is the
// sealed panel and the one light on it, not a door mid-swing.
//
// It replaces the previous notch-cutout mark, which was drawn for a product
// called agentic-notch and said "notch" rather than "airlock". The dark tile also
// costs less than it looks: it puts the app's own obsidian back in the icon,
// which the cutout mark had to give up to stay legible.
//
// **The lamp is thicker than the concept sketch.** At the sketch's proportions it
// came out around a pixel and a third at 32px and simply vanished into the panel
// edge. Everything else here is subordinate to that bar surviving a Finder list:
// the recess is only dark enough to be a hole for it to sit in.

import AppKit

// MARK: - The product's palette, not a new one

let obsidian = (r: 0.020, g: 0.024, b: 0.031)   // Theme.pill
let accent   = (r: 0.231, g: 0.576, b: 0.941)   // Theme.running — the brand blue
let eyeInk   = (r: 0.020, g: 0.024, b: 0.031)   // Theme.bloubEyes, dark end

// MARK: - The mark, read from the app rather than copied into this file
//
// The bloub's geometry lives in `Sources/AirlockApp/Views/Bloub.swift`, which
// that file declares is the source of truth. A script cannot import the app
// target, and the obvious workaround — pasting the numbers here — would make two
// sources of truth for one shape and guarantee they drift.
//
// So this parses them out instead, and fails loudly if it cannot. A wrong icon
// is worse than no icon: the .icns is committed, so a silent misparse would ship
// a blank tile that nobody notices until it is in the Dock.

let bloubSource = try! String(contentsOf: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/AirlockApp/Views/Bloub.swift"), encoding: .utf8)

func numbers(in text: String) -> [CGFloat] {
    let pattern = try! NSRegularExpression(pattern: "-?\\d+\\.?\\d*")
    let range = NSRange(text.startIndex..., in: text)
    return pattern.matches(in: text, range: range).compactMap {
        Range($0.range, in: text).flatMap { CGFloat(Double(text[$0]) ?? .nan) }
    }
}

func fail(_ why: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(why)\n".utf8))
    exit(1)
}

/// The body, in the artwork's own coordinate space (y DOWN, spans about ±97).
func bloubBodyPath() -> CGPath {
    guard let from = bloubSource.range(of: "private static let start"),
          let to = bloubSource.range(of: "p.move(to: start)")
    else { fail("could not find the body table in Bloub.swift") }
    let values = numbers(in: String(bloubSource[from.lowerBound..<to.lowerBound]))
    // start x,y then curves of six.
    guard values.count >= 8, (values.count - 2) % 6 == 0 else {
        fail("body table is \(values.count) numbers, which is not a start plus curves")
    }
    let path = CGMutablePath()
    path.move(to: CGPoint(x: values[0], y: values[1]))
    for i in stride(from: 2, to: values.count, by: 6) {
        path.addCurve(to: CGPoint(x: values[i + 4], y: values[i + 5]),
                      control1: CGPoint(x: values[i], y: values[i + 1]),
                      control2: CGPoint(x: values[i + 2], y: values[i + 3]))
    }
    path.closeSubpath()
    return path
}

/// The attentive eyes — the face the product wears when it is paying attention,
/// which is the one the owner picked for the mark.
func bloubAttentiveEyes() -> [(size: CGSize, pose: CGAffineTransform)] {
    guard let line = bloubSource.range(of: "case .attentive: return")
    else { fail("could not find the attentive eyes in Bloub.swift") }
    let tail = bloubSource[line.upperBound...]
    guard let end = tail.range(of: "case .") else { fail("attentive entry never ends") }
    let v = numbers(in: String(tail[..<end.lowerBound]))
    guard v.count >= 16 else { fail("attentive entry has \(v.count) numbers, expected 16") }
    // Spelled out rather than mapped: the inferred tuple type defeated the
    // type-checker's time budget in a script with no module to cache it.
    var eyes: [(size: CGSize, pose: CGAffineTransform)] = []
    for o in [0, 8] {
        let size = CGSize(width: v[o], height: v[o + 1])
        let a: CGFloat = v[o + 2], b: CGFloat = v[o + 3]
        let c: CGFloat = v[o + 4], d: CGFloat = v[o + 5]
        let tx: CGFloat = v[o + 6], ty: CGFloat = v[o + 7]
        eyes.append((size, CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)))
    }
    return eyes
}

/// Apple's macOS icon grid: a 1024 canvas with the tile inset, so the system can
/// add its own shadow without clipping. 824/1024 with a 185 corner radius.
let canvas: CGFloat = 1024
let tileInset: CGFloat = 100
let tileCorner: CGFloat = 185

/// The sealed recess, as fractions of the tile. Generous, because the panel is
/// the icon's whole structure — a smaller one leaves the tile reading as an empty
/// square with a scratch on it.
let panelWidthFraction: CGFloat = 0.70
let panelHeightFraction: CGFloat = 0.60

/// The lamp. `0.055` of the tile rather than the sketch's `0.052` of the *panel*
/// — the difference is about 3× at small sizes, and it is what makes the bar
/// survive at 32px instead of thinning to nothing.
let lampWidthFraction: CGFloat = 0.40
let lampHeightFraction: CGFloat = 0.055

// sRGB, explicitly, and it is not a detail.
//
// `CGColor(red:green:blue:alpha:)` builds in GENERIC RGB, while `Theme` builds
// every colour with `NSColor(srgbRed:)`. Feeding the same numbers to both and
// rendering into a device-RGB context put the icon's body at #56B6F5 when the
// token says #3B93F0 — measured off the rendered PNG, not suspected. The icon
// and the in-app bloub were different blues from one source of truth, which is
// the exact failure that parsing the shape out of `Bloub.swift` was meant to
// prevent for the geometry.
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ tint: (r: Double, g: Double, b: Double), _ alpha: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [tint.r, tint.g, tint.b, alpha])!
}

/// Greys and the tile's own gradient, through the same space as everything else.
func grey(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func draw(into context: CGContext) {
    let tile = CGRect(x: tileInset, y: tileInset,
                      width: 1024 - tileInset * 2, height: 1024 - tileInset * 2)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tileCorner,
                          cornerHeight: tileCorner, transform: nil)

    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    // ── The tile: the app's own obsidian, lifted at the top so it reads as a
    //    surface catching light rather than a flat black square.
    context.drawLinearGradient(
        CGGradient(colorsSpace: space, colors: [
            grey(0.09, 0.12, 0.16),
            color(obsidian),
        ] as CFArray, locations: [0, 1])!,
        start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // ── The mark: the bloub, wearing the attentive face.
    //
    // It replaces the sealed recess and its lamp. The tile, its gradient and the
    // edge hairline all stay — the ground was never the part that needed to
    // change, and keeping it is what stops this reading as a different app.
    let body = bloubBodyPath()
    let art = body.boundingBoxOfPath
    guard art.width > 0, art.height > 0 else { fail("body path has no area") }

    // Fit the artwork into the tile, and FLIP: the artwork's y grows downward
    // (it came from SVG) while a bitmap context's grows upward. Without this the
    // cloud renders upside down, which reads as a slightly wrong blob rather
    // than as an obvious error — the worst kind.
    let margin: CGFloat = 0.62
    let scale = min(tile.width * margin / art.width, tile.height * margin / art.height)
    var fit = CGAffineTransform.identity
        .translatedBy(x: tile.midX, y: tile.midY)
        .scaledBy(x: scale, y: -scale)
        .translatedBy(x: -art.midX, y: -art.midY)

    // ── A glow under it, same trick the lamp used: at 32px the silhouette needs
    //    something separating it from the tile or it closes up into a dark lump.
    context.drawRadialGradient(
        CGGradient(colorsSpace: space, colors: [
            color(accent, 0.40), color(accent, 0),
        ] as CFArray, locations: [0, 1])!,
        startCenter: CGPoint(x: tile.midX, y: tile.midY), startRadius: 0,
        endCenter: CGPoint(x: tile.midX, y: tile.midY), endRadius: tile.width * 0.46,
        options: [])

    guard let fitted = body.copy(using: &fit) else { fail("could not place the body") }
    context.addPath(fitted)
    context.setFillColor(color(accent))
    context.fillPath()

    // ── The eyes, filled rather than knocked out. The app makes the same choice
    //    for the same reason: two fills give identical output to a mask here and
    //    cost no compositing group.
    context.setFillColor(color(eyeInk))
    for eye in bloubAttentiveEyes() {
        let box = CGRect(x: -eye.size.width / 2, y: -eye.size.height / 2,
                         width: eye.size.width, height: eye.size.height)
        var placed = eye.pose.concatenating(fit)
        let capsule = CGPath(roundedRect: box,
                             cornerWidth: min(box.width, box.height) / 2,
                             cornerHeight: min(box.width, box.height) / 2,
                             transform: &placed)
        context.addPath(capsule)
    }
    context.fillPath()

    // ── A hairline inside the tile's edge: the glass catching light, and it keeps
    //    the icon from dissolving into a dark Dock background.
    context.setStrokeColor(grey(1, 1, 1, 0.16))
    context.setLineWidth(5)
    context.addPath(tilePath)
    context.strokePath()

    context.restoreGState()
}

// MARK: - Render

func render(size: Int) -> Data {
    // The REP has to be sRGB too, not just the colours.
    //
    // With `.deviceRGB` here, an sRGB `CGColor` is converted on the way into the
    // bitmap and the body landed at #48A6F3 against a token of #3B93F0 — the
    // same class of shift as the generic-RGB one above, one stage later. Both
    // had to go. Verified by sampling the rendered PNG, which is the only thing
    // that actually settles a colour question.
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)?
        .retagging(with: NSColorSpace.sRGB),
        let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not make a \(size)px bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(into: context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(size)px")
    }
    return png
}

/// iconutil's required set — every nominal size needs its @2x twin.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    try! render(size: variant.pixels)
        .write(to: iconset.appendingPathComponent("\(variant.name).png"))
}
print("▸ rendered \(variants.count) sizes")

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
// The iconset is an intermediate; only the .icns is committed.
try? FileManager.default.removeItem(at: iconset)
print("✓ Resources/AppIcon.icns")
