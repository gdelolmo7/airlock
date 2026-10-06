import AppKit

let cyan  = CGColor(red: 0.353, green: 0.784, blue: 0.980, alpha: 1)
let amber = CGColor(red: 0.961, green: 0.647, blue: 0.141, alpha: 1)
let ink   = CGColor(red: 0.020, green: 0.024, blue: 0.031, alpha: 1)
let canvas: CGFloat = 1024, pad: CGFloat = 100, corner: CGFloat = 185
let space = CGColorSpaceCreateDeviceRGB()
func tile() -> CGRect { CGRect(x: pad, y: pad, width: 1024 - pad*2, height: 1024 - pad*2) }
func tilePath() -> CGPath {
    CGPath(roundedRect: tile(), cornerWidth: corner, cornerHeight: corner, transform: nil)
}
/// The notch profile: square at the bezel, rounded below.
func notch(_ r: CGRect) -> CGPath {
    let rad = r.height * 0.40
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY),
             tangent2End: CGPoint(x: r.minX + rad, y: r.minY), radius: rad)
    p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY),
             tangent2End: CGPoint(x: r.maxX, y: r.minY + rad), radius: rad)
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
    p.closeSubpath()
    return p
}
func darkTile(_ g: CGContext) {
    g.addPath(tilePath()); g.clip()
    g.drawLinearGradient(CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.09, green: 0.12, blue: 0.16, alpha: 1), ink] as CFArray,
        locations: [0, 1])!,
        start: CGPoint(x: 0, y: tile().maxY), end: CGPoint(x: 0, y: tile().minY), options: [])
}

/// A — DOOR AJAR. The notch is a sealed hatch with light escaping the seam.
func a(_ g: CGContext) {
    let t = tile(); g.saveGState(); darkTile(g)
    let w = t.width * 0.62, h = t.height * 0.30
    let n = CGRect(x: t.midX - w/2, y: t.maxY - h, width: w, height: h)
    g.addPath(notch(n)); g.setFillColor(ink); g.fillPath()
    // The seam: light forcing its way out of a closed chamber.
    let seam = CGRect(x: n.midX - t.width * 0.018, y: n.minY, width: t.width * 0.036, height: h)
    g.drawRadialGradient(CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.353, green: 0.784, blue: 0.980, alpha: 0.75),
        CGColor(red: 0.353, green: 0.784, blue: 0.980, alpha: 0)] as CFArray, locations: [0,1])!,
        startCenter: CGPoint(x: n.midX, y: n.minY + h*0.35), startRadius: 0,
        endCenter: CGPoint(x: n.midX, y: n.minY + h*0.35), endRadius: t.width*0.30, options: [])
    g.setFillColor(CGColor(red: 0.80, green: 0.95, blue: 1, alpha: 1))
    g.addPath(CGPath(roundedRect: seam, cornerWidth: seam.width/2,
                     cornerHeight: seam.width/2, transform: nil)); g.fillPath()
    g.restoreGState()
}

/// C — CHAMBER. Two doors, a gap between them, the gap's head is the notch.
func c(_ g: CGContext) {
    let t = tile(); g.saveGState(); darkTile(g)
    let gap = t.width * 0.20
    let barW = (t.width - gap) / 2 - t.width * 0.10
    for x in [t.midX - gap/2 - barW, t.midX + gap/2] {
        let bar = CGRect(x: x, y: t.minY + t.height*0.18, width: barW, height: t.height*0.64)
        g.setFillColor(cyan)
        g.addPath(CGPath(roundedRect: bar, cornerWidth: barW*0.22,
                         cornerHeight: barW*0.22, transform: nil)); g.fillPath()
    }
    // The notch, spanning the gap — the one way through.
    let n = CGRect(x: t.midX - gap/2 - barW*0.30, y: t.maxY - t.height*0.26,
                   width: gap + barW*0.60, height: t.height*0.26)
    g.addPath(notch(n)); g.setFillColor(ink); g.fillPath()
    g.restoreGState()
}

/// D — STATUS LIGHT. A sealed recess with one bar of light at its lip.
func d(_ g: CGContext) {
    let t = tile(); g.saveGState(); darkTile(g)
    let panel = CGRect(x: t.minX + t.width*0.14, y: t.minY + t.height*0.16,
                       width: t.width*0.72, height: t.height*0.62)
    g.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    g.addPath(CGPath(roundedRect: panel, cornerWidth: panel.width*0.16,
                     cornerHeight: panel.width*0.16, transform: nil)); g.fillPath()
    let lamp = CGRect(x: panel.midX - panel.width*0.30, y: panel.maxY - panel.height*0.16,
                      width: panel.width*0.60, height: panel.height*0.085)
    g.drawRadialGradient(CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.353, green: 0.784, blue: 0.980, alpha: 0.60),
        CGColor(red: 0.353, green: 0.784, blue: 0.980, alpha: 0)] as CFArray, locations: [0,1])!,
        startCenter: CGPoint(x: lamp.midX, y: lamp.midY), startRadius: 0,
        endCenter: CGPoint(x: lamp.midX, y: lamp.midY), endRadius: t.width*0.34, options: [])
    g.setFillColor(cyan)
    g.addPath(CGPath(roundedRect: lamp, cornerWidth: lamp.height/2,
                     cornerHeight: lamp.height/2, transform: nil)); g.fillPath()
    g.restoreGState()
}

/// E — THRESHOLD. The tile split by the notch: lit above, sealed below.
func e(_ g: CGContext) {
    let t = tile(); g.saveGState(); g.addPath(tilePath()); g.clip()
    g.setFillColor(cyan); g.fill(t)
    // Everything below the interlock is the sealed side.
    let split = t.minY + t.height * 0.52
    let h = t.height * 0.22, w = t.width * 0.46
    let lower = CGMutablePath()
    lower.addRect(CGRect(x: t.minX, y: t.minY, width: t.width, height: split - t.minY))
    lower.addPath(notch(CGRect(x: t.midX - w/2, y: split, width: w, height: h)))
    g.addPath(lower); g.setFillColor(ink); g.fillPath()
    // A hairline of pressure light along the threshold.
    g.setStrokeColor(CGColor(red: 0.85, green: 0.97, blue: 1, alpha: 0.9))
    g.setLineWidth(7); g.addPath(lower); g.strokePath()
    g.restoreGState()
}

func write(_ name: String, _ body: (CGContext) -> Void, _ px: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: CGFloat(px)/canvas, y: CGFloat(px)/canvas)
    body(ctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "air-\(name)-\(px).png"))
}
for (n, f) in [("a", a), ("c", c), ("d", d), ("e", e)] as [(String, (CGContext) -> Void)] {
    write(n, f, 512); write(n, f, 32)
}
print("ok")
