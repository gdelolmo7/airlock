import AppKit
import SwiftUI

/// What the panel actually composites, read from inside the process.
///
/// Exists because every STATE measurement of the invisible-island bug read
/// healthy — kit `.compact`, window at alpha 1.00, slots resolved, shoulders
/// laid out at full width — while the screen showed bare hardware. State logs
/// end at the view hierarchy. The two questions that remained were "is any
/// layer at opacity 0" and "do any pixels come out", and neither needs a
/// Screen Recording grant when the window is our own: the layer tree is
/// walkable, and `cacheDisplay` renders the view's model state to a bitmap
/// in-process.
///
/// The pixel line can return three verdicts, and each names a suspect:
///
///   opaque≈0            nothing composites — a stranded wrapper above the
///                       island shape, or a collapsed mask
///   opaque>0, lit≈0     the black shape draws and the CONTENT does not —
///                       the strand is inside the slots
///   opaque>0, lit>0     the model renders fine and the screen disagrees —
///                       the fault is below the view hierarchy, and only a
///                       real screen capture (`screencapture -l <win#>`) can
///                       see it
///
/// HoverTrace-gated by the caller and cheap enough for that: one walk and one
/// strided sample per transition, nothing when the trace is off.
@MainActor
enum LayerProbe {
    /// One line of pixel counts and one per abnormal layer or mask, ready for
    /// `HoverTrace.note`.
    static func report(window: NSWindow?) -> [String] {
        guard let view = window?.contentView else { return ["probe: no contentView"] }
        var lines: [String] = [pixels(of: view)]

        if let root = view.layer {
            var abnormal: [String] = []
            var masks: [String] = []
            var walked = 0
            walk(root, path: "L", depth: 0, walked: &walked,
                 abnormal: &abnormal, masks: &masks)
            if abnormal.isEmpty {
                lines.append("layers ok, walked \(walked), masks: "
                    + (masks.isEmpty ? "none" : masks.joined(separator: " | ")))
            } else {
                lines.append(contentsOf: abnormal.map { "layer " + $0 })
                if !masks.isEmpty { lines.append("masks: " + masks.joined(separator: " | ")) }
            }
        } else {
            lines.append("no root layer")
        }
        return lines
    }

    /// Model-tree opacities. A strand that survives indefinitely is model
    /// state by definition — a presentation-only glitch would end with its
    /// animation — so the model is the right tree to read.
    private static func walk(_ layer: CALayer, path: String, depth: Int,
                             walked: inout Int,
                             abnormal: inout [String], masks: inout [String]) {
        guard depth < 24, abnormal.count < 32 else { return }
        walked += 1
        if layer.opacity < 0.999 || layer.isHidden {
            abnormal.append(String(format: "%@ %@ o=%.3f%@ f=%@",
                                   path, String(describing: type(of: layer)),
                                   layer.opacity,
                                   layer.isHidden ? " HIDDEN" : "",
                                   NSStringFromRect(layer.frame)))
        }
        if let mask = layer.mask {
            masks.append(String(format: "%@ mask f=%@ o=%.2f",
                                path, NSStringFromRect(mask.frame), mask.opacity))
        }
        for (index, sub) in (layer.sublayers ?? []).enumerated() {
            walk(sub, path: path + ".\(index)", depth: depth + 1,
                 walked: &walked, abnormal: &abnormal, masks: &masks)
        }
    }

    /// Renders the view's model state and counts what came out. `opaque` is
    /// pixels with meaningful alpha; `lit` is the subset that is not black —
    /// the island's shape is black on a black cutout, so `opaque` without
    /// `lit` LOOKS like a bare notch and means the content, not the shape, is
    /// what went missing.
    private static func pixels(of view: NSView) -> String {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return "pixels: no rep"
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData, rep.samplesPerPixel == 4 else {
            return "pixels: unreadable format spp=\(rep.samplesPerPixel)"
        }
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let rowBytes = rep.bytesPerRow
        var opaque = 0, lit = 0
        // Every third pixel each way: blank-vs-drawn does not need a census.
        var y = 0
        while y < height {
            let row = data + y * rowBytes
            var x = 0
            while x < width {
                let p = row + x * 4
                // Premultiplied RGBA: alpha last, colour already scaled by it.
                if p[3] > 12 {
                    opaque += 1
                    if p[0] > 20 || p[1] > 20 || p[2] > 20 { lit += 1 }
                }
                x += 3
            }
            y += 3
        }
        return "pixels opaque=\(opaque) lit=\(lit) of \(width)x\(height)/9"
    }
}
