import AppKit
import OSLog
import AirlockCore

/// The island checking its own picture after every change (card C4).
///
/// The promise is that opening, closing, changing tab and entering or leaving
/// full screen never leave a black or empty box, content cut off at an edge,
/// or a panel the wrong size for what it shows. Every past break of that
/// promise was a picture the state disagreed with — the stranded fade in
/// `_hide`, the shoulders left at opacity 0, the tab fade that sat on its
/// first keyframe — and each one read healthy in every state log. So this
/// reads the PICTURE: the same in-process render `LayerProbe` uses, no Screen
/// Recording needed, measured once the change has had time to land.
///
/// Always on and silent while healthy: one short line in the unified log per
/// problem, never content, and nothing at all otherwise.
///
///     /usr/bin/log show --last 1d --predicate 'subsystem == "com.airlock.app" AND category == "frame"'
///
/// What it cannot see, said plainly: a single bad frame in the middle of an
/// animation. The settled checks run after the motion; the frame-by-frame
/// half (`motionProblems`) runs only inside the scripted loop, because
/// rendering the panel every frame costs frames.
@MainActor
enum FrameWatch {
    static let log = Logger(subsystem: "com.airlock.app", category: "frame")

    /// Problems written since launch. The scripted loop reports it.
    private(set) static var problemCount = 0
    /// The slowest measurement so far, in milliseconds — the price of the watch.
    private(set) static var slowestMeasure: Double = 0

    // MARK: - What is measured

    /// One look at the panel, reduced to numbers.
    struct Reading: Equatable {
        var presentation: IslandPresentation
        /// The kit's own state matches `presentation`.
        var kitAgrees: Bool
        var windowPresent: Bool
        var windowVisible: Bool
        var windowAlpha: CGFloat
        /// The island's drawn bounds in window points, top-left origin; nil
        /// when nothing at all draws.
        var shape: CGRect?
        var windowSize: CGSize
        var notchSize: CGSize
        /// Pixels that differ from the island's ground below the top bar —
        /// the panel's actual content.
        var contentBelowBar: Int
        /// The same, anywhere in the island.
        var content: Int
        /// Large layers left faded or hidden after the motion ended, named
        /// by class, size and opacity (never by what they show).
        var fadedLayers: [String]
        /// Points the panel's content is taller than the room it was given.
        var overflow: CGFloat
        /// A glass ground: the material does not render in-process, so the
        /// pixel checks have nothing to compare against and stand down.
        var glassGround: Bool
        /// The pointer is on the island. The kit deepens its shadow then, and
        /// a shadow is pixels the picture cannot tell from the island's own.
        var hovering = false
    }

    enum Problem: String, CaseIterable {
        /// The kit is not in the state it was asked for.
        case kitDisagrees
        /// Window missing, hidden, faded, or drawing nothing.
        case invisible
        /// A compact island at panel size, or a panel at island size.
        case wrongSize
        /// A shape with nothing in it.
        case blackBox
        /// Content cut off at the panel's or the window's edge.
        case clipped
        /// A large part of the content left faded out.
        case faded
        /// The panel's height leapt between two frames.
        case jump
        /// The panel reached full size and stayed empty for frames after.
        case lateContent
    }

    /// Room left for the island above its own notch height before a compact
    /// island counts as panel-sized. A hover grows it to the menu bar's
    /// height, which is a few points either way of the notch.
    static let compactSlack: CGFloat = 12
    /// The least a real panel adds below the notch band.
    static let expandedMinimum: CGFloat = 24
    /// A layer this large, left faded, is content and not a dimmed glyph.
    static let fadedLayerMinimum = CGSize(width: 120, height: 40)

    /// The settled verdict. Pure, so the rules are tested without a window.
    static func problems(_ r: Reading) -> [Problem] {
        var found: [Problem] = []
        if !r.kitAgrees { found.append(.kitDisagrees) }
        // Hidden is no panel; there is no picture to hold to anything.
        guard r.presentation != .hidden else { return found }
        guard r.windowPresent, r.windowVisible, r.windowAlpha >= 0.99, let shape = r.shape else {
            return found + [.invisible]
        }
        switch r.presentation {
        case .compact where !r.hovering && shape.height > r.notchSize.height + compactSlack,
             .expanded where shape.height < r.notchSize.height + expandedMinimum:
            found.append(.wrongSize)
        default: break
        }
        if !r.glassGround {
            switch r.presentation {
            case .expanded where r.contentBelowBar == 0:
                found.append(.blackBox)
            // Shoulders exist (the island is wider than the cutout) and hold nothing.
            case .compact where r.content == 0 && shape.width > r.notchSize.width + 30:
                found.append(.blackBox)
            default: break
            }
        }
        let edge: CGFloat = 1
        if r.overflow > 1 || shape.minX <= edge || shape.maxX >= r.windowSize.width - edge
            || shape.maxY >= r.windowSize.height - edge {
            found.append(.clipped)
        }
        // Only an open panel's: closing leaves the panel's content in the
        // tree at opacity 0 for a moment, below the island where nothing
        // draws (measured on the installed app, every close). A closed
        // island that lost its own content is a black box above, by pixels.
        if r.presentation == .expanded, !r.fadedLayers.isEmpty { found.append(.faded) }
        return found
    }

    // MARK: - Frame by frame

    /// One frame of a change, sampled by the scripted loop.
    struct Sample: Equatable {
        var time: TimeInterval
        var height: CGFloat
        var hasContent: Bool
    }

    /// A step bigger than this share of the whole travel, between two frames
    /// that really were consecutive, is a jump and not motion.
    static let jumpShare: CGFloat = 0.6
    /// Two samples further apart than this were not consecutive frames, and
    /// a big step between them says nothing.
    static let consecutive: TimeInterval = 0.07
    /// Movement this small, as a share of the travel (and never under 4pt),
    /// is standing still. A snap stands still on both sides of its step; a
    /// spring's fastest stretch can cover as much ground between two looks,
    /// but it is still moving after it.
    static let restShare: CGFloat = 0.05
    /// Frames a panel may stand at full size before its content arrives —
    /// the card's "a frame or two".
    static let lateFrames = 2

    /// `glassGround`: the glass itself does not render in-process, so on glass
    /// a picture's height is only its content's. A picture with nothing in it
    /// has no height to read, and the jump rule leaves it out.
    ///
    /// `reduceMotion`: the calm versions change size in one step on purpose
    /// (`Motion`), so a jump is the design there and is not looked for.
    static func motionProblems(_ samples: [Sample], presentation: IslandPresentation,
                               glassGround: Bool = false,
                               reduceMotion: Bool = false) -> [Problem] {
        guard let last = samples.last, samples.count > 2 else { return [] }
        var found: [Problem] = []
        let heights = glassGround ? samples.filter(\.hasContent) : samples
        if !reduceMotion, let first = heights.first, let end = heights.last,
           abs(end.height - first.height) >= 20 {
            let travel = abs(end.height - first.height)
            let still = max(4, restShare * travel)
            func rests(_ i: Int, _ j: Int) -> Bool {
                !heights.indices.contains(i) || !heights.indices.contains(j)
                    || abs(heights[i].height - heights[j].height) <= still
            }
            for i in heights.indices.dropLast() {
                let a = heights[i], b = heights[i + 1]
                if b.time - a.time <= consecutive, abs(b.height - a.height) > jumpShare * travel,
                   rests(i - 1, i), rests(i + 1, i + 2) {
                    found.append(.jump)
                    break
                }
            }
        }
        if presentation == .expanded,
           let arrived = samples.firstIndex(where: { abs($0.height - last.height) <= 2 }) {
            var empty = 0
            for sample in samples[arrived...] {
                empty = sample.hasContent ? 0 : empty + 1
                if empty > lateFrames {
                    found.append(.lateContent)
                    break
                }
            }
        }
        return found
    }

    // MARK: - Reading the panel

    /// Renders the panel's model state and measures it.
    static func read(window: NSWindow?, presentation: IslandPresentation, kitAgrees: Bool,
                     notchSize: CGSize, overflow: CGFloat, glassGround: Bool,
                     hovering: Bool) -> Reading {
        let began = Date()
        defer { slowestMeasure = max(slowestMeasure, Date().timeIntervalSince(began) * 1000) }
        var reading = Reading(presentation: presentation, kitAgrees: kitAgrees,
                              windowPresent: window != nil,
                              windowVisible: window?.isVisible ?? false,
                              windowAlpha: window?.alphaValue ?? 0,
                              shape: nil, windowSize: window?.frame.size ?? .zero,
                              notchSize: notchSize, contentBelowBar: 0, content: 0,
                              fadedLayers: [], overflow: overflow, glassGround: glassGround,
                              hovering: hovering)
        guard presentation != .hidden, let view = window?.contentView else { return reading }
        let pixels = Pixels(view: view)
        reading.shape = pixels?.shape
        if let pixels, let shape = pixels.shape {
            let counts = pixels.content(in: shape, belowY: notchSize.height + 6)
            reading.content = counts.all
            reading.contentBelowBar = counts.below
        }
        if let root = view.layer { reading.fadedLayers = fadedLayers(under: root) }
        return reading
    }

    /// How much of the window, from the top, a frame sample renders. The
    /// panel lives at the top and rendering all of a full-height window took
    /// longer than a frame; past the band a height reads as the band, which a
    /// jump cannot hide behind.
    static let sampleBand: CGFloat = 520

    /// Samples the panel's height every frame for `duration` seconds.
    /// The window is asked for each frame: a conversion from hidden builds a
    /// new one partway through.
    static func sample(window: () -> NSWindow?, duration: TimeInterval,
                       notchSize: CGSize) async -> [Sample] {
        let began = Date()
        var samples: [Sample] = []
        while Date().timeIntervalSince(began) < duration {
            if let view = window()?.contentView, let pixels = Pixels(view: view, band: sampleBand) {
                let shape = pixels.shape
                let content = shape.map { pixels.content(in: $0, belowY: notchSize.height + 6).below } ?? 0
                samples.append(Sample(time: Date().timeIntervalSince(began),
                                      height: shape?.height ?? 0, hasContent: content > 0))
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        return samples
    }

    /// One line per problem. `context` is what changed — a presentation or a
    /// tab name — never anything the panel shows.
    static func report(_ problems: [Problem], context: String, reading: Reading?) {
        for problem in problems {
            problemCount += 1
            let detail = reading.map(describe) ?? ""
            log.error("\(problem.rawValue, privacy: .public) after \(context, privacy: .public) \(detail, privacy: .public)")
            HoverTrace.note("frame ⚠︎ \(problem.rawValue) after \(context) \(detail)")
        }
    }

    static func describe(_ r: Reading) -> String {
        let shape = r.shape.map { String(format: "%.0fx%.0f@%.0f,%.0f", $0.width, $0.height, $0.minX, $0.minY) }
            ?? "none"
        let faded = r.fadedLayers.isEmpty ? "0" : r.fadedLayers.joined(separator: ",")
        return String(format: "shape=%@ alpha=%.2f visible=%@ content=%d below=%d faded=%@ overflow=%.0f",
                      shape, r.windowAlpha, r.windowVisible ? "yes" : "no",
                      r.content, r.contentBelowBar, faded, r.overflow)
    }

    // MARK: - Pixels and layers

    /// Large layers below full opacity, in the model tree. Small ones are
    /// dimmed glyphs and secondary text, which is design and not a strand.
    private static func fadedLayers(under root: CALayer) -> [String] {
        var found: [String] = []
        var stack: [(CALayer, Int)] = [(root, 0)]
        while let (layer, depth) = stack.popLast() {
            // Liquid Glass's own shape layer rests at opacity 0 by design:
            // the window server draws it, nothing in-process does.
            if String(describing: type(of: layer)).contains("SDF") { continue }
            if layer.opacity < 0.95 || layer.isHidden,
               layer.bounds.width >= fadedLayerMinimum.width,
               layer.bounds.height >= fadedLayerMinimum.height {
                found.append(String(format: "%@ %.0fx%.0f %@", String(describing: type(of: layer)),
                                    layer.bounds.width, layer.bounds.height,
                                    layer.isHidden ? "hidden" : String(format: "%.2f", layer.opacity)))
                continue // what is under a faded layer is faded with it
            }
            guard depth < 24 else { continue }
            for sub in layer.sublayers ?? [] { stack.append((sub, depth + 1)) }
        }
        return found
    }

    /// The panel rendered once, read at every second pixel each way.
    @MainActor private struct Pixels {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        /// In window points, top-left origin.
        let shape: CGRect?

        static let stride = 2

        /// `band`: only this many points from the top, or the whole window.
        init?(view: NSView, band: CGFloat? = nil) {
            var rect = view.bounds
            if let band, band < rect.height {
                rect = CGRect(x: 0, y: view.isFlipped ? 0 : rect.height - band,
                              width: rect.width, height: band)
            }
            // One pixel a point, not the screen's two: the questions asked
            // here are a few points wide, and the render is the whole cost of
            // a look — at full resolution a settled look took up to 0.44s,
            // long enough to be the hitch this card is about.
            guard rect.width >= 1, rect.height >= 1,
                  let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: Int(rect.width), pixelsHigh: Int(rect.height),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 32) else { return nil }
            rep.size = rect.size
            view.cacheDisplay(in: rect, to: rep)
            guard rep.bitmapData != nil, rep.samplesPerPixel == 4, view.bounds.width > 0 else { return nil }
            self.rep = rep
            scale = CGFloat(rep.pixelsWide) / view.bounds.width
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            Self.each(rep) { x, y, p in
                guard p[3] > 12 else { return }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
            shape = maxX < 0 ? nil
                : CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                         width: CGFloat(maxX - minX + Self.stride) / scale,
                         height: CGFloat(maxY - minY + Self.stride) / scale)
        }

        /// Pixels unlike the ground, which is read from the island's own
        /// bottom margin — black on the black ground, so this is "lit" there,
        /// and the right question on any other opaque ground too.
        func content(in shape: CGRect, belowY: CGFloat) -> (all: Int, below: Int) {
            guard let data = rep.bitmapData else { return (0, 0) }
            let gx = Int(shape.midX * scale), gy = Int((shape.maxY - 4) * scale)
            guard gx >= 0, gy >= 0, gx < rep.pixelsWide, gy < rep.pixelsHigh else { return (0, 0) }
            let g = data + gy * rep.bytesPerRow + gx * 4
            let ground = (Int(g[0]), Int(g[1]), Int(g[2]))
            let barLine = Int(belowY * scale)
            var all = 0, below = 0
            Self.each(rep) { _, y, p in
                guard p[3] > 12 else { return }
                if abs(Int(p[0]) - ground.0) > 24 || abs(Int(p[1]) - ground.1) > 24
                    || abs(Int(p[2]) - ground.2) > 24 {
                    all += 1
                    if y > barLine { below += 1 }
                }
            }
            return (all, below)
        }

        /// Visits every second pixel each way; rows run top to bottom.
        private static func each(_ rep: NSBitmapImageRep,
                                 _ visit: (Int, Int, UnsafeMutablePointer<UInt8>) -> Void) {
            guard let data = rep.bitmapData else { return }
            var y = 0
            while y < rep.pixelsHigh {
                let row = data + y * rep.bytesPerRow
                var x = 0
                while x < rep.pixelsWide {
                    visit(x, y, row + x * 4)
                    x += stride
                }
                y += stride
            }
        }
    }
}
