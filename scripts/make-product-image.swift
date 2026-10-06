import AppKit

// 1600x1200 (4:3) for the Lemon Squeezy checkout and receipt.
//
// CGContext throughout, in PIXELS. NSImage.draw works in POINTS and silently
// doubles every rect on a 2x source — the bug that wrecked the first pass at
// cropping these screenshots.
let W = 1600, H = 1200
// Same resolution rule as release.sh's SITE_DIR, so the two agree about where
// the sibling site repo is: $AIRLOCK_SITE_DIR, else ../website.
let siteDir = ProcessInfo.processInfo.environment["AIRLOCK_SITE_DIR"] ?? "../website"
let shotPath = "\(siteDir)/assets/shots/home.png"
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "airlock-product.png"

guard let data = try? Data(contentsOf: URL(fileURLWithPath: shotPath)),
      let src = NSBitmapImageRep(data: data)?.cgImage else {
    FileHandle.standardError.write(Data("✗ no panel capture at \(shotPath)\n".utf8))
    exit(1)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// --paper-1, the site's ground. The checkout should look like the page they
// just came from.
ctx.setFillColor(CGColor(srgbRed: 0xf3/255.0, green: 0xf0/255.0, blue: 0xe9/255.0, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

// The panel hangs from the top edge, because that is what it does — square top
// corners flush to the boundary, rounded bottom, exactly like the app and the
// hero on the site.
let panelW = 1360.0
let panelH = panelW * Double(src.height) / Double(src.width)
let x = (Double(W) - panelW) / 2
let y = Double(H) - panelH                       // CGContext origin is bottom-left
let frame = CGRect(x: x, y: y, width: panelW, height: panelH)
let radius = 42.0                                // 20pt at the panel's 640pt width

func panelPath(_ r: CGRect, _ rad: Double) -> CGPath {
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

// Shadow first, on an opaque fill, so the blur is not drawn through the
// screenshot's own dark pixels and muddied.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 60,
              color: CGColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 0.34))
ctx.addPath(panelPath(frame, radius))
ctx.setFillColor(CGColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// Clip to the same path: the crop left slivers of wallpaper in the rounded
// bottom corners, and this removes them rather than hoping nobody looks.
ctx.saveGState()
ctx.addPath(panelPath(frame, radius))
ctx.clip()
ctx.draw(src, in: frame)
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("\(W)x\(H)")
